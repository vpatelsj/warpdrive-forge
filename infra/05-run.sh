#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# 05-run.sh
# Starts WarpDrive, optionally warms the cache, then launches
# the warpdrive-forge training workload.
#
# Run ON the VM after 03-vm-setup.sh and 04-gen-warpdrive-config.sh.
# ──────────────────────────────────────────────────────────────
set -euo pipefail

WARPDRIVE_DIR="${WARPDRIVE_DIR:-$HOME/warpdrive}"
FORGE_DIR="${FORGE_DIR:-$HOME/warpdrive-forge}"
CONFIG_PATH="${CONFIG_PATH:-/etc/warpdrive/config.yaml}"
WD_MOUNT_POINT="${WD_MOUNT_POINT:-/wd}"
SKIP_WARM="${SKIP_WARM:-false}"

MOUNT_BIN="$WARPDRIVE_DIR/bin/warpdrive-mount"
CTL_BIN="$WARPDRIVE_DIR/bin/warpdrive-ctl"
FORGE_BIN="$FORGE_DIR/bin/warpdrive-forge"

for bin in "$MOUNT_BIN" "$FORGE_BIN"; do
  if [[ ! -x "$bin" ]]; then
    echo "ERROR: $bin not found. Run infra/03-vm-setup.sh first."
    exit 1
  fi
done

# ── Cleanup stale mounts ─────────────────────────────────────
echo "==> Cleaning up any stale mounts..."
sudo umount -l "$WD_MOUNT_POINT" 2>/dev/null || sudo fusermount -uz "$WD_MOUNT_POINT" 2>/dev/null || true
sudo pkill -f warpdrive-mount 2>/dev/null || true
sleep 1

# ── Start WarpDrive mount (background) ──────────────────────
echo "==> Starting WarpDrive FUSE mount..."
sudo "$MOUNT_BIN" -config "$CONFIG_PATH" > /tmp/warpdrive.log 2>&1 &
MOUNT_PID=$!
echo "    warpdrive-mount PID: $MOUNT_PID"
echo "    Log: /tmp/warpdrive.log"

# Wait for the mount to become ready
echo "    Waiting for mount at $WD_MOUNT_POINT..."
READY=false
for i in $(seq 1 30); do
  if mount | grep -q "$WD_MOUNT_POINT" && ls "$WD_MOUNT_POINT/" &>/dev/null; then
    READY=true
    break
  fi
  sleep 1
done
if [[ "$READY" != "true" ]]; then
  echo "ERROR: WarpDrive mount did not become ready within 30s."
  kill "$MOUNT_PID" 2>/dev/null || true
  exit 1
fi
echo "    Mount ready."

# ── List discovered paths ────────────────────────────────────
echo "==> Mount contents:"
ls -la "$WD_MOUNT_POINT/"
echo ""
echo "    Canada Central shards:"
ls "$WD_MOUNT_POINT/datasets-cac/train/" 2>/dev/null | head -5 || echo "    (none found)"
echo "    West US 3 shards:"
ls "$WD_MOUNT_POINT/datasets-wus3/train/" 2>/dev/null | head -5 || echo "    (none found)"
echo ""

# ── Optional: warm the cache ────────────────────────────────
if [[ "$SKIP_WARM" != "true" && -x "$CTL_BIN" ]]; then
  echo "==> Warming cache (datasets-cac)..."
  sudo "$CTL_BIN" warm \
    -config "$CONFIG_PATH" \
    -backend datasets-cac \
    -prefix train \
    -recursive \
    -workers 16 || echo "    (warm skipped or partial)"

  echo "==> Warming cache (datasets-wus3)..."
  sudo "$CTL_BIN" warm \
    -config "$CONFIG_PATH" \
    -backend datasets-wus3 \
    -prefix train \
    -recursive \
    -workers 16 || echo "    (warm skipped or partial)"
fi

# ── Run warpdrive-forge training ─────────────────────────────
TRAIN_LOG="/tmp/forge-training.log"
echo ""
echo "==> Starting warpdrive-forge training..."
echo "    Training log: $TRAIN_LOG"
"$FORGE_BIN" \
  -config "$FORGE_DIR/configs/demo.yaml" \
  -train-root-a "$WD_MOUNT_POINT/datasets-cac/train" \
  -train-root-b "$WD_MOUNT_POINT/datasets-wus3/train" \
  -steps 200 \
  -batch-size 16 \
  -num-workers 4 \
  -seed 42 2>&1 | tee "$TRAIN_LOG"

# ── WarpDrive metrics snapshot ───────────────────────────────
echo ""
echo "==> WarpDrive Metrics Snapshot:"
METRICS=$(curl -s http://localhost:9090/metrics 2>/dev/null)
if [[ -n "$METRICS" ]]; then
  echo "    FUSE reads     : $(echo "$METRICS" | grep '^warpdrive_fuse_operations_total{operation="read"}' | awk '{print $2}')"
  echo "    Cache hits     : $(echo "$METRICS" | grep '^warpdrive_cache_hit_total ' | awk '{print $2}')"
  echo "    Cache misses   : $(echo "$METRICS" | grep '^warpdrive_cache_miss_total ' | awk '{print $2}')"
  echo "    Backend CAC GB : $(echo "$METRICS" | grep '^warpdrive_backend_bytes_read_total{backend="datasets-cac"}' | awk '{printf "%.2f", $2/1073741824}')"
  echo "    Backend WUS GB : $(echo "$METRICS" | grep '^warpdrive_backend_bytes_read_total{backend="datasets-wus3"}' | awk '{printf "%.2f", $2/1073741824}')"
  echo "    Backend errors : $(echo "$METRICS" | grep '^warpdrive_backend_errors_total' | awk '{print $2}')"
fi

# ── Cleanup ──────────────────────────────────────────────────
echo ""
echo "==> Training complete. Unmounting WarpDrive..."
sudo umount "$WD_MOUNT_POINT" 2>/dev/null || true
wait "$MOUNT_PID" 2>/dev/null || true
echo "Done."
