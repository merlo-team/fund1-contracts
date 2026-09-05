#!/usr/bin/env bash
# Generates a fresh deployer key into .env (gitignored) as PRIVATE_KEY and prints only the address.
# Refuses to overwrite an existing .env.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"
[ -e .env ] && { echo ".env already exists — remove it first if you really want a new key" >&2; exit 1; }
json=$(cast wallet new --json)
key=$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["private_key"])')
addr=$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["address"])')
umask 077
printf 'PRIVATE_KEY=%s\n' "$key" > .env
echo "$addr"
