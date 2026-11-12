#!/usr/bin/env python3
"""提交前的个人信息 / 凭据体检。

用途：仓库是公开的，任何一次 push 都会把内容永久留在 GitHub 上
（即使事后删除文件，旧 commit 仍可访问）。所以在提交之前就挡掉。

用法：
    python tools/secret_check.py              # 扫全部已跟踪文件
    python tools/secret_check.py --staged     # 只扫暂存区（供 pre-commit 用）
    python tools/secret_check.py --history    # 扫全部历史提交（较慢，用于审计）

退出码：0 = 干净，1 = 发现问题。

误报怎么办：在该行加注释 `# secret-check: allow`，或在
tools/secret_check_allow.txt 里写一条正则（一行一条，# 开头为注释）。
"""
import argparse
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 本文件自己会包含各种"像密钥"的字样，扫的时候跳过
SELF = os.path.join("tools", "secret_check.py")
ALLOW_FILE = os.path.join(REPO, "tools", "secret_check_allow.txt")
ALLOW_MARK = "secret-check: allow"

# 二进制/资源文件不做文本扫描
BINARY_EXT = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".zip", ".pdf", ".ttf", ".otf"}

# ── 规则表 ────────────────────────────────────────────────────────
# 每条：(编号, 说明, 正则)
# 正则用字符串拼接/分组写，避免本文件自己被扫中
RULES = [
    # 和风天气：api_key / api_host 只要填了值就得拦（留空 "" 是正常的模板）
    ("KEY-01", "写死的 api_key",
     r"""\bapi_key\b\s*=\s*["'][^"'\s]{6,}["']"""),
    ("KEY-02", "写死的 api_host",
     r"""\bapi_host\b\s*=\s*["'][A-Za-z0-9.-]{6,}\.[A-Za-z]{2,}["']"""),
    ("KEY-03", "OpenAI 风格密钥 sk-…",
     "sk" + r"""-[A-Za-z0-9_\-]{20,}"""),
    ("KEY-04", "请求头里的密钥",
     r"""["']X-QW-Api-Key["']\s*\]\s*=\s*["'][^"'\s]{6,}["']"""),
    ("KEY-05", "通用 secret / token / password 赋值",
     r"""(?i)\b(secret|token|passwd|password|credential)[A-Za-z_]*\b\s*[:=]\s*["'][^"'\s]{8,}["']"""),
    ("KEY-06", "私钥块",
     "-" * 5 + r"BEGIN [A-Z ]*" + "PRIVATE" + r" KEY" + "-" * 5),
    ("KEY-07", "云厂商/平台令牌",
     r"""(AIza[0-9A-Za-z_\-]{30,}|ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|xox[baprs]-[A-Za-z0-9\-]{10,}|AKIA[0-9A-Z]{16})"""),
    ("KEY-08", "带凭据的 URL",
     r"""[a-z][a-z0-9+.\-]*://[^\s/:@]+:[^\s/:@]{4,}@"""),

    # 本机身份 / 位置
    ("ID-01", "本机绝对路径（暴露用户名）",
     r"""[A-Za-z]:[\\/]+(Users|用户)[\\/]+[^\\/\s"']+"""),
    ("ID-02", "类 Unix 家目录绝对路径",
     r"""/(home|Users)/[A-Za-z0-9._\-]+(?:/|\b)"""),
    ("ID-03", "邮箱地址",
     r"""[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"""),
    ("ID-04", "中国大陆手机号",
     r"""(?<!\d)1[3-9]\d{9}(?!\d)"""),
    ("ID-05", "MAC 地址",
     r"""(?i)\b(?:[0-9a-f]{2}:){5}[0-9a-f]{2}\b"""),
    ("ID-06", "内网 / 具体 IP",
     r"""(?<![\w.])(?!0\.0\.0\.0|127\.0\.0\.1|255\.255\.255\.255|1\.1\.1\.1|8\.8\.8\.8)
         (?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?![\w.])"""),
]

# 二进制资源里藏的个人信息：靠文件名挡（图片里的昵称/收款码扫不出来）
NAME_RULES = [
    ("ID-07", "个人收款/赞赏码图片", r"(?i)(wechat|weixin|alipay|wxpay)[\-_]?(reward|pay|donate|qrcode|qr)"),
    ("ID-08", "疑似个人资料/证件图片", r"(?i)(idcard|shenfenzheng|passport|driverlicen[cs]e|hukou)"),
]

# 允许出现的常规值（避免误报）
WHITELIST_VALUES = {
    "0.0.0.0", "127.0.0.1", "255.255.255.255",
    "127.0.0.1:8080",
}


def load_allow_patterns():
    pats = []
    if os.path.exists(ALLOW_FILE):
        with open(ALLOW_FILE, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#"):
                    pats.append(re.compile(line))
    return pats


def compile_rules():
    out = []
    for code, desc, pat in RULES:
        out.append((code, desc, re.compile(pat, re.X if "\n" in pat else 0)))
    return out


def iter_text_files(paths):
    for rel in paths:
        ext = os.path.splitext(rel)[1].lower()
        if ext in BINARY_EXT:
            continue
        full = os.path.join(REPO, rel)
        if not os.path.isfile(full):
            continue
        try:
            with open(full, "rb") as f:
                raw = f.read()
        except OSError:
            continue
        if b"\0" in raw[:8000]:      # 二进制
            continue
        yield rel, raw.decode("utf-8", errors="replace")


def scan_text(rel, text, rules, allows, findings, note=""):
    tag = f"（{note}）" if note else ""
    # 文件名规则
    base = os.path.basename(rel)
    if not any(a.search(rel) for a in allows):
        for code, desc, rx in [(c, d, re.compile(p)) for c, d, p in NAME_RULES]:
            if rx.search(base) or rx.search(rel):
                findings.append((rel, 0, code, desc + tag, rel))
    for lineno, line in enumerate(text.splitlines(), 1):
        if ALLOW_MARK in line:
            continue
        for code, desc, rx in rules:
            m = rx.search(line)
            if not m:
                continue
            hit = m.group(0)
            if hit.strip() in WHITELIST_VALUES:
                continue
            if any(a.search(line) for a in allows):
                continue
            findings.append((rel, lineno, code, desc + tag, hit))
            break


def mask(s, keep=6):
    s = s.strip()
    if len(s) <= keep + 4:
        return s[:3] + "***"
    return s[:keep] + "…" + s[-2:]


def git(*args, **kw):
    return subprocess.run(["git"] + list(args), cwd=REPO,
                          capture_output=True, **kw)


def tracked_files():
    r = git("ls-files", "-z")
    return [p for p in r.stdout.decode("utf-8", "replace").split("\0") if p]


def staged_files():
    r = git("diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z")
    return [p for p in r.stdout.decode("utf-8", "replace").split("\0") if p]


def history_scan(rules, allows):
    """扫全部历史版本的文件内容（含已删除的文件）。"""
    findings = []
    commits = git("rev-list", "--all").stdout.decode().split()
    r = git("log", "--all", "--pretty=format:@@%h", "--name-only")
    cur, seen = None, set()
    for line in r.stdout.decode("utf-8", "replace").splitlines():
        if line.startswith("@@"):
            cur = line[2:]
            continue
        rel = line.strip()
        if not rel:
            continue
        if (cur, rel) in seen:
            continue
        seen.add((cur, rel))
        if os.path.splitext(rel)[1].lower() in BINARY_EXT:
            scan_text(rel, "", rules, allows, findings, note=f"历史 {cur}")
            continue
        blob = git("show", f"{cur}:{rel}")
        if blob.returncode != 0 or b"\0" in blob.stdout[:8000]:
            continue
        scan_text(rel, blob.stdout.decode("utf-8", "replace"),
                  rules, allows, findings, note=f"历史 {cur}")
    return findings, len(commits)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--staged", action="store_true", help="只扫暂存区")
    ap.add_argument("--history", action="store_true", help="扫全部历史提交")
    args = ap.parse_args()

    rules = compile_rules()
    allows = load_allow_patterns()
    findings = []

    if args.history:
        findings, n = history_scan(rules, allows)
        scope = f"全部历史（{n} 个提交）"
    else:
        files = staged_files() if args.staged else tracked_files()
        scope = f"暂存区（{len(files)} 个文件）" if args.staged else f"已跟踪文件（{len(files)} 个）"
        # 文件名规则对二进制同样生效（图片里的昵称扫不出来，只能认文件名）
        text_files = {rel for rel, _ in iter_text_files(files)}
        for rel in files:
            if rel.replace(os.sep, "/") == SELF.replace(os.sep, "/"):
                continue
            text = ""
            if rel in text_files:
                with open(os.path.join(REPO, rel), "rb") as f:
                    text = f.read().decode("utf-8", errors="replace")
            scan_text(rel, text, rules, allows, findings)

    print(f"[secret-check] 扫描范围：{scope}")
    if not findings:
        print("[secret-check] PASS：未发现凭据或个人信息")
        return 0

    print(f"[secret-check] 发现 {len(findings)} 处可疑内容：\n")
    for rel, lineno, code, desc, hit in findings:
        loc = f"{rel}:{lineno}" if lineno else rel
        print(f"  [{code}] {desc}")
        print(f"     位置 {loc}")
        print(f"     内容 {mask(hit)}\n")
    print("处理方式：把真实值移到 dashboard_config.local.lua（已被 .gitignore 排除），")
    print("代码里留空字符串；确属误报则在行尾加注释 `# secret-check: allow`。")
    return 1


if __name__ == "__main__":
    sys.exit(main())
