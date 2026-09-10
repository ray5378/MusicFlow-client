#!/usr/bin/env python3
"""验证 WAF 闸门当前状态 + 主通道优先修复在公网真实生效。

三步：
  1. 确认服务端版本 == 62e9c86 系列（确认测的是修复后的代码）
  2. **闸门是否真的开着**：用二分法找 /queue/play 的拦截阈值
     （判据看**响应体**是否含 `Lucky WAF`，不看状态码是否 200）
  3. 主通道 /rest/api/v1/play 在大歌单上是否成功起播（这才是修复的验证）

用法：python tool/verify_waf_fix_live.py
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
PEER = "dlna:FF310013-FE1E-8BA1-7B61-561AFF310013"  # 主卧 HiVi H5MKII
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE


def call(path: str, body=None, timeout: int = 180):
    """返回 (status, raw_bytes, elapsed_ms)。鉴权走 query 参数 u/p。"""
    sep = "&" if "?" in path else "?"
    auth = urllib.parse.urlencode(
        {"u": CREDS["username"], "p": CREDS["password"], "v": "1.16.1",
         "c": "verify-waf-fix", "f": "json"}
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


def is_gated(raw: bytes) -> bool:
    """闸门判据：**响应体**里出现 Lucky WAF（反代特征），而不是看状态码。"""
    return b"Lucky WAF" in raw


def step1_version():
    print("=" * 72)
    print("步骤 1：确认服务端版本")
    print("=" * 72)
    q = urllib.parse.urlencode({"u": CREDS["username"], "p": CREDS["password"],
                                "v": "1.16.1", "c": "verify-waf-fix", "f": "json"})
    st, raw, _ = call(f"/rest/ping.view?{q}")
    ver = ""
    try:
        ver = json.loads(raw)["subsonic-response"].get("serverVersion", "")
    except Exception:  # noqa: BLE001
        pass
    print(f"  HTTP={st}  serverVersion={ver!r}")
    ok = "62e9c86" in ver
    print(f"  {'OK' if ok else 'WARN'}: 修复版本 {'已部署' if ok else '未确认'}")
    print()
    return ok


def step2_gate():
    print("=" * 72)
    print("步骤 2：WAF 闸门当前是否生效（二分找拦截阈值）")
    print("=" * 72)
    filler = "x" * 400
    results = []
    for n in (50, 150, 300, 600, 1000, 1500):
        items = [{"songId": f"probe-{i}", "title": filler, "artist": "probe",
                  "album": "probe", "duration": 180} for i in range(n)]
        body = {"items": items, "startIndex": 0}
        size = len(json.dumps(body))
        st, raw, ms = call(f"/rest/api/v1/peers/{urllib.parse.quote(PEER, safe='')}/queue/play",
                           body=body)
        gated = is_gated(raw)
        results.append((n, size, st, gated))
        print(f"  n={n:5d}  body={size/1024:8.1f}KB  HTTP={st:3d}  {ms:6d}ms  "
              f"{'*** WAF 拦截 ***' if gated else '通过'}  {raw[:70].decode('utf-8','replace')!r}")
    print()
    gated_any = any(r[3] for r in results)
    passed_any = any(not r[3] and r[2] == 200 for r in results)
    if gated_any:
        print("  >>> 结论：WAF 闸门【已生效】—— 整队推送被拦截，主通道优先是必需的。")
    elif passed_any:
        print("  >>> 结论：闸门【当前未生效】（大 payload 全通过）。")
        print("      注意：这不代表闸门不存在，只代表此刻是关闭态；")
        print("      下次开启后整队推送仍会失败 → 主通道优先依然是必需的。")
    print()
    return results


def pick_big_playlist():
    st, raw, _ = call("/rest/api/v1/playlists?page=1&pageSize=200")
    if st != 200:
        return None
    try:
        d = json.loads(raw)
    except Exception:  # noqa: BLE001
        return None
    items = d.get("items") or []
    best = None
    for p in items:
        n = p.get("songCount") or p.get("songTotal") or 0
        if best is None or n > best[1]:
            best = (p.get("id"), n, p.get("name"))
    return best


def step3_main_channel():
    print("=" * 72)
    print("步骤 3：主通道 /rest/api/v1/play 起播大歌单（修复的核心验证）")
    print("=" * 72)
    pl = pick_big_playlist()
    if not pl:
        print("  找不到歌单，跳过")
        return False
    pid, count, name = pl
    print(f"  目标歌单：{name!r}  id={pid}  songCount={count}")

    # 取歌单第一首的 songId 做身份定位（与客户端行为一致）
    st, raw, _ = call(f"/rest/api/v1/playlists/{urllib.parse.quote(pid, safe='')}/tracks?page=1&pageSize=1")
    song_id = None
    if st == 200:
        try:
            items = json.loads(raw).get("items") or []
            if items:
                song_id = items[0].get("id")
        except Exception:  # noqa: BLE001
            pass
    print(f"  起点 songId（身份定位）= {song_id!r}")

    body = {"peerId": PEER, "type": "playlist", "id": pid}
    if song_id:
        body["songId"] = song_id
    size = len(json.dumps(body))
    print(f"  主通道 payload = {size} 字节（整队推送约 {count}×400B ≈ {count*400/1024:.0f}KB）")
    st, raw, ms = call("/rest/api/v1/play", body=body, timeout=180)
    text = raw[:300].decode("utf-8", "replace")
    gated = is_gated(raw)
    print(f"  HTTP={st}  {ms}ms  {'*** WAF 拦截 ***' if gated else '未被拦截'}")
    print(f"  body: {text}")
    ok = (st == 200 and not gated)
    print(f"  >>> {'✅ 主通道在大歌单上起播成功' if ok else '❌ 主通道失败'}")
    print()
    return ok


def main():
    v = step1_version()
    step2_gate()
    m = step3_main_channel()
    print("=" * 72)
    print("汇总")
    print("=" * 72)
    print(f"  服务端版本（62e9c86 系列）: {'OK' if v else '未确认'}")
    print(f"  主通道大歌单起播          : {'OK' if m else 'FAILED'}")
    return 0 if (v and m) else 1


if __name__ == "__main__":
    sys.exit(main())
