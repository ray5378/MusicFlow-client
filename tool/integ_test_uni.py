#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# 全量跨格式连续流集成测试(针对「两声嘟嘟」根因):
# 队列 s1..s9 混排 44.1k-mono mp3 / wav / flac / 48k ogg / m4a / opus / aac /
# 48k-stereo mp3(旧逻辑的嘟嘟触发源) / 44.1k-stereo mp3(快通道)。
# 校验:服务端拼出的整根流必须解码无错(sample rate/声道全程一致)。
import hashlib, json, subprocess, sys, urllib.request, urllib.parse

BASE = "http://localhost:46400"
USER = "admin"; PASS = "admin"; SALT = "testcastsalt"
TOKEN = hashlib.md5((PASS + SALT).encode()).hexdigest()
auth = f"u={USER}&t={TOKEN}&s={SALT}"

SONGS = ["s1","s2","s3","s4","s5","s6","s7","s8","s9"]  # 跨格式 + 48k原生mp3 + 44.1k立体声mp3
DUR_SUM = 8.045714+5+10+6+7+4.0065+2.98409+9+8  # ≈60.036

def get(url):
    with urllib.request.urlopen(url, timeout=120) as r:
        return r.status, r.read()

# 1) create=1 -> 短 token(异步后台渲染,应立即返回)
status, body = get(f"{BASE}/rest/castStream?{auth}&create=1&songs=" + ",".join(SONGS))
print(f"[1] create status={status} body={body[:160]!r}")
data = json.loads(body)
sr = data.get("subsonic-response", data)
token = sr["stream"]["token"]
print(f"[1] token={token}")

# 2) renderer 用短链拉整根流
status, stbody = get(f"{BASE}/rest/castStream?{auth}&token={token}")
assert status == 200, f"stream status {status}"
out = "/tmp/cast_stream_all.mp3"
open(out, "wb").write(stbody)
print(f"[2] pulled {len(stbody)} bytes -> {out}")

# 3) 探测最终流格式
probe = subprocess.run(["ffprobe","-v","error","-select_streams","a:0",
    "-show_entries","stream=codec_name,sample_rate,channels:format=duration","-of","json",out],
    capture_output=True, text=True)
pj = json.loads(probe.stdout)
st = pj.get("streams",[{}])[0]; fmt = pj.get("format",{})
print(f"[3] codec={st.get('codec_name')} sr={st.get('sample_rate')} ch={st.get('channels')} dur={fmt.get('duration')}")

# 4) 全量解码(纯 renderer 等效),统计 decode 错误
dec = subprocess.run(["ffmpeg","-v","error","-i",out,"-map","0:a","-f","null","-"],
    capture_output=True, text=True)
err = (dec.stderr or "").strip()
err_lines = [l for l in err.splitlines() if l.strip()]
print(f"[4] decode_errors={len(err_lines)}")
for l in err_lines[:20]: print("    |", l)

# 判定
ok_fmt = st.get("sample_rate") == "44100" and st.get("channels") == 2 and st.get("codec_name") == "mp3"
ok_dec = len(err_lines) == 0
dur = float(fmt.get("duration") or 0)
ok_dur = abs(dur - DUR_SUM) < 2.0
print(f"[RESULT] fmt(uniform 44100/2/mp3)={ok_fmt} decode={ok_dec} dur_ok={ok_dur} (sum={DUR_SUM:.3f})")
sys.exit(0 if (ok_fmt and ok_dec and ok_dur) else 2)