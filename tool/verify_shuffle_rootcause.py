#!/usr/bin/env python3
"""验证根因假设：QueueController.playFrom 在 shuffle 模式下**无条件随机起播**，
丢弃调用方传入的 startIndex。

假设验证法：同一份请求，分别在下述状态下调用 /v1/play，比较 currentIndex：
  A. 当前 playMode = shuffle（默认）  → 期望 currentIndex 是随机值（≠0）
  B. 先把 playMode 设为 all/one/order → 期望 currentIndex 精确等于请求的起点
"""
from __future__ import annotations

import json
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = "http://192.168.10.240:46400"
CREDS = {"username": "xyz5378", "password": "@$qQ!J4pNnSoy8"}


def call(path, method="GET", body=None, token=None, timeout=180):
    req = urllib.request.Request(
        BASE + path, data=json.dumps(body).encode() if body is not None else None, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return {"__http": e.code, "__body": e.read()[:400].decode("utf8", "replace")}
    except Exception as e:  # noqa: BLE001
        return {"__err": repr(e)}


def main():
    token = call("/rest/api/v1/auth/login", "POST", CREDS)["token"]
    peer = [p for p in call("/rest/api/v1/peers", token=token)["peers"]
            if p.get("kind") == "dlna" and p.get("available")][0]["peerId"]
    enc = urllib.parse.quote(peer, safe="")
    pid = "pl-daily-roam"
    encp = urllib.parse.quote(pid, safe="")

    rows = [it for it in call(f"/rest/api/v1/playlists/{encp}/tracks?page=1&pageSize=10", token=token)["items"]
            if it.get("playable") and it.get("isMatched") and it.get("id")]
    target = rows[0]
    print(f"目标: 首曲 songId={target['id']}  {target.get('title')} / {target.get('artist')}")

    def cur(tag):
        q = call(f"/rest/api/v1/peers/{enc}/queue?offset=0&size=1", token=token)
        ci = q.get("currentIndex")
        cm = (q.get("currentMedia") or {})
        matched = cm.get("songId") == target["id"]
        print(f"  {tag:<26} playMode={q.get('playMode'):<8} currentIndex={ci:<6} "
              f"media={cm.get('title')}  {'<<< 正确' if matched else ''}")
        return ci, matched

    print("\n=== 基线 ===")
    q0 = call(f"/rest/api/v1/peers/{enc}/queue?offset=0&size=1", token=token)
    print(f"  当前 playMode = {q0.get('playMode')}")

    print("\n=== A. 在 shuffle 模式下调 /v1/play（当前默认状态）===")
    for i in range(3):
        call("/rest/api/v1/play", "POST",
             {"peerId": peer, "type": "playlist", "id": pid, "songId": target["id"]}, token=token)
        time.sleep(1)
        cur(f"A-{i+1} 次投屏 (shuffle)")

    print("\n=== B. 先设 playMode=all，再调 /v1/play ===")
    call(f"/rest/api/v1/peers/{enc}/play-mode", "POST", {"mode": "all"}, token=token)
    time.sleep(0.5)
    for i in range(3):
        call("/rest/api/v1/play", "POST",
             {"peerId": peer, "type": "playlist", "id": pid, "songId": target["id"]}, token=token)
        time.sleep(1)
        cur(f"B-{i+1} 次投屏 (all)")

    print("\n=== C. 对照：设 playMode=one（单曲循环）===")
    call(f"/rest/api/v1/peers/{enc}/play-mode", "POST", {"mode": "one"}, token=token)
    time.sleep(0.5)
    call("/rest/api/v1/play", "POST",
         {"peerId": peer, "type": "playlist", "id": pid, "songId": rows[1]["id"]}, token=token)
    time.sleep(1)
    q = call(f"/rest/api/v1/peers/{enc}/queue?offset=0&size=1", token=token)
    cm = (q.get("currentMedia") or {})
    print(f"  期望={rows[1].get('title')}  实到={cm.get('title')}  "
          f"{'一致' if cm.get('songId')==rows[1]['id'] else '**不一致**'}")


if __name__ == "__main__":
    main()
