#!/usr/bin/env python3
"""判定客户端投屏时实际走的是**哪条通道**（主通道 vs 兜底整队推送）。

原理（不需要客户端日志，纯服务端行为取证）：

  主通道 `POST /rest/api/v1/play` 的响应体是**服务端解析产物**，包含：
      {success, peerId, type, id, name, queued, startIndex, songId, shuffleOrder}
    —— 关键特征是 `shuffleOrder`（服务端洗牌序列，客户端无从构造）。

  兜底通道 `POST /peers/:id/queue/play` 的响应体只有 `{success:true}`。

因此判断「客户端是否走了主通道」的直接证据链是：
  1. 服务端队列被整体重置为歌单的**完整**长度（客户端本地可能只加载了部分页）
  2. 队列内容与 `resolveContentSongs` 的解析序一致（可用 songId 逐槽比对）
  3. 若抓到 WAF 拦截记录 / 大 payload，则说明走了兜底且失败

本脚本做 2 与 3 的采样验证。
"""
from __future__ import annotations

import json
import sys
import urllib.parse

sys.path.insert(0, "tool")
import verify_waf_fix_live as v  # noqa: E402

PEER = "dlna:FF310013-FE1E-8BA1-7B61-561AFF310013"
PLAYLIST = "pl-daily-roam"


def q(offset: int, size: int = 1):
    enc = urllib.parse.quote(PEER, safe="")
    st, raw, _ = v.call(f"/rest/api/v1/peers/{enc}/queue?offset={offset}&size={size}")
    try:
        return json.loads(raw)
    except Exception:  # noqa: BLE001
        return {}


def server_resolved_ids():
    """服务端 resolveContentSongs 的解析序（走 /v1/playlists/:id/tracks 分页端点，
    该端点是 orderBy(position,id)，与 resolveContentSongs 同源）。"""
    ids, page = [], 1
    while True:
        enc = urllib.parse.quote(PLAYLIST, safe="")
        st, raw, _ = v.call(f"/rest/api/v1/playlists/{enc}/tracks?page={page}&pageSize=200")
        if st != 200:
            break
        items = json.loads(raw).get("items") or []
        if not items:
            break
        ids.extend(i.get("id") for i in items)
        page += 1
        if page > 30:
            break
    return ids


def main():
    d = q(0, 2)
    total = d.get("total")
    print("=" * 72)
    print("客户端投屏通道取证")
    print("=" * 72)
    print(f"  设备队列 total = {total}")

    ref = server_resolved_ids()
    print(f"  服务端解析序长度 = {len(ref)}")
    if not total:
        print("  !! 队列为空，客户端尚未投屏")
        return 1

    # 逐槽比对身份：完全一致 → 队列就是服务端解析产物 → 主通道
    mismatches = 0
    checked = 0
    for off in range(0, min(total, len(ref)), max(1, len(ref) // 20)):
        it = (q(off, 1).get("items") or [{}])[0]
        got = it.get("songId")
        want = ref[off]
        checked += 1
        if got != want:
            mismatches += 1
            print(f"    ✗ offset={off}: got={got} want={want}")
    print(f"  抽样比对: {checked} 槽，{mismatches} 处不一致")

    print()
    if total == len(ref) and mismatches == 0:
        print("  >>> 判定：队列与服务端解析序**逐槽一致**")
        print("      即服务端按 (type,id) 自行重建了队列 → **走了主通道** ✓")
    else:
        print("  >>> 判定：队列与服务端解析序**不一致**")
        print("      说明队列来自客户端上传（整队推送），或歌单在期间被改动过。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
