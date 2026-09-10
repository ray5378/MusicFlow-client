#!/usr/bin/env python3
"""复现「真机推大歌单失败」：客户端 pushLocalToPeer 走的是整队推送
POST /rest/api/v1/peers/:id/queue/play,payload = 842 首歌。

日志观测(2026-09-10 16:03):
  [FALLBACK] request POST /rest/api/v1/peers/dlna:FF31.../queue/play via 家
  [FALLBACK] GET /rest/api/v1/peers/.../queue -> 200   (前一步)
  → 之后 POST 再无 -> 200 回执，说明请求卡住/超时。

本脚本直接对真实服务端发同样形状的 payload，测：
  1. payload 实际体积（对 842 首）
  2. 服务端处理耗时（是否真如记忆所说「不随规模线性劣化」）
  3. 客户端 budget 是否够（queueTransferBudget(842) = 10s + 30ms*842 ≈ 35s）
  4. 对比轻量主通道 /v1/play 的耗时
"""
from __future__ import annotations

import json
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = "http://192.168.10.240:46400"
CREDS = {"username": "xyz5378", "password": "@$qQ!J4pNnSoy8"}


def call(path, method="GET", body=None, token=None, timeout=300, raw=False):
    data = None
    if body is not None:
        data = json.dumps(body).encode() if not raw else body
    req = urllib.request.Request(BASE + path, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            payload = r.read()
            return {"__ms": int((time.time() - t0) * 1000),
                    "__len": len(payload),
                    "__json": json.loads(payload or b"{}")}
    except urllib.error.HTTPError as e:
        return {"__http": e.code,
                "__ms": int((time.time() - t0) * 1000),
                "__body": e.read()[:400].decode("utf8", "replace")}
    except Exception as e:  # noqa: BLE001
        return {"__err": repr(e), "__ms": int((time.time() - t0) * 1000)}


def song_to_queue_item(t):
    """对齐客户端 songToQueueItem 的形状（见 lib/data/models/peer.dart）。"""
    return {
        "songId": t["id"],
        "title": t.get("title") or "",
        "artist": t.get("artist") or "",
        "album": t.get("album") or "",
        "coverArt": t.get("coverArt") or "",
        "duration": t.get("duration") or 0,
        "suffix": t.get("suffix") or "",
    }


def main():
    token = call("/rest/api/v1/auth/login", "POST", CREDS)["__json"]["token"]
    peers = [p for p in call("/rest/api/v1/peers", token=token)["__json"]["peers"]
             if p.get("kind") == "dlna"]
    print("=== 可用 DLNA 设备 ===")
    for p in peers:
        print(f"  {p['peerId']}  available={p.get('available')}  name={p.get('name')}")
    avail = [p for p in peers if p.get("available")]
    if not avail:
        print("!! 当前没有 available 的设备，后续投递会失败（这本身就可能是日志里的原因）")
        return 1
    peer = avail[0]["peerId"]
    enc = urllib.parse.quote(peer, safe="")
    print(f"\n使用设备: {peer}\n")

    # ---- 造一个 842 首的大队列（贴近日志里的 queueLen=842）----
    print("=== 取歌建立大队列 ===")
    songs = []
    page = 1
    while len(songs) < 842 and page <= 20:
        r = call(f"/rest/api/v1/songs?page={page}&pageSize=200", token=token)
        items = (r.get("__json") or {}).get("items") or []
        if not items:
            break
        songs.extend(items)
        page += 1
    songs = songs[:842]
    print(f"  取到 {len(songs)} 首")

    items = [song_to_queue_item(s) for s in songs]
    payload = json.dumps({"items": items, "startIndex": 33}).encode()
    print(f"  payload 体积: {len(payload)} bytes ({len(payload)/1048576:.2f} MB)")

    # ---- 客户端 budget 公式（见 cast_peer_provider.dart queueTransferBudget）----
    budget_ms = max(10000, min(180000, 10000 + 30 * len(items)))
    print(f"  客户端 budget = {budget_ms}ms ({budget_ms/1000:.1f}s)")

    # ---- 1. 整队推送 queue/play（日志里的那条路）----
    print("\n=== 1. POST /queue/play 整队推送（客户端实际走的路）===")
    r = call(f"/rest/api/v1/peers/{enc}/queue/play", "POST",
             payload, token=token, timeout=300, raw=True)
    print(f"  耗时={r.get('__ms')}ms  结果={ {k: v for k, v in r.items() if not k.startswith('__json')} }")
    if "__json" in r:
        j = r["__json"]
        print(f"  success={j.get('success')} queued={j.get('queued')} startIndex={j.get('startIndex')}")
        print(f"  budget={budget_ms}ms vs 实际={r['__ms']}ms → "
              f"{'在预算内' if r['__ms'] < budget_ms else '<<< 超出客户端预算!'}")

    # ---- 2. 主通道 /v1/play 对照 ----
    print("\n=== 2. POST /v1/play 主通道（轻量，对照）===")
    r2 = call("/rest/api/v1/play", "POST",
              {"peerId": peer, "type": "playlist", "id": "pl-daily-roam",
               "songId": songs[33]["id"]}, token=token)
    print(f"  耗时={r2.get('__ms')}ms  queued={r2.get('__json', {}).get('queued')} "
          f"startIndex={r2.get('__json', {}).get('startIndex')}")

    # ---- 3. 队列回读，确认设备是否真的吃下了 ----
    print("\n=== 3. 回读设备队列 ===")
    q = call(f"/rest/api/v1/peers/{enc}/queue?offset=0&size=1", token=token)
    j = q.get("__json") or {}
    print(f"  total={j.get('total')} currentIndex={j.get('currentIndex')} "
          f"isActive={j.get('isActive')} currentMedia={(j.get('currentMedia') or {}).get('title')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
