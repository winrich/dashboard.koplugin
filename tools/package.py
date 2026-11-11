# -*- coding: utf-8 -*-
"""把插件目录打包成 zip，便于一次性拷进 Kindle。

zip 内保留 dashboard.koplugin/ 这一层，解压到 koreader/plugins/ 即为正确结构。
"""

import os
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "dashboard.koplugin")
DIST = os.path.join(ROOT, "dist")
OUT = os.path.join(DIST, "dashboard.koplugin.zip")


def main():
    os.makedirs(DIST, exist_ok=True)
    count = 0
    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as zf:
        for base, _dirs, files in os.walk(SRC):
            for name in sorted(files):
                full = os.path.join(base, name)
                rel = os.path.relpath(full, ROOT).replace("\\", "/")
                zf.write(full, rel)
                count += 1
                print(f"  + {rel}  {os.path.getsize(full)} B")
    size = os.path.getsize(OUT)
    print(f"\n{count} 个文件已打包 -> {OUT}  ({size/1024:.1f} KB)")
    print("部署：解压后把 dashboard.koplugin 目录放到设备的 koreader/plugins/ 下")


if __name__ == "__main__":
    main()
