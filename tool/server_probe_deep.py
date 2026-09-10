#!/usr/bin/env python3
"""深挖：为什么 /v1/play 成功、队列正确，但设备实际播的还是别的歌？

上一步发现：play(pl-daily-roam, songId=首曲) → 队列 total=3251 正确，
但 status.currentMedia = 「兰亭序」(周杰伦)，queue.currentIndex = 246。
说明**播放位置/媒体没有跟随 queue 重建**。
"""
from __future__ import annotations

import json
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = "http://192.168.10.240:46400"
CREDS = {"username": "xyz5378", "password": "@$qQ!J4pNnSoy8"}


def call(path, method="GET", body=None, token=None, timeout=120):
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
    peers = [p for p in call("/rest/api/v1/peers", token=token)["peers"]
             if p.get("kind") == "dlna" and p.get("available")]
    print("可用 DLNA peers:")
    for p in peers:
        print(f"  {p['peerId']}  name={p.get('name')}")
    peer = peers[0]["peerId"]
    enc = urllib.parse.quote(peer, safe="")

    pid = "pl-daily-roam"
    encp = urllib.parse.quote(pid, safe="")
    rows = [it for it in call(f"/rest/api/v1/playlists/{encp}/tracks?page=1&pageSize=5", token=token)["items"]
            if it.get("playable") and it.get("isMatched") and it.get("id")]
    target = rows[0]
    print(f"\n目标首曲: {target['id']}  {target.get('title')} / {target.get('artist')}")

    def snapshot(tag):
        st = call(f"/rest/api/v1/peers/{enc}/status", token=token)
        q = call(f"/rest/api/v1/peers/{enc}/queue?offset=0&size=1", token=token)
        print(f"\n--- {tag} ---")
        print(f"  status : state={st.get('state')} pos={st.get('position')} "
              f"media={(st.get('media') or {}).get('title')} ({(st.get('media') or {}).get('songId')})")
        print(f"  queue  : total={q.get('total')} currentIndex={q.get('currentIndex')} "
              f"isActive={q.get('isActive')} slot0={(q.get('items') or [{}])[0].get('songId')}")
        print(f"           currentMedia={(q.get('currentMedia') or {}).get('title')} "
              f"({(q.get('currentMedia') or {}).get('songId')})")
        return st, q

    snapshot("投前基线")

    print("\n>>> POST /v1/play {type:playlist, id:pl-daily-roam, songId:首曲}")
    t0 = time.time()
    r = call("/rest/api/v1/play", "POST",
             {"peerId": peer, "type": "playlist", "id": pid, "songId": target["id"]}, token=token)
    print(f"    耗时 {time.time()-t0:.1f}s -> {json.dumps(r, ensure_ascii=False)[:260]}")
    snapshot("投后 0s")
    time.sleep(3); snapshot("投后 3s")
    time.sleep(5); snapshot("投后 8s")

    print("\n>>> 对照：先用 queue/play 推一个小队列（兜底通道）")
    small = rows[:2]
    items = [{"songId": s["id"], "title": s.get("title"), "artist": s.get("artist"),
              "duration": s.get("duration") or 200} for s in small]
    t0 = time.time()
    r2 = call(f"/rest/api/v1/peers/{enc}/queue/play", "POST",
              {"items": items, "startIndex": 0}, token=token)
    print(f"    耗时 {time.time()-t0:.1f}s -> {json.dumps(r2, ensure_ascii=False)[:260]}")
    snapshot("整队推送后 0s")
    time.sleep(3); snapshot("整队推送后 3s")

    print("\n>>> 再试 /v1/play 回主通道")
    t0 = time.time()
    r3 = call("/rest/api/v1/play", "POST",
              {"peerId": peer, "type": "playlist", "id": pid, "songId": target["id"]}, token=token)
    print(f"    耗时 {time.time()-t0:.1f}s -> {json.dumps(r3, ensure_ascii=False)[:260]}")
    time.sleep(2); snapshot("再投后 2s")


if __name__ == "__main__":
    main()
