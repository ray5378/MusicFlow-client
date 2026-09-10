#!/usr/bin/env python3
"""Print MusicFlow peer/queue state over the public (WAF-fronted) entry.

Usage:
  python tool/peers_state.py            # all peers
  python tool/peers_state.py <peerId>   # one peer, includes currentMedia

Auth goes via query params (u/p/v/c/f) -- headers yield 401 on this deployment.
The authoritative queue-existence signal is GET /rest/api/v1/peers; the
per-slot contents come from GET /rest/api/v1/peers/<id>/queue?offset=&size=.
"""

import json
import ssl
import sys
import urllib.parse
import urllib.request

WAN = "https://music.cmct.fun:35378"
AUTH = {"u": "xyz5378", "p": "@$qQ!J4pNnSoy8", "v": "1.16.1", "c": "MusicFlow", "f": "json"}
_CTX = ssl.create_default_context()
_CTX.check_hostname = False
_CTX.verify_mode = ssl.CERT_NONE


def call(path: str, timeout: int = 60):
    """Return (status, parsed_json_or_raw). Never raises on HTTP error status."""
    sep = "&" if "?" in path else "?"
    url = WAN + path + sep + urllib.parse.urlencode(AUTH)
    req = urllib.request.Request(url, headers={"User-Agent": "MusicFlowProbe/1.0"})
    try:
        with urllib.request.urlopen(req, context=_CTX, timeout=timeout) as r:
            raw = r.read()
            status = r.status
    except urllib.error.HTTPError as e:
        raw = e.read()
        status = e.code
    try:
        return status, json.loads(raw.decode("utf-8", "replace"))
    except Exception:
        return status, raw


def main() -> int:
    want = sys.argv[1] if len(sys.argv) > 1 else None
    status, data = call("/rest/api/v1/peers")
    if status != 200 or not isinstance(data, dict):
        print(f"GET /peers -> HTTP {status}: {str(data)[:300]}")
        return 1
    for p in data.get("peers", []):
        pid = p.get("peerId")
        if want and pid != want:
            continue
        q = p.get("queue") or {}
        line = (
            f"{pid:<50s} kind={p.get('kind'):<5s} name={p.get('name')} "
            f"avail={p.get('available')} active={q.get('isActive')} "
            f"items={len(q.get('items') or [])} cur={q.get('currentIndex')} "
            f"mode={q.get('playMode')} ended={q.get('ended')} "
            f"shuffleOrder={len(q.get('shuffleOrder') or [])}"
        )
        print(line)
        if want:
            print("  currentMedia:", json.dumps(q.get("currentMedia"), ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
