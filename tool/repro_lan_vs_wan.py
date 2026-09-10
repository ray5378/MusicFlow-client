#!/usr/bin/env python3
"""验证「真实设备可达性」是否是大歌单失败的真正原因。

日志事实（2026-09-10 16:03 与 16:06 两段）：
  1. POST .../queue/play  发出后,**从未出现对应的 `-> 200` 响应行**
  2. 但客户端没有报错、没有卡死 —— 85ms 后就继续跑轮询了
  3. 客户端连接的是 `via 家` = https://music.cmct.fun:35378 (公网 HTTPS)

关键推论：请求被**静默丢弃**,而不是超时也不是服务端拒绝。

本脚本从「客户端侧视角」验证：
  A. 公网地址下 POST /queue/play 是否真能成功
  B. 对比同一操作走局域网 IP 是否成功
  C. 客户端 baseUrl 在请求过程中被改写会不会中断请求

→ 用真实 HTTP 请求测 A/B, 用源码静态分析验证 C。
"""
from __future__ import annotations

import json
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request

LAN = "http://192.168.10.240:46400"
WAN = "https://music.cmct.fun:35378"
CREDS = {"username": "xyz5378", "password": "@$qQ!J4pNnSoy8"}
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE


def call(base, path, method="GET", body=None, token=None, timeout=300, raw=None):
    data = raw if raw is not None else (
        json.dumps(body).encode() if body is not None else None)
    req = urllib.request.Request(base + path, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=CTX) as r:
            b = r.read()
            return {"ms": int((time.time() - t0) * 1000), "n": len(b),
                    "ct": r.headers.get("content-type"),
                    "j": json.loads(b or b"{}")}
    except urllib.error.HTTPError as e:
        return {"http": e.code, "ms": int((time.time() - t0) * 1000),
                "body": e.read()[:300].decode("utf8", "replace")}
    except Exception as e:  # noqa: BLE001
        return {"err": repr(e), "ms": int((time.time() - t0) * 1000)}


def grab_items(base, enc, token, want=842):
    """从服务端回读现有队列, 拼出与客户端 songToQueueItem 同形的 items。"""
    out, off = [], 0
    while off < want:
        r = call(base, f"/rest/api/v1/peers/{enc}/queue?offset={off}&size=200",
                 token=token)
        j = r.get("j") or {}
        items = j.get("items") or []
        if not items:
            break
        out.extend(items)
        off += len(items)
    return [{k: s.get(k) for k in
             ("songId", "title", "artist", "album", "albumId",
              "mime", "coverArt", "duration")} for s in out]


def main():
    print("=" * 66)
    print("A/B. 同一份 842 首 payload,换个地址再推一次")
    print("=" * 66)

    # 先用局域网建好 842 队列（作为 payload 源）
    tok = call(LAN, "/rest/api/v1/auth/login", "POST", CREDS)["j"]["token"]
    peers = [p for p in call(LAN, "/rest/api/v1/peers", token=tok)["j"]["peers"]
             if p.get("kind") == "dlna" and p.get("available")]
    peer = peers[0]["peerId"]
    enc = urllib.parse.quote(peer, safe="")
    print(f"设备: {peer}")

    items = grab_items(LAN, enc, tok)
    print(f"payload 源: {len(items)} 首")
    if not items:
        print("!! 队列为空, 先推一次建队")
        return 1
    body = json.dumps({"items": items, "startIndex": 33}).encode()
    print(f"payload 体积: {len(body)} bytes ({len(body)/1048576:.2f} MB)\n")

    for label, base in (("局域网 (LAN)", LAN), ("公网 (WAN)", WAN)):
        t = call(base, "/rest/api/v1/auth/login", "POST", CREDS).get("j", {}).get("token")
        if not t:
            print(f"{label}: 登录失败")
            continue
        r = call(base, f"/rest/api/v1/peers/{enc}/queue/play", "POST",
                 raw=body, token=t, timeout=300)
        j = r.get("j") or {}
        print(f"{label:14s} {r.get('ms'):>6}ms  成功={j.get('success')}  "
              f"content-type={r.get('ct')}  响应体={r.get('n')}B")
        if r.get("err") or r.get("http"):
            print(f"    !! {r.get('err') or r.get('body')}")

    # 回读确认设备真的换了队
    q = call(LAN, f"/rest/api/v1/peers/{enc}/queue?offset=0&size=1", token=tok)
    j = q.get("j") or {}
    print(f"\n设备最终队列: total={j.get('total')} idx={j.get('currentIndex')} "
          f"isActive={j.get('isActive')} "
          f"media={(j.get('currentMedia') or {}).get('title')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
