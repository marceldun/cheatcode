#!/usr/bin/env bash
# HY2 v8 + REALITY v13 + Throne/Shadowrocket 原生远程配置 v16
# 不生成、不交付 Mihomo/Clash 配置。
set -Eeuo pipefail

VERSION=16.0.0
ROOT_DIR=/etc/hy2-reality-remote-v16
PUBLIC_DIR=$ROOT_DIR/public
LOG=/root/hy2-reality-v16-install.log
DONE=/root/hy2-reality-v16-install.done
RUNNER=/root/install_hy2_reality_throne_shadowrocket_v16.sh
TMP="$(mktemp -d /tmp/hy2-reality-v16.XXXXXX)"
R='\033[31m'; G='\033[32m'; C='\033[36m'; N='\033[0m'
step(){ printf '\n%b[%s/8] %s%b\n' "$C" "$1" "$2" "$N"; }
ok(){ printf '%b[成功] %s%b\n' "$G" "$*" "$N"; }
die(){ printf '%b[失败] %s%b\n' "$R" "$*" "$N" >&2; exit 1; }
cleanup(){ local rc=$?; rm -rf "$TMP"; exit "$rc"; }
trap cleanup EXIT

[ "$(id -u)" -eq 0 ] || die '请使用root账号执行。'
command -v systemctl >/dev/null || die '当前系统不是systemd。'

if [ "${V16_WORKER:-0}" != 1 ]; then
  install -m 700 "${BASH_SOURCE[0]}" "$RUNNER"
  : >"$LOG"; rm -f "$DONE"
  unit="hy2-reality-v16-installer-$(date +%s)"
  systemd-run --unit="$unit" --property=Type=exec /bin/bash -c \
    "V16_WORKER=1 bash '$RUNNER' >>'$LOG' 2>&1; rc=\$?; echo \$rc >'$DONE'; exit \$rc" >/dev/null
  ok 'v16后台安装已启动；命令立即结束，SSH断开也不会中止。'
  printf '结果：%s（0=成功）\n日志：%s\n' "$DONE" "$LOG"
  exit 0
fi

step 1 '检查系统并建立重启自动续装'
. /etc/os-release 2>/dev/null || true
case "${ID:-}" in ubuntu|debian) ;; *) die '仅支持Ubuntu/Debian。' ;; esac
cat >/etc/systemd/system/hy2-reality-v16-resume.service <<EOF
[Unit]
Description=Resume HY2 REALITY remote config v16
After=network-online.target hy2-reality-v14-resume.service
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/bin/bash -c 'V16_WORKER=1 bash $RUNNER >>$LOG 2>&1; rc=\$?; echo \$rc >$DONE; exit \$rc'
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable hy2-reality-v16-resume.service >/dev/null
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y --no-install-recommends ca-certificates curl jq openssl python3 iproute2 >/dev/null
ok '自动续装已启用。'

download(){ local url=$1 dst=$2 p; for p in '' 'https://ghfast.top/' 'https://gh-proxy.com/'; do curl -A v16 -fL --retry 3 --connect-timeout 10 --max-time 300 -o "$dst" "${p}${url}" 2>/dev/null && [ -s "$dst" ] && return 0; done; return 1; }

step 2 '从零安装HY2 v8与REALITY v13'
if ! systemctl is-active --quiet sing-box || ! systemctl is-active --quiet xray-reality-v13; then
  download 'https://raw.githubusercontent.com/marceldun/cheatcode/main/install_hy2_reality_smart_failover_v14.sh' "$TMP/v14.sh" || die '基础安装器下载失败。'
  bash -n "$TMP/v14.sh"
  set +e; SMART_V14_WORKER=1 bash "$TMP/v14.sh"; rc=$?; set -e
  if [ "$rc" -eq 75 ]; then
    ok '新内核已安装，重启后v16会自动续装。'
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
install -d -m 700 "$ROOT_DIR" "$PUBLIC_DIR"
TOKEN="$(cat "$ROOT_DIR/token" 2>/dev/null || true)"
[ "${#TOKEN}" -ge 32 ] || TOKEN="$(openssl rand -hex 24)"
printf '%s' "$TOKEN" >"$ROOT_DIR/token"; chmod 600 "$ROOT_DIR/token"
install -d -m 700 "$PUBLIC_DIR/$TOKEN"

jq -n \
  --arg ip "$PUBLIC_IP" --arg hp "$HY2_PASSWORD" --arg uuid "$UUID" \
  --arg sni "$REALITY_DOMAIN" --arg pbk "$REALITY_PUBLIC" --arg sid "$SHORT_ID" \
  --argjson hport "$HY2_ACTUAL_PORT" --argjson rport "$REALITY_ACTUAL_PORT" \
  '{log:{level:"warn",timestamp:true},
    inbounds:[{type:"mixed",tag:"mixed-in",listen:"127.0.0.1",listen_port:2080}],
    outbounds:[
      {type:"hysteria2",tag:"V16-HY2-PRIMARY",server:$ip,server_port:$hport,password:$hp,
       tls:{enabled:true,server_name:$sni,insecure:true,alpn:["h3"]}},
      {type:"vless",tag:"V16-REALITY-BACKUP",server:$ip,server_port:$rport,uuid:$uuid,
       flow:"xtls-rprx-vision",tls:{enabled:true,server_name:$sni,
       utls:{enabled:true,fingerprint:"chrome"},reality:{enabled:true,public_key:$pbk,short_id:$sid}}},
      {type:"urltest",tag:"HY2优先自动组",outbounds:["V16-HY2-PRIMARY","V16-REALITY-BACKUP"],
       url:"https://www.gstatic.com/generate_204",interval:"10s",tolerance:1,
       idle_timeout:"30m",interrupt_exist_connections:true}],
    route:{auto_detect_interface:true,final:"HY2优先自动组"}}' >"$ROOT_DIR/throne-core.json"

CUSTOM_JSON="$(jq -cn --arg cfg "$(jq -c . "$ROOT_DIR/throne-core.json")" \
  '{type:"custom",subtype:"fullconfig",name:"HY2优先自动组",tag:"HY2优先自动组",config:$cfg}')"
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
V16-HY2-PRIMARY = hysteria2, $PUBLIC_IP, $HY2_ACTUAL_PORT, auth=$HY2_PASSWORD, udp=1, peer=$REALITY_DOMAIN, alpn=h3, skip-cert-verify=true
V16-REALITY-BACKUP = vless, $PUBLIC_IP, $REALITY_ACTUAL_PORT, password=$UUID, tls=true, udp=1, peer=$REALITY_DOMAIN, flow=xtls-rprx-vision, reality-public-key=$REALITY_PUBLIC, reality-short-id=$SHORT_ID

[Proxy Group]
HY2优先自动组 = fallback, V16-HY2-PRIMARY, V16-REALITY-BACKUP, url=https://www.gstatic.com/generate_204, interval=10, timeout=3, select=0

[Rule]
FINAL,HY2优先自动组
EOF
chmod 600 "$PUBLIC_DIR/$TOKEN/shadowrocket.conf"
ok '小火箭已按HY2第一、REALITY第二生成fallback组。'

step 5 '启动随机密钥路径远程配置服务'
# 升级时先停旧配置HTTP服务；节点服务和旧版文件均保留。
systemctl disable --now hy2-reality-remote-v15.service >/dev/null 2>&1 || true
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
        self.send_header('Content-Type','text/plain; charset=utf-8'); self.send_header('Cache-Control','no-store')
        self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
    def log_message(self,*args): pass
http.server.ThreadingHTTPServer(('0.0.0.0',port),H).serve_forever()
PY
chmod 700 "$ROOT_DIR/server.py"
cat >/etc/systemd/system/hy2-reality-remote-v16.service <<EOF
[Unit]
Description=Throne and Shadowrocket remote configs v16
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
systemctl enable --now hy2-reality-remote-v16.service >/dev/null
if command -v ufw >/dev/null; then ufw allow "$PORT/tcp" >/dev/null 2>&1 || true; fi
if command -v firewall-cmd >/dev/null; then firewall-cmd --permanent --add-port="$PORT/tcp" >/dev/null 2>&1 || true; firewall-cmd --reload >/dev/null 2>&1 || true; fi
ready=0
for _ in $(seq 1 30); do
  if systemctl is-active --quiet hy2-reality-remote-v16.service && ss -H -ltn "sport = :$PORT" | grep -q .; then ready=1; break; fi
  sleep 0.2
done
if [ "$ready" -ne 1 ]; then
  journalctl -u hy2-reality-remote-v16.service -n 30 --no-pager >&2 || true
  die "远程配置服务未能监听TCP $PORT。"
fi
ok "远程配置服务已真实监听：TCP $PORT。"

step 6 '生成两个客户端的一次导入地址'
THRONE_URL="http://$PUBLIC_IP:$PORT/$TOKEN/throne.txt"
SHADOW_URL="http://$PUBLIC_IP:$PORT/$TOKEN/shadowrocket.conf"
THRONE_URL_B64="$(printf '%s' "$THRONE_URL" | base64 -w0 | tr '+/' '-_' | tr -d '=')"
THRONE_DEEP="throne://addsub/$THRONE_URL_B64#V16-HY2-REALITY"
cat >"/root/Throne和苹果小火箭远程配置_v16.txt" <<EOF
v$VERSION
Throne一键导入：
$THRONE_DEEP

Throne远程订阅地址：
$THRONE_URL

苹果小火箭远程配置地址：
$SHADOW_URL
EOF
chmod 600 "/root/Throne和苹果小火箭远程配置_v16.txt"
ok '导入地址已保存。'

step 7 '执行唯一一次综合验证'
systemctl is-active --quiet sing-box xray-reality-v13 hy2-reality-remote-v16 || die '服务状态验证失败。'
curl -fsS --max-time 5 "http://127.0.0.1:$PORT/$TOKEN/throne.txt" | grep -q '^throne://add/' || die 'Throne配置读取失败。'
curl -fsS --max-time 5 "http://127.0.0.1:$PORT/$TOKEN/shadowrocket.conf" | grep -q '^HY2优先自动组 = fallback' || die '小火箭配置读取失败。'
/usr/local/bin/sing-box check -c "$ROOT_DIR/throne-core.json" >/dev/null 2>&1 || die 'Throne内置完整配置校验失败。'
grep -q 'reality-public-key=' "$PUBLIC_DIR/$TOKEN/shadowrocket.conf" || die '小火箭REALITY参数缺失。'
if find "$ROOT_DIR" -type f -exec grep -Eil 'mihomo|clash meta|proxy-groups:' {} + | grep -q .; then die '检测到禁止的Mihomo/Clash内容。'; fi
ok '一次综合验证通过：双服务、两个客户端配置和远程下载均正常。'

step 8 '完成并关闭续装任务'
systemctl disable hy2-reality-v16-resume.service >/dev/null 2>&1 || true
printf '\n%b安装完成。每个客户端只需首次导入一次。%b\n' "$G" "$N"
cat "/root/Throne和苹果小火箭远程配置_v16.txt"
