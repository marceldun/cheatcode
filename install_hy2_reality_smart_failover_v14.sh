#!/usr/bin/env bash
# HY2 v8 + REALITY v12/v13 智能主备一键搭建 v14
# HY2 永远优先；HY2 不可用时客户端切换 REALITY，恢复后自动回切 HY2。
# 服务端永久禁用 v5-v8 外部网站误重启探针；客户端连通检测只选路、不重启服务。
set -Eeuo pipefail

VERSION=14.0.0
ROOT_DIR=/etc/hy2-reality-smart-v14
TMP="$(mktemp -d /tmp/hy2-reality-v14.XXXXXX)"
LOG=/root/hy2-reality-v14-install.log
DONE=/root/hy2-reality-v14-install.done
RUNNER=/root/install_hy2_reality_smart_failover_v14.sh
ENV_FILE=/root/.hy2-reality-v14.env
HY2_PORT="${HY2_PORT:-443}"
REALITY_PORT="${REALITY_PORT:-443}"
R='\033[31m'; G='\033[32m'; Y='\033[33m'; C='\033[36m'; N='\033[0m'
step(){ printf '\n%b[%s/8] %s%b\n' "$C" "$1" "$2" "$N"; }
ok(){ printf '%b[成功] %s%b\n' "$G" "$*" "$N"; }
warn(){ printf '%b[提示] %s%b\n' "$Y" "$*" "$N"; }
die(){ printf '%b[失败] %s%b\n' "$R" "$*" "$N" >&2; exit 1; }
cleanup(){ local rc=$?; rm -rf "$TMP"; exit "$rc"; }
trap cleanup EXIT

[ "$(id -u)" -eq 0 ] || die '请使用root账号执行。'
command -v systemctl >/dev/null || die '当前系统不是systemd。'

# 独立后台安装，SSH即使经旧节点连接并断开也不会中止。
if [ "${SMART_V14_WORKER:-0}" != 1 ]; then
  install -m 700 "${BASH_SOURCE[0]}" "$RUNNER"
  printf 'HY2_PORT=%q\nREALITY_PORT=%q\n' "$HY2_PORT" "$REALITY_PORT" >"$ENV_FILE"
  chmod 600 "$ENV_FILE"; : >"$LOG"; rm -f "$DONE"
  unit="hy2-reality-v14-installer-$(date +%s)"
  systemd-run --unit="$unit" --property=Type=exec /bin/bash -c \
    "set -a; . '$ENV_FILE'; set +a; SMART_V14_WORKER=1 bash '$RUNNER' >>'$LOG' 2>&1; rc=\$?; echo \$rc >'$DONE'; [ \$rc -eq 75 ] || rm -f '$ENV_FILE'; exit \$rc" >/dev/null
  ok 'v14后台安装已启动；Xshell断开也会继续。'
  for _ in $(seq 1 180); do
    [ -f "$DONE" ] && break
    tail -n 1 "$LOG" 2>/dev/null || true
    sleep 1
  done
  if [ ! -f "$DONE" ]; then warn "仍在后台安装；无需重复运行。日志：$LOG"; exit 0; fi
  rc="$(cat "$DONE")"
  [ "$rc" = 0 ] && { cat "$LOG"; exit 0; }
  [ "$rc" = 75 ] && { warn '正在自动换内核并重启；开机后会自动续装，无需输入任何命令。'; exit 0; }
  die "安装失败，详情：$LOG"
fi

step 1 '检测系统、内核与自动续装条件'
. /etc/os-release 2>/dev/null || true
case "${ID:-}" in ubuntu|debian) ;; *) die 'v14完整自动换核支持Ubuntu/Debian。' ;; esac
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y --no-install-recommends ca-certificates curl jq unzip tar openssl iproute2 ethtool >/dev/null
running="$(uname -r)"
if [ ! -e "/lib/modules/$running/build/Makefile" ]; then
  virt="$(systemd-detect-virt 2>/dev/null || true)"
  case "$virt" in lxc|openvz|docker|podman|container-other) die "当前是$virt容器，宿主机不允许自行更换内核。旧服务未改动。" ;; esac
  if [ -f /root/hy2-reality-v14-kernel.txt ] && grep -Fqx "old=$running" /root/hy2-reality-v14-kernel.txt; then
    die "云商重启后仍固定旧内核$running，已阻止无限重启；旧服务未改动。"
  fi
  if [ "${ID:-}" = ubuntu ]; then packages=(linux-generic linux-headers-generic)
  elif [ "$(uname -m)" = x86_64 ]; then packages=(linux-image-amd64 linux-headers-amd64)
  else packages=(linux-image-arm64 linux-headers-arm64); fi
  apt-get install -y --no-install-recommends "${packages[@]}" >/dev/null || die '官方新内核安装失败；旧服务未改动。'
  if [ ! -e "/lib/modules/$running/build/Makefile" ]; then
    newer="$(find /lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | while read -r k; do [ -e "/lib/modules/$k/build/Makefile" ] && [ -e "/boot/vmlinuz-$k" ] && echo "$k"; done | sort -V | tail -1)"
    [ -n "$newer" ] && [ "$newer" != "$running" ] || die '找不到带完整headers的可启动新内核；旧服务未改动。'
    command -v update-grub >/dev/null && update-grub >/dev/null 2>&1 || true
    cat >/etc/systemd/system/hy2-reality-v14-resume.service <<EOF
[Unit]
Description=Resume HY2 and REALITY v14 after kernel upgrade
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/bin/bash -c 'set -a; . $ENV_FILE; set +a; SMART_V14_WORKER=1 bash $RUNNER >>$LOG 2>&1; rc=\$?; echo \$rc >$DONE; rm -f $ENV_FILE; systemctl disable hy2-reality-v14-resume.service >/dev/null 2>&1 || true; exit \$rc'
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable hy2-reality-v14-resume.service >/dev/null
    printf 'old=%s\nnew=%s\n' "$running" "$newer" >/root/hy2-reality-v14-kernel.txt
    sync
    ok "将自动重启进入$newer，随后自动续装。"
    systemd-run --unit=hy2-reality-v14-reboot --on-active=5s /usr/bin/systemctl reboot >/dev/null
    trap - EXIT
    exit 75
  fi
fi
rm -f /root/hy2-reality-v14-kernel.txt
ok "当前内核$(uname -r)具备匹配headers。"

download(){ local url=$1 dst=$2 p; for p in '' 'https://ghfast.top/' 'https://gh-proxy.com/'; do curl -A smart-v14 -fL --retry 3 --connect-timeout 10 --max-time 300 -o "$dst" "${p}${url}" 2>/dev/null && [ -s "$dst" ] && return 0; done; return 1; }

step 2 '下载并校验完整HY2 v8与REALITY安装器'
download 'https://raw.githubusercontent.com/marceldun/cheatcode/main/install_fast_proxy_v8.sh' "$TMP/hy2-v8.sh" || die 'HY2 v8安装器下载失败。'
download 'https://raw.githubusercontent.com/marceldun/cheatcode/main/install_fast_reality_v13.sh' "$TMP/reality-v13.sh" || die 'REALITY安装器下载失败。'
bash -n "$TMP/hy2-v8.sh"; bash -n "$TMP/reality-v13.sh"
ok '两个完整安装器语法校验通过。'

step 3 '安装HY2 v8并永久关闭误重启探针'
SB_FAST_V8_WORKER=1 HY2_PORT="$HY2_PORT" bash "$TMP/hy2-v8.sh"
systemctl is-active --quiet sing-box || die 'HY2服务未运行。'
for v in v5 v6 v7 v8; do
  for suffix in timer service; do
    unit="sb-fast-health-$v.$suffix"; file="/etc/systemd/system/$unit"
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
    if [ -f "$file" ] && [ ! -L "$file" ]; then
      install -d -m 700 /etc/sing-box/backup/disabled-health-timers
      cp -a "$file" "/etc/sing-box/backup/disabled-health-timers/${unit}.$(date +%s)"
    fi
    rm -f "$file"; ln -s /dev/null "$file"
  done
done
systemctl daemon-reload
ok 'HY2运行正常；全部旧外部网站重启探针已永久mask。'

step 4 '安装与v12配置一致的REALITY备用节点'
# v13只修复v12安装器的旧headers问题，协议与v12相同：VLESS+RAW/TCP+REALITY+Vision+Brutal。
REALITY_V13_WORKER=1 REALITY_PORT="$REALITY_PORT" bash "$TMP/reality-v13.sh"
systemctl is-active --quiet xray-reality-v13 || die 'REALITY备用服务未运行。'
ok 'HY2与REALITY已在同一VPS并行运行。'

step 5 '生成严格HY2优先的智能主备客户端配置'
. /etc/sing-box/fast-v8.env
. /etc/xray-reality-v13/state.env
actual_hy2_port="$(jq -r '.inbounds[0].listen_port' /etc/sing-box/config.json)"
actual_reality_port="$(jq -r '.inbounds[0].port' /etc/xray-reality-v13/config.json)"
public_ip="$(curl -4fsS --max-time 10 https://api.ipify.org)"
mkdir -p "$ROOT_DIR"
chmod 700 "$ROOT_DIR"
jq -n \
  --arg server "$public_ip" --arg hy2_password "$HY2_PASSWORD" \
  --arg uuid "$UUID" --arg sni "$REALITY_DOMAIN" \
  --arg public_key "$REALITY_PUBLIC" --arg short_id "$SHORT_ID" \
  --argjson hy2_port "$actual_hy2_port" --argjson reality_port "$actual_reality_port" \
  '{
    "mixed-port":2080,"allow-lan":false,"mode":"rule","log-level":"info","ipv6":false,
    "external-controller":"127.0.0.1:9090",
    "proxies":[
      {"name":"HY2-PRIMARY","type":"hysteria2","server":$server,"port":$hy2_port,
       "password":$hy2_password,"sni":"addons.mozilla.org","skip-cert-verify":true,"alpn":["h3"]},
      {"name":"REALITY-BACKUP","type":"vless","server":$server,"port":$reality_port,
       "uuid":$uuid,"network":"tcp","tls":true,"udp":true,"flow":"xtls-rprx-vision",
       "servername":$sni,"client-fingerprint":"chrome",
       "reality-opts":{"public-key":$public_key,"short-id":$short_id}}
    ],
    "proxy-groups":[
      {"name":"SMART-AUTO","type":"fallback","proxies":["HY2-PRIMARY","REALITY-BACKUP"],
       "url":"https://www.gstatic.com/generate_204","interval":3,"timeout":3000,
       "lazy":false,"max-failed-times":1}
    ],
    "rules":["MATCH,SMART-AUTO"]
  }' >"$ROOT_DIR/mihomo-hy2-first-failover.yaml"
chmod 600 "$ROOT_DIR/mihomo-hy2-first-failover.yaml"
ok 'fallback顺序固定为HY2第一、REALITY第二；每3秒复检并自动回切。'

step 6 '验证双服务、端口和无误重启探针'
ss -H -lun | grep -qE "[:.]${actual_hy2_port}[[:space:]]" || die 'HY2 UDP端口未监听。'
ss -H -ltn | grep -qE "[:.]${actual_reality_port}[[:space:]]" || die 'REALITY TCP端口未监听。'
if systemctl list-timers --all --no-legend | grep -q 'sb-fast-health-'; then die '发现旧误重启timer仍处于活动状态。'; fi
jq -e '.inbounds[0].type=="hysteria2"' /etc/sing-box/config.json >/dev/null
jq -e '.inbounds[0].streamSettings.security=="reality"' /etc/xray-reality-v13/config.json >/dev/null
ok '双协议监听及服务端零外部探针验证通过。'

step 7 '保存节点和客户端文件'
hy2_link="$(grep -m1 '^hysteria2://' /root/sing-box-fast-v8-info.txt)"
reality_link="$(grep -m1 '^vless://' /root/xray-reality-v13-info.txt)"
cat >"/root/HY2优先_REALITY自动备用_v14.txt" <<EOF
HY2+REALITY智能主备 v$VERSION
HY2主节点：UDP $actual_hy2_port
REALITY备用：TCP $actual_reality_port
自动切换：客户端fallback每3秒检测；HY2恢复后重新成为第一选择。
服务端：没有任何外部网站误重启探针。

$hy2_link
$reality_link

智能主备配置：$ROOT_DIR/mihomo-hy2-first-failover.yaml
EOF
chmod 600 "/root/HY2优先_REALITY自动备用_v14.txt"
ok '节点资料和智能主备配置已保存。'

step 8 '最终验证完成'
systemctl is-active --quiet sing-box xray-reality-v13 reality-v13-brutal || die '最终服务状态异常。'
printf '\n%bHY2 v8 + REALITY智能主备 v14安装成功。%b\n' "$G" "$N"
cat "/root/HY2优先_REALITY自动备用_v14.txt"
