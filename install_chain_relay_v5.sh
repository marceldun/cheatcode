#!/usr/bin/env bash
# 低配 VPS 极速代理 v5：任意高速 VPS 入口中转 + Domainesia 最终出口
# 默认在 Domainesia 执行一次；自动经 SSH 部署入口 VPS，并进行完整两跳联网测试。
set -Eeuo pipefail

CONFIG_ENV="${CONFIG_ENV:-}"
if [ -n "$CONFIG_ENV" ] && [ -f "$CONFIG_ENV" ]; then
  # 仅允许 root 持有的部署参数文件。
  [ "$(stat -c %u "$CONFIG_ENV" 2>/dev/null || echo 1)" = 0 ] || { echo "参数文件必须属于 root" >&2; exit 1; }
  # shellcheck disable=SC1090
  . "$CONFIG_ENV"
fi

ROLE="${ROLE:-controller}" # controller | exit-only | relay
VERSION="5.0.0"
RAW_URL="https://raw.githubusercontent.com/marceldun/cheatcode/main/install_chain_relay_v5.sh"
ESC="$(printf '\033')"; G="${ESC}[32m"; Y="${ESC}[33m"; R="${ESC}[31m"; C="${ESC}[36m"; N="${ESC}[0m"
ok(){ printf '%b\n' "${G}[成功]${N} $*"; }
warn(){ printf '%b\n' "${Y}[提示]${N} $*"; }
step(){ printf '\n%b\n' "${C}[$1/8] $2${N}"; }
die(){ printf '%b\n' "${R}[失败]${N} $*" >&2; exit 1; }
cleanup(){ rm -rf "${TMP:-}" 2>/dev/null || true; unset SSHPASS RELAY_PASSWORD 2>/dev/null || true; }
trap cleanup EXIT
[ "$(id -u)" -eq 0 ] || die "必须使用 root 运行。"

TMP="$(mktemp -d /tmp/chain-v5.XXXXXX)"
SELF_COPY="$TMP/install_chain_relay_v5.sh"
if [ -r "${BASH_SOURCE[0]}" ]; then cat "${BASH_SOURCE[0]}" > "$SELF_COPY"; else curl -fsSL "$RAW_URL" -o "$SELF_COPY"; fi
chmod 700 "$SELF_COPY"

if [ "$ROLE" = relay ]; then
  WORK_DIR="${WORK_DIR:-/etc/sing-box-chain-v5}"
  SERVICE_NAME="${SERVICE_NAME:-sing-box-chain-v5}"
  STATE="$WORK_DIR/relay-v5.env"
  INFO="/root/sing-box-chain-v5-info.txt"
  REQUEST_HY2_PORT="${RELAY_HY2_PORT:-24443}"
  REQUEST_REALITY_PORT="${RELAY_REALITY_PORT:-24444}"
else
  WORK_DIR="${WORK_DIR:-/etc/sing-box}"
  SERVICE_NAME="${SERVICE_NAME:-sing-box}"
  STATE="$WORK_DIR/chain-exit-v5.env"
  INFO="/root/sing-box-chain-exit-v5-info.txt"
  REQUEST_HY2_PORT="${EXIT_HY2_PORT:-443}"
  REQUEST_REALITY_PORT="${EXIT_REALITY_PORT:-443}"
fi
BIN="$WORK_DIR/sing-box"
CONF="$WORK_DIR/config.json"
CERT_DIR="$WORK_DIR/cert"
REALITY_DOMAIN="${REALITY_DOMAIN:-addons.mozilla.org}"

install_deps(){
  . /etc/os-release 2>/dev/null || true
  case "${ID:-}" in
    debian|ubuntu)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y >/dev/null 2>&1 || true
      apt-get install -y curl jq tar openssl iproute2 ca-certificates openssh-client >/dev/null
      apt-get install -y ethtool python3 sshpass >/dev/null 2>&1 || true ;;
    alpine)
      apk add --no-cache curl jq tar openssl iproute2 ca-certificates openssh-client ethtool python3 sshpass >/dev/null ;;
    *)
      local pm=yum; command -v dnf >/dev/null && pm=dnf
      "$pm" -y install curl jq tar openssl iproute ca-certificates openssh-clients ethtool python3 sshpass >/dev/null ;;
  esac
  for c in curl jq tar openssl ip ss ssh; do command -v "$c" >/dev/null || die "缺少必要组件：$c"; done
}

install_core(){
  mkdir -p "$WORK_DIR" "$WORK_DIR/backup" "$CERT_DIR"
  chmod 700 "$WORK_DIR"
  if [ -x "$BIN" ] && "$BIN" version >/dev/null 2>&1; then return; fi
  local old
  for old in /etc/sing-box/sing-box /usr/local/bin/sing-box /usr/bin/sing-box; do
    if [ -x "$old" ] && "$old" version >/dev/null 2>&1; then install -m 755 "$old" "$BIN"; return; fi
  done
  local arch ver url file p
  case "$(uname -m)" in x86_64|amd64) arch=amd64;; aarch64|arm64) arch=arm64;; armv7l) arch=armv7;; *) die "不支持的架构";; esac
  ver="$(curl -A chain-v5 -fsSL --connect-timeout 10 --max-time 30 https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null | jq -r '.tag_name // empty' | sed 's/^v//' || true)"
  if [ -z "$ver" ]; then
    ver="$(curl -A chain-v5 -fsSL --connect-timeout 10 --max-time 30 https://ghfast.top/https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null | jq -r '.tag_name // empty' | sed 's/^v//' || true)"
  fi
  [ -n "$ver" ] || die "无法获取 sing-box 官方版本。"
  url="https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box-${ver}-linux-${arch}.tar.gz"
  file="$TMP/sing-box.tar.gz"
  for p in "" https://ghfast.top/ https://gh-proxy.com/ https://ghproxy.net/; do
    if curl -A chain-v5 -fL --connect-timeout 10 --max-time 600 --retry 3 -o "$file.part" "${p}${url}" 2>/dev/null; then mv "$file.part" "$file"; break; fi
  done
  [ -s "$file" ] || die "sing-box 官方内核下载失败。"
  tar -xzf "$file" -C "$TMP"
  old="$(find "$TMP" -type f -name sing-box | head -1)"
  [ -n "$old" ] || die "官方压缩包中没有 sing-box。"
  install -m 755 "$old" "$BIN"
  "$BIN" version >/dev/null || die "sing-box 内核无法运行。"
}

listener_lines(){
  local proto="$1" port="$2"
  if [ "$proto" = tcp ]; then ss -H -ltnp 2>/dev/null | grep -E "[:.]${port}[[:space:]]" || true
  else ss -H -lunp 2>/dev/null | grep -E "[:.]${port}[[:space:]]" || true; fi
}
port_can_use(){
  local proto="$1" port="$2" lines
  lines="$(listener_lines "$proto" "$port")"
  [ -z "$lines" ] && return 0
  # 只允许复用本次将替换的同名服务；入口中转使用独立高位端口，不影响已有代理。
  if [ "$ROLE" != relay ]; then ! printf '%s\n' "$lines" | grep -qv '"sing-box"'; else return 1; fi
}
pick_port(){
  local proto="$1" preferred="$2" p
  for p in "$preferred" 24443 24444 30443 30444 10443 10444 8443 2053 2083 2087 2096; do
    port_can_use "$proto" "$p" && { printf '%s' "$p"; return; }
  done
  for p in $(seq 32000 137 60000); do port_can_use "$proto" "$p" && { printf '%s' "$p"; return; }; done
  return 1
}

make_cert(){
  mkdir -p "$CERT_DIR"
  if [ ! -s "$CERT_DIR/cert.pem" ] || [ ! -s "$CERT_DIR/key.pem" ]; then
    openssl ecparam -genkey -name prime256v1 -out "$CERT_DIR/key.pem" >/dev/null 2>&1
    openssl req -new -x509 -days 3650 -key "$CERT_DIR/key.pem" -out "$CERT_DIR/cert.pem" -subj "/CN=$REALITY_DOMAIN" >/dev/null 2>&1
  fi
  chmod 600 "$CERT_DIR/key.pem"
}

write_service(){
  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=sing-box two-hop chain v5 ($ROLE)
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
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
  systemctl restart "$SERVICE_NAME"
  sleep 2
  systemctl is-active --quiet "$SERVICE_NAME" || { journalctl -u "$SERVICE_NAME" -n 60 --no-pager >&2; die "$SERVICE_NAME 启动失败。"; }
}

open_firewall(){
  local port="$1" proto="$2"
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -qi active; then ufw allow "$port/$proto" >/dev/null || true; fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$port/$proto" >/dev/null || true
    firewall-cmd --reload >/dev/null || true
  fi
}

tune_network(){
  local mem_kb sockbuf backlog cc iface
  mem_kb="${MEM_KB_OVERRIDE:-$(awk '/MemTotal/{print $2}' /proc/meminfo)}"
  if [ "$mem_kb" -le 524288 ]; then sockbuf=8388608; backlog=2048
  elif [ "$mem_kb" -le 1048576 ]; then sockbuf=16777216; backlog=4096
  elif [ "$mem_kb" -le 2097152 ]; then sockbuf=33554432; backlog=8192
  else sockbuf=67108864; backlog=16384; fi
  modprobe tcp_bbr >/dev/null 2>&1 || true
  if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then cc=bbr; else cc=cubic; fi
  cat > /etc/sysctl.d/99-sing-box-chain-v5.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=$cc
net.core.rmem_max=$sockbuf
net.core.wmem_max=$sockbuf
net.ipv4.tcp_rmem=4096 87380 $sockbuf
net.ipv4.tcp_wmem=4096 65536 $sockbuf
net.ipv4.udp_rmem_min=16384
net.ipv4.udp_wmem_min=16384
net.core.netdev_max_backlog=$backlog
net.core.somaxconn=4096
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_slow_start_after_idle=0
EOF
  sysctl -p /etc/sysctl.d/99-sing-box-chain-v5.conf >/dev/null 2>&1 || true
  iface="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')"
  if [ -n "$iface" ] && command -v ethtool >/dev/null 2>&1; then ethtool -K "$iface" rx-udp-gro-forwarding on rx-gro-list off >/dev/null 2>&1 || true; fi
  ok "网络优化：$cc/fq，QUIC缓冲 $((sockbuf/1024/1024))MB"
}

public_ip(){ curl -4 -fsS --max-time 12 https://api.ipify.org 2>/dev/null || ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}'; }

test_hy2(){
  local server="$1" port="$2" password="$3" label="$4" socks="$5"
  cat > "$TMP/test-client-${socks}.json" <<EOF
{"log":{"level":"error"},"inbounds":[{"type":"socks","listen":"127.0.0.1","listen_port":$socks}],"outbounds":[{"type":"hysteria2","server":"$server","server_port":$port,"password":"$password","tls":{"enabled":true,"server_name":"$REALITY_DOMAIN","insecure":true,"alpn":["h3"]}}]}
EOF
  "$BIN" check -c "$TMP/test-client-${socks}.json" >/dev/null
  "$BIN" run -c "$TMP/test-client-${socks}.json" >"$TMP/test-client-${socks}.log" 2>&1 & local pid=$!
  sleep 2
  local result code time_start speed
  result="$(curl --noproxy '' -sS -o /dev/null -w '%{http_code} %{time_starttransfer}' --socks5-hostname "127.0.0.1:$socks" --max-time 30 https://www.gstatic.com/generate_204 2>/dev/null || true)"
  code="${result%% *}"; time_start="${result#* }"
  if [ "$code" != 204 ] && [ "$code" != 200 ]; then cat "$TMP/test-client-${socks}.log" >&2; kill "$pid" 2>/dev/null || true; die "$label 联网失败（HTTP=$code）。"; fi
  speed="$(curl --noproxy '' -sS -o /dev/null -w '%{speed_download}' --socks5-hostname "127.0.0.1:$socks" --max-time 60 'https://speed.cloudflare.com/__down?bytes=8388608' 2>/dev/null || echo 0)"
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  TEST_TTFB="$time_start"
  TEST_MBPS="$(awk -v b="$speed" 'BEGIN{printf "%.1f", b*8/1000000}')"
  ok "$label 真实联网通过：HTTP $code，首字节 ${TEST_TTFB}s，下载 ${TEST_MBPS} Mbps"
}

prepare_exit_state(){
  if [ -f "$STATE" ]; then
    # shellcheck disable=SC1090
    . "$STATE"
    return
  fi
  if [ -f /etc/sing-box/fast-v4.env ]; then
    # shellcheck disable=SC1091
    . /etc/sing-box/fast-v4.env
  else
    UUID="$($BIN generate uuid)"
    local kp
    kp="$($BIN generate reality-keypair)"
    REALITY_PRIVATE="$(awk '/PrivateKey/{print $NF}' <<<"$kp")"
    REALITY_PUBLIC="$(awk '/PublicKey/{print $NF}' <<<"$kp")"
    SHORT_ID="$(openssl rand -hex 4)"
    HY2_PASSWORD="$(openssl rand -hex 18)"
  fi
  CHAIN_EXIT_PASSWORD="$(openssl rand -hex 20)"
  cat > "$STATE" <<EOF
UUID='$UUID'
REALITY_PRIVATE='$REALITY_PRIVATE'
REALITY_PUBLIC='$REALITY_PUBLIC'
SHORT_ID='$SHORT_ID'
HY2_PASSWORD='$HY2_PASSWORD'
CHAIN_EXIT_PASSWORD='$CHAIN_EXIT_PASSWORD'
EOF
  chmod 600 "$STATE"
}

install_exit(){
  step 1 "准备 Domainesia 出口"
  install_deps; install_core; make_cert; prepare_exit_state; tune_network
  EXIT_PORT="$(pick_port udp "$REQUEST_HY2_PORT")" || die "没有可用 UDP 出口端口。"
  EXIT_REALITY_PORT_FINAL="$(pick_port tcp "$REQUEST_REALITY_PORT")" || die "没有可用 TCP 端口。"
  [ "$EXIT_PORT" = "$REQUEST_HY2_PORT" ] || warn "UDP $REQUEST_HY2_PORT 被占用，出口自动改用 $EXIT_PORT。"
  [ "$EXIT_REALITY_PORT_FINAL" = "$REQUEST_REALITY_PORT" ] || warn "TCP $REQUEST_REALITY_PORT 被占用，备用节点自动改用 $EXIT_REALITY_PORT_FINAL。"
  cat > "$TMP/exit-config.json" <<EOF
{
 "log":{"disabled":true},
 "dns":{"servers":[{"type":"local","tag":"local-dns"}],"strategy":"ipv4_only"},
 "inbounds":[
  {"type":"hysteria2","tag":"hy2-exit","listen":"::","listen_port":$EXIT_PORT,"users":[{"name":"direct","password":"$HY2_PASSWORD"},{"name":"relay","password":"$CHAIN_EXIT_PASSWORD"}],"ignore_client_bandwidth":false,"tls":{"enabled":true,"alpn":["h3"],"certificate_path":"$CERT_DIR/cert.pem","key_path":"$CERT_DIR/key.pem"}},
  {"type":"vless","tag":"reality-backup","listen":"::","listen_port":$EXIT_REALITY_PORT_FINAL,"users":[{"uuid":"$UUID","flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":"$REALITY_DOMAIN","reality":{"enabled":true,"handshake":{"server":"$REALITY_DOMAIN","server_port":443},"private_key":"$REALITY_PRIVATE","short_id":["$SHORT_ID"]}}}
 ],
 "outbounds":[{"type":"direct","tag":"direct"}]
}
EOF
  "$BIN" check -c "$TMP/exit-config.json" >"$TMP/exit-check.log" 2>&1 || { cat "$TMP/exit-check.log" >&2; die "出口配置校验失败。"; }
  [ -f "$CONF" ] && cp -a "$CONF" "$WORK_DIR/backup/config.before-v5.$(date +%Y%m%d-%H%M%S).json"
  install -m 600 "$TMP/exit-config.json" "$CONF"
  open_firewall "$EXIT_PORT" udp; open_firewall "$EXIT_REALITY_PORT_FINAL" tcp
  write_service
  ss -uln | grep -qE "[:.]${EXIT_PORT}[[:space:]]" || die "出口 UDP/$EXIT_PORT 未监听。"
  test_hy2 127.0.0.1 "$EXIT_PORT" "$CHAIN_EXIT_PASSWORD" "Domainesia 出口" 19180
  EXIT_IP="${EXIT_IP:-$(public_ip)}"
  [ -n "$EXIT_IP" ] || die "无法取得 Domainesia 公网 IP。"
  cat > "$INFO" <<EOF
Domainesia 两跳出口 v$VERSION
出口IP=$EXIT_IP
出口UDP端口=$EXIT_PORT
IPv4优先DNS=已启用
本机测试首字节=${TEST_TTFB}s
本机测试下载=${TEST_MBPS}Mbps
EOF
  chmod 600 "$INFO"
  ok "Domainesia 出口完成：$EXIT_IP UDP/$EXIT_PORT"
}

prepare_relay_state(){
  if [ -f "$STATE" ]; then
    # shellcheck disable=SC1090
    . "$STATE"
    return
  fi
  RELAY_UUID="$($BIN generate uuid)"
  local kp
  kp="$($BIN generate reality-keypair)"
  RELAY_REALITY_PRIVATE="$(awk '/PrivateKey/{print $NF}' <<<"$kp")"
  RELAY_REALITY_PUBLIC="$(awk '/PublicKey/{print $NF}' <<<"$kp")"
  RELAY_SHORT_ID="$(openssl rand -hex 4)"
  RELAY_CLIENT_PASSWORD="$(openssl rand -hex 20)"
  cat > "$STATE" <<EOF
RELAY_UUID='$RELAY_UUID'
RELAY_REALITY_PRIVATE='$RELAY_REALITY_PRIVATE'
RELAY_REALITY_PUBLIC='$RELAY_REALITY_PUBLIC'
RELAY_SHORT_ID='$RELAY_SHORT_ID'
RELAY_CLIENT_PASSWORD='$RELAY_CLIENT_PASSWORD'
EOF
  chmod 600 "$STATE"
}

install_relay(){
  [ -n "${EXIT_IP:-}" ] && [ -n "${EXIT_PORT:-}" ] && [ -n "${CHAIN_EXIT_PASSWORD:-}" ] || die "缺少 Domainesia 出口参数。"
  step 1 "准备高速 VPS 独立入口中转"
  install_deps; install_core; make_cert; prepare_relay_state; tune_network
  RELAY_HY2_PORT_FINAL="$(pick_port udp "$REQUEST_HY2_PORT")" || die "没有可用入口 UDP 端口。"
  RELAY_REALITY_PORT_FINAL="$(pick_port tcp "$REQUEST_REALITY_PORT")" || die "没有可用入口 TCP 端口。"
  cat > "$TMP/relay-config.json" <<EOF
{
 "log":{"disabled":true},
 "inbounds":[
  {"type":"hysteria2","tag":"hy2-entry","listen":"::","listen_port":$RELAY_HY2_PORT_FINAL,"users":[{"password":"$RELAY_CLIENT_PASSWORD"}],"ignore_client_bandwidth":false,"tls":{"enabled":true,"alpn":["h3"],"certificate_path":"$CERT_DIR/cert.pem","key_path":"$CERT_DIR/key.pem"}},
  {"type":"vless","tag":"reality-entry","listen":"::","listen_port":$RELAY_REALITY_PORT_FINAL,"users":[{"uuid":"$RELAY_UUID","flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":"$REALITY_DOMAIN","reality":{"enabled":true,"handshake":{"server":"$REALITY_DOMAIN","server_port":443},"private_key":"$RELAY_REALITY_PRIVATE","short_id":["$RELAY_SHORT_ID"]}}}
 ],
 "outbounds":[{"type":"hysteria2","tag":"chain-to-domainesia","server":"$EXIT_IP","server_port":$EXIT_PORT,"password":"$CHAIN_EXIT_PASSWORD","tls":{"enabled":true,"server_name":"$REALITY_DOMAIN","insecure":true,"alpn":["h3"]}}],
 "route":{"final":"chain-to-domainesia"}
}
EOF
  "$BIN" check -c "$TMP/relay-config.json" >"$TMP/relay-check.log" 2>&1 || { cat "$TMP/relay-check.log" >&2; die "入口中转配置校验失败。"; }
  [ -f "$CONF" ] && cp -a "$CONF" "$WORK_DIR/backup/config.before-v5.$(date +%Y%m%d-%H%M%S).json"
  install -m 600 "$TMP/relay-config.json" "$CONF"
  open_firewall "$RELAY_HY2_PORT_FINAL" udp; open_firewall "$RELAY_REALITY_PORT_FINAL" tcp
  write_service
  test_hy2 127.0.0.1 "$RELAY_HY2_PORT_FINAL" "$RELAY_CLIENT_PASSWORD" "高速VPS→Domainesia 两跳链路" 19280
  RELAY_PUBLIC_IP="${RELAY_PUBLIC_IP:-$(public_ip)}"
  [ -n "$RELAY_PUBLIC_IP" ] || die "无法取得入口 VPS 公网 IP。"
  HY2_LINK="hysteria2://${RELAY_CLIENT_PASSWORD}@${RELAY_PUBLIC_IP}:${RELAY_HY2_PORT_FINAL}/?sni=${REALITY_DOMAIN}&insecure=1&alpn=h3#Chain-v5-Domainesia-Exit"
  REALITY_LINK="vless://${RELAY_UUID}@${RELAY_PUBLIC_IP}:${RELAY_REALITY_PORT_FINAL}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_DOMAIN}&fp=chrome&pbk=${RELAY_REALITY_PUBLIC}&sid=${RELAY_SHORT_ID}&type=tcp&headerType=none#Chain-v5-TCP-Backup"
  cat > "$INFO" <<EOF
高速 VPS 入口 → Domainesia 出口 v$VERSION
入口IP=$RELAY_PUBLIC_IP
最终出口IP=$EXIT_IP
完整两跳首字节=${TEST_TTFB}s
完整两跳下载=${TEST_MBPS}Mbps

[NekoRay首选]
$HY2_LINK

[TCP备用]
$REALITY_LINK
EOF
  chmod 600 "$INFO"
  printf '\n%b\n%s\n\n%b\n%s\n' "${G}两跳真实联网测试通过。NekoRay 首选导入：${N}" "$HY2_LINK" "${C}UDP受限时的TCP备用：${N}" "$REALITY_LINK"
}

deploy_relay(){
  step 6 "连接并自动部署任意高速 VPS"
  local login ssh_port auth password rc
  login="${RELAY_LOGIN:-}"
  if [ -z "$login" ]; then
    read -r -p "输入高速 VPS（格式 root@公网IP）: " login
  fi
  case "$login" in *@*) ;; *) login="root@$login" ;; esac
  ssh_port="${RELAY_SSH_PORT:-22}"
  local -a base_ssh=(ssh -p "$ssh_port" -o ConnectTimeout=12 -o ServerAliveInterval=10 -o StrictHostKeyChecking=accept-new)
  if "${base_ssh[@]}" -o BatchMode=yes "$login" 'test "$(id -u)" -eq 0' >/dev/null 2>&1; then
    auth=key
  else
    command -v sshpass >/dev/null 2>&1 || die "该高速 VPS 没有可用 SSH 密钥，并且 sshpass 安装失败。"
    password="${RELAY_PASSWORD:-}"
    if [ -z "$password" ]; then read -r -s -p "输入高速 VPS 的 root 密码（不会显示）: " password; echo; fi
    export SSHPASS="$password"
    if ! sshpass -e "${base_ssh[@]}" "$login" 'test "$(id -u)" -eq 0' >/dev/null 2>&1; then die "高速 VPS 的 SSH 登录失败。"; fi
    auth=password
  fi
  remote(){ if [ "$auth" = key ]; then "${base_ssh[@]}" "$login" "$@"; else sshpass -e "${base_ssh[@]}" "$login" "$@"; fi; }
  {
    printf 'EXIT_IP=%q\n' "$EXIT_IP"
    printf 'EXIT_PORT=%q\n' "$EXIT_PORT"
    printf 'CHAIN_EXIT_PASSWORD=%q\n' "$CHAIN_EXIT_PASSWORD"
    printf 'REALITY_DOMAIN=%q\n' "$REALITY_DOMAIN"
    printf 'WORK_DIR=%q\n' "${REMOTE_WORK_DIR:-/etc/sing-box-chain-v5}"
    printf 'SERVICE_NAME=%q\n' "${REMOTE_SERVICE_NAME:-sing-box-chain-v5}"
    printf 'RELAY_HY2_PORT=%q\n' "${RELAY_HY2_PORT:-24443}"
    printf 'RELAY_REALITY_PORT=%q\n' "${RELAY_REALITY_PORT:-24444}"
    [ -z "${RELAY_PUBLIC_IP:-}" ] || printf 'RELAY_PUBLIC_IP=%q\n' "$RELAY_PUBLIC_IP"
  } > "$TMP/relay-v5.env"
  chmod 600 "$TMP/relay-v5.env"
  remote 'umask 077; cat > /tmp/install_chain_relay_v5.sh' < "$SELF_COPY"
  remote 'umask 077; cat > /tmp/relay-v5.env' < "$TMP/relay-v5.env"
  set +e
  remote 'chmod 700 /tmp/install_chain_relay_v5.sh /tmp/relay-v5.env && ROLE=relay CONFIG_ENV=/tmp/relay-v5.env bash /tmp/install_chain_relay_v5.sh' | tee /root/chain-v5-relay-deploy-result.txt
  rc=${PIPESTATUS[0]}
  set -e
  unset SSHPASS password RELAY_PASSWORD
  [ "$rc" -eq 0 ] || die "高速 VPS 自动部署或两跳联网测试失败。"
  ok "任意高速 VPS 中转部署完成；结果已保存：/root/chain-v5-relay-deploy-result.txt"
}

case "$ROLE" in
  relay) install_relay ;;
  exit-only) install_exit ;;
  controller) install_exit; deploy_relay ;;
  *) die "未知角色：$ROLE" ;;
esac
