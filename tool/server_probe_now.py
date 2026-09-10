#!/usr/bin/env python3
"""一次性诊断：直连真实服务端，验证 (1) songId 参数是否已上线 (2) 今日漫游等大歌单投屏是否成功。

比盲测客户端更快定位根因 —— 客户端只是发一个 HTTP 请求，服务端行为才是决定性的。
"""
from __future__ import annotations

import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = "http://192.168.10.240:46400"
CREDS = {"username": "xyz5378", "password": "@$qQ!J4pNnSoy8"}


def call(path: str, method: str = "GET", body=None, token: str | None = None, timeout: int = 120):
    req = urllib.request.Request(
        BASE + path,
        data=json.dumps(body).encode() if body is not None else None,
        method=method,
    )
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        raw = e.read()[:400].decode("utf8", "replace")
        return {"__http": e.code, "__body": raw}
    except Exception as e:  # noqa: BLE001
        return {"__err": repr(e)}


def main() -> None:
    print("=== 1. 登录 ===")
    tok = call("/rest/api/v1/auth/login", "POST", CREDS)
    if "token" not in tok:
        print("登录失败:", json.dumps(tok, ensure_ascii=False)[:400])
        sys.exit(1)
    token = tok["token"]
    print("token ok, len =", len(token))

    print("\n=== 2. 服务端版本/peer 列表 ===")
    peers = call("/rest/api/v1/peers", token=token)
    for p in peers.get("peers", []):
        print(f"  {p.get('peerId'):28} kind={p.get('kind'):8} avail={p.get('available')}")
    dlna = [p for p in peers.get("peers", []) if p.get("kind") == "dlna" and p.get("available")]
    if not dlna:
        print("!! 没有可用 DLNA peer")
        sys.exit(1)
    peer = dlna[0]["peerId"]

    print("\n=== 3. 找今日漫游 / 大歌单 ===")
    pls = call("/rest/api/v1/playlists?page=1&pageSize=200", token=token).get("items", [])
    roam = [p for p in pls if p.get("id") == "pl-daily-roam"]
    big = sorted(pls, key=lambda p: -(p.get("songCount") or 0))[:5]
    for p in roam + big:
        print(f"  {p.get('id'):28} songs={p.get('songCount')}  {p.get('name')}")

    targets = roam if roam else big[:1]
    pl = targets[0]
    pid, pname = pl["id"], pl.get("name")
    print(f"\n选定测试歌单: {pid} ({pname}) songCount={pl.get('songCount')}")

    print("\n=== 4. 取客户端行序前 3 首（模拟客户端列表） ===")
    enc = urllib.parse.quote(pid, safe="")
    tracks = call(f"/rest/api/v1/playlists/{enc}/tracks?page=1&pageSize=5", token=token)
    rows = [it for it in tracks.get("items", []) if it.get("playable") and it.get("isMatched") and it.get("id")]
    print(f"  返回 {len(tracks.get('items', []))} 条, 可播 {len(rows)} 条")
    for i, it in enumerate(rows[:3]):
        print(f"  [{i}] {it['id']:22} {it.get('title')} / {it.get('artist')}")
    if len(rows) < 2:
        print("!! 可播行不足，无法测试")
        sys.exit(1)

    # ---- 测试 A：不传 songId，传 startIndex=1（旧行为） ----
    print("\n=== 5. 测试 A：传 startIndex=1（旧行为） ===")
    t0 = time.time()
    ra = call("/rest/api/v1/play", "POST",
              {"peerId": peer, "type": "playlist", "id": pid, "startIndex": 1}, token=token)
    print(f"  耗时 {time.time()-t0:.1f}s  响应: {json.dumps(ra, ensure_ascii=False)[:300]}")
    time.sleep(2)
    q = call(f"/rest/api/v1/peers/{urllib.parse.quote(peer, safe='')}/queue?offset=1&size=1", token=token)
    got_a = (q.get("items") or [{}])[0].get("songId")
    print(f"  期望 songId={rows[1]['id']}  实到={got_a}  total={q.get('total')}  "
          f"{'一致' if got_a == rows[1]['id'] else '**不一致**'}")

    # ---- 测试 B：传 songId（新行为） ----
    print("\n=== 6. 测试 B：传 songId（新行为，需服务端 >= v2.3.22） ===")
    t0 = time.time()
    rb = call("/rest/api/v1/play", "POST",
              {"peerId": peer, "type": "playlist", "id": pid, "songId": rows[1]["id"]}, token=token)
    dt = time.time() - t0
    print(f"  耗时 {dt:.1f}s  响应: {json.dumps(rb, ensure_ascii=False)[:300]}")
    if "__http" in rb:
        print(f"  !! songId 参数未生效（HTTP {rb['__http']}）→ 服务端仍是旧版")
    else:
        print(f"  回执 songId={rb.get('songId')}  startIndex={rb.get('startIndex')}  queued={rb.get('queued')}")
        time.sleep(2)
        q2 = call(f"/rest/api/v1/peers/{urllib.parse.quote(peer, safe='')}/queue?offset=1&size=1", token=token)
        got_b = (q2.get("items") or [{}])[0].get("songId")
        print(f"  期望 songId={rows[1]['id']}  实到={got_b}  "
              f"{'一致' if got_b == rows[1]['id'] else '**不一致**'}")

    # ---- 测试 C：大歌单整体（今日漫游）主通道 ----
    print("\n=== 7. 测试 C：今日漫游主通道（首曲） ===")
    t0 = time.time()
    rc = call("/rest/api/v1/play", "POST",
              {"peerId": peer, "type": "playlist", "id": pid, "songId": rows[0]["id"]}, token=timeout if False else token)
    dt = time.time() - t0
    print(f"  耗时 {dt:.1f}s  响应: {json.dumps(rc, ensure_ascii=False)[:400]}")

    print("\n=== 8. 设备状态 ===")
    st = call(f"/rest/api/v1/peers/{urllib.parse.quote(peer, safe='')}/status", token=token)
    print(" ", json.dumps(st, ensure_ascii=False)[:300])
    q3 = call(f"/rest/api/v1/peers/{urllib.parse.quote(peer, safe='')}/queue?size=0", token=token, timeout=180)
    print(f"  队列 total={q3.get('total')} currentIndex={q3.get('currentIndex')} "
          f"isActive={q3.get('isActive')} currentMedia={(q3.get('currentMedia') or {}).get('title')}")


if __name__ == "__main__":
    main()
