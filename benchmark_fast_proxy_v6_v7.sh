#!/usr/bin/env bash
set -Eeuo pipefail

[ "$(id -u)" -eq 0 ] || { echo 'run as root' >&2; exit 1; }
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${OUT_DIR:-/tmp/proxy-v6-v7-benchmark}"
CSV="$OUT_DIR/raw.csv"
mkdir -p "$OUT_DIR"
exec > >(tee "$OUT_DIR/benchmark.log") 2>&1
set -x
printf 'version,round,kind,sequence,http,ttfb_s,total_s,speed_Bps\n' >"$CSV"

cleanup(){
  ip netns del hyclient >/dev/null 2>&1 || true
  ip link del veth-srv >/dev/null 2>&1 || true
  pkill -f '/tmp/bench-client-' >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

# 同一台机器上构造固定的250ms RTT、约2%双向累计丢包，避免公网路线每轮变化。
ip netns add hyclient
ip link add veth-srv type veth peer name veth-cli
ip addr add 10.200.0.1/30 dev veth-srv
ip link set veth-srv up
ip link set veth-cli netns hyclient
ip netns exec hyclient ip addr add 10.200.0.2/30 dev veth-cli
ip netns exec hyclient ip link set lo up
ip netns exec hyclient ip link set veth-cli up
modprobe sch_netem >/dev/null 2>&1 || true
tc qdisc add dev veth-srv root netem delay 125ms 10ms loss 1%
ip netns exec hyclient tc qdisc add dev veth-cli root netem delay 125ms 10ms loss 1%
set +x

run_install(){
  local version="$1" script="$ROOT_DIR/install_fast_proxy_v${version}.sh" done_file="/root/sb-fast-v${version}-install.done"
  rm -f "$done_file"
  MEM_KB_OVERRIDE=912384 SB_VERSION=1.14.4 bash "$script" >"$OUT_DIR/install-v${version}.log" 2>&1
  [ -s "$done_file" ] && [ "$(cat "$done_file")" = 0 ]
  for old in v5 v6 v7; do systemctl disable --now "sb-fast-health-${old}.timer" >/dev/null 2>&1 || true; done
  systemctl set-property --runtime sing-box.service CPUQuota=100% MemoryMax=891M >/dev/null
  systemctl is-active --quiet sing-box
}

run_phase(){
  local version="$1" round="$2" port password obfs_json="" client="/tmp/bench-client-v${version}-${round}.json" pid
  port="$(jq -r '.inbounds[]|select(.type=="hysteria2")|.listen_port' /etc/sing-box/config.json)"
  # shellcheck disable=SC1090
  . "/etc/sing-box/fast-v${version}.env"
  password="$HY2_PASSWORD"
  if jq -e '.inbounds[]|select(.type=="hysteria2")|has("obfs")' /etc/sing-box/config.json >/dev/null; then
    local otype opass
    otype="$(jq -r '.inbounds[]|select(.type=="hysteria2")|.obfs.type' /etc/sing-box/config.json)"
    opass="$(jq -r '.inbounds[]|select(.type=="hysteria2")|.obfs.password' /etc/sing-box/config.json)"
    printf -v obfs_json ',"obfs":{"type":"%s","password":"%s"}' "$otype" "$opass"
  fi
  cat >"$client" <<EOF
{"log":{"level":"error"},"inbounds":[{"type":"socks","listen":"127.0.0.1","listen_port":19081}],"outbounds":[{"type":"hysteria2","server":"10.200.0.1","server_port":$port,"password":"$password","tls":{"enabled":true,"server_name":"addons.mozilla.org","insecure":true,"alpn":["h3"]}$obfs_json}]}
EOF
  /etc/sing-box/sing-box check -c "$client"
  ip netns exec hyclient /etc/sing-box/sing-box run -c "$client" >"$OUT_DIR/client-v${version}-${round}.log" 2>&1 & pid=$!
  sleep 3
  measure(){
    local kind="$1" seq="$2" url="$3" max="$4" result
    result="$(ip netns exec hyclient curl --noproxy '' -sS -o /dev/null -w '%{http_code},%{time_starttransfer},%{time_total},%{speed_download}' --socks5-hostname 127.0.0.1:19081 --max-time "$max" "$url" 2>/dev/null || printf '000,0,0,0')"
    printf 'v%s,%s,%s,%s,%s\n' "$version" "$round" "$kind" "$seq" "$result" >>"$CSV"
  }
  local i nonce
  for i in $(seq 1 30); do nonce="${version}-${round}-${i}-$(date +%s%N)"; measure page "$i" "https://www.gstatic.com/generate_204?b=$nonce" 20; done
  for i in $(seq 1 10); do nonce="${version}-${round}-${i}-$(date +%s%N)"; measure startup "$i" "https://speed.cloudflare.com/__down?bytes=1048576&b=$nonce" 30; done
  for i in $(seq 1 5); do nonce="${version}-${round}-${i}-$(date +%s%N)"; measure sustained "$i" "https://speed.cloudflare.com/__down?bytes=33554432&b=$nonce" 120; done
  kill "$pid" >/dev/null 2>&1 || true; wait "$pid" 2>/dev/null || true
  systemctl show sing-box -p MemoryCurrent -p MemoryPeak -p CPUUsageNSec >"$OUT_DIR/resources-v${version}-${round}.txt"
}

# A/B/A/B，抵消测试先后顺序造成的网络偏差。
run_install 6; run_phase 6 1
run_install 7; run_phase 7 1
run_install 6; run_phase 6 2
run_install 7; run_phase 7 2

python3 - "$CSV" "$OUT_DIR/REPORT.txt" <<'PY'
import csv,statistics,sys,glob,re
src,out=sys.argv[1:]
rows=list(csv.DictReader(open(src)))
def pct(a,p):
 a=sorted(a); return a[min(len(a)-1,max(0,int((len(a)-1)*p)))]
lines=['HY2 v6/v7 同机A/B/A/B严谨测试','条件：同一Ubuntu 24临时VPS；CPUQuota=1核；MemoryMax=891MB；sing-box=1.14.4；同一密码/端口/证书；受控250ms RTT、双向各1%丢包。','']
summary={}
for v in ('v6','v7'):
 lines.append(v)
 for kind in ('page','startup','sustained'):
  rs=[r for r in rows if r['version']==v and r['kind']==kind]
  good=[r for r in rs if r['http'] in ('200','204')]
  t=[float(r['ttfb_s']) for r in good]; speed=[float(r['speed_Bps'])*8/1e6 for r in good]
  vals={'success':len(good),'total':len(rs),'ttfb_med':statistics.median(t) if t else 0,'ttfb_p95':pct(t,.95) if t else 0,'speed_med':statistics.median(speed) if speed else 0,'speed_p10':pct(speed,.10) if speed else 0}
  summary[v,kind]=vals
  lines.append(f"  {kind}: 成功 {len(good)}/{len(rs)}；首字节中位数 {vals['ttfb_med']:.3f}s；P95 {vals['ttfb_p95']:.3f}s；速度中位数 {vals['speed_med']:.2f}Mbps；P10 {vals['speed_p10']:.2f}Mbps")
 resources=[]
 for p in glob.glob(f'/tmp/proxy-v6-v7-benchmark/resources-{v}-*.txt'):
  d=dict(x.split('=',1) for x in open(p).read().splitlines() if '=' in x); resources.append(d)
 peaks=[int(x.get('MemoryPeak','0') or 0)/1048576 for x in resources]
 lines.append(f"  服务内存峰值：{max(peaks) if peaks else 0:.1f}MiB")
 lines.append('')
lines.append('相对差异（正数表示v7数值更高）：')
for kind in ('page','startup','sustained'):
 a,b=summary['v6',kind],summary['v7',kind]
 dt=(b['ttfb_med']/a['ttfb_med']-1)*100 if a['ttfb_med'] else 0
 ds=(b['speed_med']/a['speed_med']-1)*100 if a['speed_med'] else 0
 lines.append(f"  {kind}: v7首字节 {dt:+.1f}%；v7速度 {ds:+.1f}%")
lines += ['','边界：该实验比较相同服务器和受控链路下的脚本差异，不是用户所在地到其VPS的实测。公网运营商路由、客户端实现、缓存和目标视频CDN可能改变体感。','原始数据：raw.csv']
open(out,'w').write('\n'.join(lines)+'\n')
print('\n'.join(lines))
PY
