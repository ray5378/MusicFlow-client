import json, ssl, urllib.request, urllib.parse, os, sys

WAN = "https://music.cmct.fun:35378"
CREDS = {"username": "xyz5378", "password": "@$qQ!J4pNnSoy8"}
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE


def call(path, body=None, method=None, timeout=60):
    """发请求，返回 (status, body_bytes)。鉴权走 **query 参数** u/p（与客户端一致）。"""
    sep = "&" if "?" in path else "?"
    auth = urllib.parse.urlencode({"u": CREDS["username"], "p": CREDS["password"],
                                   "v": "1.16.1", "c": "wafprobe", "f": "json"})
    url = f"{WAN}{path}{sep}{auth}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method or ("POST" if data else "GET"))
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, context=CTX, timeout=timeout) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except Exception as e:
        return None, f"{type(e).__name__}: {e}".encode()


def main():
    q = urllib.parse.urlencode({"u": CREDS["username"], "p": CREDS["password"],
                                "v": "1.16.1", "c": "wafprobe", "f": "json"})
    st, raw = call(f"/rest/ping.view?{q}")
    print("ping:", st, raw[:200])
    print()

    # ---- 闸门是否真的开着？----------------------------------------------
    # 判据：把一个**已知会被拦**的超大整队 payload 打到 /queue/play，
    # 看响应体里有没有 `Lucky WAF`。只有确认闸门生效，后面的主通道验证才有意义
    # （闸门关闭时整队推送也能过，测不出主通道的价值）。
    print("=== WAF 闸门探针：向 /queue/play 推一个超大整队 ===")
    filler = "x" * 400  # 单条 ~400B，与真实 queue item 同量级
    for n in (300, 600, 1200):
        items = [{"songId": f"probe-{i}", "title": filler, "artist": "probe",
                  "album": "probe", "duration": 180} for i in range(n)]
        body = {"items": items, "startIndex": 0}
        size = len(json.dumps(body))
        st, raw = call("/rest/api/v1/peers/dlna:__nonexistent__/queue/play",
                       body=body, timeout=120)
        text = raw[:400].decode("utf-8", "replace")
        gated = "Lucky WAF" in text or (st == 403 and "Lucky" in text)
        print(f"  n={n:5d}  body={size/1024:8.1f}KB  HTTP={st}  "
              f"{'*** WAF 闸门命中 ***' if gated else '通过'}  {text[:110]!r}")
    print()


if __name__ == "__main__":
    main()
