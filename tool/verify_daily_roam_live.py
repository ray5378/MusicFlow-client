#!/usr/bin/env python3
"""公网 WAF 开启状态下，用**今日漫游（3251 首）大歌单**验证主通道修复。

对照三组，覆盖客户端会走的两条通道：

  A. 主通道  POST /rest/api/v1/play {peerId,type,id,songId}   —— 应成功（几百字节）
  B. 兜底通道 POST /peers/:id/queue/play {items,...}          —— 大歌单整队，闸门开则应被拦
  C. 主通道起点定位：指定歌单**中间位置**的 songId，验证不是静默从头播

用法：python tool/verify_daily_roam_live.py
"""
from __future__ import annotations

import json
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

WAN = "https://music.cmct.fun:35378"
CREDS = {"username": "xyz5378", "password": "@$qQ!J4pNnSoy8"}
PEER = "dlna:FF310013-FE1E-8BA1-7B61-561AFF310013"          # 主卧 HiVi H5MKII
PLAYLIST_ID = "pl-daily-roam"                                # 今日漫游 3251 首
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE


def call(path: str, body=None, timeout: int = 240):
    sep = "&" if "?" in path else "?"
    auth = urllib.parse.urlencode(
        {"u": CREDS["username"], "p": CREDS["password"], "v": "1.16.1",
         "c": "verify-daily-roam", "f": "json"}
    )
    url = f"{WAN}{path}{sep}{auth}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method="POST" if data else "GET")
    if data:
        req.add_header("Content-Type", "application/json")
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, context=CTX, timeout=timeout) as r:
            return r.status, r.read(), int((time.time() - t0) * 1000)
    except urllib.error.HTTPError as e:
        return e.code, e.read(), int((time.time() - t0) * 1000)
    except Exception as e:  # noqa: BLE001
        return -1, f"{type(e).__name__}: {e}".encode(), int((time.time() - t0) * 1000)


def gated(raw: bytes) -> bool:
    return b"Lucky WAF" in raw


def fetch_tracks(page=1, size=200):
    """拉歌单曲目（分页端点，orderBy(position,id)）。"""
    enc = urllib.parse.quote(PLAYLIST_ID, safe="")
    st, raw, _ = call(f"/rest/api/v1/playlists/{enc}/tracks?page={page}&pageSize={size}")
    if st != 200:
        return []
    try:
        return json.loads(raw).get("items") or []
    except Exception:  # noqa: BLE001
        return []


def get_queue_offset(offset: int, size: int = 1):
    """读服务端队列的指定槽位，用于验证起点定位是否真的生效。"""
    enc = urllib.parse.quote(PEER, safe="")
    st, raw, _ = call(f"/rest/api/v1/peers/{enc}/queue?offset={offset}&size={size}")
    if st != 200:
        return None
    try:
        return json.loads(raw)
    except Exception:  # noqa: BLE001
        return None


def main():
    print("=" * 78)
    print("公网验证：今日漫游（3251 首）大歌单 — 主通道 vs 兜底通道")
    print("=" * 78)
    print(f"  入口: {WAN}")
    print(f"  设备: {PEER}")
    print(f"  歌单: {PLAYLIST_ID}（今日漫游）")
    print()

    # ---------- 取整份歌单（分页拉完，模拟客户端本地列表） ----------
    tracks, page = [], 1
    while True:
        batch = fetch_tracks(page, 200)
        if not batch:
            break
        tracks.extend(batch)
        page += 1
        if page > 30:
            break
    print(f"  本地拉取歌单曲目: {len(tracks)} 首（{page-1} 页）")
    if len(tracks) < 2:
        print("  !! 歌单为空或拉取失败，无法验证")
        return 1
    print(f"  首曲: {tracks[0].get('title')!r}  id={tracks[0].get('id')}")
    mid = len(tracks) // 2
    print(f"  中位: {tracks[mid].get('title')!r}  id={tracks[mid].get('id')}  (offset={mid})")
    print()

    # ---------- A. 主通道，起点 = 中位 songId（身份定位） ----------
    print("─" * 78)
    print("A. 主通道 POST /rest/api/v1/play（起点=中位 songId，身份定位）")
    print("─" * 78)
    body = {"peerId": PEER, "type": "playlist", "id": PLAYLIST_ID,
            "songId": tracks[mid].get("id")}
    payload_size = len(json.dumps(body))
    st, raw, ms = call("/rest/api/v1/play", body=body, timeout=240)
    armed = gated(raw)
    try:
        resp = json.loads(raw)
    except Exception:  # noqa: BLE001
        resp = {}
    print(f"  payload = {payload_size} 字节（整队推送约 {len(tracks)*400/1024:.0f}KB）")
    print(f"  HTTP={st}  {ms}ms  WAF拦截={armed}")
    print(f"  queued={resp.get('queued')}  startIndex={resp.get('startIndex')}  "
          f"echo songId={resp.get('songId')}")
    main_ok = st == 200 and not armed and resp.get("success") is True
    print(f"  >>> {'✅ 主通道成功' if main_ok else '❌ 主通道失败'}")
    print()

    # ---------- 起点定位校验：读回队列，确认设备真的停在中位那首 ----------
    if main_ok:
        print("  起点校验：读服务端队列槽位，确认不是静默从头播")
        for label, want in (("中位", tracks[mid]), ("首曲", tracks[0])):
            q = get_queue_offset(mid if label == "中位" else 0, 1)
            if not q:
                print(f"    {label}: 读队列失败")
                continue
            items = q.get("items") or []
            got = items[0].get("songId") if items else None
            print(f"    {label}: 槽位 songId={got}  期望={want.get('id')}  "
                  f"{'✅ 一致' if got == want.get('id') else '❌ 不一致'}")
        ci = None
        q = get_queue_offset(0, 1)
        if q:
            ci = q.get("currentIndex")
        print(f"    服务端 currentIndex={ci}（期望 {mid} 附近，shuffle 模式下为洗牌序）")
        print()

    # ---------- B. 兜底通道：大歌单整队 ----------
    print("─" * 78)
    print(f"B. 兜底通道 POST /peers/:id/queue/play（整队 {len(tracks)} 首）")
    print("─" * 78)
    items = [{"songId": t.get("id"), "title": t.get("title"), "artist": t.get("artist"),
              "album": t.get("album"), "duration": t.get("duration") or 0}
             for t in tracks]
    qbody = {"items": items, "startIndex": 0}
    qsize = len(json.dumps(qbody))
    enc = urllib.parse.quote(PEER, safe="")
    st2, raw2, ms2 = call(f"/rest/api/v1/peers/{enc}/queue/play", body=qbody, timeout=300)
    armed2 = gated(raw2)
    print(f"  payload = {qsize/1024:.1f}KB")
    print(f"  HTTP={st2}  {ms2}ms  WAF拦截={armed2}")
    print(f"  body: {raw2[:200].decode('utf-8','replace')!r}")
    print()

    # ---------- 汇总 ----------
    print("=" * 78)
    print("汇总")
    print("=" * 78)
    print(f"  A 主通道（148B 级）      : {'✅ 成功' if main_ok else '❌ 失败'}")
    print(f"  B 兜底通道（{qsize/1024:.0f}KB）    : "
          f"{'*** 被 WAF 拦截 ***' if armed2 else ('200 通过' if st2 == 200 else f'HTTP {st2}')}")
    print()
    if armed2:
        print("  → 闸门已生效：整队推送被拦、主通道畅通。修复有效性得到证明。")
    else:
        print("  → 闸门当前未拦（关闭态）。主通道依然成功，但无法在此证明"
              "「闸门开启时整队会失败」。")
    return 0 if main_ok else 1


if __name__ == "__main__":
    sys.exit(main())
