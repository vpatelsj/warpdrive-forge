#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# 05-run.sh — WarpDrive Showcase
#
# Demonstrates WarpDrive's key capabilities through a
# multi-phase training workload:
#
#   Phase 1: Cross-region data fabric  (unified namespace)
#   Phase 2: Cold-cache training       (first touch, all misses)
#   Phase 3: Warm-cache training       (repeat, all hits)
#   Phase 4: Comparison & governance   (side-by-side results)
#
# Run ON the VM after 03-vm-setup.sh and 04-gen-warpdrive-config.sh.
# ──────────────────────────────────────────────────────────────
set -euo pipefail

# ── Configuration ────────────────────────────────────────────
WARPDRIVE_DIR="${WARPDRIVE_DIR:-$HOME/warpdrive}"
FORGE_DIR="${FORGE_DIR:-$HOME/warpdrive-forge}"
CONFIG_PATH="${CONFIG_PATH:-/etc/warpdrive/config.yaml}"
WD_MOUNT_POINT="${WD_MOUNT_POINT:-/wd}"
METRICS_URL="http://localhost:9090/metrics"

MOUNT_BIN="$WARPDRIVE_DIR/bin/warpdrive-mount"
CTL_BIN="$WARPDRIVE_DIR/bin/warpdrive-ctl"
FORGE_BIN="$FORGE_DIR/bin/warpdrive-forge"

TRAIN_STEPS="${TRAIN_STEPS:-300}"
TRAIN_BATCH="${TRAIN_BATCH:-32}"
TRAIN_WORKERS="${TRAIN_WORKERS:-8}"

# ── Colors ───────────────────────────────────────────────────
BOLD='\033[1m'
CYAN='\033[36m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
DIM='\033[2m'
RESET='\033[0m'

banner() {
  echo ""
  echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${RESET}"
  echo -e "${BOLD}${CYAN}  $1${RESET}"
  echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${RESET}"
  echo ""
}

info()   { echo -e "${GREEN}  ▸${RESET} $1"; }
dim()    { echo -e "${DIM}    $1${RESET}"; }
metric() { printf "  ${YELLOW}%-24s${RESET} %s\n" "$1" "$2"; }
hr()     { echo -e "${DIM}  ─────────────────────────────────────────────────────${RESET}"; }

# ── Metric Helpers ───────────────────────────────────────────
grab_metric() {
  # Grab a Prometheus gauge/counter value by full metric line prefix.
  # Usage: grab_metric 'warpdrive_fuse_operations_total{operation="read"}'
  local pattern="$1"
  curl -s "$METRICS_URL" 2>/dev/null | grep "^${pattern}" | head -1 | awk '{print $2}'
}

grab_histogram_count() {
  curl -s "$METRICS_URL" 2>/dev/null | grep "^${1}_count" | head -1 | awk '{print $2}'
}

grab_histogram_sum() {
  curl -s "$METRICS_URL" 2>/dev/null | grep "^${1}_sum" | head -1 | awk '{print $2}'
}

safe_val() { echo "${1:-0}"; }

snapshot_warpdrive() {
  # Capture a named snapshot of WarpDrive Prometheus metrics.
  # Usage: snapshot_warpdrive BEFORE
  local pfx="$1"
  eval "${pfx}_FUSE_READS=$(safe_val "$(grab_metric 'warpdrive_fuse_operations_total{operation="read"}')")"
  eval "${pfx}_CACHE_HITS=$(safe_val "$(grab_metric 'warpdrive_cache_hit_total')")"
  eval "${pfx}_CACHE_MISSES=$(safe_val "$(grab_metric 'warpdrive_cache_miss_total')")"
  eval "${pfx}_BYTES_BACKEND=$(safe_val "$(grab_metric 'warpdrive_backend_bytes_read_total')")"
  # per-backend bytes if available
  eval "${pfx}_BYTES_CAC=$(safe_val "$(grab_metric 'warpdrive_backend_bytes_read_total{backend="datasets-cac"}')")"
  eval "${pfx}_BYTES_WUS=$(safe_val "$(grab_metric 'warpdrive_backend_bytes_read_total{backend="datasets-wus3"}')")"
}

delta() { echo "$1 $2" | awk '{printf "%.0f", $1 - $2}'; }
delta_f() { echo "$1 $2" | awk '{printf "%.6f", $1 - $2}'; }
bytes_to_gb() { echo "$1" | awk '{printf "%.2f", $1 / 1073741824}'; }
pct() {
  local a="$1" b="$2"
  if [[ "$b" == "0" ]] || [[ -z "$b" ]]; then echo "N/A"; return; fi
  echo "$a $b" | awk '{printf "%.1f%%", ($1/$2)*100}'
}

# Extract the last reported value from training logs
extract_ips()     { grep 'images_per_sec' "$1" | tail -1 | sed 's/.*images_per_sec=\([^ ]*\).*/\1/'; }
extract_data_ms() { grep 'data_ms'        "$1" | tail -1 | sed 's/.*data_ms=\([^ ]*\).*/\1/'; }

# ── Training wrapper ─────────────────────────────────────────
run_training() {
  "$FORGE_BIN" \
    -config "$FORGE_DIR/configs/demo.yaml" \
    -train-root-a "$WD_MOUNT_POINT/datasets-cac/train" \
    -train-root-b "$WD_MOUNT_POINT/datasets-wus3/train" \
    -steps "$TRAIN_STEPS" \
    -batch-size "$TRAIN_BATCH" \
    -num-workers "$TRAIN_WORKERS" \
    -seed 42 \
    -log-every 50 2>&1
}

# ── Preflight checks ────────────────────────────────────────
for bin in "$MOUNT_BIN" "$FORGE_BIN"; do
  if [[ ! -x "$bin" ]]; then
    echo -e "${RED}ERROR:${RESET} $bin not found. Run infra/03-vm-setup.sh first."
    exit 1
  fi
done

# ══════════════════════════════════════════════════════════════
banner "WarpDrive Showcase — warpdrive-forge"
# ══════════════════════════════════════════════════════════════

echo -e "  This demo shows how ${BOLD}WarpDrive${RESET} turns multi-region cloud"
echo -e "  storage into a local POSIX filesystem, with transparent"
echo -e "  caching that accelerates repeated data access."
echo ""
echo -e "  ${DIM}Training: $TRAIN_STEPS steps · batch=$TRAIN_BATCH · workers=$TRAIN_WORKERS${RESET}"
echo -e "  ${DIM}Config  : $CONFIG_PATH${RESET}"



# ┌────────────────────────────────────────────────────────────
# │ PHASE 1 — CROSS-REGION DATA FABRIC
# └────────────────────────────────────────────────────────────
banner "Phase 1 — Cross-Region Data Fabric"

info "Cleaning up stale mounts …"
sudo umount -l "$WD_MOUNT_POINT" 2>/dev/null || \
  sudo fusermount -uz "$WD_MOUNT_POINT" 2>/dev/null || true
sudo pkill -f warpdrive-mount 2>/dev/null || true
sleep 1

# Clear the local cache for a true cold start
WD_CACHE_DIR="${WD_CACHE_DIR:-/mnt/nvme/warpdrive-cache}"
if [[ -d "$WD_CACHE_DIR" ]]; then
  info "Clearing cache at $WD_CACHE_DIR for clean cold start …"
  sudo rm -rf "$WD_CACHE_DIR"
fi
mkdir -p "$WD_CACHE_DIR"

info "Starting WarpDrive FUSE mount …"
sudo "$MOUNT_BIN" -config "$CONFIG_PATH" > /tmp/warpdrive.log 2>&1 &
MOUNT_PID=$!
dim "PID $MOUNT_PID"

READY=false
for i in $(seq 1 30); do
  if mount | grep -q "$WD_MOUNT_POINT" && ls "$WD_MOUNT_POINT/" &>/dev/null; then
    READY=true; break
  fi
  sleep 1
done
if [[ "$READY" != "true" ]]; then
  echo -e "${RED}ERROR:${RESET} mount not ready within 30 s"
  tail -20 /tmp/warpdrive.log
  kill "$MOUNT_PID" 2>/dev/null || true
  exit 1
fi

info "Mount ready at ${BOLD}$WD_MOUNT_POINT${RESET}"
echo ""

echo -e "  ${BOLD}Feature: Unified Namespace${RESET}"
echo -e "  Two Azure Blob Storage backends appear as directories"
echo -e "  under a single FUSE mount point:\n"

echo -e "  ${BOLD}/wd/${RESET}"
for backend in $(ls "$WD_MOUNT_POINT/"); do
  shard_count=$(ls "$WD_MOUNT_POINT/$backend/train/" 2>/dev/null | wc -l | tr -d ' ')
  shards=$(ls "$WD_MOUNT_POINT/$backend/train/" 2>/dev/null | head -3 | tr '\n' ', ' | sed 's/,$//')
  echo -e "   ├── ${BOLD}${backend}/${RESET}"
  echo -e "   │   └── train/  ${DIM}($shard_count shards: $shards …)${RESET}"
done

echo ""
info "Auth: Managed Identity (Entra ID) — zero secrets in config"
echo ""
echo -e "  ${BOLD}Key insight:${RESET} The training code uses plain POSIX paths like"
echo -e "  ${DIM}/wd/datasets-cac/train/shard-000000.tar${RESET}"
echo -e "  No Azure SDK, no credentials, no cloud-specific code."
echo ""



# ┌────────────────────────────────────────────────────────────
# │ PHASE 2 — COLD-CACHE TRAINING
# └────────────────────────────────────────────────────────────
banner "Phase 2 — Cold-Cache Training (every read is a miss)"

echo -e "  Cache is empty. Every byte must be fetched from Azure"
echo -e "  Blob Storage across two regions."
echo ""
hr

snapshot_warpdrive COLD_A
COLD_T0=$(date +%s%N)

run_training | tee /tmp/forge-cold.log

COLD_T1=$(date +%s%N)
snapshot_warpdrive COLD_B

COLD_MS=$(( (COLD_T1 - COLD_T0) / 1000000 ))
COLD_FUSE=$(delta "$COLD_B_FUSE_READS" "$COLD_A_FUSE_READS")
COLD_HIT=$(delta  "$COLD_B_CACHE_HITS"   "$COLD_A_CACHE_HITS")
COLD_MISS=$(delta "$COLD_B_CACHE_MISSES" "$COLD_A_CACHE_MISSES")
COLD_TOTAL_RQ=$(( COLD_HIT + COLD_MISS ))
COLD_HIT_PCT=$(pct "$COLD_HIT" "$COLD_TOTAL_RQ")
COLD_GB_CAC=$(bytes_to_gb "$(delta "$COLD_B_BYTES_CAC" "$COLD_A_BYTES_CAC")")
COLD_GB_WUS=$(bytes_to_gb "$(delta "$COLD_B_BYTES_WUS" "$COLD_A_BYTES_WUS")")

COLD_IPS=$(extract_ips /tmp/forge-cold.log)
COLD_DATA_MS=$(extract_data_ms /tmp/forge-cold.log)

hr
echo ""
echo -e "  ${BOLD}Cold-Cache Results${RESET}"
metric "Wall time"            "${COLD_MS} ms"
metric "Throughput"           "${COLD_IPS:-N/A} images/sec"
metric "Avg data load"       "${COLD_DATA_MS:-N/A} ms/step"
metric "FUSE reads"          "$COLD_FUSE"
metric "Cache hits / misses" "$COLD_HIT / $COLD_MISS  ($COLD_HIT_PCT hit)"
metric "Fetched (CAC)"       "${COLD_GB_CAC} GB"
metric "Fetched (WUS3)"      "${COLD_GB_WUS} GB"
echo ""



# ┌────────────────────────────────────────────────────────────
# │ PHASE 3 — WARM-CACHE TRAINING
# └────────────────────────────────────────────────────────────
banner "Phase 3 — Warm-Cache Training (everything is cached)"

echo -e "  Same workload, same data. But WarpDrive already cached"
echo -e "  every shard during Phase 2. Watch the difference."
echo ""
hr

snapshot_warpdrive WARM_A
WARM_T0=$(date +%s%N)

run_training | tee /tmp/forge-warm.log

WARM_T1=$(date +%s%N)
snapshot_warpdrive WARM_B

WARM_MS=$(( (WARM_T1 - WARM_T0) / 1000000 ))
WARM_FUSE=$(delta "$WARM_B_FUSE_READS" "$WARM_A_FUSE_READS")
WARM_HIT=$(delta  "$WARM_B_CACHE_HITS"   "$WARM_A_CACHE_HITS")
WARM_MISS=$(delta "$WARM_B_CACHE_MISSES" "$WARM_A_CACHE_MISSES")
WARM_TOTAL_RQ=$(( WARM_HIT + WARM_MISS ))
WARM_HIT_PCT=$(pct "$WARM_HIT" "$WARM_TOTAL_RQ")
WARM_GB_CAC=$(bytes_to_gb "$(delta "$WARM_B_BYTES_CAC" "$WARM_A_BYTES_CAC")")
WARM_GB_WUS=$(bytes_to_gb "$(delta "$WARM_B_BYTES_WUS" "$WARM_A_BYTES_WUS")")

WARM_IPS=$(extract_ips /tmp/forge-warm.log)
WARM_DATA_MS=$(extract_data_ms /tmp/forge-warm.log)

hr
echo ""
echo -e "  ${BOLD}Warm-Cache Results${RESET}"
metric "Wall time"            "${WARM_MS} ms"
metric "Throughput"           "${WARM_IPS:-N/A} images/sec"
metric "Avg data load"       "${WARM_DATA_MS:-N/A} ms/step"
metric "FUSE reads"          "$WARM_FUSE"
metric "Cache hits / misses" "$WARM_HIT / $WARM_MISS  ($WARM_HIT_PCT hit)"
metric "Fetched (CAC)"       "${WARM_GB_CAC} GB"
metric "Fetched (WUS3)"      "${WARM_GB_WUS} GB"
echo ""



# ┌────────────────────────────────────────────────────────────
# │ PHASE 4 — COMPARISON & GOVERNANCE
# └────────────────────────────────────────────────────────────
banner "Phase 4 — Results Comparison"

echo -e "  ${BOLD}Cold Cache  vs  Warm Cache${RESET}\n"

printf "  ${BOLD}%-26s  %14s  %14s  %10s${RESET}\n" "Metric" "Cold" "Warm" "Δ"
echo -e "  ${DIM}──────────────────────────  ──────────────  ──────────────  ──────────${RESET}"

# Wall time
if (( WARM_MS > 0 )); then
  TIME_DELTA=$(echo "$COLD_MS $WARM_MS" | awk '{printf "%.1fx", $1/$2}')
else
  TIME_DELTA="N/A"
fi
printf "  %-26s  %12s ms  %12s ms  %10s\n" "Wall time" "$COLD_MS" "$WARM_MS" "$TIME_DELTA"

# Throughput
if [[ -n "${COLD_IPS:-}" && -n "${WARM_IPS:-}" ]]; then
  IPS_DELTA=$(echo "$WARM_IPS $COLD_IPS" | awk '{if($2>0) printf "%.1fx",$1/$2; else print "—"}')
  printf "  %-26s  %10s/sec  %10s/sec  %10s\n" "Throughput (images)" "$COLD_IPS" "$WARM_IPS" "$IPS_DELTA"
fi

# Data load time
if [[ -n "${COLD_DATA_MS:-}" && -n "${WARM_DATA_MS:-}" ]]; then
  DATA_DELTA=$(echo "$COLD_DATA_MS $WARM_DATA_MS" | awk '{if($2>0) printf "%.1fx",$1/$2; else print "—"}')
  printf "  %-26s  %11s ms  %11s ms  %10s\n" "Avg data load / step" "$COLD_DATA_MS" "$WARM_DATA_MS" "$DATA_DELTA"
fi

# Cache
printf "  %-26s  %14s  %14s\n" "Cache hit rate" "$COLD_HIT_PCT" "$WARM_HIT_PCT"
printf "  %-26s  %14s  %14s\n" "Cache hits" "$COLD_HIT" "$WARM_HIT"
printf "  %-26s  %14s  %14s\n" "Cache misses" "$COLD_MISS" "$WARM_MISS"

# Backend
COLD_TOTAL_GB=$(echo "$COLD_GB_CAC $COLD_GB_WUS" | awk '{printf "%.2f", $1+$2}')
WARM_TOTAL_GB=$(echo "$WARM_GB_CAC $WARM_GB_WUS" | awk '{printf "%.2f", $1+$2}')
printf "  %-26s  %11s GB  %11s GB\n" "Backend data fetched" "$COLD_TOTAL_GB" "$WARM_TOTAL_GB"

echo ""



# ── Governance ───────────────────────────────────────────────
banner "WarpDrive Observability & Governance"

# ─────────────────────────  PROMETHEUS DASHBOARD  ─────────────────────────
echo -e "  ${BOLD}┌─ Prometheus Metrics Dashboard  (http://localhost:9090/metrics)${RESET}"
echo -e "  ${BOLD}│${RESET}"

# FUSE operations breakdown
echo -e "  ${BOLD}│  FUSE Operations${RESET}"
FUSE_READS=$(safe_val "$(grab_metric 'warpdrive_fuse_operations_total{operation="read"}')")
FUSE_LOOKUPS=$(safe_val "$(grab_metric 'warpdrive_fuse_operations_total{operation="lookup"}')")
FUSE_READDIRS=$(safe_val "$(grab_metric 'warpdrive_fuse_operations_total{operation="readdir"}')")
echo -e "  ${BOLD}│${RESET}    ${YELLOW}read${RESET}    $FUSE_READS        ${YELLOW}lookup${RESET}  $FUSE_LOOKUPS        ${YELLOW}readdir${RESET}  $FUSE_READDIRS"

# FUSE latency distribution
echo -e "  ${BOLD}│${RESET}"
echo -e "  ${BOLD}│  FUSE Read Latency Histogram${RESET}"
FUSE_DUR_SUM=$(safe_val "$(grab_histogram_sum 'warpdrive_fuse_operation_duration_seconds{operation="read"')")
FUSE_DUR_COUNT=$(safe_val "$(grab_histogram_count 'warpdrive_fuse_operation_duration_seconds{operation="read"')")
if (( $(echo "$FUSE_DUR_COUNT > 0" | bc -l 2>/dev/null || echo 0) )); then
  FUSE_MEAN_US=$(echo "$FUSE_DUR_SUM $FUSE_DUR_COUNT" | awk '{printf "%.0f", ($1/$2)*1000000}')
else
  FUSE_MEAN_US="0"
fi
# Parse histogram buckets for a visual bar chart
HIST_100us=$(safe_val "$(curl -s "$METRICS_URL" 2>/dev/null | grep 'warpdrive_fuse_operation_duration_seconds_bucket{operation="read",le="0.0001"}' | awk '{print $2}')")
HIST_500us=$(safe_val "$(curl -s "$METRICS_URL" 2>/dev/null | grep 'warpdrive_fuse_operation_duration_seconds_bucket{operation="read",le="0.0005"}' | awk '{print $2}')")
HIST_1ms=$(safe_val "$(curl -s "$METRICS_URL" 2>/dev/null | grep 'warpdrive_fuse_operation_duration_seconds_bucket{operation="read",le="0.001"}' | awk '{print $2}')")
HIST_5ms=$(safe_val "$(curl -s "$METRICS_URL" 2>/dev/null | grep 'warpdrive_fuse_operation_duration_seconds_bucket{operation="read",le="0.005"}' | awk '{print $2}')")
HIST_10ms=$(safe_val "$(curl -s "$METRICS_URL" 2>/dev/null | grep 'warpdrive_fuse_operation_duration_seconds_bucket{operation="read",le="0.01"}' | awk '{print $2}')")
HIST_50ms=$(safe_val "$(curl -s "$METRICS_URL" 2>/dev/null | grep 'warpdrive_fuse_operation_duration_seconds_bucket{operation="read",le="0.05"}' | awk '{print $2}')")
HIST_INF=$(safe_val "$(curl -s "$METRICS_URL" 2>/dev/null | grep 'warpdrive_fuse_operation_duration_seconds_bucket{operation="read",le="+Inf"}' | awk '{print $2}')")

bar_chart() {
  local val=$1 total=$2 label=$3 width=30
  if [[ "$total" == "0" ]] || [[ -z "$total" ]]; then
    printf "  │    %-8s │%${width}s│ %s\n" "$label" "" "0"
    return
  fi
  local filled=$(echo "$val $total $width" | awk '{if($2>0) printf "%.0f", ($1/$2)*$3; else print 0}')
  local bar=""
  for ((i=0; i<filled; i++)); do bar+="█"; done
  for ((i=filled; i<width; i++)); do bar+=" "; done
  printf "  ${BOLD}│${RESET}    ${DIM}%-8s${RESET} │${GREEN}%-${width}s${RESET}│ %s\n" "$label" "$bar" "$val"
}

bar_chart "$HIST_100us" "$HIST_INF" "≤100μs"
bar_chart "$(echo "$HIST_500us $HIST_100us" | awk '{print $1-$2}')" "$HIST_INF" "≤500μs"
bar_chart "$(echo "$HIST_1ms $HIST_500us" | awk '{print $1-$2}')" "$HIST_INF" "≤1ms"
bar_chart "$(echo "$HIST_5ms $HIST_1ms" | awk '{print $1-$2}')" "$HIST_INF" "≤5ms"
bar_chart "$(echo "$HIST_50ms $HIST_5ms" | awk '{print $1-$2}')" "$HIST_INF" "≤50ms"
bar_chart "$(echo "$HIST_INF $HIST_50ms" | awk '{print $1-$2}')" "$HIST_INF" ">50ms"
echo -e "  ${BOLD}│${RESET}    ${DIM}Mean: ${FUSE_MEAN_US} μs across $FUSE_DUR_COUNT reads${RESET}"

# Cache statistics
echo -e "  ${BOLD}│${RESET}"
echo -e "  ${BOLD}│  Cache${RESET}"
CACHE_HITS=$(safe_val "$(grab_metric 'warpdrive_cache_hit_total')")
CACHE_MISSES=$(safe_val "$(grab_metric 'warpdrive_cache_miss_total')")
CACHE_EVICTIONS=$(safe_val "$(grab_metric 'warpdrive_cache_evictions_total')")
CACHE_SIZE=$(safe_val "$(grab_metric 'warpdrive_cache_size_bytes')")
CACHE_UTIL=$(safe_val "$(grab_metric 'warpdrive_cache_utilization_ratio')")
CACHE_SIZE_MB=$(echo "$CACHE_SIZE" | awk '{printf "%.1f", $1/1048576}')
CACHE_UTIL_PCT=$(echo "$CACHE_UTIL" | awk '{printf "%.1f%%", $1*100}')
CACHE_TOTAL=$((CACHE_HITS + CACHE_MISSES))
if (( CACHE_TOTAL > 0 )); then
  CACHE_HIT_PCT=$(echo "$CACHE_HITS $CACHE_TOTAL" | awk '{printf "%.1f%%", ($1/$2)*100}')
else
  CACHE_HIT_PCT="N/A"
fi
echo -e "  ${BOLD}│${RESET}    ${YELLOW}hits${RESET}  $CACHE_HITS   ${YELLOW}misses${RESET}  $CACHE_MISSES   ${YELLOW}evictions${RESET}  $CACHE_EVICTIONS"
echo -e "  ${BOLD}│${RESET}    ${YELLOW}hit rate${RESET}  $CACHE_HIT_PCT        ${YELLOW}cache used${RESET}  ${CACHE_SIZE_MB} MB ($CACHE_UTIL_PCT)"

# Readahead
echo -e "  ${BOLD}│${RESET}"
echo -e "  ${BOLD}│  Readahead${RESET}"
RA_HIT=$(safe_val "$(grab_metric 'warpdrive_readahead_hit_total')")
RA_WASTE=$(safe_val "$(grab_metric 'warpdrive_readahead_wasted_total')")
echo -e "  ${BOLD}│${RESET}    ${YELLOW}prefetch hits${RESET}  $RA_HIT        ${YELLOW}wasted${RESET}  $RA_WASTE"

# Backend
echo -e "  ${BOLD}│${RESET}"
echo -e "  ${BOLD}│  Backend I/O${RESET}"
BE_BYTES=$(safe_val "$(grab_metric 'warpdrive_backend_bytes_read_total{backend=""}')")
BE_ERRORS=$(safe_val "$(grab_metric 'warpdrive_backend_errors_total{backend="",error_type="io"}')")
BE_BYTES_MB=$(echo "$BE_BYTES" | awk '{printf "%.1f", $1/1048576}')
BE_DUR_COUNT=$(safe_val "$(grab_histogram_count 'warpdrive_backend_request_duration_seconds{backend="",operation="read"')")
echo -e "  ${BOLD}│${RESET}    ${YELLOW}bytes fetched${RESET}  ${BE_BYTES_MB} MB   ${YELLOW}requests${RESET}  $BE_DUR_COUNT   ${YELLOW}errors${RESET}  $BE_ERRORS"

# Auth
echo -e "  ${BOLD}│${RESET}"
echo -e "  ${BOLD}│  Auth${RESET}"
AUTH_OK=$(safe_val "$(grab_metric 'warpdrive_auth_refresh_total{provider="",status="success"}')")
echo -e "  ${BOLD}│${RESET}    ${YELLOW}credential refreshes${RESET}  $AUTH_OK  (managed identity / Entra ID)"

echo -e "  ${BOLD}│${RESET}"
echo -e "  ${BOLD}└──────────────────────────────────────────────────────────────${RESET}"
echo ""

echo -e "  ${DIM}Full Prometheus endpoint is scrapable by Grafana, Datadog, etc.${RESET}"
echo -e "  ${DIM}$ curl -s http://localhost:9090/metrics | grep warpdrive${RESET}"
echo ""



# ── Cleanup & post-unmount governance ────────────────────────
banner "Data Governance (warpdrive-ctl)"

echo -e "  Unmounting WarpDrive to release cache lock for governance …"
sudo umount "$WD_MOUNT_POINT" 2>/dev/null || \
  sudo fusermount -uz "$WD_MOUNT_POINT" 2>/dev/null || true
wait "$MOUNT_PID" 2>/dev/null || true
sleep 1
info "WarpDrive unmounted."
echo ""

if [[ -x "$CTL_BIN" ]]; then
  for cmd in stats usage stale; do
    echo -e "  ${BOLD}\$ warpdrive-ctl $cmd -config $CONFIG_PATH${RESET}"
    hr
    sudo "$CTL_BIN" "$cmd" -config "$CONFIG_PATH" 2>&1 \
      | grep -v "^$" | grep -v "^warpdrive-ctl" | sed 's/^/    /' \
      || dim "(no output)"
    echo ""
  done

  echo -e "  ${BOLD}Other available commands:${RESET}"
  echo -e "    ${YELLOW}warpdrive-ctl warm${RESET}    Pre-populate cache for a path"
  echo -e "    ${YELLOW}warpdrive-ctl quota${RESET}   Manage per-team storage quotas"
  echo -e "    ${YELLOW}warpdrive-ctl move${RESET}    Move/copy data between backends"
  echo -e "    ${YELLOW}warpdrive-ctl status${RESET}  Show mount + control-plane health"
  echo -e "    ${YELLOW}warpdrive-ctl serve${RESET}   Start the control-plane server"
  echo ""
fi



# ── Summary ──────────────────────────────────────────────────
banner "Capabilities Demonstrated"

cat <<EOF
  ✓  Cross-Region Data Fabric
     Two Azure regions (Canada Central + West US 3) accessible
     under a single FUSE mount at /wd.

  ✓  Transparent NVMe Caching
     Cold run: ${COLD_MISS} cache misses, fetched ${COLD_TOTAL_GB} GB from blob.
     Warm run: ${WARM_HIT_PCT} cache hit rate — near-zero backend I/O.

  ✓  Zero-Code Cloud Access
     Training reads plain POSIX paths. Zero Azure SDK calls.
     Switch cloud providers by changing WarpDrive config only.

  ✓  Managed-Identity Auth
     Credentials auto-resolved via Entra ID. No secrets stored.

  ✓  Prometheus Observability
     Real-time metrics at :9090 — FUSE ops, cache stats,
     backend bytes, latency histograms, auth events.

  ✓  Data Governance (warpdrive-ctl)
     status, usage, quota, stale, warm — manage cached data
     across hybrid and multi-cloud storage.
EOF

echo ""



info "Showcase complete."
echo ""