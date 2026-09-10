"""通过 VM 服务 getCpuSamples 抓 UI isolate 的符号化 CPU 热点。

用法: python vm_cpu.py <vm_service_url>
"""
import base64
import hashlib
import json
import os
import socket
import struct
import sys
import time

url = sys.argv[1]  # http://127.0.0.1:PORT/KEY=/
secs = int(sys.argv[2]) if len(sys.argv) > 2 else 8

# 记录采样窗口起点(VM 时间)
# 先连接拿 getVM/time
hostport = url.split("/")[2]
host, port = hostport.split(":")
port = int(port)
key = url.split("/", 3)[3]  # rO1Qxc76LXA=/

def ws_connect(path):
    s = socket.create_connection((host, port), timeout=10)
    keyb = base64.b64encode(os.urandom(16)).decode()
    req = (f"GET /{path} HTTP/1.1\r\nHost: {host}:{port}\r\n"
           "Upgrade: websocket\r\nConnection: Upgrade\r\n"
           f"Sec-WebSocket-Key: {keyb}\r\nSec-WebSocket-Version: 13\r\n\r\n")
    s.sendall(req.encode())
    resp = b""
    while b"\r\n\r\n" not in resp:
        resp += s.recv(4096)
    assert b"101" in resp.split(b"\r\n")[0], resp[:200]
    return s

def ws_send(s, data: str):
    payload = data.encode()
    mask = os.urandom(4)
    header = b""
    ln = len(payload)
    if ln < 126:
        header = struct.pack("!BB", 0x81, 0x80 | ln)
    elif ln < 65536:
        header = struct.pack("!BBH", 0x81, 0x80 | 126, ln)
    else:
        header = struct.pack("!BBQ", 0x81, 0x80 | 127, ln)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    s.sendall(header + mask + masked)

def ws_recv(s):
    def read(n):
        buf = b""
        while len(buf) < n:
            chunk = s.recv(n - len(buf))
            if not chunk:
                raise EOFError
            buf += chunk
        return buf
    h = read(2)
    opcode = h[0] & 0x0F
    ln = h[1] & 0x7F
    if ln == 126:
        ln = struct.unpack("!H", read(2))[0]
    elif ln == 127:
        ln = struct.unpack("!Q", read(8))[0]
    payload = read(ln)
    return json.loads(payload.decode())

s = ws_connect(key + "ws")

rid = [0]
def rpc(method, params=None):
    rid[0] += 1
    req = {"jsonrpc": "2.0", "id": str(rid[0]), "method": method}
    if params:
        req["params"] = params
    ws_send(s, json.dumps(req))
    while True:
        msg = ws_recv(s)
        if msg.get("id") == str(rid[0]):
            return msg

# 提高采样频率: 500us 一次
rpc("setFlag", {"name": "profile_period", "value": "500"})
rpc("setFlag", {"name": "profiler", "value": "true"})

vm = rpc("getVM")
iso = None
for i in vm["result"].get("isolates", []):
    iso = i["id"]
print(f"isolate: {iso}")

# 持续采样: 每隔 4 秒取一次环形缓冲增量, 共采 windows 轮
windows = int(sys.argv[3]) if len(sys.argv) > 3 else 5
from collections import Counter
leaf_total = Counter()
stack_total = Counter()
seen = set()
for w in range(windows):
    res = rpc("getCpuSamples", {"isolateId": iso})
    r = res.get("result", {})
    samples = r.get("samples", [])
    # functions 是数组, samples.stack 存的是数组下标
    flist = r.get("functions", [])
    fmeta = []
    for f in flist:
        fn = f.get("function", {})
        nm = fn.get("name", "?")
        uu = f.get("resolvedUrl", "")
        cls = (fn.get("class") or {}).get("name", "")
        fmeta.append((nm, uu, cls))
    new = 0
    for sm in samples:
        sid = sm.get("tid", 0), sm.get("timestamp", 0), tuple(sm.get("stack", [])[:3])
        if sid in seen:
            continue
        seen.add(sid)
        new += 1
        stack = sm.get("stack", [])
        if not stack:
            continue
        def nm_at(i):
            if isinstance(stack[i], int) and 0 <= stack[i] < len(fmeta):
                return fmeta[stack[i]]
            return ("?", "", "")
        nm0, uu0, cls0 = nm_at(0)
        leaf = f"{cls0}.{nm0}" if cls0 else nm0
        if leaf == "?" or leaf.startswith("[") or "Native" in leaf:
            leaf += f" ({uu0[-50:]})" if uu0 else ""
        leaf_total[leaf] += 1
        for i in range(len(stack)):
            nm, uu, cls = nm_at(i)
            if uu.startswith("package:") or uu.startswith("file:"):
                full = f"{cls}.{nm}" if cls else nm
                stack_total[f"{full}  [{uu.split('/')[-1][:45]}]"] += 1
                break
    print(f"[窗口{w+1}/{windows}] 新样本 {new} (累计 {len(seen)})")
    if w < windows - 1:
        time.sleep(4)

print(f"\n=== 叶子函数热点 (总样本 {len(seen)}) ===")
for name, cnt in leaf_total.most_common(30):
    print(f"  {cnt:>6}  {name}")
print("\n=== Dart 用户函数热点(栈中第一个业务函数) ===")
for name, cnt in stack_total.most_common(30):
    print(f"  {cnt:>6}  {name}")
