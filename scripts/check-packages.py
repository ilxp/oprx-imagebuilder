#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""校验 openwrt-imagebuilder 的 config/<arch>.conf 里的包列表在官方源中是否都存在。

为什么需要：CI 上一次构建要 2~3 分钟，而「包名写错 / 换版本后某包被移除」这类问题
本可以在本地用几秒的索引查询提前发现。

用法：
    python check-packages.py [arch] [openwrt-version]

    arch            默认 x86_64（对应 ../../openwrt-imagebuilder/config/x86_64.conf）
    openwrt-version 默认当前 build.conf 的 VERSION（现为 25.12.6）

实现要点
--------
* OpenWrt 24.10 起用 apk v3（APKINDEX 变成了 ``packages.adb``）。该文件是
  ``b"ADB" + 1 字节头 `` 后面跟一段 raw deflate（windowBits = -15）。
* 索引里包名是「单字节长度前缀 + 该长度的字符串」，用这个特征精确提取包名，
  比裸字符串匹配可靠得多（否则 depends 字段里的名字会造成假阳性）。
* kernel modules 不在主 ``packages`` 索引里：24.10+ 把它们放在
  ``targets/<t>/<s>/kmods/<kernelver>/packages.adb``，内核版本要先去目录列表里找。
  漏掉这个 feed 会把所有 kmod-* 误判成缺失。
"""
import gzip
import os
import re
import sys
import urllib.error
import urllib.request
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, ".."))   # 本脚本就在仓库根的 scripts/ 下
MIRROR = "https://downloads.openwrt.org"

ARCH = sys.argv[1] if len(sys.argv) > 1 else "x86_64"
VER = sys.argv[2] if len(sys.argv) > 2 else "25.12.6"

CONF = os.path.join(REPO, "config", "%s.conf" % ARCH)
if not os.path.exists(CONF):
    sys.exit("找不到 %s" % CONF)

# 直连 downloads.openwrt.org 在部分网络下会 503 first byte timeout；
# 需要代理时设 OPENWRT_PROXY=http://127.0.0.1:7890 即可。
PROXY = os.environ.get("OPENWRT_PROXY", "").strip()
if PROXY:
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({"http": PROXY, "https": PROXY}))
else:
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def fetch(url, timeout=180, retries=3):
    last = None
    for attempt in range(1, retries + 1):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "curl/8.0"})
            with opener.open(req, timeout=timeout) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            last = e
            # 404 重试没有意义（路径/版本就是不存在），直接抛，别白等三轮。
            if e.code == 404:
                raise
            print("    (retry %d/%d  %s: %s)"
                  % (attempt, retries, type(e).__name__, e), file=sys.stderr)
        except Exception as e:
            last = e
            print("    (retry %d/%d  %s: %s)"
                  % (attempt, retries, type(e).__name__, e), file=sys.stderr)
    raise last


def load_conf(path):
    """把 <arch>.conf 当 shell 变量文件读出来（只认 KEY="value" 形式）。"""
    vals = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            vals[k.strip()] = v.strip().strip('"')
    return vals


def adb_package_names(raw):
    """从 packages.adb 里精确提取包名集合。"""
    if raw[:2] == b"\x1f\x8b":
        raw = gzip.decompress(raw)
    body = raw[4:] if raw[:3] == b"ADB" else raw
    try:
        payload = zlib.decompress(body, -15)
    except zlib.error:
        payload = zlib.decompress(body)
    names = set()
    for m in re.finditer(rb"([\x01-\x3f])([a-zA-Z0-9][a-zA-Z0-9+_.-]{0,60})", payload):
        if m.group(1)[0] == len(m.group(2)):
            names.add(m.group(2).decode())
    return names


cfg = load_conf(CONF)
T, S, AP = cfg["TARGET"], cfg["SUBTARGET"], cfg["ARCH_PACKAGES"]
BASE_T = "%s/releases/%s/targets/%s/%s" % (MIRROR, VER, T, S)
BASE_P = "%s/releases/%s/packages/%s" % (MIRROR, VER, AP)

try:
    kmods_html = fetch(BASE_T + "/kmods/").decode("utf-8", "replace")
except Exception as e:
    # 这条最容易在「刚探测到新版本、镜像还没同步完」或「版本号写错」时命中。
    # 给一句人话，别甩 traceback —— upstream-check 把它当闸门用，日志要能直接看懂。
    sys.exit("拿不到 %s/kmods/（%s: %s）\n"
             "  ⇒ 目标 %s/%s 的 OpenWrt %s 可能不存在，或镜像还没同步完。"
             % (BASE_T, type(e).__name__, e, T, S, VER))

kernel = sorted(set(re.findall(r'href="([0-9][^"/]*?)/"', kmods_html)))
if not kernel:
    sys.exit("拿不到 kmods 内核版本目录")
KF = kernel[-1]

FEEDS = [
    ("core",      BASE_T + "/packages"),
    ("kmods",     "%s/kmods/%s" % (BASE_T, KF)),
    ("base",      BASE_P + "/base"),
    ("luci",      BASE_P + "/luci"),
    ("packages",  BASE_P + "/packages"),
    ("routing",   BASE_P + "/routing"),
    ("telephony", BASE_P + "/telephony"),
    ("video",     BASE_P + "/video"),
]

print("config : %s" % CONF)
print("target : %s/%s   arch_packages=%s" % (T, S, AP))
print("version: %s   kernel: %s" % (VER, KF))
print()

index = {}
for feed, url in FEEDS:
    try:
        names = adb_package_names(fetch(url + "/packages.adb"))
        index[feed] = names
        print("  [%-9s] %6d 个包名" % (feed, len(names)))
    except Exception as e:
        print("  [%-9s] 跳过 (%s: %s)" % (feed, type(e).__name__, e))

index["kernel"] = {"kernel"}
print()

WANT = cfg["PACKAGES"].split()
miss = []
for p in WANT:
    neg = p.startswith("-")
    name = p.lstrip("-")
    hit = [f for f, s in index.items() if name in s]
    if hit:
        print("  OK      %-34s <- %s" % (p, ",".join(hit)))
    else:
        print("  MISSING %-34s" % p)
        miss.append(p)

print()
print("共 %d 项，缺失 %d 项：%s" % (len(WANT), len(miss), miss or "无"))
sys.exit(1 if miss else 0)
