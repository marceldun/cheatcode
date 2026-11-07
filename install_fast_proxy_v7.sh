#!/usr/bin/env bash
# sing-box 低配 VPS 极速一键搭建 v7
# 改进点：HY2单协议、UDP端口自动避让、ping0.cc国家命名。
# 目标：只运行Hysteria2，针对网页首字节、视频起播和持续传输做低内存自适应优化。
# 支持：Debian/Ubuntu/CentOS/Rocky/Alma/Fedora/Alpine，x86_64/arm64/armv7。
set -Eeuo pipefail

VERSION="7.0.0"
WORK_DIR="/etc/sing-box"
BIN="$WORK_DIR/sing-box"
CONF="$WORK_DIR/config.json"
STATE="$WORK_DIR/fast-v7.env"
OLD_STATE="$WORK_DIR/fast-v6.env"
INFO="/root/sing-box-fast-v7-info.txt"
TMP="$(mktemp -d /tmp/sb-fast-v7.XXXXXX)"
HY2_PORT="${HY2_PORT:-443}"
REALITY_DOMAIN="${REALITY_DOMAIN:-addons.mozilla.org}"
ENABLE_OBFS="${ENABLE_OBFS:-0}"
OBFS_TYPE="${OBFS_TYPE:-salamander}"
ESC="$(printf '\033')"; G="${ESC}[32m"; Y="${ESC}[33m"; R="${ESC}[31m"; C="${ESC}[36m"; N="${ESC}[0m"

ok(){ printf '%b\n' "${G}[成功]${N} $*"; }
warn(){ printf '%b\n' "${Y}[提示]${N} $*"; }
step(){ printf '\n%b\n' "${C}[$1/8] $2${N}"; }
die(){ printf '%b\n' "${R}[失败]${N} $*" >&2; exit 1; }
on_error(){ local rc=$? line=${BASH_LINENO[0]:-?}; printf '%b\n' "${R}[失败]${N} 第 ${line} 行，退出码 ${rc}。旧配置备份仍保留在 ${WORK_DIR}/backup/。" >&2; exit "$rc"; }
cleanup(){ rm -rf "$TMP" 2>/dev/null || true; }
trap on_error ERR
trap cleanup EXIT

[ "$(id -u)" -eq 0 ] || die "请用 root 运行。"

# SSH可能正通过旧代理连接本机。安装过程重启sing-box时前台会断线，
# 因此完整任务由systemd独立执行，Xshell断开也不会中止。
if [ "${SB_FAST_V7_WORKER:-0}" != 1 ]; then
  RUNNER=/root/install_fast_proxy_v7.sh
  WORKER_ENV=/root/.sb-fast-v7-installer.env
  INSTALL_LOG=/root/sb-fast-v7-install.log
  DONE_FILE=/root/sb-fast-v7-install.done
  install -m 700 "${BASH_SOURCE[0]}" "$RUNNER"
  {
    for name in HY2_PORT REALITY_DOMAIN ENABLE_OBFS OBFS_TYPE SB_VERSION MEM_KB_OVERRIDE; do
      [ -z "${!name:-}" ] || printf '%s=%q\n' "$name" "${!name}"
    done
  } > "$WORKER_ENV"
  chmod 600 "$WORKER_ENV"; : > "$INSTALL_LOG"; rm -f "$DONE_FILE"
  UNIT="sb-fast-v7-installer-$(date +%s)"
  systemd-run --unit="$UNIT" --property=Type=exec /bin/bash -c \
    "set -a; . '$WORKER_ENV'; set +a; SB_FAST_V7_WORKER=1 bash '$RUNNER' >>'$INSTALL_LOG' 2>&1; rc=\$?; rm -f '$WORKER_ENV'; echo \$rc >'$DONE_FILE'; exit \$rc" >/dev/null
  ok "后台安装已启动；即使Xshell断线也会继续。"
  printf '安装日志：%s\n完成状态：%s（显示0代表成功）\n' "$INSTALL_LOG" "$DONE_FILE"
  shown=0
  while [ ! -s "$DONE_FILE" ]; do
    lines=$(wc -l < "$INSTALL_LOG" 2>/dev/null || echo 0)
    if [ "$lines" -gt "$shown" ]; then sed -n "$((shown+1)),${lines}p" "$INSTALL_LOG"; shown="$lines"; fi
    sleep 2
  done
  lines=$(wc -l < "$INSTALL_LOG" 2>/dev/null || echo 0)
  [ "$lines" -le "$shown" ] || sed -n "$((shown+1)),${lines}p" "$INSTALL_LOG"
  [ "$(cat "$DONE_FILE")" = 0 ] || die "后台安装失败，详情：$INSTALL_LOG"
  exit 0
fi

step 1 "检测系统与低配置参数"
case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  armv7l) ARCH=armv7 ;;
  *) die "不支持的 CPU 架构：$(uname -m)" ;;
esac
. /etc/os-release 2>/dev/null || true
OS_NAME="${PRETTY_NAME:-Linux}"
case "${ID:-}" in
  debian|ubuntu) PM=apt ;;
  centos|rhel|rocky|almalinux|fedora) PM=rpm ;;
  alpine) PM=apk ;;
  *) command -v apt-get >/dev/null && PM=apt || { command -v apk >/dev/null && PM=apk || PM=rpm; } ;;
esac
MEM_KB="${MEM_KB_OVERRIDE:-$(awk '/MemTotal/{print $2}' /proc/meminfo)}"
CPU_COUNT="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
if [ "$MEM_KB" -le 524288 ]; then
  PROFILE=tiny; SOCKBUF=8388608; BACKLOG=2048
elif [ "$MEM_KB" -le 1048576 ]; then
  PROFILE=small; SOCKBUF=16777216; BACKLOG=4096
elif [ "$MEM_KB" -le 2097152 ]; then
  PROFILE=normal; SOCKBUF=33554432; BACKLOG=8192
else
  PROFILE=large; SOCKBUF=67108864; BACKLOG=16384
fi
ok "系统：$OS_NAME；CPU：${CPU_COUNT} 核；内存：$((MEM_KB/1024)) MB；自动档位：$PROFILE"

step 2 "安装必要组件"
if [ "$PM" = apt ]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y curl jq tar openssl iproute2 ca-certificates >/dev/null
  apt-get install -y ethtool qrencode python3 >/dev/null 2>&1 || true
elif [ "$PM" = apk ]; then
  apk add --no-cache curl jq tar openssl iproute2 ca-certificates ethtool qrencode python3 >/dev/null
else
  INSTALLER=yum; command -v dnf >/dev/null && INSTALLER=dnf
  "$INSTALLER" -y install curl jq tar openssl iproute ethtool qrencode python3 ca-certificates >/dev/null
fi
for c in curl jq tar openssl ip ss; do command -v "$c" >/dev/null || die "缺少组件：$c"; done
ok "组件已就绪"

step 3 "下载并校验 sing-box 官方内核"
mkdir -p "$WORK_DIR" "$WORK_DIR/backup"
chmod 700 "$WORK_DIR"
PREFIXES=("" "https://ghfast.top/" "https://gh-proxy.com/" "https://ghproxy.net/")
fetch_text(){ local url=$1 p; for p in "${PREFIXES[@]}"; do curl -A 'sb-fast-v7' -fsSL --connect-timeout 8 --max-time 25 "${p}${url}" 2>/dev/null && return 0; done; return 1; }
download(){ local url=$1 dst=$2 p part; part="${dst}.part"; for p in "${PREFIXES[@]}"; do
  if curl -A 'sb-fast-v7' -fL --connect-timeout 10 --max-time 600 --retry 3 --retry-delay 2 -C - -o "$part" "${p}${url}" 2>/dev/null && [ -s "$part" ]; then mv -f "$part" "$dst"; return 0; fi
done; return 1; }
SB_VERSION="${SB_VERSION:-}"
if [ -z "$SB_VERSION" ]; then
  SB_VERSION="$(fetch_text 'https://api.github.com/repos/SagerNet/sing-box/releases/latest' | jq -r '.tag_name // empty' | sed 's/^v//' || true)"
fi
if [ -x "$BIN" ] && "$BIN" version >/dev/null 2>&1; then
  ok "沿用已安装内核：$($BIN version | head -1)"
else
  [ -n "$SB_VERSION" ] || die "无法取得 sing-box 版本，请检查 VPS 到 GitHub 的网络。"
  URL="https://github.com/SagerNet/sing-box/releases/download/v${SB_VERSION}/sing-box-${SB_VERSION}-linux-${ARCH}.tar.gz"
  download "$URL" "$TMP/sing-box.tar.gz" || die "所有官方内核下载通道均失败。重新运行会断点续传。"
  tar -xzf "$TMP/sing-box.tar.gz" -C "$TMP"
  NEW_BIN="$(find "$TMP" -type f -name sing-box | head -1)"
  [ -n "$NEW_BIN" ] || die "压缩包中没有 sing-box。"
  install -m 755 "$NEW_BIN" "$BIN"
  "$BIN" version >/dev/null 2>&1 || die "sing-box 内核无法运行。"
  ok "已安装：$($BIN version | head -1)"
fi

step 4 "生成 HY2 单协议极速配置"

listener_lines(){ ss -H -lunp 2>/dev/null | grep -E "[:.]${1}[[:space:]]" || true; }
port_can_use(){ local lines; lines="$(listener_lines "$1")"; [ -z "$lines" ] || ! printf '%s\n' "$lines" | grep -qv '"sing-box"'; }
pick_port(){ local preferred="$1" p; for p in "$preferred" 443 8443 2053 2083 2087 2096 10443 24443 30443; do port_can_use "$p" && { printf '%s' "$p"; return; }; done; for p in $(seq 20000 200 60000); do port_can_use "$p" && { printf '%s' "$p"; return; }; done; return 1; }
REQUESTED_HY2_PORT="$HY2_PORT"
HY2_PORT="$(pick_port "$REQUESTED_HY2_PORT")" || die "找不到可用 UDP 端口。"
[ "$HY2_PORT" = "$REQUESTED_HY2_PORT" ] || warn "UDP $REQUESTED_HY2_PORT 被占用，自动改用 UDP $HY2_PORT。"

if [ ! -f "$STATE" ] && [ -f "$OLD_STATE" ]; then cp -a "$OLD_STATE" "$STATE"; chmod 600 "$STATE"; ok "已沿用 v6 的 HY2 密码。"; fi
if [ -f "$STATE" ]; then
  # shellcheck disable=SC1090
  . "$STATE"
fi
HY2_PASSWORD="${HY2_PASSWORD:-$(openssl rand -hex 18)}"
OBFS_PASSWORD="${OBFS_PASSWORD:-$(openssl rand -hex 18)}"
cat > "$STATE" <<EOF
HY2_PASSWORD='$HY2_PASSWORD'
OBFS_PASSWORD='$OBFS_PASSWORD'
EOF
chmod 600 "$STATE"

mkdir -p "$WORK_DIR/cert"
if [ ! -s "$WORK_DIR/cert/cert.pem" ] || [ ! -s "$WORK_DIR/cert/key.pem" ]; then
  openssl ecparam -genkey -name prime256v1 -out "$WORK_DIR/cert/key.pem" >/dev/null 2>&1
  openssl req -new -x509 -days 3650 -key "$WORK_DIR/cert/key.pem" -out "$WORK_DIR/cert/cert.pem" -subj "/CN=$REALITY_DOMAIN" >/dev/null 2>&1
fi
chmod 600 "$WORK_DIR/cert/key.pem"

gen_hy2_config(){
  local level="$1" extra=""
  if [ "$ENABLE_OBFS" = 1 ]; then printf -v extra ',\n      "obfs":{"type":"%s","password":"%s"}' "$OBFS_TYPE" "$OBFS_PASSWORD"; fi
  if [ "$level" -ge 1 ]; then extra+=',
      "bbr_profile":"aggressive"'; fi
  if [ "$level" -ge 2 ]; then extra+=',
      "stream_receive_window":"16 MB",
      "connection_receive_window":"64 MB",
      "max_concurrent_streams":256,
      "keep_alive_period":"15s",
      "idle_timeout":"120s"'; fi
  cat > "$TMP/config-level-${level}.json" <<EOF
{
  "log":{"disabled":true},
  "inbounds":[{
    "type":"hysteria2","tag":"hy2-max-speed","listen":"::","listen_port":$HY2_PORT,
    "users":[{"password":"$HY2_PASSWORD"}],
    "ignore_client_bandwidth":false,
    "tls":{"enabled":true,"alpn":["h3"],"certificate_path":"$WORK_DIR/cert/cert.pem","key_path":"$WORK_DIR/cert/key.pem"}$extra
  }],
  "outbounds":[{"type":"direct","tag":"direct"}]
}
EOF
}

TUNE_LEVEL=-1
for level in 2 1 0; do
  gen_hy2_config "$level"
  if "$BIN" check -c "$TMP/config-level-${level}.json" >"$TMP/config-check.log" 2>&1; then TUNE_LEVEL=$level; break; fi
done
[ "$TUNE_LEVEL" -ge 0 ] || { cat "$TMP/config-check.log" >&2; die "当前 sing-box 内核不能生成 HY2 配置。"; }
[ -f "$CONF" ] && cp -a "$CONF" "$WORK_DIR/backup/config.$(date +%Y%m%d-%H%M%S).json"
install -m 600 "$TMP/config-level-${TUNE_LEVEL}.json" "$CONF"
ok "HY2 单协议配置校验通过；官方内核支持的调优等级：$TUNE_LEVEL/2"

step 5 "应用低内存自适应 UDP/QUIC 优化"
modprobe tcp_bbr >/dev/null 2>&1 || true
printf '%s\n' tcp_bbr > /etc/modules-load.d/sing-box-fast-v7.conf 2>/dev/null || true
QDISC=fq
AVAILABLE_CC="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || true)"
case " $AVAILABLE_CC " in *" bbr "*) CC=bbr ;; *) CC=cubic ;; esac
RDEFAULT=$((SOCKBUF/8)); [ "$RDEFAULT" -lt 1048576 ] && RDEFAULT=1048576; [ "$RDEFAULT" -gt 4194304 ] && RDEFAULT=4194304
cat > /etc/sysctl.d/99-sing-box-fast-v7.conf <<EOF
# sing-box fast v7: adaptive HY2/QUIC tuning
net.core.default_qdisc=$QDISC
net.ipv4.tcp_congestion_control=$CC
net.core.rmem_max=$SOCKBUF
net.core.wmem_max=$SOCKBUF
net.core.rmem_default=$RDEFAULT
net.core.wmem_default=$RDEFAULT
net.ipv4.tcp_rmem=4096 87380 $SOCKBUF
net.ipv4.tcp_wmem=4096 65536 $SOCKBUF
net.ipv4.udp_rmem_min=16384
net.ipv4.udp_wmem_min=16384
net.core.netdev_max_backlog=$BACKLOG
net.core.somaxconn=4096
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.ip_local_port_range=10240 65535
EOF
sysctl -p /etc/sysctl.d/99-sing-box-fast-v7.conf >/dev/null 2>&1 || true
IFACE="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')"
GRO=unsupported
if [ -n "$IFACE" ] && command -v ethtool >/dev/null 2>&1; then if ethtool -K "$IFACE" rx-udp-gro-forwarding on rx-gro-list off >/dev/null 2>&1; then GRO=enabled; fi; fi
ok "QUIC缓冲：$((SOCKBUF/1024/1024)) MB；UDP GRO：$GRO；拥塞控制：$CC"

step 6 "启动 HY2 并启用单协议故障自愈"
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box HY2 maximum speed v7
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=root
WorkingDirectory=$WORK_DIR
ExecStart=$BIN run -c $CONF
Restart=always
RestartSec=1
LimitNOFILE=524288
Nice=-5
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable sing-box >/dev/null 2>&1
if command -v ufw >/dev/null 2>&1 && ufw status | grep -qi active; then ufw allow "$HY2_PORT/udp" >/dev/null || true; fi
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then firewall-cmd --permanent --add-port="$HY2_PORT/udp" >/dev/null || true; firewall-cmd --reload >/dev/null || true; fi
systemctl restart sing-box
sleep 2
systemctl is-active --quiet sing-box || { journalctl -u sing-box -n 60 --no-pager >&2; die "HY2 服务启动失败。"; }
ss -uln | grep -qE "[:.]${HY2_PORT}[[:space:]]" || die "HY2 UDP端口没有监听。"

HEALTH_OBFS=""
if [ "$ENABLE_OBFS" = 1 ]; then printf -v HEALTH_OBFS ',"obfs":{"type":"%s","password":"%s"}' "$OBFS_TYPE" "$OBFS_PASSWORD"; fi
cat > "$WORK_DIR/health-client-v7.json" <<EOF
{"log":{"level":"error"},"inbounds":[{"type":"socks","listen":"127.0.0.1","listen_port":19090}],"outbounds":[{"type":"hysteria2","server":"127.0.0.1","server_port":$HY2_PORT,"password":"$HY2_PASSWORD","tls":{"enabled":true,"server_name":"$REALITY_DOMAIN","insecure":true,"alpn":["h3"]}$HEALTH_OBFS}]}
EOF
"$BIN" check -c "$WORK_DIR/health-client-v7.json" >/dev/null || die "HY2健康检查配置校验失败。"
cat > /usr/local/bin/sb-fast-health-v7 <<EOF
#!/usr/bin/env bash
set -u
FAIL=/run/sb-fast-v7-health-fails
if ! systemctl is-active --quiet sing-box; then systemctl restart sing-box; echo 0 >"\$FAIL"; exit 0; fi
$BIN run -c $WORK_DIR/health-client-v7.json >/run/sb-fast-v7-health.log 2>&1 & pid=\$!
trap 'kill "\$pid" 2>/dev/null || true' EXIT
sleep 2
code=\$(curl --noproxy '' -sS -o /dev/null -w '%{http_code}' --socks5-hostname 127.0.0.1:19090 --max-time 12 https://www.gstatic.com/generate_204 2>/dev/null || true)
if [ "\$code" = 204 ] || [ "\$code" = 200 ]; then echo 0 >"\$FAIL"; exit 0; fi
n=\$(cat "\$FAIL" 2>/dev/null || echo 0); n=\$((n+1)); echo "\$n" >"\$FAIL"
if [ "\$n" -ge 2 ]; then logger -t sb-fast-v7 'HY2 health failed twice, restarting'; systemctl restart sing-box; echo 0 >"\$FAIL"; fi
EOF
chmod 700 /usr/local/bin/sb-fast-health-v7
cat > /etc/systemd/system/sb-fast-health-v7.service <<EOF
[Unit]
Description=sing-box v7 HY2 encrypted path health check
After=sing-box.service
[Service]
Type=oneshot
ExecStart=/usr/local/bin/sb-fast-health-v7
EOF
cat > /etc/systemd/system/sb-fast-health-v7.timer <<EOF
[Unit]
Description=Run sing-box v7 HY2 health check every minute
[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
RandomizedDelaySec=5
Unit=sb-fast-health-v7.service
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
for old in v5 v6; do systemctl disable --now "sb-fast-health-${old}.timer" >/dev/null 2>&1 || true; done
systemctl enable --now sb-fast-health-v7.timer >/dev/null
ok "HY2单协议已运行；连续两次完整加密联网失败才自愈，避免短暂抖动误重启"

step 7 "执行网页首字节、视频分片和持续吞吐测试"
cat > "$TMP/client.json" <<EOF
{"log":{"level":"error"},"inbounds":[{"type":"socks","listen":"127.0.0.1","listen_port":19080}],"outbounds":[{"type":"hysteria2","server":"127.0.0.1","server_port":$HY2_PORT,"password":"$HY2_PASSWORD","tls":{"enabled":true,"server_name":"$REALITY_DOMAIN","insecure":true,"alpn":["h3"]}$HEALTH_OBFS}]}
EOF
"$BIN" check -c "$TMP/client.json" >/dev/null
"$BIN" run -c "$TMP/client.json" >"$TMP/client.log" 2>&1 & CLIENT_PID=$!
sleep 2
TTFB_LIST=""; HTTP_CODE=""
for n in 1 2 3; do
  RESULT="$(curl --noproxy '' -sS -o /dev/null -w '%{http_code} %{time_starttransfer}' --socks5-hostname 127.0.0.1:19080 --max-time 20 "https://www.gstatic.com/generate_204?r=$n" 2>/dev/null || true)"
  HTTP_CODE="${RESULT%% *}"; TTFB_LIST="${TTFB_LIST}${TTFB_LIST:+,}${RESULT#* }"
  [ "$HTTP_CODE" = 204 ] || [ "$HTTP_CODE" = 200 ] || { cat "$TMP/client.log" >&2; kill "$CLIENT_PID" 2>/dev/null || true; die "HY2第${n}次联网测试失败。"; }
done
VIDEO_TEST="$(curl --noproxy '' -sS -o /dev/null -w '%{http_code} %{time_starttransfer} %{speed_download}' --socks5-hostname 127.0.0.1:19080 --max-time 90 'https://speed.cloudflare.com/__down?bytes=33554432' 2>/dev/null || true)"
VIDEO_CODE="$(printf '%s' "$VIDEO_TEST" | awk '{print $1}')"; VIDEO_TTFB="$(printf '%s' "$VIDEO_TEST" | awk '{print $2}')"; SPEED="$(printf '%s' "$VIDEO_TEST" | awk '{print $3}')"
[ "$VIDEO_CODE" = 200 ] || { kill "$CLIENT_PID" 2>/dev/null || true; die "32MB持续传输测试失败（HTTP=$VIDEO_CODE）。"; }
THROUGHPUT="$(awk -v b="$SPEED" 'BEGIN{printf "%.1f Mbps", b*8/1000000}')"
kill "$CLIENT_PID" 2>/dev/null || true; wait "$CLIENT_PID" 2>/dev/null || true
ok "HY2连续3次网页测试通过；首字节 ${TTFB_LIST}s；32MB首字节 ${VIDEO_TTFB}s；持续下载 $THROUGHPUT"

step 8 "通过 ping0.cc 确认国家并生成小火箭节点"
PUBLIC_IP="$(curl -4 -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
[ -n "$PUBLIC_IP" ] || PUBLIC_IP="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}')"
[ -n "$PUBLIC_IP" ] || die "无法取得VPS公网IPv4。"

PING0_RAW=""
for attempt in 1 2 3; do
  for geo_url in https://ipv4.ping0.cc/geo https://ping0.cc/geo; do
    PING0_RAW="$(curl -4fsSL --connect-timeout 6 --max-time 15 "$geo_url" 2>/dev/null | tr -d '\r' || true)"
    [ -n "$PING0_RAW" ] && break 2
  done
  sleep 2
done
PING0_IP="$(printf '%s\n' "$PING0_RAW" | sed -n '1p' | awk '{print $1}')"
GEO_LOC="$(printf '%s\n' "$PING0_RAW" | sed -n '2p')"
COUNTRY_CN="$(printf '%s' "$GEO_LOC" | awk '{print $1}')"
[ -n "$COUNTRY_CN" ] || die "ping0.cc没有返回国家位置；为防止错误命名，本次不生成假国家节点。稍后重跑会继续。"

flag_of(){
  case "$1" in
    美国) echo '🇺🇸';; 加拿大) echo '🇨🇦';; 英国) echo '🇬🇧';; 德国) echo '🇩🇪';; 法国) echo '🇫🇷';; 荷兰) echo '🇳🇱';;
    日本) echo '🇯🇵';; 韩国) echo '🇰🇷';; 新加坡) echo '🇸🇬';; 印度尼西亚|印尼) echo '🇮🇩';; 马来西亚) echo '🇲🇾';; 泰国) echo '🇹🇭';; 越南) echo '🇻🇳';; 菲律宾) echo '🇵🇭';;
    中国) echo '🇨🇳';; 中国香港|香港) echo '🇭🇰';; 中国台湾|台湾) echo '🇹🇼';; 中国澳门|澳门) echo '🇲🇴';;
    澳大利亚) echo '🇦🇺';; 新西兰) echo '🇳🇿';; 印度) echo '🇮🇳';; 巴基斯坦) echo '🇵🇰';; 沙特阿拉伯) echo '🇸🇦';; 阿联酋) echo '🇦🇪';; 土耳其) echo '🇹🇷';; 以色列) echo '🇮🇱';;
    俄罗斯) echo '🇷🇺';; 乌克兰) echo '🇺🇦';; 波兰) echo '🇵🇱';; 瑞士) echo '🇨🇭';; 瑞典) echo '🇸🇪';; 挪威) echo '🇳🇴';; 芬兰) echo '🇫🇮';; 丹麦) echo '🇩🇰';; 爱尔兰) echo '🇮🇪';; 意大利) echo '🇮🇹';; 西班牙) echo '🇪🇸';; 葡萄牙) echo '🇵🇹';;
    巴西) echo '🇧🇷';; 阿根廷) echo '🇦🇷';; 墨西哥) echo '🇲🇽';; 南非) echo '🇿🇦';; 埃及) echo '🇪🇬';; *) echo '🌐';;
  esac
}
FLAG="$(flag_of "$COUNTRY_CN")"
NODE_NAME="$FLAG $COUNTRY_CN 纯净独享IP"
ENCODED_NAME="$(jq -rn --arg v "$NODE_NAME" '$v|@uri')"
HY2_LINK="hysteria2://${HY2_PASSWORD}@${PUBLIC_IP}:${HY2_PORT}/?sni=${REALITY_DOMAIN}&insecure=1&alpn=h3"
[ "$ENABLE_OBFS" = 1 ] && HY2_LINK="${HY2_LINK}&obfs=${OBFS_TYPE}&obfs-password=${OBFS_PASSWORD}"
HY2_LINK="${HY2_LINK}#${ENCODED_NAME}"
QR_FILE="/root/Shadowrocket-v7-${COUNTRY_CN}-纯净独享IP.png"
if command -v qrencode >/dev/null 2>&1; then qrencode -o "$QR_FILE" -s 8 -m 2 "$HY2_LINK"; chmod 600 "$QR_FILE"; fi

cat > "$INFO" <<EOF
sing-box HY2单协议极速版 v$VERSION
服务器：$PUBLIC_IP
ping0.cc检测IP：${PING0_IP:-$PUBLIC_IP}
ping0.cc位置：$GEO_LOC
节点名称：$NODE_NAME
端口：UDP $HY2_PORT
档位：$PROFILE / CPU ${CPU_COUNT}核 / 内存 $((MEM_KB/1024))MB
内核调优等级：$TUNE_LEVEL/2 / QUIC缓冲 $((SOCKBUF/1024/1024))MB / UDP GRO $GRO
连续网页首字节：${TTFB_LIST}s
32MB测试首字节：${VIDEO_TTFB}s / 持续下载：$THROUGHPUT

$HY2_LINK

二维码：$QR_FILE
管理命令：sb-fast info | sb-fast status | sb-fast restart | sb-fast log | sb-fast health
云厂商安全组必须放行：UDP $HY2_PORT
EOF
chmod 600 "$INFO"
cat > /usr/local/bin/sb-fast <<'EOF'
#!/usr/bin/env bash
case "${1:-info}" in
  info) cat /root/sing-box-fast-v7-info.txt ;;
  status) systemctl status sing-box --no-pager -l ;;
  restart) systemctl restart sing-box && systemctl is-active sing-box ;;
  health) /usr/local/bin/sb-fast-health-v7; systemctl status sb-fast-health-v7.timer --no-pager -l ;;
  log) journalctl -u sing-box -n 100 --no-pager ;;
  *) echo '用法：sb-fast {info|status|restart|log|health}' ;;
esac
EOF
chmod 755 /usr/local/bin/sb-fast
printf '\n%b\n%s\n' "${G}安装、ping0.cc定位和真实传输测试全部通过：${N}" "$HY2_LINK"
printf '%b\n' "${G}小火箭节点名：$NODE_NAME${N}"
printf '%b\n' "${Y}注意：安全组必须允许 UDP $HY2_PORT；脚本无法改变客户端到VPS的物理线路质量。${N}"
