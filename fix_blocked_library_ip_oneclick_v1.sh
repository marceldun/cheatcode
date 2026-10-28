#!/usr/bin/env bash
set -Eeuo pipefail
if [ "$(id -u)" -ne 0 ];then echo "请使用root运行。";exit 1;fi
need(){ command -v "$1" >/dev/null 2>&1; }
if ! need curl;then
 if need apt-get;then apt-get update -y&&DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates;
 elif need dnf;then dnf install -y curl ca-certificates;
 elif need yum;then yum install -y curl ca-certificates;
 else echo "无法自动安装curl。";exit 1;fi
fi
echo "[1/6] 定位并修复Library Manager本机服务……"
systemctl restart personal-media-library.service >/dev/null 2>&1||true
port="$(sed -n 's/^PORT=//p' /etc/personal-media-library.env 2>/dev/null|tail -n1)"
[[ "$port" =~ ^[0-9]+$ ]]||port=""
if [ -z "$port" ];then
 for candidate in 80 8080 18080 30080 39080 39081;do curl -fsS --max-time 2 "http://127.0.0.1:$candidate/api/health" >/dev/null 2>&1&&{ port="$candidate";break;};done
fi
[ -n "$port" ]||{ echo "未找到正在运行的Library Manager。请先完成Library Manager安装。";journalctl -u personal-media-library.service -n40 --no-pager 2>/dev/null||true;exit 1;}
curl -fsS --max-time 5 "http://127.0.0.1:$port/api/health" >/dev/null||{ echo "本机网站服务异常。";journalctl -u personal-media-library.service -n60 --no-pager;exit 1;}
echo "[2/6] 下载Cloudflare官方隧道程序……"
case "$(uname -m)" in x86_64)asset=cloudflared-linux-amd64;;aarch64|arm64)asset=cloudflared-linux-arm64;;*)echo "不支持的CPU架构：$(uname -m)";exit 1;;esac
tmp="$(mktemp)";trap 'rm -f "$tmp"' EXIT
curl -fL --retry 8 --retry-all-errors --connect-timeout 15 "https://github.com/cloudflare/cloudflared/releases/latest/download/$asset" -o "$tmp"
chmod 755 "$tmp";"$tmp" --version;install -m755 "$tmp" /usr/local/bin/cloudflared
echo "[3/6] 创建不暴露原IP的HTTPS入口……"
install -d -m755 /var/lib/personal-media-tunnel
cat >/usr/local/sbin/personal-media-tunnel-runner <<RUNNER
#!/usr/bin/env bash
set -o pipefail
rm -f /var/lib/personal-media-tunnel/address.txt
/usr/local/bin/cloudflared tunnel --no-autoupdate --url http://127.0.0.1:$port 2>&1 | while IFS= read -r line;do
 echo "\$line"
 url="\$(printf '%s' "\$line"|sed -n 's#.*\(https://[a-zA-Z0-9-]*\.trycloudflare\.com\).*#\1#p'|head -n1)"
 [ -z "\$url" ]||printf '%s\n' "\$url" >/var/lib/personal-media-tunnel/address.txt
done
RUNNER
chmod 755 /usr/local/sbin/personal-media-tunnel-runner
cat >/etc/systemd/system/personal-media-tunnel.service <<'UNIT'
[Unit]
Description=Blocked IP alternate HTTPS entrance for Personal Media Library
After=network-online.target personal-media-library.service
Wants=network-online.target
[Service]
Type=simple
ExecStart=/usr/local/sbin/personal-media-tunnel-runner
Restart=always
RestartSec=8
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=/var/lib/personal-media-tunnel
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload;systemctl reset-failed personal-media-tunnel.service >/dev/null 2>&1||true;systemctl enable --now personal-media-tunnel.service
echo "[4/6] 等待备用地址生成……"
url=""
for _ in $(seq 1 90);do
 [ -s /var/lib/personal-media-tunnel/address.txt ]&&url="$(cat /var/lib/personal-media-tunnel/address.txt)"
 [ -n "$url" ]&&break
 systemctl is-active --quiet personal-media-tunnel.service||break
 sleep 1
done
if [ -z "$url" ];then echo "备用入口未建立。以下是准确故障日志：";journalctl -u personal-media-tunnel.service -n80 --no-pager;exit 1;fi
echo "[5/6] 真实测试HTTPS入口和网站健康状态……"
ok=""
for _ in $(seq 1 30);do curl -fsS --max-time 15 "$url/api/health"|grep -q '"ok"[[:space:]]*:[[:space:]]*true'&&{ ok=1;break;};sleep 2;done
[ -n "$ok" ]||{ echo "隧道地址已生成但网站健康检查失败。";journalctl -u personal-media-tunnel.service -n80 --no-pager;exit 1;}
printf '%s\n' "$url" >/root/Library_Manager_新地址.txt
echo "[6/6] 验证通过。"
printf '\n新的HTTPS网站地址：%s\n地址已保存：/root/Library_Manager_新地址.txt\n' "$url"
