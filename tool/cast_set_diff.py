#!/usr/bin/env python3
"""诊断：客户端列表 vs 服务端 resolveContentSongs 的**集合**差异。

同集异序的问题修完后，残留的是「集合本身不同」——服务端少推了几首。
本工具精确定位「少了哪几首」以及它们的库里字段（playable / songId / song 行是否存在）。
"""
from __future__ import annotations

import json
import urllib.error
import urllib.parse
import urllib.request

BASE = "http://192.168.10.240:46400"
CREDS = {"username": "xyz5378", "password": "@$qQ!J4pNnSoy8"}


def call(path, method="GET", body=None, token=None):
    req = urllib.request.Request(
        BASE + path,
        data=json.dumps(body).encode() if body is not None else None,
        method=method,
    )
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=90) as r:
            return json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"HTTP {e.code}: {e.read()[:200]!r}") from None


def main():
    token = call("/rest/api/v1/auth/login", "POST", CREDS)["token"]

    # 复现出问题的两个歌单
    pls = call("/rest/api/v1/playlists?page=1&pageSize=200", token=token)["items"]
    targets = [p for p in pls if (p.get("name") or "").startswith(("欧美万评优质女声", "华语经典"))]
    peer = next(p["peerId"] for p in call("/rest/api/v1/peers", token=token)["peers"]
                if p.get("kind") == "dlna" and p.get("available"))

    for pl in targets:
        pid, name = pl["id"], pl["name"]
        print(f"\n=== {name} (songCount={pl.get('songCount')}) ===")

        # 客户端列表（playable + isMatched + id）
        rows, page = [], 1
        enc = urllib.parse.quote(pid, safe="")
        while True:
            d = call(f"/rest/api/v1/playlists/{enc}/tracks?page={page}&pageSize=200", token=token)
            rows += d.get("items", [])
            if len(d.get("items", [])) < 200 or page > 20:
                break
            page += 1
        client_ids = [r["id"] for r in rows if r.get("playable") and r.get("isMatched") and r.get("id")]
        print(f"客户端可播行数 : {len(client_ids)}  (总 items {len(rows)})")

        # 服务端实际推的队列
        call("/rest/api/v1/play", "POST",
             {"peerId": peer, "type": "playlist", "id": pid, "startIndex": 0}, token=token)
        q = call(f"/rest/api/v1/peers/{urllib.parse.quote(peer, safe='')}/queue", token=token)
        server_ids = [i["songId"] for i in (q.get("items") or [])]
        print(f"服务端推队列   : {len(server_ids)}")

        cs, ss = set(client_ids), set(server_ids)
        missing = [i for i in client_ids if i not in ss]      # 客户端有、服务端没推
        extra = [i for i in server_ids if i not in cs]        # 服务端推了、客户端没有
        print(f"客户端有/服务端缺 : {len(missing)}")
        print(f"服务端有/客户端缺 : {len(extra)}")

        by_id = {r["id"]: r for r in rows}
        for sid in missing[:10]:
            r = by_id.get(sid, {})
            print(f"  [缺] {sid[:8]} {str(r.get('title'))[:30]!r} "
                  f"playable={r.get('playable')} isMatched={r.get('isMatched')} "
                  f"suffix={r.get('suffix')!r} size={r.get('size')}")
            # 直查该歌曲行是否存在
            try:
                s = call(f"/rest/api/v1/songs/{sid}", token=token)
                print(f"        /v1/songs 存在: {str(s.get('title'))[:30]!r} suffix={s.get('suffix')!r}")
            except Exception as e:  # noqa: BLE001
                print(f"        /v1/songs 查询失败: {e}")

        # 顺序是否一致（同集情况下）
        if cs == ss:
            same_order = client_ids == server_ids
            print(f"集合相同 → 顺序一致: {same_order}")
            if not same_order:
                for k, (a, b) in enumerate(zip(client_ids, server_ids)):
                    if a != b:
                        print(f"        首个顺序分歧 @ {k}: client={a[:8]} server={b[:8]}")
                        break


if __name__ == "__main__":
    main()
