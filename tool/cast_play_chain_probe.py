#!/usr/bin/env python3
"""真机联调：用 /v1/play 主通道实测 startIndex 是否落在正确的歌上。

比 /rest/api/playlist/:id/tracks 更贴近真实链路 —— 它走的就是
resolveContentSongs(type,id) 这条被修复的路径。

判定：
  取客户端列表第 N 行 songId（orderBy position,id 的行序）
  → POST /v1/play {peerId, type: playlist, id, startIndex: N}
  → 读回 GET /peers/:id/queue?offset=N&size=1 的 songId
  一致 = 槽位正确；不一致 = 静默播错歌。

用法：
    python tool/cast_play_chain_probe.py                # 前 24 个歌单，各测第 0/中/末行
    python tool/cast_play_chain_probe.py --sample 40
    python tool/cast_play_chain_probe.py --peer dlna:XXX
"""
from __future__ import annotations

import argparse
import json
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_BASE = "http://192.168.10.240:46400"
CREDS = {"username": "xyz5378", "password": "@$qQ!J4pNnSoy8"}


def call(base: str, path: str, method: str = "GET", body=None, token: str | None = None):
    req = urllib.request.Request(
        base + path,
        data=json.dumps(body).encode() if body is not None else None,
        method=method,
    )
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"HTTP {e.code}: {e.read()[:200]!r}") from None


def client_order(base: str, token: str, pid: str) -> list[str]:
    """客户端看到的行序（/v1/playlists/:id/tracks，同 orderBy position,id）。"""
    out: list[str] = []
    page = 1
    while True:
        enc = urllib.parse.quote(pid, safe="")
        d = call(base, f"/rest/api/v1/playlists/{enc}/tracks?page={page}&pageSize=200", token=token)
        for it in d.get("items", []):
            if it.get("playable") and it.get("isMatched") and it.get("id"):
                out.append(it["id"])
        if len(d.get("items", [])) < 200 or page > 60:
            break
        page += 1
    return out


def queue_slot(base: str, token: str, peer: str, idx: int) -> tuple[str | None, int]:
    """返回 (该槽位 songId, 队列总长)。total 恒为全量长度，与 offset/size 无关。"""
    enc = urllib.parse.quote(peer, safe="")
    d = call(
        base,
        f"/rest/api/v1/peers/{enc}/queue?offset={idx}&size=1",
        token=token,
    )
    items = d.get("items") or []
    total = d.get("total")
    if total is None:
        total = len(items)
    if not items:
        return None, int(total)
    return items[0].get("songId"), int(total)


def pick_cast_peer(base: str, token: str, forced: str | None) -> str:
    if forced:
        return forced
    peers = call(base, "/rest/api/v1/peers", token=token).get("peers", [])
    for p in peers:
        if p.get("kind") == "dlna" and p.get("available"):
            return p["peerId"]
    raise SystemExit("没有可用的 DLNA peer")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default=DEFAULT_BASE)
    ap.add_argument("--sample", type=int, default=24)
    ap.add_argument("--peer", default=None)
    args = ap.parse_args()

    token = call(args.base, "/rest/api/v1/auth/login", "POST", CREDS)["token"]
    peer = pick_cast_peer(args.base, token, args.peer)
    print(f"peer = {peer}\n")

    pls = call(args.base, "/rest/api/v1/playlists?page=1&pageSize=200", token=token)["items"]
    pls = [p for p in pls if (p.get("songCount") or 0) > 0][: args.sample]

    ok = bad = skipped = 0
    print(f"{'判定':<8}{'行号':>6}  {'期望':<10}{'实到':<10}歌单")
    for p in pls:
        pid, name = p["id"], (p.get("name") or "")[:24]
        try:
            rows = client_order(args.base, token, pid)
        except Exception as e:  # noqa: BLE001
            skipped += 1
            print(f"{'拉取失败':<8}{'-':>6}  {'-':<10}{'-':<10}{name} :: {e}")
            continue
        if len(rows) < 2:
            skipped += 1
            continue
        # 测 3 个位置：首行、中间、末行
        # 注意：每次 /v1/play 都会**重置整个队列**，故判定必须紧跟在一次 play 之后，
        # 且只能读该次 play 之后的队列快照（不能跨歌单复用 offset）。
        probes = sorted({0, len(rows) // 2, len(rows) - 1})
        for idx in probes:
            expected = rows[idx]
            try:
                call(
                    args.base,
                    "/rest/api/v1/play",
                    "POST",
                    {"peerId": peer, "type": "playlist", "id": pid, "startIndex": idx},
                    token=token,
                )
                # 本次 play 刚推的队列，长度应等于 rows（或服务端可播子集）
                snap = queue_slot(args.base, token, peer, idx)
                got = snap[0] if snap else None
                total = snap[1] if snap else 0
            except Exception as e:  # noqa: BLE001
                print(f"{'请求失败':<8}{idx:>6}  {expected[:8]:<10}{'-':<10}{name} :: {e}")
                skipped += 1
                continue
            if got == expected:
                ok += 1
                if idx == probes[0]:
                    print(f"{'一致':<8}{idx:>6}  {expected[:8]:<10}{(got or '-')[:8]:<10}{name}")
            else:
                bad += 1
                print(
                    f"{'**错位**':<8}{idx:>6}  {expected[:8]:<10}{(got or '-')[:8]:<10}"
                    f"{name}  [queue total={total} 本地行数={len(rows)}]"
                )

    print(f"\n=== 结论（{len(pls)} 个歌单，{ok + bad} 次实测）===")
    print(f"  槽位一致 : {ok}")
    print(f"  **槽位错位** : {bad}")
    print(f"  跳过     : {skipped}")


if __name__ == "__main__":
    main()
