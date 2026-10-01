#!/usr/bin/env bash
# 对比「公网 HTTPS 域名」与「内网 IP」的建连分段耗时。
# 每次循环都是一个独立 curl 进程 => DNS / TCP / TLS 会话全冷（等同客户端冷启动）。
# 用法: bash tool/probe_connect_paths.sh [采样次数]
set -u

PUB="https://music.cmct.fun:35378/rest/ping"
LAN="http://192.168.10.240:46400/rest/ping"
N="${1:-6}"

echo "采样 ${N} 次/路径（单位 s，curl 原生输出）"
echo "=== 公网 HTTPS  ${PUB} ==="
for i in $(seq 1 "$N"); do
  curl -s -o /dev/null -m 20 -w "  #$i code=%{http_code} dns=%{time_namelookup} tcp=%{time_connect} tls=%{time_appconnect} ttfb=%{time_starttransfer} total=%{time_total}\n" "$PUB"
done
echo "=== 内网 HTTP    ${LAN} ==="
for i in $(seq 1 "$N"); do
  curl -s -o /dev/null -m 10 -w "  #$i code=%{http_code} dns=%{time_namelookup} tcp=%{time_connect} ttfb=%{time_starttransfer} total=%{time_total}\n" "$LAN"
done
echo "=== 对照：公网 IP 上开了哪些端口（定位映射是否配错） ==="
getent ahostsv4 music.cmct.fun | awk '{print $1}' | sort -u
for p in 22 80 443 3537 35378 46400; do
  if timeout 3 bash -c "cat </dev/null >/dev/tcp/$(getent hosts music.cmct.fun | awk '{print $1}' | head -1)/$p" 2>/dev/null; then
    echo "  port $p OPEN"
  fi
done
