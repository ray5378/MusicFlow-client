#!/usr/bin/env python3
"""部署后严格验证：shuffle 模式下「指定起点」必须精确命中。

与 verify_shuffle_rootcause.py 的区别：那个脚本里 A 段依赖「服务器当前恰好是
shuffle」，一旦上轮跑完残留 playMode=one，A 段就退化成非 shuffle 路径（假绿）。
这里**显式先设 shuffle 再投**，保证测的真是历史 bug 那条路径。

覆盖：
  1. shuffle + songId(首曲)   x5  → 每次都必须是首曲
  2. shuffle + songId(中间曲) x5  → 每次都必须是那首（身份定位，非行号）
  3. shuffle + 未指定 songId  x6  → 必须随机（服务端是唯一随机点）
  4. shuffle 下回执带 shuffleOrder/shufflePos 且自洽
  5. 大歌单（今日漫游）全链路：queued 数 + 定位耗时
"""
from __future__ import annotations

import json
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = "http://192.168.10.240:46400"
CREDS = {"username": "xyz5378", "password": "@$qQ!J4pNnSoy8"}
PLAYLIST = "pl-daily-roam"

PASS: list[str] = []
FAIL: list[str] = []


def call(path, method="GET", body=None, token=None, timeout=300):
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
        return {"__http": e.code, "__body": e.read()[:400].decode("utf8", "replace")}
    except Exception as e:  # noqa: BLE001
        return {"__err": repr(e)}


def check(name: str, ok: bool, detail: str = ""):
    (PASS if ok else FAIL).append(name)
    print(f"  {'PASS' if ok else 'FAIL'}  {name}{('  ' + detail) if detail else ''}")


def main():
    token = call("/rest/api/v1/auth/login", "POST", CREDS)["token"]
    peers = [p for p in call("/rest/api/v1/peers", token=token)["peers"]
             if p.get("kind") == "dlna" and p.get("available")]
    peer = peers[0]["peerId"]
    enc = urllib.parse.quote(peer, safe="")
    encp = urllib.parse.quote(PLAYLIST, safe="")
    print(f"设备: {peer}\n歌单: {PLAYLIST}\n")

    # 取可播曲目样本（首曲 + 中间一首）
    page = call(f"/rest/api/v1/playlists/{encp}/tracks?page=1&pageSize=10", token=token)
    rows = [it for it in page["items"]
            if it.get("playable") and it.get("isMatched") and it.get("id")]
    assert len(rows) >= 2, f"可播样本不足: {len(rows)}"
    first, mid_src = rows[0], rows[5] if len(rows) > 5 else rows[-1]
    print(f"样本A(首): {first.get('title')} / {first.get('artist')}  id={first['id'][:12]}…")
    print(f"样本B(中): {mid_src.get('title')} / {mid_src.get('artist')}  id={mid_src['id'][:12]}…\n")

    def snapshot():
        return call(f"/rest/api/v1/peers/{enc}/queue?offset=0&size=1", token=token)

    def set_shuffle():
        call(f"/rest/api/v1/peers/{enc}/play-mode", "POST", {"mode": "shuffle"}, token=token)
        time.sleep(0.4)

    # ---------- 1. shuffle + songId 首曲 ----------
    print("=== 1. shuffle 模式 + 指定首曲 songId（x5，历史 bug 路径）===")
    set_shuffle()
    hits = 0
    for i in range(5):
        r = call("/rest/api/v1/play", "POST",
                 {"peerId": peer, "type": "playlist", "id": PLAYLIST,
                  "songId": first["id"]}, token=token)
        time.sleep(0.8)
        q = snapshot()
        cm = q.get("currentMedia") or {}
        good = cm.get("songId") == first["id"]
        hits += good
        print(f"  [{i+1}] playMode={r.get('playMode')} "
              f"回执startIndex={r.get('startIndex')} songId={str(r.get('songId'))[:12]}… "
              f"| 实播 idx={q.get('currentIndex')} {cm.get('title')} {'OK' if good else '<<< 错'}")
    check("shuffle+指定首曲 5/5 精确命中", hits == 5, f"({hits}/5)")

    # ---------- 2. shuffle + songId 中间曲 ----------
    print("\n=== 2. shuffle 模式 + 指定中间曲 songId（x5，身份定位而非行号）===")
    hits = 0
    for i in range(5):
        r = call("/rest/api/v1/play", "POST",
                 {"peerId": peer, "type": "playlist", "id": PLAYLIST,
                  "songId": mid_src["id"]}, token=token)
        time.sleep(0.8)
        q = snapshot()
        cm = q.get("currentMedia") or {}
        good = cm.get("songId") == mid_src["id"]
        hits += good
        print(f"  [{i+1}] 回执startIndex={r.get('startIndex')} | 实播 idx={q.get('currentIndex')} "
              f"{cm.get('title')} {'OK' if good else '<<< 错'}")
    check("shuffle+指定中间曲 5/5 精确命中", hits == 5, f"({hits}/5)")

    # ---------- 3. shuffle + 未指定 → 必须随机 ----------
    print("\n=== 3. shuffle 模式 + 不指定起点（x6，服务端是唯一随机点）===")
    idxs = []
    for i in range(6):
        call("/rest/api/v1/play", "POST",
             {"peerId": peer, "type": "playlist", "id": PLAYLIST}, token=token)
        time.sleep(0.8)
        q = snapshot()
        idxs.append(q.get("currentIndex"))
    uniq = len(set(idxs))
    print(f"  落点: {idxs}")
    check("未指定起点时确实随机（>=2 个不同落点）", uniq >= 2, f"({uniq} 个)")

    # ---------- 4. 回执 shuffleOrder 自洽 ----------
    print("\n=== 4. 回执携带服务端权威 shuffleOrder/shufflePos ===")
    set_shuffle()
    r = call("/rest/api/v1/play", "POST",
             {"peerId": peer, "type": "playlist", "id": PLAYLIST,
              "songId": mid_src["id"]}, token=token)
    order = r.get("shuffleOrder")
    pos = r.get("shufflePos")
    total = r.get("queued")
    ok_order = isinstance(order, list) and len(order) > 0
    ok_perm = ok_order and sorted(order) == list(range(len(order)))
    ok_pos = isinstance(pos, int) and 0 <= pos < (len(order) if ok_order else 1)
    ok_head = ok_order and ok_pos and order[pos] == r.get("startIndex")
    print(f"  queued={total} len(shuffleOrder)={len(order) if isinstance(order, list) else 'N/A'} "
          f"shufflePos={pos} startIndex={r.get('startIndex')}")
    check("shuffleOrder 是 0..n-1 完整排列", ok_perm)
    check("shufflePos 在界内", ok_pos)
    check("order[shufflePos] == startIndex（序列与起点自洽）", bool(ok_head))

    # ---------- 5. 大歌单全链路 ----------
    print("\n=== 5. 大歌单（今日漫游）全链路 ===")
    t0 = time.time()
    r = call("/rest/api/v1/play", "POST",
             {"peerId": peer, "type": "playlist", "id": PLAYLIST,
              "songId": first["id"]}, token=token)
    dt = time.time() - t0
    q = snapshot()
    cm = q.get("currentMedia") or {}
    queued = r.get("queued")
    total_srv = q.get("total")
    print(f"  queued={queued} 服务端total={total_srv} 耗时={dt:.1f}s")
    print(f"  回执songId={(r.get('songId') or '')[:12]}… 实播={cm.get('title')}")
    check("大歌单整队入库（queued>1000）", isinstance(queued, int) and queued > 1000,
          f"(queued={queued})")
    check("服务端 total 与 queued 一致", queued == total_srv, f"({queued} vs {total_srv})")
    check("大歌单下当前曲仍精确命中", cm.get("songId") == first["id"])
    check("定位耗时 < 30s", dt < 30, f"({dt:.1f}s)")

    # ---------- 汇总 ----------
    print("\n" + "=" * 60)
    print(f"通过 {len(PASS)}  失败 {len(FAIL)}")
    for f in FAIL:
        print(f"  FAIL: {f}")
    print("=" * 60)
    return 1 if FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
