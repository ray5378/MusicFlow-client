#!/usr/bin/env python3
"""投屏主通道 `startIndex` 错位取证工具。

背景：客户端点歌单/专辑时走主通道 `POST /rest/api/v1/play {peerId, type, id, startIndex}`，
只把**本地列表行号**交给服务端，服务端按自己的解析顺序取第 N 首。两侧顺序并不同源：

  客户端序  `/rest/api/v1/playlists/:id/tracks`  → orderBy(playlistSongs.position, id)
  服务端序  `resolveContentSongs('playlist')`    → where(playlistId).all().filter(playable)
                                                  **无 ORDER BY**（SQLite rowid 序）
  等价端点  `/rest/api/playlist/:id/tracks`      → 与上面同款查询（本工具用它取证）

顺序不一致 ⇒ 服务端第 N 首 ≠ 用户看到的第 N 行 ⇒ **静默播错歌**（越界还会静默归 0）。
另外顺手实测 queue 端点的 offset/size 体积收益（SPEC §12.1）。

用法：
    python tool/cast_index_alignment.py                 # 默认抽样 24 个歌单
    python tool/cast_index_alignment.py --sample 40
    python tool/cast_index_alignment.py --base http://192.168.10.240:46400

判定口径：`异集` 长度校验（queued != localItems.length）能抓到；
          `同集异序` 长度相同、顺序不同，**长度校验抓不到**，必须做槽位身份校验。
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
        with urllib.request.urlopen(req, timeout=40) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"HTTP {e.code}: {e.read()[:160]!r}") from None


def client_order(base: str, token: str, pid: str) -> list[str]:
    """客户端看到的行序（getAllPlaylistSongs 同款：逐页拉全量 + playable/isMatched）。"""
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


def server_order(base: str, token: str, pid: str) -> list[str]:
    """resolveContentSongs('playlist') 同款查询的返回序。"""
    enc = urllib.parse.quote(pid, safe="")
    rows = call(base, f"/rest/api/playlist/{enc}/tracks", token=token)
    return [r["songId"] for r in rows if r.get("playable") and r.get("songId")]


def queue_payload_probe(base: str, token: str) -> None:
    """SPEC §12.1：实测 /queue 分页体积（全量 vs size=1）。"""
    peers = call(base, "/rest/api/v1/peers", token=token).get("peers", [])
    target = None
    for p in peers:
        q = p.get("queue") or {}
        n = q.get("total") or len(q.get("items") or [])
        if n and (target is None or n > target[1]):
            target = (p["peerId"], n)
    if not target:
        print("\n[queue 体积] 没有带队列的 peer，跳过。")
        return
    pid, n = target
    enc = urllib.parse.quote(pid, safe="")
    print(f"\n[queue 体积] peer={pid!r} total={n}")
    for label, suffix in (("全量   ", ""), ("size=1 ", "?offset=0&size=1")):
        req = urllib.request.Request(base + f"/rest/api/v1/peers/{enc}/queue{suffix}")
        req.add_header("Authorization", "Bearer " + token)
        try:
            with urllib.request.urlopen(req, timeout=40) as resp:
                raw = resp.read()
            d = json.loads(raw)
            print(f"  {label} bytes={len(raw):>9} items={len(d.get('items') or [])} "
                  f"total={d.get('total')} currentIndex={d.get('currentIndex')} "
                  f"currentMedia={'有' if d.get('currentMedia') is not None else '无'}")
        except Exception as e:  # noqa: BLE001
            print(f"  {label} 失败: {e}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default=DEFAULT_BASE)
    ap.add_argument("--sample", type=int, default=24)
    ap.add_argument("--skip-queue", action="store_true", help="跳过 queue 体积实测")
    args = ap.parse_args()

    token = call(args.base, "/rest/api/v1/auth/login", "POST", CREDS)["token"]
    pls = call(args.base, "/rest/api/v1/playlists?page=1&pageSize=200", token=token)["items"]
    pls = [p for p in pls if (p.get("songCount") or 0) > 0][: args.sample]

    same_seq = same_set_diff = diff_set = failed = 0
    print(f"{'判定':<10}{'客户端':>7}{'服务端':>7}  歌单")
    for p in pls:
        pid, name = p["id"], (p.get("name") or "")[:26]
        try:
            a = client_order(args.base, token, pid)
            b = server_order(args.base, token, pid)
        except Exception as e:  # noqa: BLE001
            failed += 1
            print(f"{'拉取失败':<10}{'-':>7}{'-':>7}  {name} :: {e}")
            continue
        if a == b:
            same_seq += 1
            verdict = "同集同序"
        elif sorted(a) == sorted(b):
            same_set_diff += 1
            verdict = "同集异序"
        else:
            diff_set += 1
            verdict = "异集"
        print(f"{verdict:<10}{len(a):>7}{len(b):>7}  {name}")

    total = same_seq + same_set_diff + diff_set
    print(f"\n=== 结论（样本 {total} 个歌单）===")
    print(f"  同集同序（主通道安全）        : {same_seq}")
    print(f"  同集异序（长度校验抓不到!）   : {same_set_diff}")
    print(f"  异集（长度校验可抓，可回落）  : {diff_set}")
    if failed:
        print(f"  拉取失败                      : {failed}")
    if same_set_diff:
        print("\n  ⇒ 必须做槽位身份校验（playContentOnPeer 已实施），"
              "或给 resolveContentSongs 的 playlist 分支补 ORDER BY position。")

    if not args.skip_queue:
        queue_payload_probe(args.base, token)


if __name__ == "__main__":
    main()
