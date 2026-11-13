#!/usr/bin/env bash
# v22 安卓附加包 v2：仅新增 Clash Meta Android 配置和二维码，不修改任何 v22 服务/参数。
set -Eeuo pipefail

VERSION=2.0.0
V22_ROOT=/etc/hy2-reality-remote-v22
INFO=/root/安卓ClashMeta连接v22_v2.txt
R='\033[31m'; G='\033[32m'; N='\033[0m'
ok(){ printf '%b[成功] %s%b\n' "$G" "$*" "$N"; }
die(){ printf '%b[失败] %s%b\n' "$R" "$*" "$N" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die '请使用root账号执行。'

printf '[1/4] 检查v22，不重装、不重启任何节点服务……\n'
[ -f /root/Throne和苹果小火箭远程配置_v22.txt ] || die '没有找到已完成的v22节点资料。'
systemctl is-active --quiet sing-box || die 'v22的HY2服务未运行。'
if systemctl is-active --quiet xray-reality-v13; then REALITY_DIR=/etc/xray-reality-v13
elif systemctl is-active --quiet xray-reality-v11; then REALITY_DIR=/etc/xray-reality-v11
else die 'v22的REALITY服务未运行。'; fi
HOST_ROOT=''
for remote_v in 25 24 23 22; do
  if systemctl is-active --quiet "hy2-reality-remote-v${remote_v}"; then
    HOST_ROOT="/etc/hy2-reality-remote-v${remote_v}"
    break
  fi
done
[ -n "$HOST_ROOT" ] && [ -f "$HOST_ROOT/token" ] && [ -f "$HOST_ROOT/port" ] || die '没有找到正在运行的配置下载服务。'
PUBLIC_DIR=$HOST_ROOT/public
command -v jq >/dev/null && command -v python3 >/dev/null && command -v qrencode >/dev/null || die 'v22组件不完整。'
ok "v22全部沿用；只借用$HOST_ROOT存放安卓文件，未执行安装、重启或网络调优。"

printf '[2/4] 读取v22已验证的节点和国家名称……\n'
. /etc/sing-box/fast-v8.env
. "$REALITY_DIR/state.env"
TOKEN="$(cat "$HOST_ROOT/token")"
PORT="$(cat "$HOST_ROOT/port")"
PUBLIC_IP="$(sed -n 's/^ping0.cc检测IP：//p' /root/Throne和苹果小火箭远程配置_v22.txt | head -1)"
HY2_NODE="$(sed -n 's/^HY2节点名称：//p' /root/Throne和苹果小火箭远程配置_v22.txt | head -1)"
REALITY_NODE="$(sed -n 's/^REALITY节点名称：//p' /root/Throne和苹果小火箭远程配置_v22.txt | head -1)"
GROUP_NAME="$(sed -n 's/^自动组名称：//p' /root/Throne和苹果小火箭远程配置_v22.txt | head -1)"
[ -n "$PUBLIC_IP" ] && [ -n "$HY2_NODE" ] && [ -n "$REALITY_NODE" ] && [ -n "$GROUP_NAME" ] || die '无法读取v22节点资料。'
HY2_PORT="$(jq -r '.inbounds[0].listen_port' /etc/sing-box/config.json)"
REALITY_PORT="$(jq -r '.inbounds[0].port' "$REALITY_DIR/config.json")"
RAW_HY2_LINK="$(grep -m1 '^hysteria2://' /root/sing-box-fast-v8-info.txt 2>/dev/null || true)"
[ -n "$RAW_HY2_LINK" ] || die '找不到v22已验证的HY2链接。'
mapfile -t HY2_QUERY < <(python3 - "$RAW_HY2_LINK" <<'PY'
import sys, urllib.parse
u=urllib.parse.urlsplit(sys.argv[1]); q=urllib.parse.parse_qs(u.query)
print(q.get('sni',['addons.mozilla.org'])[0])
print(q.get('obfs',[''])[0])
print(q.get('obfs-password',[''])[0])
PY
)
HY2_SNI="${HY2_QUERY[0]:-addons.mozilla.org}"
HY2_OBFS="${HY2_QUERY[1]:-}"
HY2_OBFS_PASSWORD="${HY2_QUERY[2]:-}"
q(){ jq -Rn --arg v "$1" '$v'; }
QN_HY2="$(q "$HY2_NODE")"; QN_REALITY="$(q "$REALITY_NODE")"; QN_GROUP="$(q "$GROUP_NAME")"

printf '[3/4] 生成Clash Meta Android原生配置和扫码链接……\n'
ANDROID_FILE="$PUBLIC_DIR/$TOKEN/android-clash-meta-v22.yaml"
{
cat <<EOF
mixed-port: 7890
allow-lan: false
mode: rule
log-level: warning
ipv6: false
unified-delay: true
tcp-concurrent: true
tun:
  enable: true
  stack: mixed
  auto-route: true
  auto-detect-interface: true
  dns-hijack:
    - any:53
dns:
  enable: true
  ipv6: false
  enhanced-mode: fake-ip
  nameserver:
    - https://1.1.1.1/dns-query
    - https://8.8.8.8/dns-query
proxies:
  - name: $QN_HY2
    type: hysteria2
    server: $PUBLIC_IP
    port: $HY2_PORT
    password: $(q "$HY2_PASSWORD")
    sni: $(q "$HY2_SNI")
    skip-cert-verify: true
    alpn:
      - h3
EOF
if [ -n "$HY2_OBFS" ]; then
cat <<EOF
    obfs: $(q "$HY2_OBFS")
    obfs-password: $(q "$HY2_OBFS_PASSWORD")
EOF
fi
cat <<EOF
  - name: $QN_REALITY
    type: vless
    server: $PUBLIC_IP
    port: $REALITY_PORT
    uuid: $(q "$UUID")
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: $(q "$REALITY_DOMAIN")
    client-fingerprint: chrome
    reality-opts:
      public-key: $(q "$REALITY_PUBLIC")
      short-id: $(q "$SHORT_ID")
proxy-groups:
  - name: $QN_GROUP
    type: fallback
    proxies:
      - $QN_HY2
      - $QN_REALITY
    url: https://www.gstatic.com/generate_204
    interval: 10
    timeout: 3000
    lazy: false
    max-failed-times: 1
rules:
  - $(q "MATCH,$GROUP_NAME")
EOF
} >"$ANDROID_FILE"
chmod 600 "$ANDROID_FILE"

ANDROID_URL="http://$PUBLIC_IP:$PORT/$TOKEN/android-clash-meta-v22.yaml"
ENC_URL="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1],safe=""))' "$ANDROID_URL")"
ENC_NAME="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1],safe=""))' "$GROUP_NAME")"
ANDROID_DEEP="clashmeta://install-config?url=$ENC_URL&name=$ENC_NAME"
ANDROID_QR_URL="http://$PUBLIC_IP:$PORT/$TOKEN/android-clash-meta-v22.png"
qrencode -l M -s 8 -m 3 -o "$PUBLIC_DIR/$TOKEN/android-clash-meta-v22.png" "$ANDROID_DEEP"
chmod 600 "$PUBLIC_DIR/$TOKEN/android-clash-meta-v22.png"

cat >"$INFO" <<EOF
v22安卓Clash Meta附加包 v$VERSION
未修改、未重启v22的HY2、REALITY及速度参数。

安卓远程配置：
$ANDROID_URL

安卓一键导入：
$ANDROID_DEEP

安卓二维码图片：
$ANDROID_QR_URL

使用安卓系统相机扫描下面二维码，选择Clash Meta打开并保存：
EOF
qrencode -l M -t UTF8 "$ANDROID_DEEP" >>"$INFO"
chmod 600 "$INFO"
ok '安卓配置和一键导入二维码已生成。'

printf '[4/4] 执行唯一一次读取与结构验证……\n'
curl -fsS --max-time 5 "http://127.0.0.1:$PORT/$TOKEN/android-clash-meta-v22.yaml" | grep -Fq "name: $QN_GROUP" || die '安卓远程配置读取失败。'
grep -Fq 'type: hysteria2' "$ANDROID_FILE" && grep -Fq 'type: vless' "$ANDROID_FILE" && grep -Fq 'type: fallback' "$ANDROID_FILE" || die '安卓主备结构不完整。'
test -s "$PUBLIC_DIR/$TOKEN/android-clash-meta-v22.png" || die '安卓二维码生成失败。'
ok '唯一一次验证通过。'
cat "$INFO"
