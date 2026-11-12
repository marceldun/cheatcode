#!/usr/bin/env bash
# 低配 VPS REALITY 极速一键搭建 v12
# 协议：VLESS + RAW/TCP + REALITY + XTLS Vision
# 改进点：保留 v11 所有调优，并为真实 REALITY 客户端动态启用 TCP Brutal v2 丢包补偿。
set -Eeuo pipefail

VERSION="12.0.0"
WORK_DIR="/etc/xray-reality-v12"
BIN="$WORK_DIR/xray"
CONF="$WORK_DIR/config.json"
STATE="$WORK_DIR/state.env"
OLD_STATE="/etc/xray-reality-v11/state.env"
LEGACY_STATE="/etc/xray-reality-v10/state.env"
INFO="/root/xray-reality-v12-info.txt"
TMP="$(mktemp -d /tmp/reality-fast-v12.XXXXXX)"
REALITY_PORT="${REALITY_PORT:-443}"
REALITY_DOMAIN="${REALITY_DOMAIN:-}"
REALITY_BRUTAL_MBPS="${REALITY_BRUTAL_MBPS:-100}"
BRUTAL_VERSION="2.0.1"
BRUTAL_INSTALLER_COMMIT="d2397ff8bca04a29fd2de01cf7d2d4b825224de8"
BRUTAL_INSTALLER_SHA256="399eebb8df5e14f4ca1e11468b292f27585f633aa56f08d0c20e9eb1d5f35880"
BRUTAL_TARBALL_SHA256="64a2778f308f7684cb5a137d578bc071e373960a3b9b79f9de015b84b29a7299"
XRAY_ARCH=""

R='\033[31m'; G='\033[32m'; Y='\033[33m'; C='\033[36m'; N='\033[0m'
step(){ printf '\n%b[%s/8] %s%b\n' "$C" "$1" "$2" "$N"; }
ok(){ printf '%b[成功] %s%b\n' "$G" "$*" "$N"; }
warn(){ printf '%b[提示] %s%b\n' "$Y" "$*" "$N"; }
die(){ printf '%b[失败] %s%b\n' "$R" "$*" "$N" >&2; exit 1; }
cleanup(){ local rc=$?; jobs -pr | xargs -r kill 2>/dev/null || true; command -v brutalctl >/dev/null 2>&1 && brutalctl del 127.0.0.1/32 >/dev/null 2>&1 || true; rm -rf "$TMP"; exit "$rc"; }
trap cleanup EXIT

[ "$(id -u)" -eq 0 ] || die "请使用root账号执行。"
command -v systemctl >/dev/null 2>&1 || die "当前系统不是systemd，无法安全配置自启。"

# SSH可能正通过旧代理连接。后台worker保证窗口断开也不会中止安装。
if [ "${REALITY_V12_WORKER:-0}" != 1 ]; then
  RUNNER=/root/install_fast_reality_v12.sh
  WORKER_ENV=/root/.reality-v12-installer.env
  INSTALL_LOG=/root/reality-v12-install.log
  DONE_FILE=/root/reality-v12-install.done
  install -m 700 "${BASH_SOURCE[0]}" "$RUNNER"
  {
    printf 'REALITY_PORT=%q\n' "$REALITY_PORT"
    printf 'REALITY_DOMAIN=%q\n' "$REALITY_DOMAIN"
    printf 'REALITY_BRUTAL_MBPS=%q\n' "$REALITY_BRUTAL_MBPS"
  } >"$WORKER_ENV"
  chmod 600 "$WORKER_ENV"; : >"$INSTALL_LOG"; rm -f "$DONE_FILE"
  UNIT="reality-v12-installer-$(date +%s)"
  systemd-run --unit="$UNIT" --property=Type=exec /bin/bash -c \
    "set -a; . '$WORKER_ENV'; set +a; REALITY_V12_WORKER=1 bash '$RUNNER' >>'$INSTALL_LOG' 2>&1; rc=\$?; rm -f '$WORKER_ENV'; echo \$rc >'$DONE_FILE'; exit \$rc" >/dev/null
  ok "REALITY v12后台安装已启动；Xshell断开也会继续。"
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
if [ "$MEM_KB" -le 524288 ]; then PROFILE=tiny; SOCKBUF=16777216; BACKLOG=4096
elif [ "$MEM_KB" -le 1048576 ]; then PROFILE=small; SOCKBUF=33554432; BACKLOG=8192
elif [ "$MEM_KB" -le 2097152 ]; then PROFILE=normal; SOCKBUF=67108864; BACKLOG=16384
else PROFILE=large; SOCKBUF=134217728; BACKLOG=32768; fi
ok "系统：$OS_NAME；CPU：${CPU_COUNT}核；内存：$((MEM_KB/1024))MB；档位：$PROFILE"

step 2 "安装必要组件"
if [ "$PM" = apt ]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y --no-install-recommends curl jq unzip openssl iproute2 ca-certificates ethtool >/dev/null
  timeout 90 apt-get install -y --no-install-recommends qrencode >/dev/null 2>&1 || true
elif [ "$PM" = apk ]; then
  apk add --no-cache curl jq unzip openssl iproute2 ca-certificates ethtool qrencode >/dev/null
else
  "$PM" -y install curl jq unzip openssl iproute ca-certificates ethtool qrencode >/dev/null
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
  if curl -A 'reality-fast-v12' -fL --connect-timeout 10 --max-time 600 --retry 3 --retry-delay 2 -C - -o "$part" "${p}${url}" 2>/dev/null && [ -s "$part" ]; then mv -f "$part" "$dst"; return 0; fi
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
if [ ! -f "$STATE" ] && { [ -f "$OLD_STATE" ] || [ -f "$LEGACY_STATE" ]; }; then
  SOURCE_STATE="$OLD_STATE"
  [ -f "$SOURCE_STATE" ] || SOURCE_STATE="$LEGACY_STATE"
  cp -a "$SOURCE_STATE" "$STATE"
  chmod 600 "$STATE"
  ok "已沿用旧版的UUID、REALITY密钥、端口和伪装站；旧版文件原样保留。"
fi
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
  "policy":{"levels":{"0":{"handshake":60,"connIdle":600,"uplinkOnly":0,"downlinkOnly":0,"bufferSize":0}},"system":{"statsInboundUplink":false,"statsInboundDownlink":false,"statsOutboundUplink":false,"statsOutboundDownlink":false}},
  "inbounds":[{
    "listen":"0.0.0.0","port":$REALITY_PORT,"protocol":"vless","tag":"reality-vision-in",
    "settings":{"clients":[{"id":"$UUID","flow":"xtls-rprx-vision","email":"reality-v12"}],"decryption":"none"},
    "streamSettings":{
      "network":"raw","security":"reality",
      "realitySettings":{"show":false,"target":"$REALITY_DOMAIN:443","xver":0,"serverNames":["$REALITY_DOMAIN"],"privateKey":"$REALITY_PRIVATE","shortIds":["$SHORT_ID"]},
      "sockopt":{"tcpFastOpen":true,"tcpKeepAliveIdle":60,"tcpKeepAliveInterval":15,"tcpUserTimeout":60000,"tcpCongestion":"brutal"}
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

step 5 "应用 BBR 基线、TCP Brutal 丢包补偿和硬件卸载"
modprobe tcp_bbr >/dev/null 2>&1 || true
printf '%s\n' tcp_bbr >/etc/modules-load.d/reality-fast-v12.conf 2>/dev/null || true
AVAILABLE_CC="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || true)"
case " $AVAILABLE_CC " in *" bbr "*) CC=bbr ;; *) CC=cubic ;; esac
cat >/etc/sysctl.d/99-reality-fast-v12.conf <<EOF
# REALITY v12: high-throughput baseline; Brutal is only selected by per-client routes.
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=$CC
net.ipv4.tcp_fastopen=3
net.core.somaxconn=$BACKLOG
net.core.netdev_max_backlog=$BACKLOG
net.core.optmem_max=4194304
net.core.rps_sock_flow_entries=32768
net.core.rmem_max=$SOCKBUF
net.core.wmem_max=$SOCKBUF
net.ipv4.tcp_rmem=4096 131072 $SOCKBUF
net.ipv4.tcp_wmem=4096 65536 $SOCKBUF
net.ipv4.tcp_max_syn_backlog=$BACKLOG
net.ipv4.tcp_moderate_rcvbuf=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_dsack=1
net.ipv4.tcp_early_retrans=3
net.ipv4.tcp_recovery=1
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_keepalive_time=60
net.ipv4.tcp_keepalive_intvl=15
net.ipv4.tcp_keepalive_probes=4
net.ipv4.tcp_notsent_lowat=4294967295
net.ipv4.ip_local_port_range=10240 65535
fs.file-max=1048576
EOF
sysctl -p /etc/sysctl.d/99-reality-fast-v12.conf >/dev/null 2>&1 || true
IFACE="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')"
OFFLOAD=unsupported
if [ -n "$IFACE" ] && command -v ethtool >/dev/null 2>&1; then
  if ethtool -K "$IFACE" gro on gso on tso on >/dev/null 2>&1; then OFFLOAD=enabled; fi
fi

# TCP Brutal v2 不是系统默认算法；只对识别到的 REALITY 客户端 IP 创建目标路由。
KERNEL_MM="$(uname -r | grep -oE '^[0-9]+\.[0-9]+' || true)"
[ -n "$KERNEL_MM" ] && [ "$(printf '5.10\n%s\n' "$KERNEL_MM" | sort -V | head -n1)" = 5.10 ] || \
  die "TCP Brutal v2 需要 Linux 5.10+；当前内核 $(uname -r)。v11 仍保持运行。"
[[ "$REALITY_BRUTAL_MBPS" =~ ^[0-9]+$ ]] && [ "$REALITY_BRUTAL_MBPS" -ge 10 ] && [ "$REALITY_BRUTAL_MBPS" -le 10000 ] || \
  die "REALITY_BRUTAL_MBPS 必须是 10-10000 之间的整数。"
BRUTAL_INSTALLER_URL="https://raw.githubusercontent.com/HyNetworks/tcp-brutal/$BRUTAL_INSTALLER_COMMIT/scripts/install_dkms.sh"
BRUTAL_TARBALL_URL="https://github.com/HyNetworks/tcp-brutal/releases/download/v${BRUTAL_VERSION}/tcp-brutal.dkms.tar.gz"
download "$BRUTAL_INSTALLER_URL" "$TMP/install-tcp-brutal.sh" || die "TCP Brutal 官方安装器下载失败；v11 仍保持运行。"
download "$BRUTAL_TARBALL_URL" "$TMP/tcp-brutal.dkms.tar.gz" || die "TCP Brutal 官方源码包下载失败；v11 仍保持运行。"
printf '%s  %s\n' "$BRUTAL_INSTALLER_SHA256" "$TMP/install-tcp-brutal.sh" | sha256sum -c - >/dev/null || die "TCP Brutal 安装器校验失败。"
printf '%s  %s\n' "$BRUTAL_TARBALL_SHA256" "$TMP/tcp-brutal.dkms.tar.gz" | sha256sum -c - >/dev/null || die "TCP Brutal 源码包校验失败。"
TERM=dumb bash "$TMP/install-tcp-brutal.sh" --local "$TMP/tcp-brutal.dkms.tar.gz" || \
  die "TCP Brutal 内核模块安装失败（通常是 VPS 没有与当前内核匹配的 headers）。v11 仍保持运行。"
modprobe brutal || die "TCP Brutal 模块无法加载；v11 仍保持运行。"
command -v brutalctl >/dev/null 2>&1 && [ -r /proc/net/tcp_brutal/rules ] || die "TCP Brutal 安装后验证失败。"

install -d -m 700 /etc/xray-reality-v12 /var/lib/xray-reality-v12
cat >/etc/xray-reality-v12/brutal.env <<EOF
REALITY_PORT=$REALITY_PORT
REALITY_BRUTAL_MBPS=$REALITY_BRUTAL_MBPS
EOF
chmod 600 /etc/xray-reality-v12/brutal.env
cat >/usr/local/sbin/reality-v12-brutal-watcher <<'WATCHER'
#!/usr/bin/env bash
set -u
STATE=/run/reality-v12-brutal-seen
mkdir -p /run
[ -s /proc/net/tcp_brutal/rules ] || : >"$STATE"
touch "$STATE"
peer_ip() {
  case "$1" in
    \[*\]:*) local x="${1#\[}"; printf '%s\n' "${x%%\]:*}" ;;
    *:*) printf '%s\n' "${1%:*}" ;;
  esac
}
while :; do
  while IFS= read -r peer; do
    [ -n "$peer" ] || continue
    ip="$(peer_ip "$peer")"
    case "$ip" in ''|127.*|::1|0.0.0.0) continue ;; esac
    case "$ip" in *:*) prefix="$ip/128" ;; *) prefix="$ip/32" ;; esac
    grep -Fqx "$prefix" "$STATE" && continue
    if /usr/local/bin/brutalctl add "$prefix" "$REALITY_BRUTAL_MBPS" gain=20; then
      printf '%s\n' "$prefix" >>"$STATE"
      # 第一条连接建立时规则尚不存在；只终止该端口到该客户的旧连接，促使客户端立即自动重连。
      timeout 2 ss -K state established sport = :"$REALITY_PORT" dst "$ip" >/dev/null 2>&1 || true
      echo "REALITY client $prefix now uses TCP Brutal ${REALITY_BRUTAL_MBPS}Mbps; first connection was recycled"
    fi
  done < <(ss -Htn state established "sport = :$REALITY_PORT" 2>/dev/null | awk '{print $4}' | sort -u)
  sleep 1
done
WATCHER
chmod 755 /usr/local/sbin/reality-v12-brutal-watcher
ok "基线拥塞控制：$CC；客户端丢包补偿：TCP Brutal ${REALITY_BRUTAL_MBPS}Mbps；窗口：$((SOCKBUF/1024/1024))MB；GRO/GSO/TSO：$OFFLOAD"

step 6 "启动 REALITY 并启用真实进程崩溃自愈"
cat >/etc/systemd/system/xray-reality-v12.service <<EOF
[Unit]
Description=Xray VLESS REALITY Vision with TCP Brutal v12
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=root
WorkingDirectory=$WORK_DIR
ExecStart=$BIN run -config $CONF
Restart=always
RestartSec=1
LimitNOFILE=1048576
TasksMax=infinity
Nice=-10
OOMScoreAdjust=-500
Environment=XRAY_RAY_BUFFER_SIZE=0
[Install]
WantedBy=multi-user.target
EOF
cat >/etc/systemd/system/reality-v12-brutal-watcher.service <<EOF
[Unit]
Description=Apply TCP Brutal only to REALITY v12 client addresses
After=network-online.target xray-reality-v12.service
Requires=xray-reality-v12.service
[Service]
Type=simple
EnvironmentFile=/etc/xray-reality-v12/brutal.env
ExecStart=/usr/local/sbin/reality-v12-brutal-watcher
Restart=always
RestartSec=1
Nice=-5
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable xray-reality-v12 reality-v12-brutal-watcher >/dev/null 2>&1
if command -v ufw >/dev/null 2>&1 && ufw status | grep -qi active; then ufw allow "$REALITY_PORT/tcp" >/dev/null || true; fi
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then firewall-cmd --permanent --add-port="$REALITY_PORT/tcp" >/dev/null || true; firewall-cmd --reload >/dev/null || true; fi
OLD_ACTIVE_SERVICE=""
for old_service in xray-reality-v11 xray-reality-v10; do
  if systemctl is-active --quiet "$old_service" 2>/dev/null; then OLD_ACTIVE_SERVICE="$old_service"; systemctl disable --now "$old_service" >/dev/null 2>&1 || true; break; fi
done
restore_old(){ if [ -n "$OLD_ACTIVE_SERVICE" ]; then systemctl enable "$OLD_ACTIVE_SERVICE" >/dev/null 2>&1 || true; systemctl start "$OLD_ACTIVE_SERVICE" >/dev/null 2>&1 || true; fi; }
if ! systemctl restart xray-reality-v12; then
  restore_old
  die "REALITY v12启动失败，已恢复旧版运行。"
fi
sleep 2
systemctl is-active --quiet xray-reality-v12 || { journalctl -u xray-reality-v12 -n 80 --no-pager >&2; restore_old; die "REALITY v12启动失败，已恢复旧版运行。"; }
if ! systemctl restart reality-v12-brutal-watcher; then
  systemctl disable --now xray-reality-v12 >/dev/null 2>&1 || true
  restore_old
  die "TCP Brutal 客户端识别服务启动失败，已恢复旧版运行。"
fi
systemctl is-active --quiet reality-v12-brutal-watcher || { systemctl disable --now xray-reality-v12 >/dev/null 2>&1 || true; restore_old; die "TCP Brutal 客户端识别服务未运行，已恢复旧版。"; }
ss -ltn | grep -qE "[:.]${REALITY_PORT}[[:space:]]" || die "REALITY TCP端口没有监听。"
ok "REALITY v12正在监听TCP $REALITY_PORT；TCP Brutal监听器正常；v11文件原样保留，HY2未删除、未停止"

step 7 "执行 TCP Brutal 内核规则、REALITY 网页和持续传输测试"
TEST_PREFIX="127.0.0.1/32"
brutalctl add "$TEST_PREFIX" "$REALITY_BRUTAL_MBPS" gain=20 noroute >/dev/null || die "TCP Brutal测试规则无法建立。"
brutalctl list | grep -Fq "$TEST_PREFIX" || { brutalctl del "$TEST_PREFIX" >/dev/null 2>&1 || true; die "TCP Brutal测试规则未生效。"; }
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
brutalctl del "$TEST_PREFIX" >/dev/null || die "TCP Brutal回环测试规则无法清理。"
ok "TCP Brutal规则生效并完整清理；5次网页通过；首字节 ${TTFB_LIST}s；32MB持续下载 $THROUGHPUT"

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
QR_FILE="/root/Reality-v12-${COUNTRY_CN}-纯净独享IP.png"
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
极限优化：Vision bufferSize=0 / TCP窗口 $((SOCKBUF/1024/1024))MB / GRO-GSO-TSO $OFFLOAD
REALITY客户端丢包补偿：TCP Brutal v$BRUTAL_VERSION / 目标 ${REALITY_BRUTAL_MBPS}Mbps / 新连接自动生效
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
  info) cat /root/xray-reality-v12-info.txt ;;
  status) systemctl status xray-reality-v12 reality-v12-brutal-watcher --no-pager -l ;;
  restart) systemctl restart xray-reality-v12 reality-v12-brutal-watcher && systemctl is-active xray-reality-v12 reality-v12-brutal-watcher ;;
  log) journalctl -u xray-reality-v12 -u reality-v12-brutal-watcher -n 100 --no-pager ;;
  health) systemctl is-active xray-reality-v12 reality-v12-brutal-watcher; ss -ltnp | grep xray; brutalctl list ;;
  *) echo '用法：reality-fast {info|status|restart|log|health}' ;;
esac
EOF
chmod 755 /usr/local/bin/reality-fast
printf '\n%b\n%s\n' "$G安装、TCP Brutal内核规则、REALITY鉴权、真实代理联网和持续传输全部通过：$N" "$VLESS_LINK"
printf '%b\n' "$G小火箭节点名：$NODE_NAME$N"
printf '%b\n' "$Y注意：安全组必须放行TCP $REALITY_PORT；Brutal能补偿丢包，但不能凭空创造VPS带宽或改变物理路由。$N"
