# WarpDrive Forge

WarpDrive Forge is a demo workload that shows how WarpDrive can serve globally replicated datasets to training-style jobs. The binary reads COCO-style WebDataset shards from WarpDrive-mounted POSIX paths in canadacentral (even shards) and westus3 (odd shards) simultaneously, exercising cross-region cache coherence without any Azure SDK calls. The training loop is pure Go: WebDataset shard streaming, deterministic multi-root sampling, CPU-only preprocessing, and a tiny SGD classifier that you can later swap for DGX-friendly code with minimal plumbing changes.

## Repo layout
- `cmd/warpdrive-forge/`: CLI entry point and signal handling.
- `internal/config`: strict YAML loader + CLI overrides.
- `internal/dataset`: shard discovery, TAR pairing, and deterministic sampler workers.
- `internal/model`: simple softmax classifier to keep CPU busy.
- `internal/trainer`: end-to-end loop with batching, preprocessing, metrics.
- `internal/metrics`: sliding-window throughput and latency stats.
- `configs/demo.yaml`: canadacentral + westus3 defaults with even/odd shard split.
- `demo/`: ready-to-run scripts for cold cache, warm cache, and WarpDrive metrics tailing.

## Prerequisites

| Component | Version |
|-----------|---------|
| Azure CLI | >= 2.50 |
| Go | >= 1.22 (forge), >= 1.24 (WarpDrive) |
| OS (VM) | Ubuntu 24.04 LTS |
| FUSE | fuse3 / libfuse3-dev (installed by setup script) |
| Python 3 | For synthetic dataset generation (with Pillow recommended) |
| Azure subscription | With permissions to create resource groups, storage accounts, VMs, and role assignments |

## End-to-end deployment

The `infra/` directory contains numbered scripts that provision Azure resources, generate a synthetic dataset, install WarpDrive on a VM, and run the training workload. Run them in order:

### Step 1 — Provision Azure infrastructure (from your laptop)
```bash
# Log in to Azure (if not already)
az login

# Create resource group, two storage accounts (canadacentral + westus3),
# a Linux VM with system-assigned managed identity, and RBAC role assignments.
./infra/01-provision.sh
```
This creates:
- Resource group `warpdrive-forge-rg`
- Storage account in **Canada Central** (even-numbered shards)
- Storage account in **West US 3** (odd-numbered shards)
- Ubuntu 24.04 VM (`Standard_D4s_v5`) with managed identity
- `Storage Blob Data Reader` role on both storage accounts

### Step 2 — Generate & upload synthetic dataset (from your laptop)
```bash
./infra/02-gen-dataset.sh
```
Generates COCO-style WebDataset TAR shards (`.jpg` + `.cls` pairs) and uploads even shards to Canada Central, odd shards to West US 3.

### Step 3 — Set up the VM (on the VM)
```bash
ssh azureuser@<VM_IP>
# Copy the repo to the VM (or clone it)
# Then run:
./infra/03-vm-setup.sh
```
Installs Go 1.24, FUSE, clones and builds [WarpDrive](https://github.com/vpatelsj/WarpDrive), and builds warpdrive-forge.

### Step 4 — Generate WarpDrive config (on the VM)
```bash
export STORAGE_ACCOUNT_A="<canadacentral account name>"
export STORAGE_ACCOUNT_B="<westus3 account name>"
./infra/04-gen-warpdrive-config.sh
```
Writes `/etc/warpdrive/config.yaml` with two `azureblob` backends using managed identity auth, mounting to `/wd/datasets-cac/` and `/wd/datasets-wus3/`.

### Step 5 — Run the training workload (on the VM)
```bash
./infra/05-run.sh
```
This script:
1. Starts `warpdrive-mount` (FUSE) in the background
2. Optionally warms the cache with `warpdrive-ctl warm`
3. Runs `warpdrive-forge` training against the mounted POSIX paths
4. Unmounts cleanly on completion

### Teardown
```bash
./infra/06-teardown.sh   # Deletes the entire resource group
```

## Quick start (on a pre-configured VM)
If WarpDrive is already mounted at `/wd/`:
```bash
go build -o warpdrive-forge ./cmd/warpdrive-forge

# Cold run: first touch of shards through WarpDrive caches
./demo/01_train_cold.sh

# Warm run: repeat to highlight cache hit rates
./demo/02_train_warm.sh

# Tail WarpDrive metrics while runs execute
./demo/03_watch_warpdrive_metrics.sh
```
Each training script records stdout under `demo/logs/{cold,warm}.log` with periodic lines such as:
```
step=100 images_per_sec=920.4 data_ms=12.5 compute_ms=8.1 loss=1.8324
```

## Configuration
- Default CLI flags (and `configs/demo.yaml`) point to `/wd/datasets-cac/coco2017-wds/train` for even-numbered `shard-*.tar` files and `/wd/datasets-wus3/coco2017-wds/train` for odd ones. Add shards at either root whenever WarpDrive ingests more data—the discovery phase re-indexes on every run, so no code change is required.
- Override any flag explicitly, e.g. `./warpdrive-forge --config configs/demo.yaml --steps 500 --batch-size 32`.
- All reads go through POSIX mounts (`/wd/...`). There are zero Azure SDK or cloud API calls in this repo; storage semantics are entirely delegated to [WarpDrive](https://github.com/vpatelsj/WarpDrive).

## Logging & metrics
- The trainer prints throughput, average data loading time, average compute time, and loss every `log_every` steps (default 100). These stats come from the sliding window in `internal/metrics`.
- `demo/03_watch_warpdrive_metrics.sh` continuously curls `http://localhost:9090/metrics` (override via `WARPDRIVE_METRICS_URL`) and filters out cache/backend/fetch/readahead/latency lines for quick health checks.
- For DGX migrations, reuse the same POSIX readers; swap `internal/model/simplecnn.go` with your GPU-backed implementation and the rest of the pipeline stays intact.

## Infra scripts reference

| Script | Where | Description |
|--------|-------|-------------|
| `infra/00-env.sh` | Laptop | Shared environment variables (customizable) |
| `infra/01-provision.sh` | Laptop | Create Azure RG, storage accounts, VM, RBAC |
| `infra/02-gen-dataset.sh` | Laptop | Generate synthetic WebDataset shards & upload |
| `infra/03-vm-setup.sh` | VM | Install Go, FUSE, build WarpDrive + forge |
| `infra/04-gen-warpdrive-config.sh` | VM | Write WarpDrive YAML config |
| `infra/05-run.sh` | VM | Mount WarpDrive, warm cache, run training |
| `infra/06-teardown.sh` | Laptop | Delete all Azure resources |
