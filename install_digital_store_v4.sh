#!/usr/bin/env bash
# Marcel 合法数字商品商城 v4：Ubuntu/Debian 一键部署、DuckDNS、HTTPS、自动发货
set -Eeuo pipefail
ESC=$(printf '\033'); G="${ESC}[32m"; Y="${ESC}[33m"; R="${ESC}[31m"; C="${ESC}[36m"; N="${ESC}[0m"
ok(){ printf '%b\n' "${G}[成功]${N} $*"; }; warn(){ printf '%b\n' "${Y}[提示]${N} $*"; }; die(){ printf '%b\n' "${R}[失败]${N} $*" >&2; exit 1; }; step(){ printf '\n%b\n' "${C}[$1/8] $2${N}"; }
[ "$(id -u)" -eq 0 ] || die "必须使用root运行。"
APP=/opt/marcel-digital-store-v4; DATA=/var/lib/marcel-store; ENV=/etc/marcel-store.env
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RAW_BASE=https://raw.githubusercontent.com/marceldun/cheatcode/main
DOMAIN="${STORE_DOMAIN:-}"; CONTACT="${STORE_CONTACT:-}"; ADMIN_PASSWORD="${STORE_ADMIN_PASSWORD_INPUT:-}"; TEST_MODE="${INSTALL_TEST_MODE:-0}"; GENERATED_PASSWORD="${STORE_GENERATED_PASSWORD:-0}"

step 1 "收集最少配置并检查系统"
if [ -z "$DOMAIN" ]; then read -r -p "域名（直接回车使用 fbshangcheng.duckdns.org）: " DOMAIN; DOMAIN="${DOMAIN:-fbshangcheng.duckdns.org}"; fi
DOMAIN="${DOMAIN#http://}"; DOMAIN="${DOMAIN#https://}"; DOMAIN="${DOMAIN%%/*}"
[[ "$DOMAIN" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] || die "域名格式错误。"
if [ -z "$CONTACT" ]; then read -r -p "客服联系方式（微信号或邮箱）: " CONTACT; fi
if [ -z "$ADMIN_PASSWORD" ]; then read -r -s -p "管理员marcel的新密码（至少12位；直接回车自动生成）: " ADMIN_PASSWORD; echo; fi
if [ -z "$ADMIN_PASSWORD" ]; then ADMIN_PASSWORD="$(openssl rand -base64 18 | tr -d '/+=' | head -c 18)"; GENERATED_PASSWORD=1; fi
[ "${#ADMIN_PASSWORD}" -ge 12 ] || die "管理员密码至少12位，不能使用已公开的456qwe456。"

# 当前SSH可能正经过本机代理；后续调整TCP 443或重启sing-box时，前台SSH可能断开。
# 先把完整安装交给systemd独立执行，断线不会终止任务。
if [ "${STORE_INSTALL_WORKER:-0}" != 1 ]; then
  RUNNER=/root/install_digital_store_v4.sh
  WORKER_ENV=/root/.marcel-store-installer.env
  INSTALL_LOG=/root/marcel-store-install.log
  DONE_FILE=/root/marcel-store-install.done
  install -m 700 "${BASH_SOURCE[0]}" "$RUNNER"
  {
    printf 'STORE_DOMAIN=%q\n' "$DOMAIN"
    printf 'STORE_CONTACT=%q\n' "$CONTACT"
    printf 'STORE_ADMIN_PASSWORD_INPUT=%q\n' "$ADMIN_PASSWORD"
    printf 'INSTALL_TEST_MODE=%q\n' "$TEST_MODE"
    printf 'STORE_GENERATED_PASSWORD=%q\n' "$GENERATED_PASSWORD"
  } > "$WORKER_ENV"
  chmod 600 "$WORKER_ENV"; : > "$INSTALL_LOG"; rm -f "$DONE_FILE"
  UNIT="marcel-store-installer-$(date +%s)"
  systemd-run --unit="$UNIT" --property=Type=exec /bin/bash -c \
    "set -a; . '$WORKER_ENV'; set +a; STORE_INSTALL_WORKER=1 bash '$RUNNER' >>'$INSTALL_LOG' 2>&1; rc=\$?; rm -f '$WORKER_ENV'; echo \$rc >'$DONE_FILE'; exit \$rc" >/dev/null
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

. /etc/os-release 2>/dev/null || true
case "${ID:-}" in debian|ubuntu) ;; *) die "当前v4支持Ubuntu/Debian。";; esac
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y python3 python3-venv python3-pip nginx haproxy certbot curl jq openssl ca-certificates >/dev/null
if command -v ufw >/dev/null && ufw status | grep -qi active; then
  ufw allow 80/tcp >/dev/null
  ufw allow 443/tcp >/dev/null
fi

step 2 "下载并校验完整商城程序"
TMP=$(mktemp -d /tmp/marcel-store-v4.XXXXXX); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/app/templates" "$TMP/app/static"
files=(app.py payments.py requirements.txt templates/base.html templates/index.html templates/buy.html templates/order.html templates/lookup.html templates/admin_login.html templates/admin.html static/style.css)
for rel in "${files[@]}"; do
  mkdir -p "$TMP/app/$(dirname "$rel")"
  if [ -f "$SCRIPT_DIR/digital_store_v4/$rel" ]; then cp "$SCRIPT_DIR/digital_store_v4/$rel" "$TMP/app/$rel"
  else
    url="$RAW_BASE/digital_store_v4/$rel"; got=0
    for prefix in "" https://ghfast.top/ https://gh-proxy.com/; do
      curl -4fL --connect-timeout 10 --max-time 180 --retry 3 "${prefix}${url}" -o "$TMP/app/$rel" && got=1 && break
    done
    [ "$got" -eq 1 ] || die "下载失败：$rel"
  fi
  [ -s "$TMP/app/$rel" ] || die "程序文件为空：$rel"
done
python3 -m py_compile "$TMP/app/app.py" "$TMP/app/payments.py"

step 3 "安装独立运行环境和加密数据库"
mkdir -p "$APP" "$DATA" "$APP/backup"
if [ -d "$APP/current" ]; then cp -a "$APP/current" "$APP/backup/current.$(date +%Y%m%d-%H%M%S)"; fi
rm -rf "$APP/current.new"; cp -a "$TMP/app" "$APP/current.new"
python3 -m venv "$APP/venv"
"$APP/venv/bin/pip" install --disable-pip-version-check --no-cache-dir -r "$APP/current.new/requirements.txt" >/dev/null
rm -rf "$APP/current"; mv "$APP/current.new" "$APP/current"
SECRET=$(openssl rand -hex 32)
FERNET=$($APP/venv/bin/python - <<'PY'
from cryptography.fernet import Fernet
print(Fernet.generate_key().decode())
PY
)
if [ -f "$ENV" ]; then . "$ENV"; SECRET="${STORE_SECRET_KEY:-$SECRET}"; FERNET="${STORE_ENCRYPTION_KEY:-$FERNET}"; fi
cat > "$ENV" <<EOF
STORE_SECRET_KEY='$SECRET'
STORE_ENCRYPTION_KEY='$FERNET'
STORE_DATA_DIR='$DATA'
STORE_ADMIN_USER='marcel'
STORE_ADMIN_PASSWORD='$ADMIN_PASSWORD'
STORE_HTTPS='$([ "$TEST_MODE" = 1 ] && echo 0 || echo 1)'
EOF
chmod 600 "$ENV"
set -a; . "$ENV"; set +a
cd "$APP/current"; "$APP/venv/bin/flask" --app app init-db >/dev/null
sed -i '/^STORE_ADMIN_PASSWORD=/d' "$ENV"
chown -R www-data:www-data "$DATA"; chmod 700 "$DATA"; chmod 600 "$DATA/store.db" 2>/dev/null || true
cat > /etc/systemd/system/marcel-digital-store.service <<EOF
[Unit]
Description=Marcel legal digital goods store v4
After=network-online.target
Wants=network-online.target
[Service]
User=www-data
Group=www-data
WorkingDirectory=$APP/current
EnvironmentFile=$ENV
ExecStart=$APP/venv/bin/gunicorn --workers 2 --threads 2 --timeout 30 --bind 127.0.0.1:8088 app:app
Restart=always
RestartSec=2
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=$DATA
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload; systemctl enable marcel-digital-store >/dev/null; systemctl restart marcel-digital-store
for _ in {1..15}; do curl -fsS http://127.0.0.1:8088/healthz >/dev/null && break; sleep 1; done
curl -fsS http://127.0.0.1:8088/healthz | jq -e '.ok==true and .db==1' >/dev/null || { journalctl -u marcel-digital-store -n 80 --no-pager >&2; die "商城服务启动失败。"; }
ok "商城应用和加密库存数据库正常"

step 4 "配置网站反向代理和静态缓存"
mkdir -p /var/www/marcel-acme
# v1可能已经写入新式“http2 on”后在旧Nginx处失败；先原地兼容修复，
# 确保本次第一次nginx -t就能通过，不要求用户手工删除失败文件。
if [ -f /etc/nginx/sites-enabled/marcel-store-https ]; then
  sed -i --follow-symlinks 's/listen 127\.0\.0\.1:8443 ssl;[[:space:]]*http2 on;/listen 127.0.0.1:8443 ssl http2;/' /etc/nginx/sites-enabled/marcel-store-https
fi
cat > /etc/nginx/sites-available/marcel-store-http <<EOF
server { listen 80; listen [::]:80; server_name $DOMAIN;
 location ^~ /.well-known/acme-challenge/ { root /var/www/marcel-acme; }
 location / { return 301 https://\$host\$request_uri; }
}
EOF
ln -sf /etc/nginx/sites-available/marcel-store-http /etc/nginx/sites-enabled/marcel-store-http
nginx -t >/dev/null
systemctl enable --now nginx >/dev/null
systemctl reload nginx
if [ "$TEST_MODE" = 1 ]; then
  warn "测试模式跳过公网证书签发与TCP 443分流"
  cat > /etc/nginx/sites-available/marcel-store-test <<EOF
server { listen 127.0.0.1:18088; server_name _; location / { proxy_pass http://127.0.0.1:8088; proxy_set_header Host \$host; } }
EOF
  ln -sf /etc/nginx/sites-available/marcel-store-test /etc/nginx/sites-enabled/marcel-store-test
  nginx -t >/dev/null; systemctl reload nginx
else
  resolved=$(getent ahostsv4 "$DOMAIN" | awk 'NR==1{print $1}')
  public=$(curl -4fsS --max-time 15 https://api.ipify.org || true)
  [ -n "$resolved" ] || die "域名尚未产生IPv4解析。DuckDNS中请确认 $DOMAIN 已指向本VPS。"
  if [ -n "$public" ] && [ "$resolved" != "$public" ]; then die "域名解析到$resolved，但本机公网IP是$public。请先在DuckDNS改正确。"; fi
  certbot certonly --webroot -w /var/www/marcel-acme -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email --keep-until-expiring >/dev/null
  cat > /etc/nginx/sites-available/marcel-store-https <<EOF
server { listen 127.0.0.1:8443 ssl http2; server_name $DOMAIN;
 ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
 ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
 ssl_protocols TLSv1.2 TLSv1.3; ssl_session_cache shared:SSL:10m; ssl_session_timeout 1d;
 add_header Strict-Transport-Security "max-age=31536000" always;
 gzip on; gzip_types text/css application/javascript application/json image/svg+xml;
 location /static/ { proxy_pass http://127.0.0.1:8088; expires 365d; add_header Cache-Control "public, immutable"; }
 location / { proxy_pass http://127.0.0.1:8088; proxy_set_header Host \$host; proxy_set_header X-Real-IP \$remote_addr; proxy_set_header X-Forwarded-Proto https; proxy_http_version 1.1; }
}
EOF
  ln -sf /etc/nginx/sites-available/marcel-store-https /etc/nginx/sites-enabled/marcel-store-https
  nginx -t >/dev/null; systemctl reload nginx
fi

step 5 "保留HY2并配置TCP 443按域名分流"
if [ "$TEST_MODE" != 1 ]; then
  BACKEND=""
  if ss -H -ltnp '( sport = :443 )' 2>/dev/null | grep -q haproxy && grep -Eq 'marcel-store-v(1|2|3|4)' /etc/haproxy/haproxy.cfg 2>/dev/null; then
    sed -Ei 's/marcel-store-v(1|2|3)/marcel-store-v4/g' /etc/haproxy/haproxy.cfg
    ok "已有商城HTTPS分流配置，兼容升级后保持运行"
  else
    owner=$(ss -H -ltnp '( sport = :443 )' 2>/dev/null || true)
    if printf '%s' "$owner" | grep -q sing-box; then
      conf=/etc/sing-box/config.json
      [ -f "$conf" ] || die "TCP 443由sing-box占用，但未找到配置文件。"
      target=24444; while ss -H -ltn '( sport = :'"$target"' )' | grep -q .; do target=$((target+10)); done
      cp -a "$conf" "$conf.before-store-v4.$(date +%Y%m%d-%H%M%S)"
      jq --argjson p "$target" '(.inbounds[] | select(.type=="vless" and .listen_port==443) | .listen_port)=$p' "$conf" > "$conf.new"
      if cmp -s "$conf" "$conf.new"; then rm -f "$conf.new"; die "未能识别sing-box的TCP 443 VLESS入站，停止以免破坏代理。"; fi
      mv "$conf.new" "$conf"; systemctl restart sing-box; sleep 2; systemctl is-active --quiet sing-box || die "移动Reality端口后sing-box启动失败，备份为$conf.before-store-v4.*"
      BACKEND="127.0.0.1:$target"; ok "HY2 UDP/443保持不变；Reality TCP/443由HAProxy透明转发到$target"
    elif [ -z "$owner" ]; then BACKEND=""
    else die "TCP 443被其他程序占用：$owner。脚本未擅自停止它。"
    fi
    cp -a /etc/haproxy/haproxy.cfg "/etc/haproxy/haproxy.cfg.before-store-v4.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
    cat > /etc/haproxy/haproxy.cfg <<EOF
# marcel-store-v4
global
  log /dev/log local0
  maxconn 4096
defaults
  log global
  mode tcp
  timeout connect 5s
  timeout client 1m
  timeout server 1m
frontend tls443
  bind :443
  tcp-request inspect-delay 3s
  tcp-request content accept if { req.ssl_hello_type 1 }
  use_backend store_https if { req.ssl_sni -i $DOMAIN }
$( [ -n "$BACKEND" ] && echo '  default_backend existing_reality' )
backend store_https
  server nginx 127.0.0.1:8443 check
$( [ -n "$BACKEND" ] && printf 'backend existing_reality\n  server singbox %s\n' "$BACKEND" )
EOF
    haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null
    systemctl enable --now haproxy >/dev/null; systemctl restart haproxy
  fi
fi

step 6 "放行防火墙并配置证书自动续期"
if command -v ufw >/dev/null && ufw status | grep -qi active; then ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null; fi
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-marcel-store <<'EOF'
#!/bin/sh
systemctl reload nginx
EOF
chmod 755 /etc/letsencrypt/renewal-hooks/deploy/reload-marcel-store
systemctl enable --now certbot.timer >/dev/null 2>&1 || true

step 7 "执行真实页面、后台、数据库和HTTPS检查"
curl -fsS http://127.0.0.1:8088/ | grep -q '选择商品' || die "首页检查失败。"
curl -fsS http://127.0.0.1:8088/admin/login | grep -q '管理员登录' || die "后台入口检查失败。"
if [ "$TEST_MODE" = 1 ]; then curl -fsS http://127.0.0.1:18088/healthz | jq -e '.ok' >/dev/null || die "Nginx反代检查失败。"
else
  curl -fsS --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/healthz" | jq -e '.ok' >/dev/null || die "本机HTTPS检查失败。"
  expiry=$(openssl s_client -connect 127.0.0.1:443 -servername "$DOMAIN" </dev/null 2>/dev/null | openssl x509 -noout -enddate)
  ok "可信HTTPS证书有效：$expiry"
fi

step 8 "完成"
printf '\n%b\n' "${G}商城部署与检查全部通过。${N}"
printf '网站：https://%s\n后台：https://%s/admin/login\n管理员：marcel\n' "$DOMAIN" "$DOMAIN"
if [ "${GENERATED_PASSWORD:-0}" = 1 ]; then printf '自动生成的管理员密码：%s\n' "$ADMIN_PASSWORD"; fi
printf '支付宝/微信官方自动支付：登录后台后填写官方商户资料即可启用。\n'
