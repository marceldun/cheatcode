#!/usr/bin/env bash
set -euo pipefail

required=(CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID META_ACCESS_TOKEN META_APP_SECRET META_PHONE_NUMBER_ID OPENAI_API_KEY)
for name in "${required[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required environment value: $name" >&2
    exit 1
  fi
done

export npm_config_cache="${TMPDIR:-/tmp}/npm-cache-whatsapp-v3"
npm ci
npx wrangler deploy

secret_file="${TMPDIR:-/tmp}/whatsapp-v3-secrets-$$.json"
trap 'rm -f "$secret_file"' EXIT
export secret_file
python3 - <<'PY'
import json, os, secrets
names = ["META_ACCESS_TOKEN", "META_APP_SECRET", "META_PHONE_NUMBER_ID", "OPENAI_API_KEY"]
data = {name: os.environ[name] for name in names}
data["META_VERIFY_TOKEN"] = os.environ.get("META_VERIFY_TOKEN") or secrets.token_hex(24)
with open(os.environ["secret_file"], "w", encoding="utf-8") as f:
    json.dump(data, f)
PY
npx wrangler secret bulk "$secret_file"
echo "Deployment and encrypted secret upload completed."
