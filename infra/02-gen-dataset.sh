#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# 02-gen-dataset.sh
# Generates synthetic COCO-style WebDataset shards and uploads
# them to the two Azure storage accounts.
#
# ▸ Run this ON THE VM (not locally) so uploads are fast
#   (Azure-internal ~10 Gbps vs your home internet).
#
#   • Even-numbered shards → storage account A (canadacentral)
#   • Odd-numbered shards  → storage account B (westus3)
#
# Each shard is a TAR containing paired <key>.jpg + <key>.cls
# files, matching the format expected by internal/dataset.
#
# Prerequisites:
#   - Azure CLI installed (03-vm-setup.sh installs it)
#   - VM managed identity has Storage Blob Data Contributor
#     on both storage accounts (01-provision.sh assigns it)
#   - .env.generated exists with STORAGE_ACCOUNT_A/B values
# ──────────────────────────────────────────────────────────────
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname "$0")" && pwd)
source "$SCRIPT_DIR/00-env.sh"
[[ -f "$SCRIPT_DIR/.env.generated" ]] && source "$SCRIPT_DIR/.env.generated"

# ── Validate storage account names ───────────────────────────
if [[ -z "${STORAGE_ACCOUNT_A:-}" || -z "${STORAGE_ACCOUNT_B:-}" ]]; then
  echo "ERROR: STORAGE_ACCOUNT_A and STORAGE_ACCOUNT_B must be set."
  echo "       Source .env.generated or export them manually."
  exit 1
fi

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
echo "==> Working directory: $WORK_DIR"

# ── Auth: try managed identity, fall back to account keys ────
echo "==> Authenticating..."
AUTH_MODE="key"
if az login --identity --allow-no-subscriptions &>/dev/null; then
  echo "    Using managed identity (Entra ID)"
  AUTH_MODE="identity"
else
  echo "    Managed identity unavailable — falling back to account keys"
fi

if [[ "$AUTH_MODE" == "key" ]]; then
  KEY_A=$(az storage account keys list \
    --account-name "$STORAGE_ACCOUNT_A" \
    --resource-group "${RESOURCE_GROUP:-warpdrive-forge-rg}" \
    --query '[0].value' -o tsv)
  KEY_B=$(az storage account keys list \
    --account-name "$STORAGE_ACCOUNT_B" \
    --resource-group "${RESOURCE_GROUP:-warpdrive-forge-rg}" \
    --query '[0].value' -o tsv)
fi

# ── Check for Python ─────────────────────────────────────────
if ! command -v python3 &>/dev/null; then
  echo "ERROR: python3 is required. Install it first."
  exit 1
fi

# ── Estimate dataset size ────────────────────────────────────
EST_PER_SHARD=$((IMAGES_PER_SHARD * IMAGE_WIDTH * IMAGE_HEIGHT * 3 / 10))  # rough JPEG estimate
EST_TOTAL=$((NUM_SHARDS * EST_PER_SHARD))
EST_GB=$(echo "$EST_TOTAL" | awk '{printf "%.1f", $1/1073741824}')
echo "==> Dataset: $NUM_SHARDS shards × $IMAGES_PER_SHARD images × ${IMAGE_WIDTH}×${IMAGE_HEIGHT}"
echo "    Estimated total size: ~${EST_GB} GB"
echo ""

# ── Generate shards ──────────────────────────────────────────
echo "==> Generating $NUM_SHARDS shards ($IMAGES_PER_SHARD images each, ${IMAGE_WIDTH}x${IMAGE_HEIGHT})"

python3 - "$WORK_DIR" "$NUM_SHARDS" "$IMAGES_PER_SHARD" \
  "$IMAGE_WIDTH" "$IMAGE_HEIGHT" "$NUM_CLASSES" <<'PYEOF'
import io, os, random, struct, sys, tarfile

work_dir        = sys.argv[1]
num_shards      = int(sys.argv[2])
images_per_shard = int(sys.argv[3])
width           = int(sys.argv[4])
height          = int(sys.argv[5])
num_classes     = int(sys.argv[6])

def make_jpeg_bytes(w, h):
    """Produce a minimal valid JFIF JPEG with random pixel data."""
    # We build a tiny but valid JPEG: SOI + APP0 (JFIF) + DQT + SOF0 + DHT + SOS + raw + EOI
    # For simplicity, we create a 1x1 JPEG and scale via the header so decoders accept it.
    # A more realistic approach: use Pillow if available.
    try:
        from PIL import Image
        img = Image.new("RGB", (w, h))
        pixels = img.load()
        for y in range(h):
            for x in range(w):
                pixels[x, y] = (random.randint(0,255), random.randint(0,255), random.randint(0,255))
        buf = io.BytesIO()
        img.save(buf, format="JPEG", quality=50)
        return buf.getvalue()
    except ImportError:
        pass
    # Fallback: generate a trivially small but valid JPEG via struct
    # SOI
    data = b'\xff\xd8'
    # APP0 JFIF header
    data += b'\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00'
    # DQT (quantization table, all 1s for simplicity)
    dqt = b'\xff\xdb\x00\x43\x00' + bytes(64)
    data += dqt
    # SOF0 baseline, 8-bit, 1x1, 1 component (grayscale)
    data += b'\xff\xc0\x00\x0b\x08\x00\x01\x00\x01\x01\x01\x11\x00'
    # DHT (minimal Huffman table for DC)
    dht = b'\xff\xc4\x00\x1f\x00\x00\x01\x05\x01\x01\x01\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b'
    data += dht
    # SOS
    data += b'\xff\xda\x00\x08\x01\x01\x00\x00\x3f\x00\x7a\x50'
    # EOI
    data += b'\xff\xd9'
    return data

random.seed(42)

for shard_idx in range(num_shards):
    shard_name = f"shard-{shard_idx:06d}.tar"
    shard_path = os.path.join(work_dir, shard_name)
    with tarfile.open(shard_path, "w") as tar:
        for img_idx in range(images_per_shard):
            key = f"{img_idx:08d}"
            # Image
            jpeg_data = make_jpeg_bytes(width, height)
            info_img = tarfile.TarInfo(name=f"{key}.jpg")
            info_img.size = len(jpeg_data)
            tar.addfile(info_img, io.BytesIO(jpeg_data))
            # Label
            label_str = str(random.randint(0, num_classes - 1))
            label_data = label_str.encode()
            info_lbl = tarfile.TarInfo(name=f"{key}.cls")
            info_lbl.size = len(label_data)
            tar.addfile(info_lbl, io.BytesIO(label_data))
    print(f"    {shard_name}  ({os.path.getsize(shard_path)} bytes)")

print(f"Generated {num_shards} shards in {work_dir}")
PYEOF

# ── Upload shards (parallel, with progress) ─────────────────
BLOB_PREFIX="train"

upload_shard() {
  local shard_idx="$1"
  local shard_name
  shard_name=$(printf "shard-%06d.tar" "$shard_idx")
  local shard_path="$WORK_DIR/$shard_name"

  if (( shard_idx % 2 == 0 )); then
    local ACCT="$STORAGE_ACCOUNT_A"
    local REGION="$LOCATION_A"
  else
    local ACCT="$STORAGE_ACCOUNT_B"
    local REGION="$LOCATION_B"
  fi

  local AUTH_ARGS=()
  if [[ "$AUTH_MODE" == "identity" ]]; then
    AUTH_ARGS=(--auth-mode login)
  else
    if (( shard_idx % 2 == 0 )); then
      AUTH_ARGS=(--account-key "$KEY_A")
    else
      AUTH_ARGS=(--account-key "$KEY_B")
    fi
  fi

  az storage blob upload \
    --account-name "$ACCT" \
    "${AUTH_ARGS[@]}" \
    --container-name "$CONTAINER_NAME" \
    --name "$BLOB_PREFIX/$shard_name" \
    --file "$shard_path" \
    --overwrite \
    --output none 2>/dev/null

  local size
  size=$(stat --printf="%s" "$shard_path" 2>/dev/null || stat -f%z "$shard_path" 2>/dev/null)
  local mb
  mb=$(echo "$size" | awk '{printf "%.1f", $1/1048576}')
  echo "    ✓ $shard_name → $ACCT ($REGION) [${mb} MB]"
}
export -f upload_shard
export WORK_DIR STORAGE_ACCOUNT_A STORAGE_ACCOUNT_B LOCATION_A LOCATION_B
export CONTAINER_NAME BLOB_PREFIX AUTH_MODE
export KEY_A KEY_B 2>/dev/null || true

echo "==> Uploading $NUM_SHARDS shards (8 parallel uploads)..."
UPLOAD_START=$(date +%s)

# Upload in parallel batches of 8
for batch_start in $(seq 0 8 $((NUM_SHARDS - 1))); do
  pids=()
  for offset in $(seq 0 7); do
    idx=$((batch_start + offset))
    if (( idx >= NUM_SHARDS )); then break; fi
    upload_shard "$idx" &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do
    wait "$pid" || true
  done
done

UPLOAD_END=$(date +%s)
UPLOAD_DUR=$((UPLOAD_END - UPLOAD_START))

echo ""
echo "==> Dataset upload complete in ${UPLOAD_DUR}s."
echo "    Even shards → $STORAGE_ACCOUNT_A ($LOCATION_A)"
echo "    Odd  shards → $STORAGE_ACCOUNT_B ($LOCATION_B)"
echo "    Blob prefix : $CONTAINER_NAME/$BLOB_PREFIX/"
