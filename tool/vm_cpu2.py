"""VM 服务 CPU 采样 v2: 按线程分组 + 完整调用链聚合.
用法: python vm_cpu2.py <vm_url> [窗口数]
"""
import base64, json, os, socket, struct, sys, time
from collections import Counter, defaultdict

u = sys.argv[1]
wins = int(sys.argv[2]) if len(sys.argv) > 2 else 4
hostport = u.split("/")[2]; host, port = hostport.split(":"); port = int(port)
key = u.split("/", 3)[3]
s = socket.create_connection((host, port), timeout=10)
kb = base64.b64encode(os.urandom(16)).decode()
s.sendall((f"GET /{key}ws HTTP/1.1\r\nHost: {host}:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {kb}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
resp = b""
while b"\r\n\r\n" not in resp: resp += s.recv(4096)

def send(d):
    p = d.encode(); m = os.urandom(4)
    h = struct.pack("!BB", 0x81, 0x80|len(p)) if len(p) < 126 else struct.pack("!BBH", 0x81, 0x80|126, len(p))
    s.sendall(h + m + bytes(b ^ m[i%4] for i, b in enumerate(p)))
def recv():
    h = s.recv(2); ln = h[1] & 0x7F
    if ln == 126: ln = struct.unpack("!H", s.recv(2))[0]
    elif ln == 127: ln = struct.unpack("!Q", s.recv(8))[0]
    buf = b""
    while len(buf) < ln: buf += s.recv(ln - len(buf))
    return json.loads(buf.decode())
rid = [0]
def rpc(m, p=None):
    rid[0] += 1
    send(json.dumps({"jsonrpc": "2.0", "id": str(rid[0]), "method": m, **({"params": p} if p else {})}))
    while True:
        x = recv()
        if x.get("id") == str(rid[0]): return x

rpc("setFlag", {"name": "profile_period", "value": "300"})
vm = rpc("getVM"); iso = vm["result"]["isolates"][0]["id"]
print(f"isolate: {iso}")

def short(nm, uu):
    n = nm
    if uu.endswith("flutter_windows.dll") or "flutter_windows.dll+" in uu:
        n = f"FW.dll{uu.split('flutter_windows.dll')[1]}" if "+" in uu else n
    return n[:80]

seen = set()
tid_tot = Counter()
tid_frames = defaultdict(Counter)   # tid -> 叶子计数
tid_chains = defaultdict(Counter)   # tid -> 调用链计数
for w in range(wins):
    r = rpc("getCpuSamples", {"isolateId": iso}).get("result", {})
    fmeta = []
    for f in r.get("functions", []):
        fn = f.get("function", {})
        fmeta.append((fn.get("name", "?"), f.get("resolvedUrl", "")))
    new = 0
    for sm in r.get("samples", []):
        sid = (sm.get("tid"), sm.get("timestamp"), tuple(sm.get("stack", [])[:3]))
        if sid in seen: continue
        seen.add(sid); new += 1
        tid = sm.get("tid")
        tid_tot[tid] += 1
        stack = sm.get("stack", [])
        if not stack: continue
        def nm(i):
            if isinstance(stack[i], int) and 0 <= stack[i] < len(fmeta):
                n, uu = fmeta[stack[i]]
                return short(n, uu)
            return "?"
        tid_frames[tid][nm(0)] += 1
        chain = " <- ".join(nm(i) for i in range(min(len(stack), 8)))
        tid_chains[tid][chain] += 1
    print(f"[窗口{w+1}/{wins}] 新样本 {new} 累计 {len(seen)}")
    if w < wins - 1: time.sleep(3)

print(f"\n=== 按线程分布 (总 {len(seen)}) ===")
for tid, c in tid_tot.most_common():
    print(f"  TID {tid}: {c} 样本")
hot = tid_tot.most_common(3)
for tid, _ in hot:
    print(f"\n=== TID {tid} 叶子热点 ===")
    for k, v in tid_frames[tid].most_common(12): print(f"  {v:>6}  {k}")
    print(f"=== TID {tid} 高频调用链 ===")
    for k, v in tid_chains[tid].most_common(12): print(f"  {v:>6}  {k}")
