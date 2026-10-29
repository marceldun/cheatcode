#!/usr/bin/env bash
# =============================================================================
#  sing-box 全协议 · 一键安装（增强版 v2：二维码 + Hysteria2 提速 + ping0.cc 命名）
#    VLESS-Vision-REALITY (TCP)     抗封锁、最稳 —— UDP 被 QoS/封禁时的兜底
#    Hysteria2            (UDP/QUIC) 速度天花板 —— 已做「稳 + 快」优化
#    Shadowsocks-2022     (TCP+UDP)  轻量低开销 —— 低调备用
#    TUIC v5              (UDP/QUIC) 可选
#
#  自动完成：依赖 → 内核调优(BBR/fq/大缓冲/QUIC缓冲) → 下载内核 → 生成密钥/证书
#            → 写配置(带调优自降级) → systemd → 放行防火墙 → 启动 → 实测
#            → ping0.cc 归属地 → 生成链接/二维码 → 输出
#  适用系统：Ubuntu / Debian（兼容 CentOS/Rocky/Alma/Fedora/Alpine），需 root
#  运行方式：bash install.sh
#  覆盖默认：ENABLE_TUIC=1 ENABLE_HY2_OBFS=1 LISTEN_PORT=443 bash install.sh
# =============================================================================
set -uo pipefail

# ------------------------------- 可自定义 -----------------------------------
LISTEN_PORT="${LISTEN_PORT:-443}"        # VLESS-Vision-REALITY 监听端口（TCP）
HY2_PORT="${HY2_PORT:-443}"              # Hysteria2 监听端口（UDP，可与 443/TCP 共存）
SS_PORT="${SS_PORT:-8388}"               # Shadowsocks-2022 端口（TCP+UDP）
TUIC_PORT="${TUIC_PORT:-8443}"           # TUIC v5 端口（UDP，默认关闭）

ENABLE_HY2="${ENABLE_HY2:-1}"            # 1=启用 Hysteria2（强烈推荐，速度最快）
ENABLE_SS="${ENABLE_SS:-1}"              # 1=启用 Shadowsocks-2022
ENABLE_TUIC="${ENABLE_TUIC:-0}"          # 1=启用 TUIC v5

# --- Hysteria2 稳定性/速度（v2 新增）---
ENABLE_HY2_OBFS="${ENABLE_HY2_OBFS:-1}"          # 1=开启混淆（强烈建议，规避 UDP QoS/丢包）
HY2_OBFS_TYPE="${HY2_OBFS_TYPE:-salamander}"     # salamander（兼容最好）| gecko（需内核≥1.14）
HY2_BBR_PROFILE="${HY2_BBR_PROFILE:-aggressive}" # conservative|standard|aggressive（需内核≥1.14）
HY2_QUIC_TUNE="${HY2_QUIC_TUNE:-1}"              # 1=写入 QUIC 接收窗口/并发流/keep-alive 调优

REALITY_DOMAIN="${REALITY_DOMAIN:-addons.mozilla.org}"  # REALITY 握手域名（需 TLS1.3+H2）
MASQUERADE="${MASQUERADE:-https://addons.mozilla.org/}" # HY2/TUIC 伪装站点

# --- remarks / 二维码（v2 新增）---
NODE_PREFIX="${NODE_PREFIX:-}"                   # 节点名前缀，默认空
GEO_API="${GEO_API:-auto}"                       # auto=用 ping0.cc 实测归属地
IP_TAG="${IP_TAG:-原生IP}"                        # 原生IP / 纯净IP / 广播IP / none
REMARK_PROTO_SUFFIX="${REMARK_PROTO_SUFFIX:-1}"  # 1=节点名后加协议后缀（便于区分 4 个节点）
ENABLE_QR="${ENABLE_QR:-1}"                      # 1=生成二维码
ENABLE_SUB_SERVER="${ENABLE_SUB_SERVER:-0}"      # 1=内置订阅HTTP服务并生成订阅二维码（有暴露风险，默认关）
SUB_PORT="${SUB_PORT:-}"                         # 订阅服务端口，空=随机高位端口
# 备选 REALITY 域名：www.microsoft.com / www.apple.com / dl.google.com / www.lovelive-anime.jp
# ---------------------------------------------------------------------------

WORK_DIR="/etc/sing-box"
LOG_DIR="${WORK_DIR}/logs"
CERT_DIR="${WORK_DIR}/cert"
CONF="${WORK_DIR}/config.json"
TEMP_DIR="/tmp/sbinstall"
INB_DIR="${TEMP_DIR}/inbounds"
QR_DIR="/root/sing-box-qr"

# 下载通道：空串=直连，其余为 GitHub 反代前缀（逐个尝试，谁通用谁）
PREFIXES=(
  ""
  "https://ghfast.top/"
  "https://gh-proxy.com/"
  "https://ghproxy.net/"
  "https://mirror.ghproxy.com/"
  "https://gh.llkk.cc/"
  "https://github.moeyy.xyz/"
  "https://ghproxy.cc/"
  "https://hub.gitmirror.com/"
  "https://gh-proxy.org/"
)
export DEBIAN_FRONTEND=noninteractive

ESC=$(printf '\033'); G="${ESC}[32m"; Y="${ESC}[33m"; R="${ESC}[31m"; C="${ESC}[36m"; B="${ESC}[1m"; N="${ESC}[0m"
ok(){ echo -e "${G}[✔]${N} $*"; }
warn(){ echo -e "${Y}[!]${N} $*"; }
fatal(){ echo -e "${R}[✘]${N} $*" >&2; exit 1; }
step(){ echo -e "\n${C}======== $* ========${N}"; }
raw(){ printf '%s' "$1" | openssl base64 -A; }   # 无换行 base64（Alpine 也兼容）
enc(){ printf '%s' "$1" | sed 's/ /%20/g'; }     # 仅编码空格，保留中文/emoji（小火箭可识别国旗）
trap 'rm -rf "$TEMP_DIR" >/dev/null 2>&1 || true' EXIT

# ============================ 0. 基础检测 ============================
step "0/10 基础检测"
[ "$(id -u)" -eq 0 ] || fatal "请用 root 运行：先执行 sudo -i。"
case "$(uname -m)" in
  x86_64|amd64) SB_ARCH=amd64 ;;
  aarch64|arm64) SB_ARCH=arm64 ;;
  armv7l) SB_ARCH=armv7 ;;
  *) fatal "不支持的架构: $(uname -m)" ;;
esac
PRETTY="$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
case "$PRETTY" in
  *Debian*|*Ubuntu*) PKG="apt-get -y install"; PKG_UPD="apt-get update -y" ;;
  *CentOS*|*Rocky*|*Alma*|*Red\ Hat*) PKG="yum -y install"; PKG_UPD="yum makecache -y" ;;
  *Fedora*) PKG="dnf -y install"; PKG_UPD="dnf makecache -y" ;;
  *Alpine*) PKG="apk add --no-cache"; PKG_UPD="apk update" ;;
  *) warn "未知系统，默认用 apt-get"; PKG="apt-get -y install"; PKG_UPD="apt-get update -y" ;;
esac
ok "系统：$PRETTY / $SB_ARCH"
mkdir -p "$WORK_DIR" "$LOG_DIR" "$CERT_DIR" "$TEMP_DIR" "$INB_DIR"

# ============================ 1. 依赖 ============================
step "1/10 安装依赖"
$PKG_UPD >/dev/null 2>&1 || warn "包索引更新失败，继续尝试"
for d in curl wget jq tar openssl; do
  command -v "$d" >/dev/null 2>&1 || { ok "安装依赖 $d"; $PKG "$d" >/dev/null 2>&1 || warn "$d 安装失败"; }
done
for d in curl jq tar openssl; do command -v "$d" >/dev/null 2>&1 || fatal "缺少依赖 $d，请手动安装后重跑。"; done
# 二维码工具（v2）
if [ "${ENABLE_QR}" = 1 ] && ! command -v qrencode >/dev/null 2>&1; then
  ok "安装依赖 qrencode"; $PKG qrencode >/dev/null 2>&1 || warn "qrencode 安装失败（二维码功能将跳过，可稍后手动安装）"
fi
ok "依赖就绪"

# ============================ 2. 时间同步 ============================
step "2/10 同步系统时间"
command -v timedatectl >/dev/null 2>&1 && timedatectl set-ntp true >/dev/null 2>&1 || true
command -v systemctl >/dev/null 2>&1 && systemctl restart systemd-timesyncd >/dev/null 2>&1 || true
command -v chronyc >/dev/null 2>&1 && chronyc -a makestep >/dev/null 2>&1 || true
ok "时间同步完成"

# ============================ 3. 下载通道 ============================
step "3/10 准备下载通道"
fetch(){ local u="$1" p; for p in "${PREFIXES[@]}"; do curl -fsSL --connect-timeout 8 --max-time 25 "${p}${u}" 2>/dev/null && return 0; done; return 1; }
getfile(){ local u="$1" d="$2" p
  for p in "${PREFIXES[@]}"; do
    echo -e "   ${C}通道${N}: ${p:-直连}"
    if curl -fL --connect-timeout 10 --max-time 180 --retry 0 -o "$d" "${p}${u}" 2>/dev/null && [ -s "$d" ]; then return 0; fi
    rm -f "$d"
  done; return 1; }
ok "共 ${#PREFIXES[@]} 个通道（直连 + GitHub 反代），失败自动切换"

# ============================ 4. 下载 sing-box ============================
step "4/10 下载 sing-box 内核"
if [ -x "${WORK_DIR}/sing-box" ]; then
  ok "已存在：$(${WORK_DIR}/sing-box version 2>/dev/null | head -1)"
else
  VER=""
  for a in \
    "https://api.github.com/repos/SagerNet/sing-box/releases/latest" \
    "https://ghfast.top/https://api.github.com/repos/SagerNet/sing-box/releases/latest" \
    "https://gh-proxy.com/https://api.github.com/repos/SagerNet/sing-box/releases/latest"; do
    VER=$(curl -fsSL --connect-timeout 8 --max-time 15 "$a" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null | sed 's/^v//')
    [ -n "$VER" ] && break
  done
  [ -n "$VER" ] || fatal "无法获取 sing-box 版本（GitHub API 不可达），请稍后重试。"
  ok "目标版本：v${VER}"
  GH_URL="https://github.com/SagerNet/sing-box/releases/download/v${VER}/sing-box-${VER}-linux-${SB_ARCH}.tar.gz"
  TB="${TEMP_DIR}/sing-box.tar.gz"
  getfile "$GH_URL" "$TB" || fatal "所有通道下载失败，请稍后重试，或手动放置二进制到 ${WORK_DIR}/sing-box。"
  tar xzf "$TB" -C "$TEMP_DIR" || fatal "解压失败"
  SBBIN="$(find "$TEMP_DIR" -type f -name sing-box | head -1)"
  [ -n "$SBBIN" ] || fatal "未找到 sing-box 可执行文件"
  install -m 755 "$SBBIN" "${WORK_DIR}/sing-box"
  ok "已安装：$(${WORK_DIR}/sing-box version 2>/dev/null | head -1)"
fi
SB="${WORK_DIR}/sing-box"

# --- 版本探测：决定能否使用 1.14+ 的高级 QUIC 字段（v2）---
SB_VER="$( { "$SB" version 2>/dev/null || true; } | head -n1 | awk '{print $NF}')"
ver_ge(){ # $1=当前版本 $2=要求版本
  [ -n "${1:-}" ] || return 1
  local a b
  a="$(printf '%s' "$1" | awk -F. '{printf "%d%03d%03d", $1, $2, $3}')"
  b="$(printf '%s' "$2" | awk -F. '{printf "%d%03d%03d", $1, $2, $3}')"
  [ "$a" -ge "$b" ] 2>/dev/null
}
ADVANCED=0; ver_ge "$SB_VER" "1.14.0" && ADVANCED=1
[ "$ADVANCED" = 1 ] && ok "内核 ${SB_VER}：高级 QUIC 调优可用" || warn "内核 ${SB_VER}：不支持部分高级调优，将自动降级（功能不受影响）"

# ============================ 5. 生成凭据 ============================
step "5/10 生成 UUID / REALITY 密钥 / 密码 / 自签证书"
UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || "$SB" generate uuid)"
KP="$("$SB" generate reality-keypair 2>/dev/null)"
PRIV="$(awk '/PrivateKey/{print $NF}' <<<"$KP")"
PUB="$(awk '/PublicKey/{print $NF}' <<<"$KP")"
{ [ -n "$PRIV" ] && [ -n "$PUB" ]; } || { echo "$KP"; fatal "生成 REALITY 密钥失败"; }
SID="$(openssl rand -hex 4)"

HY2_PASS="$(openssl rand -hex 16)"
OBFS_PASS="$(openssl rand -hex 16)"
SS_PASS="$(openssl rand -base64 16 | tr -d '\n')"     # SS-2022 aes-128-gcm 需 base64(16B)
TUIC_UUID="$("$SB" generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)"
TUIC_PASS="$(openssl rand -hex 16)"

# 自签证书（HY2/TUIC 用；客户端以 insecure=1 连接）
openssl ecparam -genkey -name prime256v1 -out "${CERT_DIR}/key.pem" >/dev/null 2>&1
openssl req -new -x509 -days 36500 -key "${CERT_DIR}/key.pem" -out "${CERT_DIR}/cert.pem" \
  -subj "/CN=${REALITY_DOMAIN}" >/dev/null 2>&1
[ -s "${CERT_DIR}/cert.pem" ] || fatal "自签证书生成失败"
ok "UUID         = ${UUID}"
ok "REALITY 公钥 = ${PUB}"
ok "short_id     = ${SID}"

# ============================ 6. 端口占用处理 ============================
step "6/10 端口检查"
port_busy_tcp(){ ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${1}$"; }
port_busy_udp(){ ss -uln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${1}$"; }
if port_busy_tcp "$LISTEN_PORT"; then
  warn "TCP ${LISTEN_PORT} 被占用，改用随机高位端口"
  P=$((RANDOM % 40001 + 20000)); while port_busy_tcp "$P"; do P=$((P+1)); done; LISTEN_PORT=$P
fi
if [ "$ENABLE_HY2" = 1 ] && port_busy_udp "$HY2_PORT"; then
  warn "UDP ${HY2_PORT} 被占用，改用随机高位端口"
  P=$((RANDOM % 40001 + 20000)); while port_busy_udp "$P"; do P=$((P+1)); done; HY2_PORT=$P
fi
ok "VLESS/TCP=${LISTEN_PORT}  HY2/UDP=${HY2_PORT}  SS=${SS_PORT}  TUIC=${TUIC_PORT}(启用=${ENABLE_TUIC})"

# ============================ 7. 生成配置（带调优自降级）============================
step "7/10 生成配置"

# 调优等级：2=完整(混淆+BBR+QUIC窗口/并发流/keep-alive) 1=中等(混淆+BBR) 0=兼容(仅混淆)
hy2_extra(){ # $1=level → 追加到 hy2 inbound 的 JSON 片段
  local lvl="$1" s=""
  [ "$ENABLE_HY2_OBFS" = 1 ] && s="${s}, \"obfs\": { \"type\": \"${HY2_OBFS_TYPE}\", \"password\": \"${OBFS_PASS}\" }"
  if [ "$lvl" -ge 1 ] && [ "$ADVANCED" = 1 ]; then
    s="${s}, \"bbr_profile\": \"${HY2_BBR_PROFILE}\""
  fi
  if [ "$lvl" -ge 2 ] && [ "$HY2_QUIC_TUNE" = 1 ] && [ "$ADVANCED" = 1 ]; then
    # 接收窗口 + 并发流上限（缓解「多小连接/图片视频分片」慢）+ keep-alive（移动端少重连）
    s="${s}, \"stream_receive_window\": \"16 MB\", \"connection_receive_window\": \"64 MB\""
    s="${s}, \"max_concurrent_streams\": 256, \"keep_alive_period\": \"15s\", \"idle_timeout\": \"120s\""
  fi
  printf '%s' "$s"
}

gen_config(){ # $1=level
  local LVL="$1"
  rm -f "${INB_DIR}"/*.json 2>/dev/null || true

  # --- VLESS-Vision-REALITY（TCP）---
  cat > "${INB_DIR}/10-vless.json" <<EOF
{
  "type": "vless",
  "tag": "vless-reality",
  "listen": "::",
  "listen_port": ${LISTEN_PORT},
  "users": [ { "uuid": "${UUID}", "flow": "xtls-rprx-vision" } ],
  "tls": {
    "enabled": true,
    "server_name": "${REALITY_DOMAIN}",
    "reality": {
      "enabled": true,
      "handshake": { "server": "${REALITY_DOMAIN}", "server_port": 443 },
      "private_key": "${PRIV}",
      "short_id": [ "${SID}" ]
    }
  }
}
EOF

  # --- Hysteria2（UDP/QUIC）---
  if [ "$ENABLE_HY2" = 1 ]; then
    cat > "${INB_DIR}/20-hy2.json" <<EOF
{
  "type": "hysteria2",
  "tag": "hy2",
  "listen": "::",
  "listen_port": ${HY2_PORT},
  "users": [ { "password": "${HY2_PASS}" } ],
  "ignore_client_bandwidth": false,
  "masquerade": "${MASQUERADE}",
  "tls": {
    "enabled": true,
    "alpn": [ "h3" ],
    "certificate_path": "${CERT_DIR}/cert.pem",
    "key_path": "${CERT_DIR}/key.pem"
  }$(hy2_extra "$LVL")
}
EOF
  fi

  # --- Shadowsocks-2022（TCP+UDP）---
  if [ "$ENABLE_SS" = 1 ]; then
    cat > "${INB_DIR}/30-ss.json" <<EOF
{
  "type": "shadowsocks",
  "tag": "ss-2022",
  "listen": "::",
  "listen_port": ${SS_PORT},
  "method": "2022-blake3-aes-128-gcm",
  "password": "${SS_PASS}"
}
EOF
  fi
  # 注意：新版 sing-box 的 network 字段只接受单个 "tcp" 或 "udp"。
  # 这里刻意不写 network —— 留空即同时监听 TCP+UDP，兼容所有版本。

  # --- TUIC v5（UDP/QUIC，可选）---
  if [ "$ENABLE_TUIC" = 1 ]; then
    cat > "${INB_DIR}/40-tuic.json" <<EOF
{
  "type": "tuic",
  "tag": "tuic",
  "listen": "::",
  "listen_port": ${TUIC_PORT},
  "users": [ { "uuid": "${TUIC_UUID}", "password": "${TUIC_PASS}" } ],
  "congestion_control": "bbr",
  "tls": {
    "enabled": true,
    "alpn": [ "h3" ],
    "certificate_path": "${CERT_DIR}/cert.pem",
    "key_path": "${CERT_DIR}/key.pem"
  }
}
EOF
  fi

  [ -f "$CONF" ] && cp -f "$CONF" "${CONF}.bak.$(date +%s)" 2>/dev/null || true
  jq -s '.' "${INB_DIR}"/*.json > "${TEMP_DIR}/inbounds.json" 2>/dev/null || return 1
  jq -n --slurpfile inb "${TEMP_DIR}/inbounds.json" --arg logf "${LOG_DIR}/sing-box.log" \
    '{
       log: { disabled: false, level: "warn", output: $logf, timestamp: true },
       dns: { servers: [ { type: "local" } ], strategy: "prefer_ipv4" },
       inbounds: $inb[0],
       outbounds: [ { type: "direct", tag: "direct" } ]
     }' > "$CONF" 2>/dev/null || return 1
  return 0
}

try_config(){
  local lvl
  for lvl in 2 1 0; do
    gen_config "$lvl" || { warn "调优等级 ${lvl} 生成失败，降级重试…"; continue; }
    if "$SB" check -c "$CONF" >"${TEMP_DIR}/check.log" 2>&1; then
      [ "$lvl" = 2 ] || warn "已自动降级到调优等级 ${lvl}（配置兼容优先，性能仍优于原始版）"
      return 0
    fi
    warn "调优等级 ${lvl} 校验未通过，降级重试…"
  done
  cat "${TEMP_DIR}/check.log" 2>/dev/null
  return 1
}

try_config || fatal "配置校验失败（若因 ENABLE_TUIC=1 导致，请去掉该变量重跑）"
ok "配置校验通过"

# ============================ 8. 系统调优 + systemd ============================
step "8/10 内核调优与服务"
cat > /etc/systemd/system/sing-box.service <<'EOF'
[Unit]
Description=sing-box Service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=root
Type=simple
WorkingDirectory=/etc/sing-box
ExecStart=/etc/sing-box/sing-box run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable sing-box >/dev/null 2>&1 || true

echo tcp_bbr > /etc/modules-load.d/bbr.conf 2>/dev/null || true
modprobe tcp_bbr 2>/dev/null || true

if ! grep -q 'sing-box tuner v2' /etc/sysctl.conf 2>/dev/null; then
cat >> /etc/sysctl.conf <<'EOF'

# === sing-box tuner v2 ===
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
# 大缓冲：拉满「高带宽 × 高延迟」（BDP）链路
net.core.rmem_max=268435456
net.core.wmem_max=268435456
net.core.rmem_default=262144
net.core.wmem_default=262144
net.ipv4.tcp_rmem=4096 87380 268435456
net.ipv4.tcp_wmem=4096 65536 268435456
# QUIC/UDP 缓冲（Hysteria2 稳且快的关键）
net.ipv4.udp_rmem_min=16384
net.ipv4.udp_wmem_min=16384
net.ipv4.udp_mem=65536 131072 262144
net.core.optmem_max=25165824
net.core.somaxconn=65535
net.core.netdev_max_backlog=65535
# 降低首包时延 / 提升吞吐 / 抗 MTU 黑洞（移动网络尤为重要）
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_notsent_lowat=16384
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_no_metrics_save=1
net.ipv4.ip_local_port_range=10240 65000
# === sing-box tuner v2 end ===
EOF
fi
sysctl -p >/dev/null 2>&1 || true
ok "拥塞控制：$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) / qdisc：$(sysctl -n net.core.default_qdisc 2>/dev/null)"

# ---- 防火墙放行 ----
open_fw(){ local p="$1" pr="$2"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi active; then ufw allow "${p}/${pr}" >/dev/null 2>&1 || true; fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then firewall-cmd --permanent --add-port="${p}/${pr}" >/dev/null 2>&1 || true; fi
}
open_fw "$LISTEN_PORT" tcp
[ "$ENABLE_HY2" = 1 ] && open_fw "$HY2_PORT" udp
[ "$ENABLE_SS" = 1 ] && { open_fw "$SS_PORT" tcp; open_fw "$SS_PORT" udp; }
[ "$ENABLE_TUIC" = 1 ] && open_fw "$TUIC_PORT" udp
command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1 || true

systemctl restart sing-box
sleep 1
systemctl is-active --quiet sing-box || { journalctl -u sing-box -n 40 --no-pager; fatal "sing-box 启动失败"; }
ok "sing-box 运行中"

# ============================ 9. 端到端实测 ============================
step "9/10 端到端联网实测"
run_test(){ # $1=config $2=socks_port $3=label
  local cfg="$1" sp="$2" label="$3" pid code
  "$SB" run -c "$cfg" >"${TEMP_DIR}/t.log" 2>&1 &
  pid=$!
  sleep 2
  code=$(curl -s -o /dev/null -w '%{http_code}' --socks5-hostname "127.0.0.1:${sp}" -m 15 https://www.gstatic.com/generate_204 2>/dev/null || echo 000)
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  case "$code" in
    200|204|301|302) ok "${label}：实测通过（HTTP ${code}）" ;;
    *) warn "${label}：实测返回 ${code}（可能受本机网络影响，不影响节点可用性）" ;;
  esac
}

cat > "${TEMP_DIR}/tv.json" <<EOF
{
  "log": { "level": "error" },
  "inbounds": [ { "type": "socks", "listen": "127.0.0.1", "listen_port": 10809 } ],
  "outbounds": [ {
    "type": "vless", "server": "127.0.0.1", "server_port": ${LISTEN_PORT}, "uuid": "${UUID}",
    "flow": "xtls-rprx-vision",
    "tls": { "enabled": true, "server_name": "${REALITY_DOMAIN}",
      "utls": { "enabled": true, "fingerprint": "chrome" },
      "reality": { "enabled": true, "public_key": "${PUB}", "short_id": "${SID}" } }
  } ]
}
EOF
run_test "${TEMP_DIR}/tv.json" 10809 "VLESS-Vision-REALITY"

if [ "$ENABLE_HY2" = 1 ]; then
  OB=""
  [ "$ENABLE_HY2_OBFS" = 1 ] && OB=", \"obfs\": { \"type\": \"${HY2_OBFS_TYPE}\", \"password\": \"${OBFS_PASS}\" }"
  cat > "${TEMP_DIR}/th.json" <<EOF
{
  "log": { "level": "error" },
  "inbounds": [ { "type": "socks", "listen": "127.0.0.1", "listen_port": 10810 } ],
  "outbounds": [ {
    "type": "hysteria2", "server": "127.0.0.1", "server_port": ${HY2_PORT}, "password": "${HY2_PASS}",
    "tls": { "enabled": true, "server_name": "${REALITY_DOMAIN}", "insecure": true, "alpn": [ "h3" ] }${OB}
  } ]
}
EOF
  run_test "${TEMP_DIR}/th.json" 10810 "Hysteria2"
fi

# ============================ 10. 输出链接 / 二维码 ============================
step "10/10 生成节点信息与二维码"
IP4="$(curl -fsS -m 8 https://api.ipify.org 2>/dev/null || curl -fsS -m 8 https://ifconfig.me/ip 2>/dev/null || true)"
IP6="$(curl -fsS -m 8 https://api64.ipify.org 2>/dev/null || true)"
if [ -n "$IP4" ]; then HOST="$IP4"; else
  if [ -n "$IP6" ]; then HOST="[${IP6}]"; else HOST="YOUR_SERVER_IP"; fi
fi
STAMP="$(date +%m%d-%H%M)"

# ---------- 归属地（https://ping0.cc 实测，决定 remarks 国家名 + 国旗）----------
GEO_LOC=""; GEO_ASN=""; GEO_ORG=""; COUNTRY_CN=""
geo_detect(){
  [ "${GEO_API}" = "auto" ] || { COUNTRY_CN="未知"; return; }
  local raw="" u
  for u in "https://ipv4.ping0.cc/geo" "https://ping0.cc/geo"; do
    raw="$(curl -fsSL --connect-timeout 6 --max-time 12 "$u" 2>/dev/null | tr -d '\r')" \
      || raw="$(curl -kfsSL --connect-timeout 6 --max-time 12 "$u" 2>/dev/null | tr -d '\r')" \
      || raw=""
    [ -n "$raw" ] && break
  done
  # ping0.cc/geo 返回 4 行：1=IP  2=位置(国家 省 城市 — ISP)  3=ASN  4=组织
  GEO_LOC="$(printf '%s\n' "$raw" | sed -n '2p')"
  GEO_ASN="$(printf '%s\n' "$raw" | sed -n '3p')"
  GEO_ORG="$(printf '%s\n' "$raw" | sed -n '4p')"
  COUNTRY_CN="$(printf '%s' "$GEO_LOC" | awk '{print $1}')"
  [ -n "$COUNTRY_CN" ] || COUNTRY_CN="未知"
}
geo_detect

# 中文国家名 → 国旗 emoji
flag_of(){
  case "$1" in
    印度尼西亚|印尼) echo "🇮🇩" ;;
    美国) echo "🇺🇸" ;; 加拿大) echo "🇨🇦" ;; 墨西哥) echo "🇲🇽" ;; 巴西) echo "🇧🇷" ;;
    阿根廷) echo "🇦🇷" ;; 智利) echo "🇨🇱" ;; 秘鲁) echo "🇵🇪" ;; 哥伦比亚) echo "🇨🇴" ;;
    英国) echo "🇬🇧" ;; 德国) echo "🇩🇪" ;; 法国) echo "🇫🇷" ;; 荷兰) echo "🇳🇱" ;;
    意大利) echo "🇮🇹" ;; 西班牙) echo "🇪🇸" ;; 葡萄牙) echo "🇵🇹" ;; 瑞士) echo "🇨🇭" ;;
    瑞典) echo "🇸🇪" ;; 挪威) echo "🇳🇴" ;; 丹麦) echo "🇩🇰" ;; 芬兰) echo "🇫🇮" ;;
    冰岛) echo "🇮🇸" ;; 爱尔兰) echo "🇮🇪" ;; 比利时) echo "🇧🇪" ;; 奥地利) echo "🇦🇹" ;;
    波兰) echo "🇵🇱" ;; 捷克) echo "🇨🇿" ;; 斯洛伐克) echo "🇸🇰" ;; 匈牙利) echo "🇭🇺" ;;
    罗马尼亚) echo "🇷🇴" ;; 保加利亚) echo "🇧🇬" ;; 希腊) echo "🇬🇷" ;; 乌克兰) echo "🇺🇦" ;;
    俄罗斯) echo "🇷🇺" ;; 白俄罗斯) echo "🇧🇾" ;; 摩尔多瓦) echo "🇲🇩" ;; 塞尔维亚) echo "🇷🇸" ;;
    克罗地亚) echo "🇭🇷" ;; 斯洛文尼亚) echo "🇸🇮" ;; 立陶宛) echo "🇱🇹" ;; 拉脱维亚) echo "🇱🇻" ;;
    爱沙尼亚) echo "🇪🇪" ;; 阿尔巴尼亚) echo "🇦🇱" ;; 卢森堡) echo "🇱🇺" ;; 马耳他) echo "🇲🇹" ;;
    塞浦路斯) echo "🇨🇾" ;; 土耳其) echo "🇹🇷" ;; 以色列) echo "🇮🇱" ;; 阿联酋) echo "🇦🇪" ;;
    沙特阿拉伯) echo "🇸🇦" ;; 卡塔尔) echo "🇶🇦" ;; 科威特) echo "🇰🇼" ;; 巴林) echo "🇧🇭" ;;
    阿曼) echo "🇴🇲" ;; 约旦) echo "🇯🇴" ;; 黎巴嫩) echo "🇱🇧" ;; 伊拉克) echo "🇮🇶" ;;
    伊朗) echo "🇮🇷" ;; 印度) echo "🇮🇳" ;; 巴基斯坦) echo "🇵🇰" ;; 孟加拉国) echo "🇧🇩" ;;
    斯里兰卡) echo "🇱🇰" ;; 尼泊尔) echo "🇳🇵" ;; 泰国) echo "🇹🇭" ;; 越南) echo "🇻🇳" ;;
    马来西亚) echo "🇲🇾" ;; 新加坡) echo "🇸🇬" ;; 菲律宾) echo "🇵🇭" ;; 柬埔寨) echo "🇰🇭" ;;
    老挝) echo "🇱🇦" ;; 缅甸) echo "🇲🇲" ;; 文莱) echo "🇧🇳" ;; 日本) echo "🇯🇵" ;;
    韩国) echo "🇰🇷" ;; 朝鲜) echo "🇰🇵" ;; 蒙古) echo "🇲🇳" ;; 中国) echo "🇨🇳" ;;
    中国香港|香港) echo "🇭🇰" ;; 中国台湾|台湾) echo "🇹🇼" ;; 中国澳门|澳门) echo "🇲🇴" ;;
    澳大利亚) echo "🇦🇺" ;; 新西兰) echo "🇳🇿" ;; 南非) echo "🇿🇦" ;; 埃及) echo "🇪🇬" ;;
    尼日利亚) echo "🇳🇬" ;; 肯尼亚) echo "🇰🇪" ;; 摩洛哥) echo "🇲🇦" ;; 突尼斯) echo "🇹🇳" ;;
    阿尔及利亚) echo "🇩🇿" ;; 哈萨克斯坦) echo "🇰🇿" ;; 乌兹别克斯坦) echo "🇺🇿" ;; 阿塞拜疆) echo "🇦🇿" ;;
    格鲁吉亚) echo "🇬🇪" ;; 亚美尼亚) echo "🇦🇲" ;; 波黑) echo "🇧🇦" ;; 北马其顿) echo "🇲🇰" ;;
    *) echo "🌐" ;;
  esac
}
FLAG="$(flag_of "$COUNTRY_CN")"
[ "$COUNTRY_CN" = "未知" ] && FLAG="🌐"

# IP 质量标签（原生IP / 纯净IP / 广播IP / none）
TAG=""
case "${IP_TAG}" in ""|none|None|NONE) TAG="" ;; *) TAG="${IP_TAG}" ;; esac

if [ "$COUNTRY_CN" != "未知" ]; then
  REMARK_BASE="${FLAG} ${COUNTRY_CN}${TAG}"
else
  warn "未能从 ping0.cc 获取归属地，remarks 使用通用名称（可设 GEO_API=off 关闭检测）"
  REMARK_BASE="🌐 Node-${STAMP}"
fi

mk_remark(){ # $1=协议名
  local n="${REMARK_BASE}"
  { [ "${REMARK_PROTO_SUFFIX}" = 1 ] && [ -n "${1:-}" ]; } && n="${n} ${1}"
  printf '%s' "${NODE_PREFIX}${n}"
}

V_NAME="$(mk_remark Reality)"
VLINK="vless://${UUID}@${HOST}:${LISTEN_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_DOMAIN}&fp=chrome&pbk=${PUB}&sid=${SID}&type=tcp&headerType=none#$(enc "$V_NAME")"
LINKS="${VLINK}"
QR_ITEMS=("01-Reality|${VLINK}")

HLINK=""; SLINK=""; TLINK=""
if [ "$ENABLE_HY2" = 1 ]; then
  H_NAME="$(mk_remark Hy2)"
  HLINK="hysteria2://${HY2_PASS}@${HOST}:${HY2_PORT}/?sni=${REALITY_DOMAIN}&insecure=1&alpn=h3"
  [ "$ENABLE_HY2_OBFS" = 1 ] && HLINK="${HLINK}&obfs=${HY2_OBFS_TYPE}&obfs-password=${OBFS_PASS}"
  HLINK="${HLINK}#$(enc "$H_NAME")"
  LINKS="${LINKS}"$'\n'"${HLINK}"
  QR_ITEMS+=("02-Hy2|${HLINK}")
fi
if [ "$ENABLE_SS" = 1 ]; then
  S_NAME="$(mk_remark SS2022)"
  SLINK="ss://$(raw "2022-blake3-aes-128-gcm:${SS_PASS}")@${HOST}:${SS_PORT}#$(enc "$S_NAME")"
  LINKS="${LINKS}"$'\n'"${SLINK}"
  QR_ITEMS+=("03-SS2022|${SLINK}")
fi
if [ "$ENABLE_TUIC" = 1 ]; then
  T_NAME="$(mk_remark Tuic)"
  TLINK="tuic://${TUIC_UUID}:${TUIC_PASS}@${HOST}:${TUIC_PORT}?congestion_control=bbr&alpn=h3&sni=${REALITY_DOMAIN}&udp_relay_mode=native&allow_insecure=1#$(enc "$T_NAME")"
  LINKS="${LINKS}"$'\n'"${TLINK}"
  QR_ITEMS+=("04-TUIC|${TLINK}")
fi
SUB="$(raw "$LINKS")"

# ---------- 二维码（终端 ANSI + PNG + index.html）----------
gen_qr(){
  [ "${ENABLE_QR}" = 1 ] || return 0
  if ! command -v qrencode >/dev/null 2>&1; then
    warn "未安装 qrencode，跳过二维码（可执行 ${PKG%% *} install -y qrencode 后执行 sb qr）"; return 0
  fi
  mkdir -p "$QR_DIR"; rm -f "$QR_DIR"/*.png "$QR_DIR/index.html" 2>/dev/null || true
  local it f t
  for it in "${QR_ITEMS[@]}"; do
    f="${it%%|*}"; t="${it#*|}"
    [ -n "$t" ] && { qrencode -o "$QR_DIR/${f}.png" -s 6 -m 2 "$t" 2>/dev/null || true; }
  done
  {
    echo '<!doctype html><html><head><meta charset="utf-8"><title>sing-box 节点二维码</title>'
    echo '<style>body{font-family:-apple-system,Segoe UI,Roboto,sans-serif;background:#0f1115;color:#e6e6e6;margin:24px}h2{margin:0 0 6px}p{color:#9aa0a6}.card{display:inline-block;margin:14px;padding:12px;background:#fff;border-radius:12px;text-align:center}.card b{color:#111;display:block;margin-top:8px;font-size:13px}</style></head><body>'
    echo '<h2>sing-box 节点二维码</h2><p>用 小火箭(Shadowrocket) / NekoRay / NekoBox 直接扫码导入</p>'
    for it in "${QR_ITEMS[@]}"; do
      f="${it%%|*}"; [ -f "$QR_DIR/${f}.png" ] || continue
      echo "<div class=\"card\"><img src=\"${f}.png\" width=\"260\" height=\"260\"><b>${f}</b></div>"
    done
    echo '</body></html>'
  } > "$QR_DIR/index.html"
  ok "二维码已保存：${QR_DIR}/（PNG 图片 + index.html 网页）"
}

# ---------- 可选：内置订阅服务（生成「订阅二维码」一键导入全部节点）----------
SUB_URL=""
setup_sub_server(){
  [ "${ENABLE_SUB_SERVER}" = 1 ] || return 0
  if ! command -v python3 >/dev/null 2>&1; then warn "未找到 python3，跳过订阅服务"; return 0; fi
  local dir="/etc/sing-box/sub" token port
  token="$(openssl rand -hex 16)"
  mkdir -p "$dir"
  printf '%s' "$SUB" > "$dir/$token"
  echo '<!doctype html><meta charset="utf-8"><title>Not Found</title>Not Found' > "$dir/index.html"
  port="${SUB_PORT:-$((RANDOM % 20000 + 40000))}"
  cat > /etc/systemd/system/sb-sub.service <<EOF
[Unit]
Description=sing-box subscription http
After=network.target
[Service]
User=root
ExecStart=/usr/bin/python3 -m http.server ${port} --bind 0.0.0.0 --directory ${dir}
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now sb-sub >/dev/null 2>&1 || systemctl restart sb-sub >/dev/null 2>&1 || true
  open_fw "$port" tcp
  command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1 || true
  SUB_URL="http://${HOST}:${port}/${token}"
  printf '%s' "$SUB_URL" > /root/sing-box-sub-url.txt
  ok "订阅地址（含随机路径，请勿外泄）：${SUB_URL}"
}
setup_sub_server

# ---------- 写信息文件 ----------
{
echo "==== sing-box 节点信息 ($(date)) ===="
echo "服务器IP : ${HOST}"
echo "归属地   : ${GEO_LOC:-未知}  [来源: ping0.cc]"
echo "ASN/组织 : ${GEO_ASN:-?} / ${GEO_ORG:-?}"
echo "内核     : $("$SB" version 2>/dev/null | head -1)"
[ -n "$SUB_URL" ] && echo "订阅地址 : ${SUB_URL}"
echo "二维码   : ${QR_DIR}/  （PNG 图片 + index.html）"
echo "------------------------------------------------------------"
echo "[1] VLESS-Vision-REALITY (TCP)  ← 最稳 / 抗封锁"
echo "  端口      : ${LISTEN_PORT}"
echo "  UUID      : ${UUID}"
echo "  SNI       : ${REALITY_DOMAIN}"
echo "  公钥 pbk  : ${PUB}"
echo "  short_id  : ${SID}"
echo "  flow      : xtls-rprx-vision"
echo "  指纹 fp   : chrome"
echo "  名称      : ${V_NAME}"
echo "  ${VLINK}"
echo "------------------------------------------------------------"
if [ "$ENABLE_HY2" = 1 ]; then
echo "[2] Hysteria2 (QUIC/UDP)  ← 速度最快（已开启混淆 + QUIC 调优）"
echo "  端口      : ${HY2_PORT} (UDP)"
echo "  密码      : ${HY2_PASS}"
echo "  SNI       : ${REALITY_DOMAIN} (客户端 insecure=1)"
echo "  混淆      : $([ "$ENABLE_HY2_OBFS" = 1 ] && echo "${HY2_OBFS_TYPE} / ${OBFS_PASS}" || echo "关闭")"
echo "  名称      : ${H_NAME}"
echo "  ${HLINK}"
echo "------------------------------------------------------------"
fi
if [ "$ENABLE_SS" = 1 ]; then
echo "[3] Shadowsocks-2022 (TCP+UDP)  ← 轻量备用"
echo "  端口      : ${SS_PORT}"
echo "  加密      : 2022-blake3-aes-128-gcm"
echo "  密钥(64) : ${SS_PASS}"
echo "  ${SLINK}"
echo "------------------------------------------------------------"
fi
if [ "$ENABLE_TUIC" = 1 ]; then
echo "[4] TUIC v5 (QUIC/UDP)"
echo "  端口      : ${TUIC_PORT} (UDP)"
echo "  UUID      : ${TUIC_UUID}"
echo "  密码      : ${TUIC_PASS}"
echo "  ${TLINK}"
echo "------------------------------------------------------------"
fi
echo "订阅(base64，可整段粘进 v2rayN / Clash.Meta 的订阅输入框)："
echo "${SUB}"
echo
echo "管理：sb info | sb sub | sb qr | sb status | sb restart | sb log | sb uninstall"
} > /root/sing-box-info.txt

printf '%s' "$LINKS" > /root/sing-box-sub.txt

gen_qr

# ---------- 终端直接打印二维码（手机对着屏幕扫）----------
if [ "${ENABLE_QR}" = 1 ] && command -v qrencode >/dev/null 2>&1; then
  for it in "${QR_ITEMS[@]}"; do
    f="${it%%|*}"; t="${it#*|}"
    echo; echo -e "${C}===== 二维码 ${f}（小火箭 / NekoRay / NekoBox 扫码）=====${N}"
    qrencode -t ANSIUTF8 -m 2 -s 1 "$t" 2>/dev/null || true
  done
  echo; echo -e "${C}提示：${N}上面二维码若不好扫，可用浏览器打开 ${QR_DIR}/index.html 或下载 PNG。"
fi

# ---------- 管理命令 ----------
cat > /etc/sing-box/genqr.sh <<'GQEOF'
#!/usr/bin/env bash
f=/root/sing-box-sub.txt; d=/root/sing-box-qr
command -v qrencode >/dev/null 2>&1 || { echo "请先安装 qrencode"; exit 1; }
mkdir -p "$d"; n=0
while IFS= read -r line; do
  [ -n "$line" ] || continue; n=$((n+1))
  echo; echo "===== 节点 $n 二维码 ====="
  qrencode -t ANSIUTF8 -m 2 -s 1 "$line" || true
  qrencode -o "$d/node-$n.png" -s 6 -m 2 "$line" || true
done < "$f"
echo; echo "PNG 已保存到 $d"
GQEOF
chmod +x /etc/sing-box/genqr.sh

cat > /usr/local/bin/sb <<'SBEOF'
#!/usr/bin/env bash
case "${1:-info}" in
  info|i)    cat /root/sing-box-info.txt ;;
  sub)       cat /root/sing-box-sub.txt ;;
  url)       cat /root/sing-box-sub-url.txt 2>/dev/null || echo "未开启订阅服务（安装时设 ENABLE_SUB_SERVER=1）" ;;
  qr|q)      bash /etc/sing-box/genqr.sh ;;
  status|s)  systemctl status sing-box --no-pager -l | head -20 ;;
  restart|r) systemctl restart sing-box && echo "sing-box restarted" ;;
  stop)      systemctl stop sing-box && echo "stopped" ;;
  start)     systemctl start sing-box && echo "started" ;;
  log|l)     journalctl -u sing-box -n 100 --no-pager ;;
  uninstall) bash /etc/sing-box/uninstall.sh ;;
  *) echo "usage: sb {info|sub|url|qr|status|restart|stop|start|log|uninstall}" ;;
esac
SBEOF
chmod +x /usr/local/bin/sb

cat > /etc/sing-box/uninstall.sh <<'ULEOF'
#!/usr/bin/env bash
systemctl stop sing-box 2>/dev/null
systemctl disable sing-box 2>/dev/null
systemctl stop sb-sub 2>/dev/null
systemctl disable sb-sub 2>/dev/null
rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/sb-sub.service
systemctl daemon-reload 2>/dev/null
rm -rf /etc/sing-box /usr/local/bin/sb /root/sing-box-info.txt /root/sing-box-sub.txt /root/sing-box-sub-url.txt /root/sing-box-qr
echo "已卸载 sing-box 及配置。"
ULEOF
chmod +x /etc/sing-box/uninstall.sh

echo
echo -e "${B}================= 安装完成 =================${N}"
echo -e "${C}服务器IP :${N} ${HOST}"
echo -e "${C}归属地   :${N} ${GEO_LOC:-未知}  ${FLAG} ${COUNTRY_CN}${TAG}"
echo -e "${C}内核     :${N} $("$SB" version 2>/dev/null | head -1)"
[ -n "$SUB_URL" ] && echo -e "${C}订阅地址 :${N} ${SUB_URL}"
echo -e "${C}二维码   :${N} ${QR_DIR}/"
echo
echo -e "${G}[1] VLESS-Vision-REALITY (TCP/${LISTEN_PORT})  最稳${N}  ${V_NAME}"
echo -e "${Y}${VLINK}${N}"
if [ "$ENABLE_HY2" = 1 ]; then
  echo
  echo -e "${G}[2] Hysteria2 (UDP/${HY2_PORT})  最快（混淆+调优）${N}  ${H_NAME}"
  echo -e "${Y}${HLINK}${N}"
fi
if [ "$ENABLE_SS" = 1 ]; then
  echo
  echo -e "${G}[3] Shadowsocks-2022 (${SS_PORT})  备用${N}  ${S_NAME}"
  echo -e "${Y}${SLINK}${N}"
fi
if [ "$ENABLE_TUIC" = 1 ]; then
  echo
  echo -e "${G}[4] TUIC v5 (UDP/${TUIC_PORT})${N}  ${T_NAME}"
  echo -e "${Y}${TLINK}${N}"
fi
echo
echo -e "${C}客户端提速建议（很重要，链接无法携带这些参数）：${N}"
echo -e "  · Hysteria2 带宽：在客户端把「上行/下行」填成你真实网速（如 100/500 Mbps），"
echo -e "    才会启用 Brutal 拥塞控制（弱网最快）；填太高会丢包，太低会跑不满。"
echo -e "  · 若某网站图片/视频仍慢，多为运营商 UDP QoS：本项目已默认开启混淆；"
echo -e "    仍不行就切上面的 REALITY(TCP) 节点，TCP 一般不被 QoS。"
echo -e "  · 手机端可把 MTU 设为 1200~1250 规避路径 MTU 黑洞。"
echo
ok "信息已存 /root/sing-box-info.txt ；命令 sb 可管理（sb qr 重新出二维码，sb url 看订阅地址）。"
warn "别忘了在云厂商安全组放行：TCP ${LISTEN_PORT}、UDP ${HY2_PORT}$( [ "$ENABLE_SS" = 1 ] && printf '、TCP+UDP %s' "$SS_PORT" )$( [ "$ENABLE_TUIC" = 1 ] && printf '、UDP %s' "$TUIC_PORT" )$( [ -n "$SUB_URL" ] && printf '、TCP %s(订阅)' "$(printf '%s' "$SUB_URL" | sed -E 's#.*:([0-9]+)/.*#\1#')" )。"