#!/usr/bin/env bash
# sing-box 低配 VPS 极速一键搭建 v3
# 目标：Hysteria2 最快主节点 + VLESS Reality 稳定备用；低内存/低 CPU 自适应。
# 支持：Debian/Ubuntu/CentOS/Rocky/Alma/Fedora/Alpine，x86_64/arm64/armv7。
set -Eeuo pipefail

VERSION="3.0.0"
WORK_DIR="/etc/sing-box"
BIN="$WORK_DIR/sing-box"
CONF="$WORK_DIR/config.json"
STATE="$WORK_DIR/fast-v3.env"
INFO="/root/sing-box-fast-v3-info.txt"
TMP="$(mktemp -d /tmp/sb-fast-v3.XXXXXX)"
HY2_PORT="${HY2_PORT:-443}"
REALITY_PORT="${REALITY_PORT:-443}"
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
MEM_KB="$(awk '/MemTotal/{print $2}' /proc/meminfo)"
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
fetch_text(){ local url=$1 p; for p in "${PREFIXES[@]}"; do curl -A 'sb-fast-v3' -fsSL --connect-timeout 8 --max-time 25 "${p}${url}" 2>/dev/null && return 0; done; return 1; }
download(){ local url=$1 dst=$2 p part="${dst}.part"; for p in "${PREFIXES[@]}"; do
  if curl -A 'sb-fast-v3' -fL --connect-timeout 10 --max-time 600 --retry 3 --retry-delay 2 -C - -o "$part" "${p}${url}" 2>/dev/null && [ -s "$part" ]; then mv -f "$part" "$dst"; return 0; fi
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

step 4 "生成并严格校验节点配置"
if [ -f "$STATE" ]; then
  # shellcheck disable=SC1090
  . "$STATE"
else
  UUID="$($BIN generate uuid)"
  KEYPAIR="$($BIN generate reality-keypair)"
  REALITY_PRIVATE="$(printf '%s\n' "$KEYPAIR" | awk '/PrivateKey/{print $NF}')"
  REALITY_PUBLIC="$(printf '%s\n' "$KEYPAIR" | awk '/PublicKey/{print $NF}')"
  [ -n "$REALITY_PRIVATE" ] && [ -n "$REALITY_PUBLIC" ] || die "REALITY 密钥生成失败。"
  SHORT_ID="$(openssl rand -hex 4)"
  HY2_PASSWORD="$(openssl rand -hex 18)"
  OBFS_PASSWORD="$(openssl rand -hex 18)"
  cat > "$STATE" <<EOF
UUID='$UUID'
REALITY_PRIVATE='$REALITY_PRIVATE'
REALITY_PUBLIC='$REALITY_PUBLIC'
SHORT_ID='$SHORT_ID'
HY2_PASSWORD='$HY2_PASSWORD'
OBFS_PASSWORD='$OBFS_PASSWORD'
EOF
  chmod 600 "$STATE"
fi

mkdir -p "$WORK_DIR/cert"
if [ ! -s "$WORK_DIR/cert/cert.pem" ] || [ ! -s "$WORK_DIR/cert/key.pem" ]; then
  openssl ecparam -genkey -name prime256v1 -out "$WORK_DIR/cert/key.pem" >/dev/null 2>&1
  openssl req -new -x509 -days 3650 -key "$WORK_DIR/cert/key.pem" -out "$WORK_DIR/cert/cert.pem" -subj "/CN=$REALITY_DOMAIN" >/dev/null 2>&1
fi
chmod 600 "$WORK_DIR/cert/key.pem"

OBFS_JSON=""
if [ "$ENABLE_OBFS" = 1 ]; then
  printf -v OBFS_JSON ',\n      "obfs": { "type": "%s", "password": "%s" }' "$OBFS_TYPE" "$OBFS_PASSWORD"
fi
cat > "$TMP/config.json" <<EOF
{
  "log": { "disabled": true },
  "inbounds": [
    {
      "type": "hysteria2", "tag": "hy2-fast", "listen": "::", "listen_port": $HY2_PORT,
      "users": [ { "password": "$HY2_PASSWORD" } ],
      "ignore_client_bandwidth": false,
      "tls": { "enabled": true, "alpn": ["h3"], "certificate_path": "$WORK_DIR/cert/cert.pem", "key_path": "$WORK_DIR/cert/key.pem" }$OBFS_JSON
    },
    {
      "type": "vless", "tag": "reality-stable", "listen": "::", "listen_port": $REALITY_PORT,
      "users": [ { "uuid": "$UUID", "flow": "xtls-rprx-vision" } ],
      "tls": {
        "enabled": true, "server_name": "$REALITY_DOMAIN",
        "reality": { "enabled": true, "handshake": { "server": "$REALITY_DOMAIN", "server_port": 443 }, "private_key": "$REALITY_PRIVATE", "short_id": ["$SHORT_ID"] }
      }
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
EOF
if ! "$BIN" check -c "$TMP/config.json" >"$TMP/config-check.log" 2>&1; then
  cat "$TMP/config-check.log" >&2
  die "配置不兼容，旧服务未被替换。"
fi
[ -f "$CONF" ] && cp -a "$CONF" "$WORK_DIR/backup/config.$(date +%Y%m%d-%H%M%S).json"
install -m 600 "$TMP/config.json" "$CONF"
ok "配置已通过 sing-box 官方内核校验"

step 5 "应用低内存自适应网络优化"
modprobe tcp_bbr >/dev/null 2>&1 || true
printf '%s\n' tcp_bbr > /etc/modules-load.d/sing-box-fast-v3.conf 2>/dev/null || true
if grep -q '# === sing-box tuner v2 ===' /etc/sysctl.conf 2>/dev/null; then
  cp -a /etc/sysctl.conf "$WORK_DIR/backup/sysctl.conf.before-v3.$(date +%Y%m%d-%H%M%S)"
  awk 'BEGIN{skip=0} /# === sing-box tuner v2 ===/{skip=1;next} /# === sing-box tuner v2 end ===/{skip=0;next} !skip{print}' /etc/sysctl.conf > "$TMP/sysctl.conf"
  cat "$TMP/sysctl.conf" > /etc/sysctl.conf
fi
QDISC=fq
AVAILABLE_CC="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || true)"
case " $AVAILABLE_CC " in *" bbr "*) CC=bbr ;; *) CC=cubic ;; esac
cat > /etc/sysctl.d/99-sing-box-fast-v3.conf <<EOF
# sing-box fast v3: values are memory-profiled, not blindly oversized
net.core.default_qdisc=$QDISC
net.ipv4.tcp_congestion_control=$CC
net.core.rmem_max=$SOCKBUF
net.core.wmem_max=$SOCKBUF
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
sysctl -p /etc/sysctl.d/99-sing-box-fast-v3.conf >/dev/null 2>&1 || true
IFACE="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')"
GRO=unsupported
if [ -n "$IFACE" ] && command -v ethtool >/dev/null 2>&1; then
  if ethtool -K "$IFACE" rx-udp-gro-forwarding on rx-gro-list off >/dev/null 2>&1; then GRO=enabled; fi
fi
ok "拥塞控制：$CC；QUIC 缓冲：$((SOCKBUF/1024/1024)) MB；UDP GRO：$GRO"

step 6 "启动服务并放行防火墙"
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box fast v3
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$WORK_DIR
ExecStart=$BIN run -c $CONF
Restart=on-failure
RestartSec=2
LimitNOFILE=262144
Nice=-5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable sing-box >/dev/null 2>&1
if command -v ufw >/dev/null 2>&1 && ufw status | grep -qi active; then
  ufw allow "$HY2_PORT/udp" >/dev/null || true
  ufw allow "$REALITY_PORT/tcp" >/dev/null || true
fi
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port="$HY2_PORT/udp" >/dev/null || true
  firewall-cmd --permanent --add-port="$REALITY_PORT/tcp" >/dev/null || true
  firewall-cmd --reload >/dev/null || true
fi
systemctl restart sing-box
sleep 2
systemctl is-active --quiet sing-box || { journalctl -u sing-box -n 60 --no-pager >&2; die "服务启动失败。"; }
ss -uln | grep -qE "[:.]${HY2_PORT}[[:space:]]" || die "HY2 UDP 端口没有监听。"
ss -tln | grep -qE "[:.]${REALITY_PORT}[[:space:]]" || die "REALITY TCP 端口没有监听。"
ok "HY2 UDP/$HY2_PORT 与 REALITY TCP/$REALITY_PORT 均已监听"

step 7 "执行真实 HY2 加密联网和吞吐测试"
OBFS_CLIENT=""
if [ "$ENABLE_OBFS" = 1 ]; then
  printf -v OBFS_CLIENT ', "obfs": { "type": "%s", "password": "%s" }' "$OBFS_TYPE" "$OBFS_PASSWORD"
fi
cat > "$TMP/client.json" <<EOF
{
  "log": { "level": "error" },
  "inbounds": [ { "type": "socks", "listen": "127.0.0.1", "listen_port": 19080 } ],
  "outbounds": [ {
    "type": "hysteria2", "server": "127.0.0.1", "server_port": $HY2_PORT, "password": "$HY2_PASSWORD",
    "tls": { "enabled": true, "server_name": "$REALITY_DOMAIN", "insecure": true, "alpn": ["h3"] }$OBFS_CLIENT
  } ]
}
EOF
"$BIN" check -c "$TMP/client.json" >/dev/null
"$BIN" run -c "$TMP/client.json" >"$TMP/client.log" 2>&1 & CLIENT_PID=$!
sleep 2
HTTP_CODE="$(curl --noproxy '' -sS -o /dev/null -w '%{http_code}' --socks5-hostname 127.0.0.1:19080 --max-time 20 https://www.gstatic.com/generate_204 2>/dev/null || true)"
[ "$HTTP_CODE" = 204 ] || [ "$HTTP_CODE" = 200 ] || { cat "$TMP/client.log" >&2; kill "$CLIENT_PID" 2>/dev/null || true; die "HY2 加密通道联网失败（HTTP=$HTTP_CODE）。"; }
THROUGHPUT="未测试（系统无 python3）"
if command -v python3 >/dev/null 2>&1; then
  dd if=/dev/zero of="$TMP/test.bin" bs=1M count=32 status=none
  (cd "$TMP" && python3 -m http.server 19081 --bind 127.0.0.1 >"$TMP/http.log" 2>&1) & HTTP_PID=$!
  sleep 1
  SPEED="$(curl --noproxy '' -sS -o /dev/null -w '%{speed_download}' --socks5-hostname 127.0.0.1:19080 --max-time 60 http://127.0.0.1:19081/test.bin 2>/dev/null || echo 0)"
  kill "$HTTP_PID" 2>/dev/null || true
  THROUGHPUT="$(awk -v b="$SPEED" 'BEGIN{printf "%.1f Mbps", b*8/1000000}')"
fi
kill "$CLIENT_PID" 2>/dev/null || true
wait "$CLIENT_PID" 2>/dev/null || true
ok "HY2 真实联网通过（HTTP $HTTP_CODE）；本机完整加密吞吐：$THROUGHPUT"

step 8 "生成 NekoRay 可直接导入的节点"
PUBLIC_IP="$(curl -4 -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
[ -n "$PUBLIC_IP" ] || PUBLIC_IP="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}')"
[ -n "$PUBLIC_IP" ] || PUBLIC_IP=YOUR_SERVER_IP
HY2_LINK="hysteria2://${HY2_PASSWORD}@${PUBLIC_IP}:${HY2_PORT}/?sni=${REALITY_DOMAIN}&insecure=1&alpn=h3"
[ "$ENABLE_OBFS" = 1 ] && HY2_LINK="${HY2_LINK}&obfs=${OBFS_TYPE}&obfs-password=${OBFS_PASSWORD}"
HY2_LINK="${HY2_LINK}#HY2-Fast-v3"
VLESS_LINK="vless://${UUID}@${PUBLIC_IP}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_DOMAIN}&fp=chrome&pbk=${REALITY_PUBLIC}&sid=${SHORT_ID}&type=tcp&headerType=none#Reality-Stable-v3"
cat > "$INFO" <<EOF
sing-box 低配 VPS 极速一键搭建 v$VERSION
服务器：$PUBLIC_IP
档位：$PROFILE / CPU ${CPU_COUNT}核 / 内存 $((MEM_KB/1024))MB
拥塞控制：$CC / UDP GRO：$GRO / 本机 HY2 加密吞吐：$THROUGHPUT

[首选：Hysteria2]
$HY2_LINK

[UDP 受限时备用：VLESS Reality]
$VLESS_LINK

管理命令：sb-fast info | sb-fast status | sb-fast restart | sb-fast log
云厂商安全组必须放行：UDP $HY2_PORT、TCP $REALITY_PORT
EOF
chmod 600 "$INFO"
cat > /usr/local/bin/sb-fast <<'EOF'
#!/usr/bin/env bash
case "${1:-info}" in
  info) cat /root/sing-box-fast-v3-info.txt ;;
  status) systemctl status sing-box --no-pager -l ;;
  restart) systemctl restart sing-box && systemctl is-active sing-box ;;
  log) journalctl -u sing-box -n 100 --no-pager ;;
  *) echo '用法：sb-fast {info|status|restart|log}' ;;
esac
EOF
chmod 755 /usr/local/bin/sb-fast
printf '\n%b\n%s\n\n%b\n%s\n' "${G}安装与测试全部通过。NekoRay 首选导入下面这一行：${N}" "$HY2_LINK" "${C}如果 UDP 线路不稳定，导入备用节点：${N}" "$VLESS_LINK"
printf '%b\n' "${Y}注意：云厂商控制台安全组仍需允许 UDP $HY2_PORT 和 TCP $REALITY_PORT；脚本无法越过云厂商外部防火墙。${N}"
