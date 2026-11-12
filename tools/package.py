# -*- coding: utf-8 -*-
"""把插件目录打包成 zip，便于一次性拷进 Kindle。

zip 内保留 dashboard.koplugin/ 这一层，解压到 koreader/plugins/ 即为正确结构。
dashboard_config.local.lua（本机凭据）不会被打进 zip，产物可以直接分享。
"""

import os
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "dashboard.koplugin")
DIST = os.path.join(ROOT, "dist")
OUT = os.path.join(DIST, "dashboard.koplugin.zip")

# 本机凭据绝不进 zip：自己装机用它没问题，但别人填了自己的 key 再打包分享，
# 等于把 key 一起送出去。所以按文件名无条件跳过（模板 .example 不在名单里，照常打包）。
EXCLUDE = {"dashboard_config.local.lua"}


def main():
    os.makedirs(DIST, exist_ok=True)
    count = 0
    skipped = []
    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as zf:
        for base, _dirs, files in os.walk(SRC):
            for name in sorted(files):
                full = os.path.join(base, name)
                rel = os.path.relpath(full, ROOT).replace("\\", "/")
                if name in EXCLUDE:
                    skipped.append(rel)
                    continue
                zf.write(full, rel)
                count += 1
                print(f"  + {rel}  {os.path.getsize(full)} B")
    for rel in skipped:
        print(f"  - {rel}  （含本机凭据，未打包）")
    size = os.path.getsize(OUT)
    print(f"\n{count} 个文件已打包 -> {OUT}  ({size/1024:.1f} KB)")
    if skipped:
        print("凭据文件已排除，这个 zip 可以直接分享；对方首次打开会提示去配凭据。")
    print("部署：解压后把 dashboard.koplugin 目录放到设备的 koreader/plugins/ 下")


if __name__ == "__main__":
    main()
