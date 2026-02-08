#!/usr/bin/env bash
set -euo pipefail

URL=${WARPDRIVE_METRICS_URL:-"http://localhost:9090/metrics"}
FILTER=${WARPDRIVE_METRIC_FILTER:-"cache|backend|fetch|readahead|latency"}
DELAY=${SCRAPE_DELAY:-5}

while true; do
  echo "---- $(date -u) ----"
  if curl -fsS "$URL" | grep -Ei "$FILTER"; then
    :
  else
    echo "(no matching metrics or endpoint unavailable)"
  fi
  sleep "$DELAY"
done
