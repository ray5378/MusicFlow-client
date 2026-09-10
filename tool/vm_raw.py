import base64, json, os, socket, struct, sys
u = sys.argv[1]
hostport = u.split("/")[2]; host, port = hostport.split(":"); port = int(port)
key = u.split("/", 3)[3]
s = socket.create_connection((host, port), timeout=10)
kb = base64.b64encode(os.urandom(16)).decode()
s.sendall((f"GET /{key}ws HTTP/1.1\r\nHost: {host}:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {kb}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
resp = b""
while b"\r\n\r\n" not in resp: resp += s.recv(4096)
def send(d):
    p = d.encode(); m = os.urandom(4); h = struct.pack("!BB", 0x81, 0x80|len(p)) if len(p)<126 else struct.pack("!BBH",0x81,0x80|126,len(p))
    s.sendall(h + m + bytes(b ^ m[i%4] for i,b in enumerate(p)))
def recv():
    h = s.recv(2); ln = h[1]&0x7F
    if ln==126: ln = struct.unpack("!H", s.recv(2))[0]
    elif ln==127: ln = struct.unpack("!Q", s.recv(8))[0]
    buf=b""
    while len(buf)<ln: buf += s.recv(ln-len(buf))
    return json.loads(buf.decode())
rid=[0]
def rpc(m,p=None):
    rid[0]+=1; send(json.dumps({"jsonrpc":"2.0","id":str(rid[0]),"method":m,**({"params":p} if p else {})}))
    while True:
        x=recv()
        if x.get("id")==str(rid[0]): return x
vm = rpc("getVM"); iso = vm["result"]["isolates"][0]["id"]
r = rpc("getCpuSamples", {"isolateId": iso})["result"]
print("keys:", list(r.keys()))
print("sampleCount:", r.get("sampleCount"), "period:", r.get("samplePeriod"))
fns = r.get("functions", [])
print("functions:", len(fns))
for f in fns[:6]: print(" FN:", json.dumps(f, ensure_ascii=False)[:220])
sm = r.get("samples", [{}])[0]
print("sample[0]:", json.dumps(sm, ensure_ascii=False)[:400])
