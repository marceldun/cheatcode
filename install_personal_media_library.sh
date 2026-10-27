#!/usr/bin/env bash
set -Eeuo pipefail
if [ "$(id -u)" -ne 0 ];then echo "请用root用户运行，或使用发布的一键命令。";exit 1;fi
echo "[预处理] 停止旧版循环失败服务并清理Docker缓存……"
systemctl stop personal-media-library.service caddy-library.service >/dev/null 2>&1||true
if command -v docker >/dev/null 2>&1;then
 ids="$(docker ps -aq --filter label=com.docker.compose.project=media-library 2>/dev/null||true)";[ -z "$ids" ]||docker rm -f $ids >/dev/null 2>&1||true
 docker builder prune -af >/dev/null 2>&1||true
 docker image rm media-library-app personal-media-library:test node:24-alpine caddy:2.10-alpine >/dev/null 2>&1||true
 docker image prune -f >/dev/null 2>&1||true
fi
echo "Docker失败缓存清理完成。"
need="";for c in curl unzip openssl python3;do command -v "$c">/dev/null 2>&1||need=yes;done
if [ -n "$need" ];then
 if command -v apt-get>/dev/null;then apt-get update -y&&DEBIAN_FRONTEND=noninteractive apt-get install -y curl unzip openssl ca-certificates python3;
 elif command -v dnf>/dev/null;then dnf install -y curl unzip openssl ca-certificates python3;
 elif command -v yum>/dev/null;then yum install -y curl unzip openssl ca-certificates python3;
 else echo "无法自动安装基础组件。";exit 1;fi
fi
url="https://raw.githubusercontent.com/marceldun/cheatcode/main/Personal_Media_Library_Google_Images_Admin_Requirements_v9.zip"
expected="99e2ac2067c07bc629cc4deab621354e2ba5a56947f178bba2b6b12992e0120d"
tmp="$(mktemp -d)";trap 'rm -rf "$tmp"' EXIT
echo "下载完整v9（约125KB）……";curl -fL --retry 5 --retry-all-errors --connect-timeout 15 "$url" -o "$tmp/package.zip"
echo "$expected  $tmp/package.zip"|sha256sum -c -
mkdir "$tmp/unpack";unzip -q "$tmp/package.zip" -d "$tmp/unpack";src="$(find "$tmp/unpack" -mindepth 1 -maxdepth 1 -type d|head -n1)";[ -n "$src" ]||{ echo "安装包结构错误。";exit 1; }
target=/opt/personal-media-library;oldenv="";if [ -f "$target/.env" ];then oldenv="$tmp/existing.env";cp "$target/.env" "$oldenv";fi
rm -rf "$target";mkdir -p "$(dirname "$target")";mv "$src" "$target";chmod 755 "$target" "$target/app";[ -n "$oldenv" ]&&cp "$oldenv" "$target/.env"
cd "$target";exec bash ./一键部署到VPS.sh
