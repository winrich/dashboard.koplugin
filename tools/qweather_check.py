# -*- coding: utf-8 -*-
"""用真实凭据体检和风天气接口，不需要把插件装进设备。

三件事：
  1) 确认 API Host / API Key 能连通，并报告是否 gzip 压缩
  2) 按插件里的同一套规则把字段算出来（温度取整、湿度转百分比、风向中文、AQI 等级）
  3) 与插件内的城市表对齐，检查经纬度两位小数后是否仍指向正确城市

用法（在项目根目录）：
    python tools/qweather_check.py                # 北京，东八区
    python tools/qweather_check.py 上海 480
    python tools/qweather_check.py 乌鲁木齐 360   # 看非东八区时日出日落会不会错位
"""

import gzip
import json
import os
import re
import sys
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLUGIN = os.path.join(ROOT, "dashboard.koplugin")

WIND_DIRS = ["北", "东北", "东", "东南", "南", "西南", "西", "西北"]


def read_text(name):
    path = os.path.join(PLUGIN, name)
    if not os.path.exists(path):
        return ""
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def read_credential():
    """凭据优先级与插件一致：本地凭据文件 > 默认配置文件"""
    host = key = ""
    for name in ("dashboard_config.local.lua", "dashboard_config.lua"):
        text = read_text(name)
        if not text:
            continue
        m_host = re.search(r'api_host\s*=\s*"([^"]*)"', text)
        m_key = re.search(r'api_key\s*=\s*"([^"]*)"', text)
        if m_host and m_host.group(1) and not host:
            host = m_host.group(1)
        if m_key and m_key.group(1) and not key:
            key = m_key.group(1)
    host = re.sub(r"^https?://", "", host).strip().rstrip("/")
    return host, key.strip()


def read_cities():
    text = read_text("dashboard_cities.lua")
    pattern = r'name\s*=\s*"([^"]+)"[^}]*?lat\s*=\s*([\d.]+)[^}]*?lon\s*=\s*([\d.]+)'
    return {name: (float(lat), float(lon)) for name, lat, lon in re.findall(pattern, text)}


def http_get(url, key):
    req = urllib.request.Request(url, headers={
        "X-QW-Api-Key": key,
        "User-Agent": "KOReader-Dashboard-check/1.0",
    })
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            raw = resp.read()
            encoding = resp.headers.get("Content-Encoding", "")
            status = resp.status
    except urllib.error.HTTPError as exc:
        raw = exc.read()
        encoding = exc.headers.get("Content-Encoding", "")
        status = exc.code
    compressed = encoding == "gzip" or raw[:2] == b"\x1f\x8b"
    if compressed:
        raw = gzip.decompress(raw)
    return status, raw.decode("utf-8", "replace"), ("gzip" if compressed else "identity")


def wind_dir(deg):
    if deg is None:
        return "-"
    idx = int(((deg % 360) + 22.5) % 360 / 45) + 1
    return WIND_DIRS[min(idx, 8) - 1] + "风"


def hm(iso, tz_offset):
    """ISO8601 带偏移 -> 目标时区的 HH:MM，与 dashboard_qweather.local_hm 同规则"""
    if not isinstance(iso, str):
        return "-"
    m = re.search(r"T(\d{2}):(\d{2})([+-])(\d{2}):(\d{2})", iso)
    if m:
        hh, mm, sign, oh, om = m.groups()
        off = int(oh) * 60 + int(om)
        if sign == "-":
            off = -off
    else:
        m = re.search(r"T(\d{2}):(\d{2})Z", iso)
        if not m:
            return "-"
        hh, mm, off = m.group(1), m.group(2), 0
    total = (int(hh) * 60 + int(mm) - off + tz_offset) % 1440
    return f"{total // 60:02d}:{total % 60:02d}"


def main():
    city = sys.argv[1] if len(sys.argv) > 1 else "北京"
    tz_offset = int(sys.argv[2]) if len(sys.argv) > 2 else 480

    host, key = read_credential()
    if not host or not key:
        print("[FAIL] 没读到凭据，检查 dashboard.koplugin/dashboard_config.local.lua")
        return 1

    cities = read_cities()
    if city not in cities:
        print(f"[FAIL] 城市表里没有「{city}」，可选示例：{', '.join(list(cities)[:8])} …")
        return 1
    lat, lon = cities[city]
    print(f"凭据：host={host}  key={key[:6]}****{key[-4:]}")
    print(f"地点：{city}  {lat:.4f},{lon:.4f} -> 请求用 {lat:.2f},{lon:.2f}　时区偏移 {tz_offset} 分钟\n")

    base = f"https://{host}"
    urls = {
        "实况": f"{base}/weather/v1/current/{lat:.2f}/{lon:.2f}?localTime=true&lang=zh",
        "预报": f"{base}/weather/v1/daily/{lat:.2f}/{lon:.2f}?days=1&localTime=true&lang=zh",
        "空气": f"{base}/airquality/v1/current/{lat:.2f}/{lon:.2f}?lang=zh",
    }

    payload = {}
    failed = False
    for name, url in urls.items():
        try:
            status, body, encoding = http_get(url, key)
        except Exception as exc:  # noqa: BLE001 - 网络问题需要原样呈现
            print(f"[FAIL] {name} 请求异常：{exc!r}")
            failed = True
            continue
        if status != 200:
            print(f"[FAIL] {name} HTTP {status}：{body[:200]}")
            failed = True
            continue
        try:
            payload[name] = json.loads(body)
        except json.JSONDecodeError as exc:
            print(f"[FAIL] {name} 不是合法 JSON：{exc}　前 120 字节 {body[:120]!r}")
            failed = True
            continue
        print(f"[ OK ] {name}  HTTP 200，解压后 {len(body)} 字节（响应 Content-Encoding: {encoding}）")

    if failed:
        return 1

    cur = payload["实况"]
    day = payload["预报"]["days"][0]
    air = payload["空气"]

    cond = cur.get("condition", {})
    hum = cur.get("humidity")
    wind = cur.get("wind", {})

    aqi = level = None
    for idx in air.get("indexes", []):
        if idx.get("code") == "cn-mee":
            aqi, level = idx.get("aqi"), idx.get("category")
            break
    pm25 = pm10 = None
    for p in air.get("pollutants", []):
        if p.get("code") == "pm2p5":
            pm25 = p["concentration"]["value"]
        elif p.get("code") == "pm10":
            pm10 = p["concentration"]["value"]

    print("\n---------------- 按插件规则换算后的展示值 ----------------")
    print(f"温度      {round(cur['temperature']['value']):d}°   体感 {round(cur['feelsLike']['value']):d}°")
    print(f"现象      {cond.get('text')}（代码 {cond.get('code')}）")
    print(f"湿度      {hum * 100:.0f}%" if hum is not None else "湿度      -")
    print(f"风        {wind_dir(wind.get('direction', {}).get('degree'))} {wind.get('scale')} 级")
    print(f"今日温差  {round(day['temperatureMax']['value'])}° ~ {round(day['temperatureMin']['value'])}°")
    print(f"日出日落  {hm(day['astro'].get('sunrise'), tz_offset)} / "
          f"{hm(day['astro'].get('sunset'), tz_offset)}")
    print(f"空气      AQI {aqi}（{level}）　PM2.5 {pm25}　PM10 {pm10}")
    if aqi is None:
        print("          注意：没有 cn-mee 指数，插件会退化为按 PM2.5/PM10 本地换算")
    return 0


if __name__ == "__main__":
    sys.exit(main())
