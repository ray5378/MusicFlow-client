#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# DLNA 全链路 e2e:服务端 /castStream + HiVi 模拟 renderer。
import hashlib, json, time, urllib.request, urllib.parse

BASE="http://localhost:46400"; MOCK="http://localhost:19000"
USER="admin"; PASS="admin"; SALT="testcastsalt"
TOK=hashlib.md5((PASS+SALT).encode()).hexdigest()
auth=f"u={USER}&t={TOK}&s={SALT}"
SONGS=["s1","s2","s3","s4","s5","s6","s7","s8","s9"]

def get(u, t=120):
    with urllib.request.urlopen(u, timeout=t) as r: return r.status, r.read()

def soap(action, body_xml):
    req=urllib.request.Request(MOCK+"/avt/control", data=body_xml.encode(),
        headers={"Content-Type":"text/xml; charset=\"utf-8\"",
                 "SOAPACTION":f'"urn:schemas-upnp-org:service:AVTransport:1#{action}"'})
    with urllib.request.urlopen(req, timeout=30) as r: return r.status, r.read().decode()

# 1) create token
_, b = get(f"{BASE}/rest/castStream?{auth}&create=1&songs="+",".join(SONGS))
token = json.loads(b)["subsonic-response"]["stream"]["token"]
stream_url = f"{BASE}/rest/castStream?{auth}&token={token}"
print(f"[e2e] token={token}")
print(f"[e2e] SetAVTransportURI -> {stream_url}")
xml = ('<?xml version="1.0"?>'
 '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
 '<s:Body><u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">'
 '<InstanceID>0</InstanceID>'
 f'<CurrentURI>{stream_url}</CurrentURI>'
 '<CurrentURIMetaData></CurrentURIMetaData>'
 '</u:SetAVTransportURI></s:Body></s:Envelope>')
print(soap("SetAVTransportURI", xml)[0])
print(soap("Play", '<?xml version="1.0"?>'
 '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
 '<s:Body><u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">'
 '<InstanceID>0</InstanceID><Speed>1</Speed></u:Play></s:Body></s:Envelope>')[0])

# 2) poll device status until pull done
deadline = time.time()+180
last=""
while time.time()<deadline:
    try:
        _, st = get(f"{MOCK}/status", t=15)
        j = json.loads(st)
        if j["pullSummary"] != last:
            print(f"[e2e] pullSummary={j['pullSummary']} bytes={j['pulledBytes']} state={j['transportState']}")
            last = j["pullSummary"]
        if j.get("pullDone"):
            print("DONE", j)
            ok = not j.get("pullError") and j.get("pulledBytes",0)>0
            jf = json.loads(open("/tmp/cast_stream_all.mp3").read()) if False else None
            print("[RESULT]", "PASS" if ok else "FAIL")
            raise SystemExit(0 if ok else 2)
    except Exception as e:
        print("poll err", e); time.sleep(2)
print("[RESULT] TIMEOUT waiting device pull")
sys_exit = __import__("sys"); sys_exit.exit(2)