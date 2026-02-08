#!/usr/bin/env bash
set -euo pipefail

REPO_DIR=$(cd -- "$(dirname "$0")/.." && pwd)
BIN_PATH=${BIN_PATH:-"$REPO_DIR/warpdrive-forge"}
LOG_DIR="$REPO_DIR/demo/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/warm.log"

if [[ ! -x "$BIN_PATH" ]]; then
  echo "Building warpdrive-forge binary..."
  (cd "$REPO_DIR" && go build -o warpdrive-forge ./cmd/warpdrive-forge)
fi

CMD=("$BIN_PATH" \
  --config "$REPO_DIR/configs/demo.yaml" \
  --train-root-a /wd/datasets-cac/coco2017-wds/train \
  --train-root-b /wd/datasets-wus3/coco2017-wds/train \
  --steps 2000 \
  --batch-size 64 \
  --num-workers 8 \
  --seed 42)

"${CMD[@]}" | tee "$LOG_FILE"
