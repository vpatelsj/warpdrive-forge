#!/usr/bin/env bash
# Train with a warm cache — data is already cached from a prior run.
# Run AFTER 01_train_cold.sh (do NOT clear the cache between runs).
set -euo pipefail

REPO_DIR=$(cd -- "$(dirname "$0")/.." && pwd)
BIN_PATH=${BIN_PATH:-"$REPO_DIR/bin/warpdrive-forge"}
LOG_DIR="$REPO_DIR/demo/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/warm.log"

if [[ ! -x "$BIN_PATH" ]]; then
  echo "Building warpdrive-forge binary..."
  (cd "$REPO_DIR" && go build -o bin/warpdrive-forge ./cmd/warpdrive-forge)
fi

echo "=== Warm-cache training (cache populated from prior run) ==="
"$BIN_PATH" \
  -config "$REPO_DIR/configs/demo.yaml" \
  -train-root-a /wd/datasets-cac/train \
  -train-root-b /wd/datasets-wus3/train \
  -steps 200 \
  -batch-size 16 \
  -num-workers 4 \
  -seed 42 \
  -log-every 50 2>&1 | tee "$LOG_FILE"

echo "=== Warm-cache log saved to $LOG_FILE ==="
echo ""
echo "Compare cold vs warm:"
echo "  Cold: $(grep images_per_sec $LOG_DIR/cold.log | tail -1)"
echo "  Warm: $(grep images_per_sec $LOG_FILE | tail -1)"
