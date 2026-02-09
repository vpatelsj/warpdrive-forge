#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# 01-provision.sh
# Provisions all Azure resources needed for warpdrive-forge:
#   • Resource group
#   • Two storage accounts (canadacentral + westus3)
#   • Blob containers in each
#   • A Linux VM with a system-assigned managed identity
#   • Role assignments so the VM can read from both accounts
# ──────────────────────────────────────────────────────────────
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname "$0")" && pwd)
source "$SCRIPT_DIR/00-env.sh"

echo "==> Checking Azure CLI login..."
if ! az account show &>/dev/null; then
  echo "Not logged in. Running 'az login'..."
  az login
fi
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
echo "    Subscription: $SUBSCRIPTION_ID"

# ── Resource Group ────────────────────────────────────────────
echo "==> Creating resource group: $RESOURCE_GROUP"
az group create \
  --name "$RESOURCE_GROUP" \
  --location "$LOCATION_A" \
  --output none

# ── Storage Account A (canadacentral – even shards) ──────────
echo "==> Creating storage account A: $STORAGE_ACCOUNT_A ($LOCATION_A)"
az storage account create \
  --name "$STORAGE_ACCOUNT_A" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION_A" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false \
  --output none

echo "    Creating container: $CONTAINER_NAME"
az storage container create \
  --name "$CONTAINER_NAME" \
  --account-name "$STORAGE_ACCOUNT_A" \
  --auth-mode login \
  --output none

# ── Storage Account B (westus3 – odd shards) ─────────────────
echo "==> Creating storage account B: $STORAGE_ACCOUNT_B ($LOCATION_B)"
az storage account create \
  --name "$STORAGE_ACCOUNT_B" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION_B" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false \
  --output none

echo "    Creating container: $CONTAINER_NAME"
az storage container create \
  --name "$CONTAINER_NAME" \
  --account-name "$STORAGE_ACCOUNT_B" \
  --auth-mode login \
  --output none

# ── Virtual Machine ──────────────────────────────────────────
echo "==> Creating VM: $VM_NAME ($VM_SIZE) in $LOCATION_A"
az vm create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --image "$VM_IMAGE" \
  --size "$VM_SIZE" \
  --admin-username "$ADMIN_USER" \
  --generate-ssh-keys \
  --assign-identity '[system]' \
  --output none

VM_PRINCIPAL_ID=$(az vm show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --query identity.principalId -o tsv)
echo "    VM principal ID: $VM_PRINCIPAL_ID"

# ── Role assignments (VM: Contributor for upload+read, Current user: Contributor) ─
BLOB_CONTRIBUTOR_ROLE="Storage Blob Data Contributor"
CURRENT_USER_ID=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)

for ACCT in "$STORAGE_ACCOUNT_A" "$STORAGE_ACCOUNT_B"; do
  SCOPE=$(az storage account show \
    --name "$ACCT" \
    --resource-group "$RESOURCE_GROUP" \
    --query id -o tsv)

  echo "==> Assigning '$BLOB_CONTRIBUTOR_ROLE' on $ACCT to VM (read + upload)"
  az role assignment create \
    --assignee-object-id "$VM_PRINCIPAL_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "$BLOB_CONTRIBUTOR_ROLE" \
    --scope "$SCOPE" \
    --output none

  if [[ -n "$CURRENT_USER_ID" ]]; then
    echo "==> Assigning '$BLOB_CONTRIBUTOR_ROLE' on $ACCT to current user"
    az role assignment create \
      --assignee-object-id "$CURRENT_USER_ID" \
      --assignee-principal-type User \
      --role "$BLOB_CONTRIBUTOR_ROLE" \
      --scope "$SCOPE" \
      --output none
  fi
done

# ── Summary ──────────────────────────────────────────────────
VM_IP=$(az vm show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --show-details \
  --query publicIps -o tsv)

cat <<EOF

╔══════════════════════════════════════════════════════════╗
║  Provisioning complete!                                  ║
╠══════════════════════════════════════════════════════════╣
║  Resource group : $RESOURCE_GROUP
║  Storage A      : $STORAGE_ACCOUNT_A ($LOCATION_A)
║  Storage B      : $STORAGE_ACCOUNT_B ($LOCATION_B)
║  Container      : $CONTAINER_NAME
║  VM             : $VM_NAME
║  VM public IP   : $VM_IP
║  SSH            : ssh $ADMIN_USER@$VM_IP
╚══════════════════════════════════════════════════════════╝

Next steps:
  1. SSH into VM:     ssh $ADMIN_USER@$VM_IP
  2. Run VM setup:    ./infra/03-vm-setup.sh   (on the VM)
  3. Gen dataset:     ./infra/02-gen-dataset.sh (on the VM — fast Azure-internal upload)
  4. Gen WD config:   ./infra/04-gen-warpdrive-config.sh (on the VM)
  5. Run showcase:    ./infra/05-run.sh         (on the VM)
EOF

# Persist dynamic names for other scripts
cat > "$SCRIPT_DIR/.env.generated" <<EOF
export STORAGE_ACCOUNT_A="$STORAGE_ACCOUNT_A"
export STORAGE_ACCOUNT_B="$STORAGE_ACCOUNT_B"
export VM_IP="$VM_IP"
export VM_PRINCIPAL_ID="$VM_PRINCIPAL_ID"
EOF
echo "(saved to infra/.env.generated)"
