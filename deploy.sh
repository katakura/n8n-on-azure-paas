#!/usr/bin/env bash
# Helper to deploy main.bicep. Secrets (the PostgreSQL administrator password and the n8n encryption key)
# are never stored in the repository or in files (they are passed to Bicep as environment variables).
# By default it runs what-if only. Add --apply to actually create resources.
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 -s <subscription> [-g <resource-group>] [options]

  -s  Subscription ID or name (required)
  -g  Resource group name (default: rg-n8n-paas; created if missing)
  -u  PostgreSQL administrator name (default: n8nadmin)
  -p  PostgreSQL administrator password (if omitted, Bicep derives it from uniqueString)
  -i  Allowed source IP/CIDR, comma-separated (recommended: the owner setup page is open to the first visitor)
  --apply  Deploy for real after what-if
USAGE
  exit 1
}

SUB="" RG="rg-n8n-paas" PG_USER="" PG_PASS="" ALLOW="" APPLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -s) SUB="$2"; shift 2 ;;
    -g) RG="$2"; shift 2 ;;
    -u) PG_USER="$2"; shift 2 ;;
    -p) PG_PASS="$2"; shift 2 ;;
    -i) ALLOW="$2"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    *) usage ;;
  esac
done
[[ -n "$SUB" ]] || usage

cd "$(dirname "$0")"

[[ -n "$PG_USER" ]] && export PG_ADMIN_LOGIN="$PG_USER"
[[ -n "$PG_PASS" ]] && export PG_ADMIN_PASSWORD="$PG_PASS"
export PG_ADMIN_PASSWORD="${PG_ADMIN_PASSWORD:-}"
export ALLOWED_IPS="${ALLOW:-${ALLOWED_IPS:-}}"
[[ -n "$ALLOWED_IPS" ]] || echo "warning: no -i given; n8n is open to the internet until the owner account is created"

# n8n encryption key. The state lives in PostgreSQL and no volume is mounted, so n8n cannot start
# if the key differs from the one the database was created with. Reuse the key of the existing app
# on a redeployment, and generate a new one only on the first deployment.
if [[ -z "${N8N_ENCRYPTION_KEY:-}" ]]; then
  N8N_ENCRYPTION_KEY=$(az containerapp secret show -g "$RG" -n ca-n8n --secret-name encryption-key \
    --subscription "$SUB" --query value -o tsv 2>/dev/null || true)
  if [[ -n "$N8N_ENCRYPTION_KEY" ]]; then
    echo "encryption key: reusing the key of the existing app"
  else
    N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)
    echo "encryption key: generated a new key (first deployment)"
  fi
fi
export N8N_ENCRYPTION_KEY

LOCATION=$(az bicep build-params -f main.bicepparam --stdout | jq -r '.parametersJson | fromjson | .parameters.location.value')
echo "subscription : $SUB"
echo "resource grp : $RG ($LOCATION)"
az group create -n "$RG" -l "$LOCATION" --subscription "$SUB" -o none

args=(-g "$RG" --subscription "$SUB" -p main.bicepparam)
az deployment group what-if "${args[@]}"

if [[ "$APPLY" -eq 1 ]]; then
  az deployment group create "${args[@]}" --query properties.outputs -o json
else
  echo "Ran what-if only. Add --apply to deploy."
fi
