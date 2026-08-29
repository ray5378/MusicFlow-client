#!/usr/bin/env bash
# =============================================================================
# 跨网段 DLNA 直拉流验证脚本
# -----------------------------------------------------------------------------
# 目的：
#   验证「设备在另一个网段、用公网域名直拉服务端 DLNA 流」的整条链路是否可用。
#   这是排查「局域网投屏有声、跨网段投屏无声」最直接的手段——把本脚本放到
#   与服务器不在同一网段的设备/热点网络上运行，即可模拟真实远程播放器视角。
#
# 它依次检查：
#   1) DNS      域名是否解析为公网 IP（而不是私网 IP / 内网 CNAME）
#   2) TCP       服务器公网端口是否可达（网络层）
#   3) ping      服务器 /rest/ping 是否跨网段返回正常（应用层，无鉴权）
#   4) 鉴权      （可选）用 u/t/s 换一个 DLNA token 流 URL，验证能换取
#   5) 流       对每个 token 流 URL 做 Range 拉流，确认返回的是「真实音频字节」
#                而非 HTML/JSON 错误页；并确认流 URL 的主机=公网域名而非私网 IP
#
# 用法：
#   ./cross_subnet_dlna_test.sh [BASE_URL] [streamUrl...]
#
#   BASE_URL 默认 http://music.cmct.fun:35378
#   可再传 0 或多个 token 流 URL 直接验证（不换 token 时）
#
# 可选的凭据环境变量（用于 endpoint「先换 token 再拉流」的自测）：
#   SUB_USER      Subsonic 用户名
#   SUB_PASS      Subsonic 密码
#   SONG_ID       要拉流的歌曲 ID
#
# 示例：
#   ./cross_subnet_dlna_test.sh
#   SUB_USER=me SUB_PASS=xx SONG_ID=123 ./cross_subnet_dlna_test.sh \
#       http://music.cmct.fun:35378
#   ./cross_subnet_dlna_test.sh http://music.cmct.fun:35378 \
#       'http://music.cmct.fun:35378/rest/dlna/stream/<token>'
# =============================================================================

set -uo pipefail

# ---- 参数 ----
BASE_URL="${1:-http://music.cmct.fun:35378}"
BASE_URL="${BASE_URL%/}"
shift || true
if [[ $# -gt 0 ]]; then STREAM_URLS=("$@"); else STREAM_URLS=(); fi

# 从 BASE_URL 拆出 host 与 port
SCHEME="${BASE_URL%%://*}"
HOSTPORT="${BASE_URL#*://}"
HOST="${HOSTPORT%%:*}"
case "$HOSTPORT" in
  *:*) PORT="${HOSTPORT##*:}" ;;
  *)   PORT="$SCHEME" ; PORT=443 ;;
esac

PASS=0; FAIL=0
ok()   { printf '  \033[32m[PASS]\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
info() { printf '  \033[36m[INFO]\033[0m %s\n' "$1"; }
hr()   { printf '%s\n' '------------------------------------------------------------------------'; }

is_private_ip() { [[ "$1" =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|127\.|169\.254\.|::1$|fc|fe80:) ]]; }

echo "目标: $BASE_URL  (host=$HOST port=$PORT)"
hr

# ---- 1) DNS ----
echo "[1] DNS 解析"
IP="$(getent hosts "$HOST" | awk '{print $1; exit}')"
if [[ -z "$IP" ]]; then
  bad "域名解析失败: $HOST"
else
  ok "解析成功: $HOST -> $IP"
  if is_private_ip "$IP"; then
    bad "解析到私网 IP($IP)! 远程设备无法用该域名回连,需改用公网 IP/DLNA_BASE_URL"
    # 私网 IP 时后续检查意义不大,快速退出
    hr; printf '结论: FAIL %d / %d\n' "$FAIL" "$((PASS+FAIL))"; exit 1
  else
    ok "解析到公网 IP($IP),远程设备可解析"
  fi
fi
hr

# ---- 2) TCP ----
echo "[2] TCP 可达性($HOST:$PORT)"
if timeout 6 bash -c "echo > /dev/tcp/$HOST/$PORT" 2>/dev/null; then
  ok "TCP 端口可达"
else
  bad "TCP 连不上 $HOST:$PORT(连接被拒/超时/出站被限制)"
fi
hr

# ---- 3) ping ----
echo "[3] /rest/ping"
ping_body="$(mktemp)"
ping_status="$(curl -sS -m 12 -o "$ping_body" -w '%{http_code} %{content_type}' "$BASE_URL/rest/ping" 2>/dev/null)"
ping_http="${ping_status%% *}"
if [[ "$ping_http" == "200" ]] && grep -qi 'subsonic-response' "$ping_body"; then
  ok "应用层可达,返回 Subsonic 响应"
elif [[ "$ping_http" == "200" ]]; then
  ok "HTTP 200(但响应不是标准 subsonic-response)"
else
  bad "ping 失败: HTTP=$ping_status  (若为 502/超时,多为出口代理/出站限制或服务器健康问题)"
fi
rm -f "$ping_body"
hr

# ---- 4) 换 token(可选) ----
TOKENS=("${STREAM_URLS[@]}")
if [[ ${#TOKENS[@]} -eq 0 && -n "${SUB_USER:-}" && -n "${SUB_PASS:-}" && -n "${SONG_ID:-}" ]]; then
  echo "[4] 用 u/t/s 换 DLNA token 流 URL"
  SALT="$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-' | head -c 16)"
  TOKEN="$(printf '%s%s' "$SUB_PASS" "$SALT" | md5sum | awk '{print $1}')"
  resp="$(curl -sS -m 12 -X POST "$BASE_URL/rest/api/v1/dlna/stream-url" \
    -H 'Content-Type: application/json' \
    -d "{\"songId\":\"$SONG_ID\"}" \
    --data-urlencode "u=$SUB_USER" --data-urlencode "t=$TOKEN" --data-urlencode "s=$SALT" 2>/dev/null)"
  URL="$(printf '%s' "$resp" | sed -n 's/.*"streamUrl":"\([^"]*\)".*/\1/p')"
  if [[ -n "$URL" ]]; then
    ok "换取成功: $URL"
    TOKENS=("$URL")
  else
    bad "换取 token 失败: $resp"
  fi
  hr
fi

# ---- 5) 流验证 ----
if [[ ${#TOKENS[@]} -eq 0 ]]; then
  echo "[5] 跳过:未提供流 URL,也未提供凭据自动换取(SONG_ID 的歌曲不是流 URL,按流返回应为真实音频字节)"
  echo "    可手动传入已完成鉴权的 /rest/dlna/stream/:token URL,或设 SUB_USER/SUB_PASS/SONG_ID 自动换取"
else
  echo "[5] 流 URL 主机与拉流验证"
  for url in "${TOKENS[@]}"; do
    stream_host="$(printf '%s' "$url" | sed -E 's#^[a-z]+://##; s#/.*##; s#:.*##')"
    if [[ "$stream_host" != "$HOST" ]]; then
      bad "流 URL 主机($stream_host)与目标服务器($HOST)不一致,远程设备需确认为公网域名"
    elif is_private_ip "$stream_host"; then
      bad "流 URL 使用了私网主机($url)! 远程设备回连必然失败——这正是「跨网段无声」的根因"
      continue
    else
      ok "流 URL 主机为公网域名($stream_host)"
    fi

    hdr="$(mktemp)"; body="$(mktemp)"
    http="$(curl -sS -m 15 -o "$body" -D "$hdr" \
              -H 'Range: bytes=0-65535' -w '%{http_code}' "$url" 2>/dev/null)"
    ctype="$(grep -i '^content-type:' "$hdr" | tr -d '\r' | cut -d' ' -f2- | sed 's/ *$//')"
    magic="$(head -c 4 "$body" 2>/dev/null | od -An -c | tr -d ' \n')"

    case "$http" in
      200|206) : ;;
      *) bad "拉流失败: HTTP=$http" ; rm -f "$hdr" "$body"; continue ;;
    esac
    if [[ -n "$ctype" ]] && [[ "$ctype" == audio/* ]]; then
      ok "Content-Type=音频类($ctype)"
    else
      bad "Content-Type 不是音频($ctype)"
    fi
    if grep -qiE '(<html|<!DOCTYPE|\{?\s*"error"|"error")' "$body" 2>/dev/null; then
      bad "响应是 HTML/JSON 错误页而非音频内容"
    else
      info "前几字节: $magic  (据此粗略判断音频格式)"
      case "$magic" in
        ID3|ff3*|fLaC|OggS) ok "识别为已知音频容器/帧头($magic)" ;;
        *)                  info "字节头($magic)非常见音频魔数,但 HTTP 200/206 且非 HTML/JSON 错误页,认为可拉取" ;;
      esac
    fi
    rm -f "$hdr" "$body"
  done
fi

hr
printf '结果: PASS %d / FAIL %d / 共 %d\n' "$PASS" "$((PASS+FAIL))" "$((PASS+FAIL))"
[[ "$FAIL" -eq 0 ]]