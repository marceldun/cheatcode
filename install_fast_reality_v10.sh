#!/usr/bin/env bash
# 低配 VPS REALITY 极速一键搭建 v10
# 协议：VLESS + RAW/TCP + REALITY + XTLS Vision
# 特性：与HY2 v9并存、断线后台继续、端口避让、ping0.cc国家命名、真实传输验证。
set -Eeuo pipefail

VERSION="10.0.0"
WORK_DIR="/etc/xray-reality-v10"
BIN="$WORK_DIR/xray"
CONF="$WORK_DIR/config.json"
STATE="$WORK_DIR/state.env"
INFO="/root/xray-reality-v10-info.txt"
TMP="$(mktemp -d /tmp/reality-fast-v10.XXXXXX)"
REALITY_PORT="${REALITY_PORT:-443}"
REALITY_DOMAIN="${REALITY_DOMAIN:-}"
XRAY_ARCH=""

R='\033[31m'; G='\033[32m'; Y='\033[33m'; C='\033[36m'; N='\033[0m'
step(){ printf '\n%b[%s/8] %s%b\n' "$C" "$1" "$2" "$N"; }
ok(){ printf '%b[成功] %s%b\n' "$G" "$*" "$N"; }
warn(){ printf '%b[提示] %s%b\n' "$Y" "$*" "$N"; }
die(){ printf '%b[失败] %s%b\n' "$R" "$*" "$N" >&2; exit 1; }
cleanup(){ local rc=$?; jobs -pr | xargs -r kill 2>/dev/null || true; rm -rf "$TMP"; exit "$rc"; }
trap cleanup EXIT

[ "$(id -u)" -eq 0 ] || die "请使用root账号执行。"
command -v systemctl >/dev/null 2>&1 || die "当前系统不是systemd，无法安全配置自启。"

# SSH可能正通过旧代理连接。后台worker保证窗口断开也不会中止安装。
if [ "${REALITY_V10_WORKER:-0}" != 1 ]; then
  RUNNER=/root/install_fast_reality_v10.sh
  WORKER_ENV=/root/.reality-v10-installer.env
  INSTALL_LOG=/root/reality-v10-install.log
  DONE_FILE=/root/reality-v10-install.done
  install -m 700 "${BASH_SOURCE[0]}" "$RUNNER"
  {
    printf 'REALITY_PORT=%q\n' "$REALITY_PORT"
    printf 'REALITY_DOMAIN=%q\n' "$REALITY_DOMAIN"
  } >"$WORKER_ENV"
  chmod 600 "$WORKER_ENV"; : >"$INSTALL_LOG"; rm -f "$DONE_FILE"
  UNIT="reality-v10-installer-$(date +%s)"
  systemd-run --unit="$UNIT" --property=Type=exec /bin/bash -c \
    "set -a; . '$WORKER_ENV'; set +a; REALITY_V10_WORKER=1 bash '$RUNNER' >>'$INSTALL_LOG' 2>&1; rc=\$?; rm -f '$WORKER_ENV'; echo \$rc >'$DONE_FILE'; exit \$rc" >/dev/null
  ok "REALITY v10后台安装已启动；Xshell断开也会继续。"
  printf '日志：%s\n完成状态：%s（显示0代表成功）\n' "$INSTALL_LOG" "$DONE_FILE"
  shown=0
  for _ in $(seq 1 120); do
    sleep 1
    if [ -f "$DONE_FILE" ]; then shown=1; break; fi
    tail -n 1 "$INSTALL_LOG" 2>/dev/null || true
  done
  [ "$shown" -eq 1 ] || { warn "安装仍在后台继续。重连后输入：cat $DONE_FILE"; exit 0; }
  cat "$INSTALL_LOG"
  [ "$(cat "$DONE_FILE")" = 0 ] || die "后台安装失败，详情：$INSTALL_LOG"
  exit 0
fi

step 1 "检测系统与低配自适应参数"
case "$(uname -m)" in
  x86_64|amd64) XRAY_ARCH=64 ;;
  aarch64|arm64) XRAY_ARCH=arm64-v8a ;;
  armv7l) XRAY_ARCH=arm32-v7a ;;
  *) die "不支持的CPU架构：$(uname -m)" ;;
esac
. /etc/os-release 2>/dev/null || true
OS_NAME="${PRETTY_NAME:-Linux}"
case "${ID:-}" in
  debian|ubuntu) PM=apt ;;
  alpine) PM=apk ;;
  *) command -v dnf >/dev/null 2>&1 && PM=dnf || PM=yum ;;
esac
MEM_KB="$(awk '/MemTotal/{print $2}' /proc/meminfo)"
CPU_COUNT="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
if [ "$MEM_KB" -le 524288 ]; then PROFILE=tiny; SOCKBUF=8388608; BACKLOG=2048
elif [ "$MEM_KB" -le 1048576 ]; then PROFILE=small; SOCKBUF=16777216; BACKLOG=4096
elif [ "$MEM_KB" -le 2097152 ]; then PROFILE=normal; SOCKBUF=33554432; BACKLOG=8192
else PROFILE=large; SOCKBUF=67108864; BACKLOG=16384; fi
ok "系统：$OS_NAME；CPU：${CPU_COUNT}核；内存：$((MEM_KB/1024))MB；档位：$PROFILE"

step 2 "安装必要组件"
if [ "$PM" = apt ]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y --no-install-recommends curl jq unzip openssl iproute2 ca-certificates >/dev/null
  apt-get install -y --no-install-recommends qrencode >/dev/null 2>&1 || true
elif [ "$PM" = apk ]; then
  apk add --no-cache curl jq unzip openssl iproute2 ca-certificates qrencode >/dev/null
else
  "$PM" -y install curl jq unzip openssl iproute ca-certificates qrencode >/dev/null
fi
for c in curl jq unzip openssl ip ss sha256sum; do command -v "$c" >/dev/null 2>&1 || die "缺少组件：$c"; done
ok "组件已就绪"

step 3 "下载并校验 Xray-core 官方内核"
mkdir -p "$WORK_DIR" "$WORK_DIR/backup"
chmod 700 "$WORK_DIR"
ZIP_NAME="Xray-linux-${XRAY_ARCH}.zip"
BASE_URL="https://github.com/XTLS/Xray-core/releases/latest/download"
PREFIXES=("" "https://ghfast.top/" "https://gh-proxy.com/")
download(){ local url dst p part; url=$1; dst=$2; part="${dst}.part"; for p in "${PREFIXES[@]}"; do
  if curl -A 'reality-fast-v10' -fL --connect-timeout 10 --max-time 600 --retry 3 --retry-delay 2 -C - -o "$part" "${p}${url}" 2>/dev/null && [ -s "$part" ]; then mv -f "$part" "$dst"; return 0; fi
done; return 1; }
download "$BASE_URL/$ZIP_NAME" "$TMP/$ZIP_NAME" || die "Xray官方内核下载失败。"
download "$BASE_URL/$ZIP_NAME.dgst" "$TMP/$ZIP_NAME.dgst" || die "Xray官方校验文件下载失败。"
EXPECTED="$(awk -F'= ' '/^SHA2-256=/{print $2}' "$TMP/$ZIP_NAME.dgst")"
[ -n "$EXPECTED" ] || die "无法读取官方SHA256。"
printf '%s  %s\n' "$EXPECTED" "$TMP/$ZIP_NAME" | sha256sum -c - >/dev/null || die "Xray下载校验失败。"
unzip -oq "$TMP/$ZIP_NAME" xray -d "$TMP/xray"
install -m 755 "$TMP/xray/xray" "$BIN"
ok "官方内核已校验：$($BIN version | head -1)"

step 4 "生成 VLESS + RAW/TCP + REALITY + XTLS Vision 配置"
if [ -f "$STATE" ]; then
  # shellcheck disable=SC1090
  . "$STATE"
fi
if [ -z "$REALITY_DOMAIN" ]; then
  best_time=999; best_domain=""
  for d in www.microsoft.com www.apple.com www.amazon.com; do
    t="$(curl -4fsS -o /dev/null --connect-timeout 5 --max-time 10 -w '%{time_appconnect}' "https://$d/" 2>/dev/null || true)"
    awk -v t="$t" 'BEGIN{exit !(t+0>0)}' 2>/dev/null || continue
    if awk -v a="$t" -v b="$best_time" 'BEGIN{exit !(a<b)}'; then best_time="$t"; best_domain="$d"; fi
  done
  REALITY_DOMAIN="${best_domain:-www.microsoft.com}"
fi

UUID="${UUID:-$($BIN uuid)}"
if [ -z "${REALITY_PRIVATE:-}" ] || [ -z "${REALITY_PUBLIC:-}" ]; then
  KEYPAIR="$($BIN x25519)"
  REALITY_PRIVATE="$(printf '%s\n' "$KEYPAIR" | sed -n 's/^PrivateKey: //p')"
  REALITY_PUBLIC="$(printf '%s\n' "$KEYPAIR" | sed -n -E 's/^(Password \(PublicKey\)|PublicKey): //p')"
fi
SHORT_ID="${SHORT_ID:-$(openssl rand -hex 8)}"
[ -n "$UUID" ] && [ -n "$REALITY_PRIVATE" ] && [ -n "$REALITY_PUBLIC" ] && [ -n "$SHORT_ID" ] || die "REALITY密钥生成失败。"

listener_lines(){ ss -H -ltnp 2>/dev/null | grep -E "[:.]${1}[[:space:]]" || true; }
port_can_use(){ local lines; lines="$(listener_lines "$1")"; [ -z "$lines" ] || printf '%s\n' "$lines" | grep -q 'xray'; }
REQUESTED_PORT="${SAVED_REALITY_PORT:-$REALITY_PORT}"
FINAL_PORT=""
for p in "$REQUESTED_PORT" 443 8443 2053 2083 2087 2096 10443 24443 30443; do
  if port_can_use "$p"; then FINAL_PORT="$p"; break; fi
done
[ -n "$FINAL_PORT" ] || die "找不到可用TCP端口。"
[ "$FINAL_PORT" = "$REQUESTED_PORT" ] || warn "TCP $REQUESTED_PORT被占用，自动改用TCP $FINAL_PORT。"
REALITY_PORT="$FINAL_PORT"

cat >"$STATE" <<EOF
UUID='$UUID'
REALITY_PRIVATE='$REALITY_PRIVATE'
REALITY_PUBLIC='$REALITY_PUBLIC'
SHORT_ID='$SHORT_ID'
REALITY_DOMAIN='$REALITY_DOMAIN'
SAVED_REALITY_PORT='$REALITY_PORT'
EOF
chmod 600 "$STATE"

cat >"$CONF" <<EOF
{
  "log":{"loglevel":"warning"},
  "inbounds":[{
    "listen":"0.0.0.0","port":$REALITY_PORT,"protocol":"vless","tag":"reality-vision-in",
    "settings":{"clients":[{"id":"$UUID","flow":"xtls-rprx-vision","email":"reality-v10"}],"decryption":"none"},
    "streamSettings":{
      "network":"raw","security":"reality",
      "realitySettings":{"show":false,"target":"$REALITY_DOMAIN:443","xver":0,"serverNames":["$REALITY_DOMAIN"],"privateKey":"$REALITY_PRIVATE","shortIds":["$SHORT_ID"]},
      "sockopt":{"tcpFastOpen":true,"tcpKeepAliveIdle":60,"tcpKeepAliveInterval":15,"tcpUserTimeout":60000}
    }
  }],
  "outbounds":[{
    "protocol":"freedom","tag":"direct","settings":{"domainStrategy":"UseIPv4"},
    "streamSettings":{"sockopt":{"tcpFastOpen":true,"tcpKeepAliveIdle":45,"tcpKeepAliveInterval":15,"tcpUserTimeout":60000}}
  }]
}
EOF
chmod 600 "$CONF"
"$BIN" run -test -config "$CONF" >/dev/null 2>&1 || { "$BIN" run -test -config "$CONF"; die "Xray REALITY配置校验失败。"; }
ok "REALITY配置校验通过；伪装站按TLS建连速度自动选为：$REALITY_DOMAIN"

step 5 "应用 BBR、TCP Fast Open 和低延迟内核参数"
modprobe tcp_bbr >/dev/null 2>&1 || true
printf '%s\n' tcp_bbr >/etc/modules-load.d/reality-fast-v10.conf 2>/dev/null || true
AVAILABLE_CC="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || true)"
case " $AVAILABLE_CC " in *" bbr "*) CC=bbr ;; *) CC=cubic ;; esac
cat >/etc/sysctl.d/99-reality-fast-v10.conf <<EOF
# REALITY v10: conservative high-throughput TCP tuning
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=$CC
net.ipv4.tcp_fastopen=3
net.core.somaxconn=$BACKLOG
net.core.netdev_max_backlog=$BACKLOG
net.core.rmem_max=$SOCKBUF
net.core.wmem_max=$SOCKBUF
net.ipv4.tcp_rmem=4096 131072 $SOCKBUF
net.ipv4.tcp_wmem=4096 65536 $SOCKBUF
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_keepalive_time=60
net.ipv4.tcp_keepalive_intvl=15
net.ipv4.tcp_keepalive_probes=4
net.ipv4.tcp_notsent_lowat=16384
net.ipv4.ip_local_port_range=10240 65535
EOF
sysctl -p /etc/sysctl.d/99-reality-fast-v10.conf >/dev/null 2>&1 || true
ok "拥塞控制：$CC；TCP Fast Open：启用；套接字上限：$((SOCKBUF/1024/1024))MB"

step 6 "启动 REALITY 并启用真实进程崩溃自愈"
cat >/etc/systemd/system/xray-reality-v10.service <<EOF
[Unit]
Description=Xray VLESS REALITY Vision maximum speed v10
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=root
WorkingDirectory=$WORK_DIR
ExecStart=$BIN run -config $CONF
Restart=always
RestartSec=1
LimitNOFILE=524288
Nice=-5
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable xray-reality-v10 >/dev/null 2>&1
if command -v ufw >/dev/null 2>&1 && ufw status | grep -qi active; then ufw allow "$REALITY_PORT/tcp" >/dev/null || true; fi
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then firewall-cmd --permanent --add-port="$REALITY_PORT/tcp" >/dev/null || true; firewall-cmd --reload >/dev/null || true; fi
systemctl restart xray-reality-v10
sleep 2
systemctl is-active --quiet xray-reality-v10 || { journalctl -u xray-reality-v10 -n 80 --no-pager >&2; die "REALITY服务启动失败。"; }
ss -ltn | grep -qE "[:.]${REALITY_PORT}[[:space:]]" || die "REALITY TCP端口没有监听。"
ok "REALITY正在监听TCP $REALITY_PORT；HY2 v9未删除、未停止"

step 7 "执行 REALITY 真实网页和持续传输测试"
cat >"$TMP/client.json" <<EOF
{
  "log":{"loglevel":"warning"},
  "inbounds":[{"listen":"127.0.0.1","port":19084,"protocol":"socks","settings":{"auth":"noauth","udp":false}}],
  "outbounds":[{
    "protocol":"vless",
    "settings":{"vnext":[{"address":"127.0.0.1","port":$REALITY_PORT,"users":[{"id":"$UUID","encryption":"none","flow":"xtls-rprx-vision"}]}]},
    "streamSettings":{"network":"raw","security":"reality","realitySettings":{"fingerprint":"chrome","serverName":"$REALITY_DOMAIN","password":"$REALITY_PUBLIC","shortId":"$SHORT_ID","spiderX":"/"},"sockopt":{"tcpFastOpen":true}}
  }]
}
EOF
"$BIN" run -test -config "$TMP/client.json" >/dev/null 2>&1 || die "REALITY客户端测试配置无效。"
"$BIN" run -config "$TMP/client.json" >"$TMP/client.log" 2>&1 & CLIENT_PID=$!
sleep 2
TTFB_LIST=""
for n in 1 2 3 4 5; do
  RESULT="$(curl --noproxy '' -sS -o /dev/null -w '%{http_code} %{time_starttransfer}' --socks5-hostname 127.0.0.1:19084 --max-time 20 "https://www.gstatic.com/generate_204?r=$n" 2>/dev/null || true)"
  CODE="${RESULT%% *}"; TTFB_LIST="${TTFB_LIST}${TTFB_LIST:+,}${RESULT#* }"
  [ "$CODE" = 204 ] || [ "$CODE" = 200 ] || { cat "$TMP/client.log" >&2; die "REALITY第${n}次联网测试失败。"; }
done
DL="$(curl --noproxy '' -sS -o /dev/null -w '%{http_code} %{time_starttransfer} %{speed_download}' --socks5-hostname 127.0.0.1:19084 --max-time 90 'https://speed.cloudflare.com/__down?bytes=33554432' 2>/dev/null || true)"
DL_CODE="$(printf '%s' "$DL" | awk '{print $1}')"; DL_TTFB="$(printf '%s' "$DL" | awk '{print $2}')"; SPEED="$(printf '%s' "$DL" | awk '{print $3}')"
[ "$DL_CODE" = 200 ] || die "REALITY 32MB持续传输失败（HTTP=$DL_CODE）。"
THROUGHPUT="$(awk -v b="$SPEED" 'BEGIN{printf "%.1f Mbps",b*8/1000000}')"
kill "$CLIENT_PID" 2>/dev/null || true; wait "$CLIENT_PID" 2>/dev/null || true
ok "5次网页通过；首字节 ${TTFB_LIST}s；32MB首字节 ${DL_TTFB}s；持续下载 $THROUGHPUT"

step 8 "通过 ping0.cc 确认国家并生成节点"
PUBLIC_IP="$(curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
[ -n "$PUBLIC_IP" ] || PUBLIC_IP="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}')"
[ -n "$PUBLIC_IP" ] || die "无法取得VPS公网IPv4。"
PING0_RAW=""
for _ in 1 2 3; do
  for u in https://ipv4.ping0.cc/geo https://ping0.cc/geo; do PING0_RAW="$(curl -4fsSL --connect-timeout 6 --max-time 15 "$u" 2>/dev/null | tr -d '\r' || true)"; [ -n "$PING0_RAW" ] && break 2; done
  sleep 2
done
PING0_IP="$(printf '%s\n' "$PING0_RAW" | sed -n '1p' | awk '{print $1}')"
GEO_LOC="$(printf '%s\n' "$PING0_RAW" | sed -n '2p')"
COUNTRY_CN="$(printf '%s' "$GEO_LOC" | awk '{print $1}')"
[ -n "$COUNTRY_CN" ] || die "ping0.cc没有返回国家位置。"
flag_of(){ case "$1" in
  美国) echo '🇺🇸';; 加拿大) echo '🇨🇦';; 英国) echo '🇬🇧';; 德国) echo '🇩🇪';; 法国) echo '🇫🇷';; 荷兰) echo '🇳🇱';;
  日本) echo '🇯🇵';; 韩国) echo '🇰🇷';; 新加坡) echo '🇸🇬';; 印度尼西亚|印尼) echo '🇮🇩';; 马来西亚) echo '🇲🇾';; 泰国) echo '🇹🇭';; 越南) echo '🇻🇳';;
  中国) echo '🇨🇳';; 中国香港|香港) echo '🇭🇰';; 中国台湾|台湾) echo '🇹🇼';; 澳大利亚) echo '🇦🇺';; 印度) echo '🇮🇳';; 沙特阿拉伯) echo '🇸🇦';;
  西班牙) echo '🇪🇸';; 葡萄牙) echo '🇵🇹';; 意大利) echo '🇮🇹';; 瑞士) echo '🇨🇭';; 波兰) echo '🇵🇱';; 俄罗斯) echo '🇷🇺';; 巴西) echo '🇧🇷';; *) echo '🌐';; esac; }
FLAG="$(flag_of "$COUNTRY_CN")"
NODE_NAME="$FLAG $COUNTRY_CN 纯净独享IP"
ENCODED_NAME="$(jq -rn --arg v "$NODE_NAME" '$v|@uri')"
VLESS_LINK="vless://${UUID}@${PUBLIC_IP}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_DOMAIN}&fp=chrome&pbk=${REALITY_PUBLIC}&sid=${SHORT_ID}&type=tcp&headerType=none#${ENCODED_NAME}"
QR_FILE="/root/Reality-v10-${COUNTRY_CN}-纯净独享IP.png"
if command -v qrencode >/dev/null 2>&1; then qrencode -o "$QR_FILE" -s 8 -m 2 "$VLESS_LINK"; chmod 600 "$QR_FILE"; fi
cat >"$INFO" <<EOF
VLESS + RAW/TCP + REALITY + XTLS Vision v$VERSION
服务器：$PUBLIC_IP
ping0.cc检测IP：${PING0_IP:-$PUBLIC_IP}
ping0.cc位置：$GEO_LOC
节点名称：$NODE_NAME
端口：TCP $REALITY_PORT
伪装站：$REALITY_DOMAIN
内核：$($BIN version | head -1)
档位：$PROFILE / CPU ${CPU_COUNT}核 / 内存 $((MEM_KB/1024))MB / 拥塞控制 $CC
5次网页首字节：${TTFB_LIST}s
32MB测试：首字节 ${DL_TTFB}s / 持续下载 $THROUGHPUT

$VLESS_LINK

二维码：$QR_FILE
管理命令：reality-fast info | status | restart | log | health
云厂商安全组必须放行：TCP $REALITY_PORT
EOF
chmod 600 "$INFO"
cat >/usr/local/bin/reality-fast <<'EOF'
#!/usr/bin/env bash
case "${1:-info}" in
  info) cat /root/xray-reality-v10-info.txt ;;
  status) systemctl status xray-reality-v10 --no-pager -l ;;
  restart) systemctl restart xray-reality-v10 && systemctl is-active xray-reality-v10 ;;
  log) journalctl -u xray-reality-v10 -n 100 --no-pager ;;
  health) systemctl is-active xray-reality-v10; ss -ltnp | grep xray ;;
  *) echo '用法：reality-fast {info|status|restart|log|health}' ;;
esac
EOF
chmod 755 /usr/local/bin/reality-fast
printf '\n%b\n%s\n' "$G安装、REALITY鉴权、真实代理联网和持续传输全部通过：$N" "$VLESS_LINK"
printf '%b\n' "$G小火箭节点名：$NODE_NAME$N"
printf '%b\n' "$Y注意：安全组必须放行TCP $REALITY_PORT；物理线路速度和故障无法由协议脚本改变。$N"
