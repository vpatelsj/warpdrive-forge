#!/usr/bin/env bash
# Train with a cold cache — all reads go to Azure Blob Storage.
# Run AFTER clearing the WarpDrive cache (rm -rf /tmp/warpdrive-cache).
set -euo pipefail

REPO_DIR=$(cd -- "$(dirname "$0")/.." && pwd)
BIN_PATH=${BIN_PATH:-"$REPO_DIR/bin/warpdrive-forge"}
LOG_DIR="$REPO_DIR/demo/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/cold.log"

if [[ ! -x "$BIN_PATH" ]]; then
  echo "Building warpdrive-forge binary..."
  (cd "$REPO_DIR" && go build -o bin/warpdrive-forge ./cmd/warpdrive-forge)
fi

echo "=== Cold-cache training ==="
"$BIN_PATH" \
  -config "$REPO_DIR/configs/demo.yaml" \
  -train-root-a /wd/datasets-cac/train \
  -train-root-b /wd/datasets-wus3/train \
  -steps 200 \
  -batch-size 16 \
  -num-workers 4 \
  -seed 42 \
  -log-every 50 2>&1 | tee "$LOG_FILE"

echo "=== Cold-cache log saved to $LOG_FILE ==="
