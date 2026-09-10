#!/usr/bin/env python3
"""真机端到端验证：接续搬移改走主通道后，大歌单在**公网入口**能否成功。

背景（2026-09-10 真机复现）：
  本机放好 842 首歌单 → 「推到音箱」走的是 `pushLocalToPeer`，修复前**只**做
  整队推送（848KB body）→ 撞公网 Lucky WAF ~90KB 闸门 → 403。

  **闸门确认存在**（不是猜测）：公网入口（反代 Lucky WAF）对
  `POST /peers/:id/queue/play` + 大批量 JSON 数组有体积闸门，约 90KB（≈300 首）
  起触发，响应体是 `<title>403 - Lucky WAF</title>` —— 反代层拒绝，不是服务端。

  ⚠️ **复测注意（2026-09-10 踩过）**：该闸门可被运维临时关闭。闸门关闭期间用本
  脚本会看到 541KB/642KB/868KB 也返回 HTTP 200，**那是闸门关闭态，不代表整队
  推送可用**。若据此得出「WAF 不是体积闸门」的结论并回退主通道优先，会在闸门
  恢复后立刻线上失败。判定闸门是否生效的正确姿势：看**响应体**是否出现
  `Lucky WAF` 或状态码 403，而不是只看体积是否通过。

修复后该路径改为**主通道优先**：只发 `POST /rest/api/v1/play`
{peerId, type, id, songId}（几百字节），由服务端自行解析队列。

主通道的真正价值（两个层面）：
  1. **可用性（决定性的）**：body 恒为几百字节，与队列规模无关 → 永远不过 WAF
     闸门。整队推送在公网**不是慢，而是根本发不出去**。
  2. 性能：实测 115B/205ms vs 642.3KB/8411ms（3251 首）→ 缩约 5720×、快约 27×。

本脚本从客户端视角，对**真实服务端**验证三件事：
  A. 主通道载荷体积（证明与队列规模无关）
  B. 主通道在公网 :35378 能否成功起播大歌单
  C. 对照：整队推送在公网是否被闸门拦掉（**闸门关闭时会通过，见上方警告**）

用法：
    python tool/verify_handoff_main_channel.py [--peer <peerId>]
不传 --peer 时自动挑选一个可用的 DLNA 设备。
"""
from __future__ import annotations

import argparse
import json
import ssl
import sys
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


def auth(base: str) -> None:
    """登录取 token；失败即退出（后续请求仍带 u/p 参数，兼容 Subsonic 鉴权）。"""
    q = urllib.parse.urlencode(
        {
            "u": CREDS["username"],
            "p": CREDS["password"],
            "v": "1.16.1",
            "c": "verify-handoff",
            "f": "json",
        }
    )
    url = f"{base}/rest/ping.view?{q}"
    with urllib.request.urlopen(url, context=CTX, timeout=20) as r:
        body = json.loads(r.read())
    resp = body.get("subsonic-response", {})
    if resp.get("status") != "ok":
        raise SystemExit(f"登录失败: {resp}")


def call(base: str, path: str, *, data=None, method=None, timeout=180):
    """发请求，返回 (status, body_bytes, elapsed_ms)。不抛 4xx/5xx。"""
    url = f"{base}{path}"
    payload = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(url, data=payload, method=method or ("POST" if data else "GET"))
    req.add_header("Content-Type", "application/json")
    # 带上鉴权参数（服务端从 token 或 u/p 解析）
    sep = "&" if "?" in url else "?"
    req.full_url = f"{url}{sep}{urllib.parse.urlencode({'u': CREDS['username'], 'p': CREDS['password'], 'v': '1.16.1', 'c': 'verify-handoff', 'f': 'json'})}"
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, context=CTX, timeout=timeout) as r:
            return r.status, r.read(), int((time.time() - t0) * 1000)
    except urllib.error.HTTPError as e:
        return e.code, e.read(), int((time.time() - t0) * 1000)
    except Exception as e:  # noqa: BLE001
        return -1, str(e).encode(), int((time.time() - t0) * 1000)


def pick_peer(base: str) -> str | None:
    st, body, _ = call(base, "/rest/api/v1/peers")
    if st != 200:
        return None
    try:
        data = json.loads(body)
    except Exception:  # noqa: BLE001
        return None
    peers = data.get("peers") or []
    for p in peers:
        if isinstance(p, dict) and p.get("kind") == "dlna" and p.get("available"):
            return p.get("peerId")
    return None


def pick_big_playlist(base: str) -> tuple[str, int] | None:
    """找一个歌曲数最多的歌单，返回 (id, songCount)。

    服务端歌单列表是 `/rest/api/v1/playlists`（返回 {total,page,pageSize,items}），
    不是 Subsonic 的 getPlaylists.view（该路径 404）。
    """
    st, body, _ = call(base, "/rest/api/v1/playlists?pageSize=200")
    if st != 200:
        return None
    try:
        items = json.loads(body).get("items") or []
    except Exception:  # noqa: BLE001
        return None
    best, best_n = None, -1
    for pl in items:
        if not isinstance(pl, dict):
            continue
        n = pl.get("songCount", pl.get("song_count", 0)) or 0
        if n > best_n:
            best, best_n = pl.get("id"), n
    return (best, best_n) if best else None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--peer", help="目标 DLNA peerId（缺省自动挑选）")
    ap.add_argument("--playlist", help="歌单 id（缺省挑最大的）")
    ap.add_argument("--base", default=WAN, help=f"服务端地址（默认公网 {WAN}）")
    args = ap.parse_args()

    base = args.base
    print(f"服务端: {base}")
    auth(base)

    peer = args.peer or pick_peer(base)
    if not peer:
        print("!! 未找到可用 DLNA 设备，无法验证起播（可 --peer 指定）")
        return 1
    print(f"目标设备: {peer}")

    # ---------- A/B: 主通道 vs 整队推送 ----------
    if args.playlist:
        pl_id, n = args.playlist, -1
    else:
        got = pick_big_playlist(base)
        if not got:
            print("!! 没找到歌单，无法验证")
            return 1
        pl_id, n = got
    print(f"歌单: {pl_id}（{n} 首）\n")

    # --- 主通道：只发 {peerId,type,id} ---
    main_payload = {"peerId": peer, "type": "playlist", "id": pl_id, "startIndex": 0}
    main_bytes = len(json.dumps(main_payload).encode())
    print("[主通道] POST /rest/api/v1/play")
    print(f"  请求体: {main_bytes} 字节  {json.dumps(main_payload, ensure_ascii=False)}")
    st, body, ms = call(base, "/rest/api/v1/play", data=main_payload)
    ok_main = st == 200 and b'"success":true' in body.replace(b" ", b"")
    print(f"  -> HTTP {st}  {ms}ms  {'OK' if ok_main else 'FAIL'}")
    if not ok_main:
        print(f"  响应片段: {body[:300]!r}")
    print(f"  载荷/队列规模: {main_bytes}B —— **与队列长度无关**"
          f"（3251 首时实测仍 115B）\n")

    # --- 对照：整队推送（证明规模的代价）---
    print("[对照·整队推送] POST /rest/api/v1/peers/<id>/queue/play")
    # 构造足够大的假队列以逼近真实体积（真实队列需先拉全量，这里只验体积/耗时）
    fake_items = [
        {"songId": f"s{i}", "title": f"曲目 {i} 测试填充用标题", "artist": "某某歌手",
         "artistId": "ar1", "albumId": "al1", "duration": 240, "suffix": "mp3"}
        for i in range(max(n, 842))
    ]
    qp_payload = {"items": fake_items, "startIndex": 0}
    qp_bytes = len(json.dumps(qp_payload).encode())
    st2, body2, ms2 = call(base, f"/rest/api/v1/peers/{peer}/queue/play", data=qp_payload, timeout=180)
    blocked = b"Lucky WAF" in body2 or st2 == 403
    print(f"  请求体: {qp_bytes/1024:.1f}KB（{len(fake_items)} 首）")
    print(f"  -> HTTP {st2}  {ms2}ms  {'被拦掉' if blocked else '通过'}")
    if blocked:
        print(f"  响应含: {'Lucky WAF' if b'Lucky WAF' in body2 else body2[:120]!r}")
    print()

    # ---------- 汇总结论 ----------
    print("=" * 60)
    print(f"主通道起播大歌单: {'✅ 成功' if ok_main else '❌ 失败'}")
    if blocked:
        print("整队推送上公网:   ❌ 被 WAF 闸门拦掉（预期行为，证明闸门生效）")
    else:
        print("整队推送上公网:   ⚠️  通过了 —— **可能是闸门被临时关闭**。")
        print("                  这不代表整队推送可用：闸门恢复后大歌单会 403。")
        print("                  判定闸门状态请看响应体是否含 'Lucky WAF'，而非体积。")
    print(f"载荷比: 主通道 {main_bytes}B vs 整队 {qp_bytes/1024:.0f}KB "
          f"= 缩小 {qp_bytes/max(main_bytes,1):.0f}×")
    print(f"耗时比: 主通道 {ms}ms vs 整队 {ms2}ms "
          f"= 快 {ms2/max(ms,1):.0f}×")
    print("=" * 60)
    print("结论: 主通道优先是**可用性要求**（body 与规模无关，永不过闸门），")
    print("      不是性能优化 —— 任何情况下都不得回退为整队推送优先。")
    return 0 if ok_main else 1


if __name__ == "__main__":
    sys.exit(main())
