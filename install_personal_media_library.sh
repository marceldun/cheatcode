#!/usr/bin/env bash
set -Eeuo pipefail
if [ "$(id -u)" -ne 0 ]; then echo "请用root用户运行，或在命令前使用sudo。"; exit 1; fi
need=""
for c in curl unzip openssl; do command -v "$c" >/dev/null 2>&1 || need=yes; done
if [ -n "$need" ]; then
  if command -v apt-get >/dev/null 2>&1; then apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y curl unzip openssl ca-certificates;
  elif command -v dnf >/dev/null 2>&1; then dnf install -y curl unzip openssl ca-certificates;
  elif command -v yum >/dev/null 2>&1; then yum install -y curl unzip openssl ca-certificates;
  else echo "无法自动安装curl、unzip、openssl。"; exit 1; fi
fi
url="https://raw.githubusercontent.com/marceldun/cheatcode/main/Personal_Media_Library_Auto_Cover_v1.zip"
expected="92dee80001716c666bf47abb45409cec82cc9e6da4c8e7b8bc347c57238496bf"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
echo "正在下载并校验完整安装包……"
curl -fL --retry 5 --retry-all-errors --connect-timeout 15 "$url" -o "$tmp/package.zip"
echo "$expected  $tmp/package.zip" | sha256sum -c -
mkdir "$tmp/unpack"; unzip -q "$tmp/package.zip" -d "$tmp/unpack"
src="$(find "$tmp/unpack" -mindepth 1 -maxdepth 1 -type d | head -n1)"; [ -n "$src" ] || { echo "安装包结构错误。"; exit 1; }
target="/opt/personal-media-library"; oldenv=""
if [ -f "$target/.env" ]; then oldenv="$tmp/existing.env"; cp "$target/.env" "$oldenv"; fi
rm -rf "$target"; mkdir -p "$(dirname "$target")"; mv "$src" "$target"
[ -n "$oldenv" ] && cp "$oldenv" "$target/.env"
cd "$target"; exec bash ./一键部署到VPS.sh
