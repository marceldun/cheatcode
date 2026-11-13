#!/usr/bin/env bash
# HY2 v8 + REALITY v13 + Throne/Shadowrocket 原生远程配置 v21
# 不生成、不交付 Mihomo/Clash 配置。
set -Eeuo pipefail

VERSION=21.0.0
ROOT_DIR=/etc/hy2-reality-remote-v21
PUBLIC_DIR=$ROOT_DIR/public
LOG=/root/hy2-reality-v21-install.log
DONE=/root/hy2-reality-v21-install.done
RUNNER=/root/install_hy2_reality_throne_shadowrocket_v21.sh
TMP="$(mktemp -d /tmp/hy2-reality-v21.XXXXXX)"
R='\033[31m'; G='\033[32m'; C='\033[36m'; N='\033[0m'
step(){ printf '\n%b[%s/8] %s%b\n' "$C" "$1" "$2" "$N"; }
ok(){ printf '%b[成功] %s%b\n' "$G" "$*" "$N"; }
die(){ printf '%b[失败] %s%b\n' "$R" "$*" "$N" >&2; exit 1; }
cleanup(){ local rc=$?; rm -rf "$TMP"; exit "$rc"; }
trap cleanup EXIT

[ "$(id -u)" -eq 0 ] || die '请使用root账号执行。'
command -v systemctl >/dev/null || die '当前系统不是systemd。'

if [ "${V21_WORKER:-0}" != 1 ]; then
  install -m 700 "${BASH_SOURCE[0]}" "$RUNNER"
  : >"$LOG"; rm -f "$DONE"
  unit="hy2-reality-v21-installer-$(date +%s)"
  systemd-run --unit="$unit" --property=Type=exec /bin/bash -c \
    "V21_WORKER=1 bash '$RUNNER' >>'$LOG' 2>&1; rc=\$?; echo \$rc >'$DONE'; exit \$rc" >/dev/null
  ok 'v21后台安装已启动；命令立即结束，SSH断开也不会中止。'
  printf '结果：%s（0=成功）\n日志：%s\n' "$DONE" "$LOG"
  exit 0
fi

step 1 '检查系统并建立重启自动续装'
. /etc/os-release 2>/dev/null || true
case "${ID:-}" in ubuntu|debian) ;; *) die '仅支持Ubuntu/Debian。' ;; esac
cat >/etc/systemd/system/hy2-reality-v21-resume.service <<EOF
[Unit]
Description=Resume HY2 REALITY remote config v21
After=network-online.target hy2-reality-v14-resume.service
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/bin/bash -c 'V21_WORKER=1 bash $RUNNER >>$LOG 2>&1; rc=\$?; echo \$rc >$DONE; exit \$rc'
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable hy2-reality-v21-resume.service >/dev/null
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y --no-install-recommends ca-certificates curl jq openssl python3 iproute2 qrencode >/dev/null
ok '自动续装已启用。'

download(){ local url=$1 dst=$2 p; for p in '' 'https://ghfast.top/' 'https://gh-proxy.com/'; do curl -A v21 -fL --retry 3 --connect-timeout 10 --max-time 300 -o "$dst" "${p}${url}" 2>/dev/null && [ -s "$dst" ] && return 0; done; return 1; }

step 2 '从零安装HY2 v8与REALITY v13'
if ! systemctl is-active --quiet sing-box || ! systemctl is-active --quiet xray-reality-v13; then
  download 'https://raw.githubusercontent.com/marceldun/cheatcode/main/install_hy2_reality_smart_failover_v14.sh' "$TMP/v14.sh" || die '基础安装器下载失败。'
  bash -n "$TMP/v14.sh"
  set +e; SMART_V14_WORKER=1 bash "$TMP/v14.sh"; rc=$?; set -e
  if [ "$rc" -eq 75 ]; then
    ok '新内核已安装，重启后v21会自动续装。'
    trap - EXIT
    exit 75
  fi
  [ "$rc" -eq 0 ] || die 'HY2/REALITY基础安装失败。'
fi
systemctl is-active --quiet sing-box || die 'HY2服务未运行。'
systemctl is-active --quiet xray-reality-v13 || die 'REALITY服务未运行。'
rm -f /etc/hy2-reality-smart-v14/mihomo-hy2-first-failover.yaml
ok 'HY2与REALITY均已运行。'

step 3 '生成Throne原生完整远程配置'
. /etc/sing-box/fast-v8.env
. /etc/xray-reality-v13/state.env
HY2_ACTUAL_PORT="$(jq -r '.inbounds[0].listen_port' /etc/sing-box/config.json)"
REALITY_ACTUAL_PORT="$(jq -r '.inbounds[0].port' /etc/xray-reality-v13/config.json)"
PUBLIC_IP="$(curl -4fsS --max-time 15 https://api.ipify.org)"
[ -n "$PUBLIC_IP" ] || die '无法取得VPS公网IPv4。'
PING0_RAW=''
for _ in 1 2 3; do
  for geo_url in https://ipv4.ping0.cc/geo https://ping0.cc/geo; do
    PING0_RAW="$(curl -4fsSL --connect-timeout 6 --max-time 15 "$geo_url" 2>/dev/null | tr -d '\r' || true)"
    [ -n "$PING0_RAW" ] && break 2
  done
  sleep 1
done
PING0_IP="$(printf '%s\n' "$PING0_RAW" | sed -n '1p' | awk '{print $1}')"
GEO_LOC="$(printf '%s\n' "$PING0_RAW" | sed -n '2p')"
COUNTRY_CN="$(printf '%s' "$GEO_LOC" | awk '{print $1}')"
[ -n "$COUNTRY_CN" ] || die 'ping0.cc没有返回国家位置；已阻止生成假国家名称。'
[ "$PING0_IP" = "$PUBLIC_IP" ] || die "ping0.cc检测IP($PING0_IP)与节点IP($PUBLIC_IP)不一致；已阻止错误命名。"
flag_of(){ case "$1" in
  美国) echo '🇺🇸';; 加拿大) echo '🇨🇦';; 英国) echo '🇬🇧';; 德国) echo '🇩🇪';; 法国) echo '🇫🇷';; 荷兰) echo '🇳🇱';;
  日本) echo '🇯🇵';; 韩国) echo '🇰🇷';; 新加坡) echo '🇸🇬';; 印度尼西亚|印尼) echo '🇮🇩';; 马来西亚) echo '🇲🇾';; 泰国) echo '🇹🇭';; 越南) echo '🇻🇳';; 菲律宾) echo '🇵🇭';;
  中国) echo '🇨🇳';; 中国香港|香港) echo '🇭🇰';; 中国台湾|台湾) echo '🇹🇼';; 中国澳门|澳门) echo '🇲🇴';;
  澳大利亚) echo '🇦🇺';; 新西兰) echo '🇳🇿';; 印度) echo '🇮🇳';; 巴基斯坦) echo '🇵🇰';; 沙特阿拉伯) echo '🇸🇦';; 阿联酋) echo '🇦🇪';; 土耳其) echo '🇹🇷';; 以色列) echo '🇮🇱';;
  俄罗斯) echo '🇷🇺';; 乌克兰) echo '🇺🇦';; 波兰) echo '🇵🇱';; 瑞士) echo '🇨🇭';; 瑞典) echo '🇸🇪';; 挪威) echo '🇳🇴';; 芬兰) echo '🇫🇮';; 丹麦) echo '🇩🇰';; 爱尔兰) echo '🇮🇪';; 意大利) echo '🇮🇹';; 西班牙) echo '🇪🇸';; 葡萄牙) echo '🇵🇹';;
  巴西) echo '🇧🇷';; 阿根廷) echo '🇦🇷';; 墨西哥) echo '🇲🇽';; 南非) echo '🇿🇦';; 埃及) echo '🇪🇬';; *) echo '🌐';; esac; }
FLAG="$(flag_of "$COUNTRY_CN")"
NODE_BASE="$FLAG $COUNTRY_CN 纯净独享IP"
HY2_NODE="$NODE_BASE HY2"
REALITY_NODE="$NODE_BASE 备用"
GROUP_NAME="$FLAG $COUNTRY_CN HY2优先自动组"
install -d -m 700 "$ROOT_DIR" "$PUBLIC_DIR"
TOKEN="$(cat "$ROOT_DIR/token" 2>/dev/null || true)"
[ "${#TOKEN}" -ge 32 ] || TOKEN="$(openssl rand -hex 24)"
printf '%s' "$TOKEN" >"$ROOT_DIR/token"; chmod 600 "$ROOT_DIR/token"
install -d -m 700 "$PUBLIC_DIR/$TOKEN"

jq -n \
  --arg ip "$PUBLIC_IP" --arg hp "$HY2_PASSWORD" --arg uuid "$UUID" \
  --arg sni "$REALITY_DOMAIN" --arg pbk "$REALITY_PUBLIC" --arg sid "$SHORT_ID" \
  --arg hy2_name "$HY2_NODE" --arg reality_name "$REALITY_NODE" --arg group_name "$GROUP_NAME" \
  --argjson hport "$HY2_ACTUAL_PORT" --argjson rport "$REALITY_ACTUAL_PORT" \
  '{log:{level:"warn",timestamp:true},
    inbounds:[{type:"mixed",tag:"mixed-in",listen:"127.0.0.1",listen_port:2080}],
    outbounds:[
      {type:"hysteria2",tag:$hy2_name,server:$ip,server_port:$hport,password:$hp,
       tls:{enabled:true,server_name:$sni,insecure:true,alpn:["h3"]}},
      {type:"vless",tag:$reality_name,server:$ip,server_port:$rport,uuid:$uuid,
       flow:"xtls-rprx-vision",tls:{enabled:true,server_name:$sni,
       utls:{enabled:true,fingerprint:"chrome"},reality:{enabled:true,public_key:$pbk,short_id:$sid}}},
      {type:"urltest",tag:$group_name,outbounds:[$hy2_name,$reality_name],
       url:"https://www.gstatic.com/generate_204",interval:"10s",tolerance:1,
       idle_timeout:"30m",interrupt_exist_connections:true}],
    route:{auto_detect_interface:true,final:$group_name}}' >"$ROOT_DIR/throne-core.json"

CUSTOM_JSON="$(jq -cn --arg cfg "$(jq -c . "$ROOT_DIR/throne-core.json")" --arg name "$GROUP_NAME" \
  '{type:"custom",subtype:"fullconfig",name:$name,tag:$name,config:$cfg}')"
CUSTOM_B64="$(printf '%s' "$CUSTOM_JSON" | base64 -w0 | tr '+/' '-_' | tr -d '=')"
printf 'throne://add/%s\n' "$CUSTOM_B64" >"$PUBLIC_DIR/$TOKEN/throne.txt"
chmod 600 "$ROOT_DIR/throne-core.json" "$PUBLIC_DIR/$TOKEN/throne.txt"
ok 'Throne配置已生成，无Mihomo/Clash。'

step 4 '生成苹果小火箭原生fallback远程配置'
cat >"$PUBLIC_DIR/$TOKEN/shadowrocket.conf" <<EOF
[General]
bypass-system = true
dns-server = system, 1.1.1.1, 8.8.8.8
ipv6 = false

[Proxy]
$HY2_NODE = hysteria2, $PUBLIC_IP, $HY2_ACTUAL_PORT, auth=$HY2_PASSWORD, udp=1, peer=$REALITY_DOMAIN, alpn=h3, skip-cert-verify=true
$REALITY_NODE = vless, $PUBLIC_IP, $REALITY_ACTUAL_PORT, password=$UUID, tls=true, udp=1, peer=$REALITY_DOMAIN, flow=xtls-rprx-vision, reality-public-key=$REALITY_PUBLIC, reality-short-id=$SHORT_ID

[Proxy Group]
$GROUP_NAME = fallback, $HY2_NODE, $REALITY_NODE, url=https://www.gstatic.com/generate_204, interval=10, timeout=3, select=0

[Rule]
FINAL,$GROUP_NAME
EOF
chmod 600 "$PUBLIC_DIR/$TOKEN/shadowrocket.conf"
ok '小火箭已按HY2第一、REALITY第二生成fallback组。'

step 5 '启动随机密钥路径远程配置服务'
# 升级时先停旧配置HTTP服务；节点服务和旧版文件均保留。
for old_remote in hy2-reality-remote-v15.service hy2-reality-remote-v16.service hy2-reality-remote-v17.service hy2-reality-remote-v18.service hy2-reality-remote-v19.service hy2-reality-remote-v20.service; do
  systemctl disable --now "$old_remote" >/dev/null 2>&1 || true
done
PORT="$(cat "$ROOT_DIR/port" 2>/dev/null || true)"
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  PORT=80
  ss -H -ltn 'sport = :80' | grep -q . && PORT=18080
  while ss -H -ltn "sport = :$PORT" | grep -q .; do PORT=$((PORT+1)); [ "$PORT" -le 18120 ] || die '找不到可用配置端口。'; done
fi
printf '%s' "$PORT" >"$ROOT_DIR/port"
cat >"$ROOT_DIR/server.py" <<'PY'
#!/usr/bin/env python3
import http.server, os, sys
root=os.path.realpath(sys.argv[1]); port=int(sys.argv[2])
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        rel=self.path.split('?',1)[0].lstrip('/'); path=os.path.realpath(os.path.join(root,rel))
        if not path.startswith(root+os.sep) or not os.path.isfile(path): self.send_error(404); return
        data=open(path,'rb').read(); self.send_response(200)
        ctype='image/png' if path.lower().endswith('.png') else 'text/plain; charset=utf-8'
        self.send_header('Content-Type',ctype); self.send_header('Cache-Control','no-store')
        self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
    def log_message(self,*args): pass
http.server.ThreadingHTTPServer(('0.0.0.0',port),H).serve_forever()
PY
chmod 700 "$ROOT_DIR/server.py"
cat >/etc/systemd/system/hy2-reality-remote-v21.service <<EOF
[Unit]
Description=Throne and Shadowrocket remote configs v21
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=/usr/bin/python3 $ROOT_DIR/server.py $PUBLIC_DIR $PORT
Restart=always
RestartSec=2
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadOnlyPaths=$PUBLIC_DIR
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now hy2-reality-remote-v21.service >/dev/null
if command -v ufw >/dev/null; then ufw allow "$PORT/tcp" >/dev/null 2>&1 || true; fi
if command -v firewall-cmd >/dev/null; then firewall-cmd --permanent --add-port="$PORT/tcp" >/dev/null 2>&1 || true; firewall-cmd --reload >/dev/null 2>&1 || true; fi
ready=0
for _ in $(seq 1 30); do
  if systemctl is-active --quiet hy2-reality-remote-v21.service && ss -H -ltn "sport = :$PORT" | grep -q .; then ready=1; break; fi
  sleep 0.2
done
if [ "$ready" -ne 1 ]; then
  journalctl -u hy2-reality-remote-v21.service -n 30 --no-pager >&2 || true
  die "远程配置服务未能监听TCP $PORT。"
fi
ok "远程配置服务已真实监听：TCP $PORT。"

step 6 '生成两个客户端的一次导入地址'
THRONE_URL="http://$PUBLIC_IP:$PORT/$TOKEN/throne.txt"
SHADOW_URL="http://$PUBLIC_IP:$PORT/$TOKEN/shadowrocket.conf"
THRONE_URL_B64="$(printf '%s' "$THRONE_URL" | base64 -w0 | tr '+/' '-_' | tr -d '=')"
THRONE_DEEP="throne://addsub/$THRONE_URL_B64#V21-HY2-REALITY"
# Shadowrocket官方URL Scheme要求在/add/后直接放原始配置URL；不能百分号编码。
SHADOW_DEEP="shadowrocket://config/add/$SHADOW_URL"
SHADOW_QR_URL="http://$PUBLIC_IP:$PORT/$TOKEN/shadowrocket-import.png"
qrencode -l M -s 8 -m 3 -o "$PUBLIC_DIR/$TOKEN/shadowrocket-import.png" "$SHADOW_DEEP"
chmod 600 "$PUBLIC_DIR/$TOKEN/shadowrocket-import.png"
cat >"/root/Throne和苹果小火箭远程配置_v21.txt" <<EOF
v$VERSION
ping0.cc检测IP：$PING0_IP
ping0.cc位置：$GEO_LOC
HY2节点名称：$HY2_NODE
REALITY节点名称：$REALITY_NODE
自动组名称：$GROUP_NAME

Throne一键导入：
$THRONE_DEEP

Throne远程订阅地址：
$THRONE_URL

苹果小火箭远程配置地址：
$SHADOW_URL

苹果小火箭一键导入链接：
$SHADOW_DEEP

苹果小火箭扫码二维码图片：
$SHADOW_QR_URL

请使用iPhone系统“相机”扫描下面二维码，然后点顶部“在小火箭中打开”：
EOF
qrencode -l M -t UTF8 "$SHADOW_DEEP" >>"/root/Throne和苹果小火箭远程配置_v21.txt"
chmod 600 "/root/Throne和苹果小火箭远程配置_v21.txt"
ok '导入地址、小火箭一键链接和二维码均已保存。'

step 7 '执行唯一一次综合验证'
systemctl is-active --quiet sing-box xray-reality-v13 hy2-reality-remote-v21 || die '服务状态验证失败。'
curl -fsS --max-time 5 "http://127.0.0.1:$PORT/$TOKEN/throne.txt" | grep -q '^throne://add/' || die 'Throne配置读取失败。'
curl -fsS --max-time 5 "http://127.0.0.1:$PORT/$TOKEN/shadowrocket.conf" | grep -Fq "$GROUP_NAME = fallback" || die '小火箭配置读取失败。'
SB_CLIENT_BIN=/etc/sing-box/sing-box
if [ ! -x "$SB_CLIENT_BIN" ]; then SB_CLIENT_BIN="$(command -v sing-box || true)"; fi
[ -n "$SB_CLIENT_BIN" ] && [ -x "$SB_CLIENT_BIN" ] || die '找不到HY2正在使用的sing-box内核。'
if ! "$SB_CLIENT_BIN" check -c "$ROOT_DIR/throne-core.json" >"$TMP/throne-check.log" 2>&1; then
  cat "$TMP/throne-check.log" >&2
  die 'Throne内置完整配置校验失败。'
fi
grep -q 'reality-public-key=' "$PUBLIC_DIR/$TOKEN/shadowrocket.conf" || die '小火箭REALITY参数缺失。'
grep -Fq "$HY2_NODE = hysteria2" "$PUBLIC_DIR/$TOKEN/shadowrocket.conf" || die '小火箭HY2国家图标或名称缺失。'
grep -Fq "$REALITY_NODE = vless" "$PUBLIC_DIR/$TOKEN/shadowrocket.conf" || die '小火箭REALITY国家图标或名称缺失。'
test -s "$PUBLIC_DIR/$TOKEN/shadowrocket-import.png" || die '小火箭二维码生成失败。'
grep -q '^shadowrocket://config/add/' "/root/Throne和苹果小火箭远程配置_v21.txt" || die '小火箭一键导入链接生成失败。'
if find "$ROOT_DIR" -type f -exec grep -Eil 'mihomo|clash meta|proxy-groups:' {} + | grep -q .; then die '检测到禁止的Mihomo/Clash内容。'; fi
ok '一次综合验证通过：双服务、两个客户端配置和远程下载均正常。'

step 8 '完成并关闭续装任务'
systemctl disable hy2-reality-v21-resume.service >/dev/null 2>&1 || true
printf '\n%b安装完成。每个客户端只需首次导入一次。%b\n' "$G" "$N"
cat "/root/Throne和苹果小火箭远程配置_v21.txt"
