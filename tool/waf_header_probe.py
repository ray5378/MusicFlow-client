#!/usr/bin/env python3
"""确认公网入口的响应头特征，判断请求是否真的经过 Lucky WAF 反代。

用途：闸门"看起来没生效"时必须先排除「请求根本没走反代」这一可能，
      否则会重复 2026-09-10 的误判（把闸门关闭态当成"闸门不存在"）。
"""
import json
import ssl
import urllib.error
import urllib.parse
import urllib.request

WAN = "https://music.cmct.fun:35378"
CREDS = {"username": "xyz5378", "password": "@$qQ!J4pNnSoy8"}
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE


def head(path, body=None):
    sep = "&" if "?" in path else "?"
    auth = urllib.parse.urlencode({"u": CREDS["username"], "p": CREDS["password"],
                                   "v": "1.16.1", "c": "hdrprobe", "f": "json"})
    url = f"{WAN}{path}{sep}{auth}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method="POST" if data else "GET")
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, context=CTX, timeout=120) as r:
            print(f"--- {path} ---")
            print(f"  status: {r.status}")
            for k, v in r.headers.items():
                print(f"  {k}: {v}")
    except urllib.error.HTTPError as e:
        print(f"--- {path} ---")
        print(f"  status: {e.code}")
        for k, v in e.headers.items():
            print(f"  {k}: {v}")
        print(f"  body: {e.read()[:300].decode('utf-8','replace')!r}")
    print()


print("=== 小请求（看反代特征头）===")
head("/rest/ping.view")

print("=== 大请求（721KB 整队）===")
filler = "x" * 400
items = [{"songId": f"p-{i}", "title": filler, "artist": "p", "album": "p",
          "duration": 180} for i in range(1500)]
head("/rest/api/v1/peers/dlna%3AFF310013-FE1E-8BA1-7B61-561AFF310013/queue/play",
     body={"items": items, "startIndex": 0})
