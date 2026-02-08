#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# 06-teardown.sh
# Deletes all Azure resources created by 01-provision.sh.
# ──────────────────────────────────────────────────────────────
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname "$0")" && pwd)
source "$SCRIPT_DIR/00-env.sh"
[[ -f "$SCRIPT_DIR/.env.generated" ]] && source "$SCRIPT_DIR/.env.generated"

echo "This will DELETE the resource group '$RESOURCE_GROUP' and ALL resources in it."
read -rp "Are you sure? (yes/no): " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
  echo "Aborted."
  exit 0
fi

echo "==> Deleting resource group: $RESOURCE_GROUP ..."
az group delete \
  --name "$RESOURCE_GROUP" \
  --yes \
  --no-wait

echo "Deletion initiated (runs in background). Resources will be removed shortly."
rm -f "$SCRIPT_DIR/.env.generated"
