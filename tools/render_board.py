"""把桩件导出的最终帧画成 PNG，用来出 README 的版面预览图。

和 tools/render_png.py 的区别：那个是「快速目视检查有没有越界」，字号一律按高度估、
图标画成黑方块；这个要给人看，所以：

  · 按控件实测的 h 反推行数，再按行宽折行（多行文案不会被画成一行大字）；
  · 单行塞不下时按 Kindle 的做法**截断加省略号**，而不是把字号缩到看不清；
  · 图标用 icons/ 里的真 PNG（黑墨 + alpha），不画方块；
  · 区分正文（黑）与注释（灰）；
  · 2 倍超采样后降采样，文字边缘不会有锯齿。

数据注入走桩件的环境变量（STUB_POWER / STUB_WIFI / STUB_READING / STUB_PREVIEW），
只在出图时生效，测试不受影响。「现在」由本文件的 ANCHOR 钉死（含 STUB_NOW 注入），
否则每跑一次时钟和「更新于」都会变，README 的图天天换脸。

用法（项目根目录）：
    python tools/render_board.py                # 中文全量：首图 portrait.png + 五竖五横
    python tools/render_board.py en             # 出全部 10 张英文图到 preview/en/
    python tools/render_board.py en landscape   # 英文 + 只出横屏
    python tools/render_board.py portrait       # 只出竖屏（中文）
    python tools/render_board.py 2              # 只出第 2 套（所选语言）
"""

import atexit
import datetime
import os
import shutil
import subprocess
import sys
import tempfile
import uuid

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT_DIR = os.path.join(ROOT, "preview")
PLUGIN = "dashboard.koplugin"

# 真机 PW3：原生竖屏 1072×1448，横屏 = 把这块 framebuffer 转 90°
NATIVE_W, NATIVE_H = 1072, 1448
SCALE = 2                    # 超采样倍数
BLACK, GRAY = 0, 105         # 桩件里的 COLOR_BLACK=255 / COLOR_DARK_GRAY=85

# 出图锚点：日期和时刻都钉死。真机时钟走的是系统时间，不钉的话每次出图都是一个新的
# 时刻，README 的图会天天换脸，文章里「写这段的时候，屏幕上是十月初四」也会对不上。
# 16:18 = 十月初四 / 立冬第 6 天 / 距小雪 10 天（2026-11-12）。
ANCHOR = datetime.datetime(2026, 11, 12, 16, 18,
                           tzinfo=datetime.timezone(datetime.timedelta(hours=8)))

FONT_CANDIDATES = [
    r"C:\Windows\Fonts\msyh.ttc",
    r"C:\Windows\Fonts\msyhl.ttc",
    r"C:\Windows\Fonts\simhei.ttf",
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
    "/System/Library/Fonts/PingFang.ttc",
]

RUNNER = """
import sys
sys.path.insert(0, r"%s")
from lupa import LuaRuntime
from run_stub import install_bridges
lua = LuaRuntime(unpack_returned_tuples=True)
install_bridges(lua)
lua.execute(sys.stdin.read())
""" % HERE


# --------------------------------------------------------------------- 素材与字体
_font_cache = {}


def font(px):
    """按像素高度取字体。px 是已乘过 SCALE 的画布像素。"""
    key = max(6, int(round(px)))
    if key in _font_cache:
        return _font_cache[key]
    for path in FONT_CANDIDATES:
        if os.path.exists(path):
            f = ImageFont.truetype(path, key)
            _font_cache[key] = f
            return f
    f = ImageFont.load_default()
    _font_cache[key] = f
    return f


def text_w(draw, s, f):
    return draw.textlength(s, font=f)


def wrap(draw, text, f, limit):
    """折行：中文按字断，英文按词断（词比一行还宽时退回按字断）。"""
    if limit <= 1:
        return [text]
    lines, cur = [], ""
    tokens = []
    for ch in text:
        if ch == " ":
            tokens.append(" ")
        elif ch.isascii() and ch.isalnum():
            if tokens and tokens[-1] and tokens[-1][-1].isascii() and tokens[-1][-1].isalnum():
                tokens[-1] += ch
            else:
                tokens.append(ch)
        else:
            tokens.append(ch)
    for tk in tokens:
        cand = cur + tk
        if text_w(draw, cand, f) <= limit or not cur:
            # 「第一个 token 就超宽」时按字拆开
            if not cur and text_w(draw, tk, f) > limit:
                for ch in tk:
                    if text_w(draw, cur + ch, f) <= limit or not cur:
                        cur += ch
                    else:
                        lines.append(cur)
                        cur = ch
                continue
            cur = cand
        else:
            lines.append(cur)
            cur = tk
    if cur:
        lines.append(cur)
    return lines or [""]


def ellipsize(draw, text, f, limit):
    """一行放不下：截断加省略号（与 TextWidget 的 truncate_with_ellipsis 一致）。"""
    if text_w(draw, text, f) <= limit:
        return text
    for i in range(len(text) - 1, 0, -1):
        cand = text[:i] + "…"
        if text_w(draw, cand, f) <= limit:
            return cand
    return "…"


# ------------------------------------------------------------------- 设置目录
# 封面缓存要真的落盘（在读卡靠 dashboard_cover 写 PNG 再交给 ImageWidget 画），
# 整个出图过程共用一个临时目录，进程退出时删掉——不往真机设置目录里写东西。
_SETTINGS_DIR = None


def settings_dir():
    global _SETTINGS_DIR
    if _SETTINGS_DIR is None:
        _SETTINGS_DIR = tempfile.mkdtemp(prefix="dashboard_preview_")
        os.makedirs(os.path.join(_SETTINGS_DIR, "dashboard_covers"), exist_ok=True)
        atexit.register(shutil.rmtree, _SETTINGS_DIR, True)
    return _SETTINGS_DIR.replace(os.sep, "/")


# --------------------------------------------------------------------- 取帧
def lua_str(s):
    """Lua 长字符串最稳：这些文案里有中文、空格、书名号，不用逐个转义。"""
    return "[[" + str(s).replace("]]", "]] .. ']' .. [[") + "]]"


def agenda_block(agenda):
    """把样例倒数日 / 待办写成 Lua 表，日期一律相对 ANCHOR 现算。

    写死日期的话，过几天出图就会变成「已过 30 天」，README 里的图看着像坏了。
    """
    today = ANCHOR.date()

    def day(off):
        return (today + datetime.timedelta(days=off)).isoformat()

    events = []
    for name, off, pinned in agenda.get("events", []):
        events.append("{name=%s, date=%s, pinned=%s}"
                      % (lua_str(name), lua_str(day(off)), "true" if pinned else "false"))
    todos = []
    for text, off, done in agenda.get("todos", []):
        todos.append("{text=%s, date=%s, done=%s}"
                     % (lua_str(text), lua_str(day(off)), "true" if done else "false"))
    return ("STUB_AGENDA = { events = {%s}, todos = {%s}, seq = 100 }\n"
            % (",".join(events), ",".join(todos)))


def grab(w, h, rot, zones, lang, power, wifi, reading, agenda=""):
    lua = (
        "STUB_FRAME = true\n"
        f"STUB_W = {w}\nSTUB_H = {h}\nSTUB_START_ROTATION = {rot}\n"
        f"STUB_SETTINGS_DIR = [[{settings_dir()}]]\n"
        f'STUB_RUN_ID = "{uuid.uuid4().hex[:8]}"\n'
        + agenda +
        f'arg = {{ [1] = [[{PLUGIN}]] }}\n'
        f'package.path = [[{PLUGIN}/?.lua;]] .. package.path\n'
        f'dofile([[{HERE}/stub_test.lua]])\n'
    )
    env = dict(os.environ,
               STUB_ZONES=",".join(zones),
               STUB_LANG=lang,
               STUB_PREVIEW="1",
               STUB_NOW=str(int(ANCHOR.timestamp())),
               STUB_POWER=power,
               STUB_WIFI=wifi,
               STUB_READING=reading)
    out = subprocess.run([sys.executable, "-c", RUNNER], cwd=ROOT, input=lua,
                         capture_output=True, text=True, encoding="utf-8",
                         errors="replace", env=env)
    if out.returncode != 0:
        raise SystemExit("桩件执行失败：\n" + (out.stdout or "")[-1500:]
                         + "\n" + (out.stderr or "")[-1500:])
    items = []
    for line in (out.stdout or "").splitlines():
        if line.startswith("FRAME|"):
            parts = line.split("|")
            if parts[1] == "END":
                break
            tag = parts[1]
            x, y, iw, ih, color = (int(v) for v in parts[2:7])
            items.append((tag, x, y, iw, ih, color, "|".join(parts[7:])))
    if not items:
        raise SystemExit("没有拿到 FRAME 帧，检查 STUB_FRAME 是否生效：\n"
                         + (out.stdout or "")[-1200:])
    return items


# --------------------------------------------------------------------- 绘制
def draw_items(items, dw, dh):
    S = SCALE
    img = Image.new("L", (dw * S, dh * S), 255)
    d = ImageDraw.Draw(img)

    for tag, x, y, iw, ih, color, text in items:
        if tag == "R":
            if iw <= 0 or ih <= 0:
                continue
            d.rectangle([x * S, y * S, (x + iw) * S - 1, (y + ih) * S - 1],
                        fill=255 - (color or 0))
        elif tag == "B":
            if iw <= 0 or ih <= 0:
                continue
            bw = max(2, S)
            d.rectangle([x * S, y * S, (x + iw) * S - 1, (y + ih) * S - 1],
                        outline=255 - (color or 0), width=bw)
        elif tag == "I":
            path = text if os.path.isabs(text) else os.path.join(ROOT, text)
            if not (os.path.exists(path) and iw > 0 and ih > 0):
                continue
            size = (max(1, iw * S), max(1, ih * S))
            try:
                src = Image.open(path)
            except Exception:  # noqa: BLE001 - 打不开就当没有这张图，不中断出图
                continue
            # 图标是「黑墨 + alpha 遮罩」，封面是整张照片：两者不能同一套画法。
            # 统一做法是先把源图取灰度（真机就是灰阶），有 alpha 才当遮罩用；
            # 一律拿 alpha 当遮罩、颜色固定涂黑，封面就会变成一块黑。
            has_alpha = src.mode in ("RGBA", "LA") or (
                src.mode == "P" and "transparency" in src.info)
            if has_alpha:
                rgba = src.convert("RGBA").resize(size, Image.LANCZOS)
                img.paste(rgba.convert("L"), (x * S, y * S), rgba.split()[3])
            else:
                img.paste(src.convert("L").resize(size, Image.LANCZOS), (x * S, y * S))
        elif tag == "T":
            draw_text(d, img, x, y, iw, ih, text, color, S)

    return img.resize((dw, dh), Image.LANCZOS)


def draw_text(d, img, x, y, w, h, text, color, S):
    if not text or h <= 0:
        return
    fill = GRAY if color == 85 else BLACK
    limit = max(4, w) * S

    def fit(px, s):
        """把字号收到「雅黑量出来的宽度 == 控件实测宽度」。

        Kindle 的 cfont 比雅黑窄，直接用 h/1.363 估出的字号画，一行会宽出 5%~10%，
        看着像顶出框、像叠字——其实真机上没有。按实测宽度反推字号才是对的：
        控件报 56 px 宽，就画到 56 px 宽。
        """
        f = font(px * S)
        actual = text_w(d, s, f)
        if actual > limit and actual > 0:
            px = px * limit / actual
            f = font(px * S)
        # 字号是整数，按比例算出来的那一下常会差 1~2 px，逐档收到真放得下为止
        guard = 0
        while text_w(d, s, f) > limit and px > 6 and guard < 24:
            px -= 0.5
            f = font(px * S)
            guard += 1
        return px, f

    # 控件高 h、行高 = 字号 × 1.363（桩件与真机一致）。
    # 先看「按一行高估出来的字号」放不放得下：放得下就是单行（绝大多数标签都走这里，
    # 走下面的折行判断反而会把 "58%" 拆成两行）。
    px0 = h / 1.363
    if text_w(d, text, font(px0 * S)) <= limit * 1.03:
        px, f = fit(px0, text)
        chosen = (px, f, [text])
    else:
        chosen = None
        for lines in range(2, 9):
            px = h / lines / 1.363
            if px < 6:
                break
            f0 = font(px * S)
            wr = wrap(d, text, f0, limit)
            if len(wr) != lines:
                continue
            widest = max(text_w(d, r, f0) for r in wr)
            if widest > limit:
                px = px * limit / widest
                f0 = font(px * S)
                wr = wrap(d, text, f0, limit)
            chosen = (px, f0, wr)
            break
        if chosen is None:
            # 一行放不下、又折不成规整的多行：按 Kindle 的做法截断加省略号
            px, f = fit(px0, text)
            chosen = (px, f, [ellipsize(d, text, f, limit)])

    px, f, rows = chosen
    line_h = h / len(rows)
    for i, row in enumerate(rows):
        d.text((x * S, (y + i * line_h) * S), row, font=f, fill=fill, anchor="la")


def border(img, pad=0):
    """给页面加一条浅灰细边：README 底色也是浅色，没有边会糊在一起。"""
    w, h = img.size
    out = Image.new("L", (w + pad * 2, h + pad * 2), 255)
    out.paste(img, (pad, pad))
    d = ImageDraw.Draw(out)
    d.rectangle([pad, pad, pad + w - 1, pad + h - 1], outline=205, width=2)
    return out


# --------------------------------------------------------------------- 八套版面
# 组件白名单（main.lua 的 COMPONENTS[].zones）决定哪些能进哪个区：
#   竖屏 A 920×407 / B 920×505 / C 920×232
#   横屏 A 1276×294 / B 630×553 / C 593×553
PRESETS = [
    # ---------------- 竖屏 ----------------
    dict(id="portrait-1", orient="portrait", title="经典 · 时钟天气 / 月历 / 三格",
         zones=["clock_weather", "calendar", "stats_cells",
                "clock_weather", "calendar", "side_panel"]),
    # 一条排布约定：同一张图里不并存「今日+三日」和「一周预报」（都是预报，读了重复）。
    # 有今日+三日的那张，中段改放农历节气；不选空气明细是因为竖屏-3 的中段就是它，
    # 两张竖屏的中段会一模一样。
    dict(id="portrait-2", orient="portrait", title="今日与农历 · 今日+三日 / 农历节气 / 电量网络",
         zones=["weather_today_3d", "lunar_term", "battery_net",
                "weather_today_3d", "lunar_term", "battery_net"]),
    dict(id="portrait-3", orient="portrait", title="空气与日月 · 纯天气 / 空气明细 / 日月",
         zones=["weather_big", "air_detail", "sun_moon",
                "weather_big", "air_detail", "sun_moon"]),
    dict(id="portrait-4", orient="portrait", title="阅读 · 大字时钟 / 在读卡 / 电量网络",
         zones=["clock_big", "reading_now", "battery_net",
                "clock_big", "reading_now", "battery_net"]),
    # ---------------- 横屏 ----------------
    dict(id="landscape-1", orient="landscape", title="经典 · 时钟天气 / 月历 / 侧栏",
         zones=["clock_weather", "calendar", "side_panel",
                "clock_weather", "calendar", "side_panel"]),
    # 同理：A 区已有今日+三日，左下就不再排一周预报，改放农历节气。
    dict(id="landscape-2", orient="landscape", title="今日与空气 · 今日+三日 / 农历节气 / 空气明细",
         zones=["weather_today_3d", "lunar_term", "air_detail",
                "weather_today_3d", "lunar_term", "air_detail"]),
    dict(id="landscape-3", orient="landscape", title="一周与日月 · 一周预报 / 日月 / 在读卡",
         zones=["forecast_week", "sun_moon", "reading_now",
                "forecast_week", "sun_moon", "reading_now"]),
    dict(id="landscape-4", orient="landscape", title="大钟与数据 · 大字时钟 / 日月 / 空气明细",
         zones=["clock_big", "sun_moon", "air_detail",
                "clock_big", "sun_moon", "air_detail"]),
    # ---------------- v2.47：倒数日 / 待办 ----------------
    dict(id="portrait-5", orient="portrait", title="倒数日与待办 · 时钟天气 / 倒数日 / 待办",
         zones=["clock_weather", "countdown", "todo",
                "clock_weather", "countdown", "todo"]),
    dict(id="landscape-5", orient="landscape", title="大钟与待办 · 大字时钟 / 倒数日 / 待办",
         zones=["clock_big", "countdown", "todo",
                "clock_big", "countdown", "todo"]),
]

# README 首图用的排法，不属于上面五套预设：竖屏「时钟天气 / 农历节气 / 三格」。
# 横屏首图就是 landscape-1（zones 一模一样），出完图拷一份改名 landscape.png。
MAIN_PORTRAIT = dict(id="portrait", orient="portrait",
                     title="主推 · 时钟天气 / 农历节气 / 三格",
                     zones=["clock_weather", "lunar_term", "stats_cells",
                            "clock_weather", "lunar_term", "stats_cells"])

# 倒数日 / 待办样例。第二个字段是「距今天几天」，出图时现算日期。
AGENDA = {
    "events": [
        ("妈妈生日", 18, True),
        ("部门年会", 9, False),
        ("结婚纪念日", 45, False),
        ("放寒假", 63, False),
        ("上次体检", -12, False),
    ],
    "todos": [
        ("交班主任月报", 0, False),
        ("修看板封面逻辑", 0, False),
        ("买牛奶", 0, True),
        ("家访：李明", 1, False),
        ("交电费", -1, False),
    ],
}

# 英文出图用同一组事件，只换文案：README.en.md 的图里不能出现中文
AGENDA_EN = {
    "events": [
        ("Mom's birthday", 18, True),
        ("Company party", 9, False),
        ("Wedding anniversary", 45, False),
        ("Winter break", 63, False),
        ("Last checkup", -12, False),
    ],
    "todos": [
        ("Submit monthly report", 0, False),
        ("Fix cover logic", 0, False),
        ("Buy milk", 0, True),
        ("Home visit: Li Ming", 1, False),
        ("Pay electric bill", -1, False),
    ],
}

# 真机数据（预览图不用 -- 占位符）：电量 58% 未充电、WiFi 已连接、在读《三体》37%
POWER, WIFI, READING = "58", "on", "1"


def render(preset, lang="zh"):
    rot = 0 if preset["orient"] == "portrait" else 1
    dw, dh = (NATIVE_W, NATIVE_H) if rot == 0 else (NATIVE_H, NATIVE_W)
    agenda = AGENDA_EN if lang == "en" else AGENDA
    items = grab(NATIVE_W, NATIVE_H, rot, preset["zones"], lang, POWER, WIFI, READING,
                 agenda_block(agenda))
    img = draw_items(items, dw, dh)
    img = border(img, pad=0)
    out_dir = os.path.join(OUT_DIR, "en") if lang == "en" else OUT_DIR
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, preset["id"] + ".png")
    img.save(path, optimize=True)
    print(f"[OK] {lang} {preset['id']:<12} {dw}×{dh}  {len(items):>3} 个元素  {preset['title']}")
    return path


def main():
    args = sys.argv[1:]
    only_orient = None
    only_idx = None
    langs = []
    for a in args:
        if a in ("portrait", "landscape"):
            only_orient = a
        elif a in ("zh", "en"):
            langs.append(a)
        elif a.isdigit():
            only_idx = int(a)
    # 不指定语言时保持老行为：只出中文，不覆盖已有的英文图
    for lang in (langs or ["zh"]):
        done = 0
        # 首图只出中文（README.en.md 用的是 portrait-1 / landscape-1），
        # 且只在「出全部图」时补，单独出某个方向时不多写文件
        if lang == "zh" and not only_orient and not only_idx:
            render(MAIN_PORTRAIT, lang)
            done += 1
        # 每个方向单独编号：加了第 5 套之后再用「i <= 4」判断会把 landscape 的第 1 套算成 5
        seen = {"portrait": 0, "landscape": 0}
        for p in PRESETS:
            seen[p["orient"]] += 1
            idx = seen[p["orient"]]
            if only_orient and p["orient"] != only_orient:
                continue
            if only_idx and idx != only_idx:
                continue
            render(p, lang)
            done += 1
        if lang == "zh" and not only_orient and not only_idx:
            shutil.copyfile(os.path.join(OUT_DIR, "landscape-1.png"),
                            os.path.join(OUT_DIR, "landscape.png"))
        where = os.path.join(OUT_DIR, "en") if lang == "en" else OUT_DIR
        print(f"\n[{lang}] 共 {done} 张，输出目录：{where}")


if __name__ == "__main__":
    main()
