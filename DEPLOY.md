# WarpDrive Forge — End-to-End Deployment Guide

This guide walks through provisioning Azure infrastructure, generating a
synthetic dataset, installing [WarpDrive](https://github.com/vpatelsj/WarpDrive)
on a VM, and running the warpdrive-forge training workload — all from scratch.

**Time estimate:** ~20 minutes (mostly waiting for Azure provisioning)

---

## Prerequisites

| Requirement | Details |
|-------------|---------|
| **Azure CLI** | `>= 2.50` — install with `brew install azure-cli` (macOS) |
| **Azure subscription** | Permissions to create resource groups, storage accounts, VMs, and role assignments |
| **Python 3** | For synthetic dataset generation (`Pillow` recommended: `pip install Pillow`) |
| **SSH key** | `~/.ssh/id_rsa.pub` (the provisioning script uses `--generate-ssh-keys`) |

Verify you're ready:

```bash
az version          # ≥ 2.50
python3 --version   # ≥ 3.8
```

---

## Step 1 — Provision Azure Infrastructure

**Run from:** your laptop

```bash
cd warpdrive-forge
./infra/01-provision.sh
```

This creates:

| Resource | Details |
|----------|---------|
| Resource group | `warpdrive-forge-rg` |
| Storage account A | Canada Central — will hold **even-numbered** shards |
| Storage account B | West US 3 — will hold **odd-numbered** shards |
| Blob container | `coco2017-wds` in both accounts |
| VM | `warpdrive-forge-vm` — Ubuntu 24.04, `Standard_D4s_v5`, system-assigned managed identity |
| RBAC | `Storage Blob Data Reader` on both storage accounts for the VM |

At the end, the script prints the VM's public IP and saves dynamic values to
`infra/.env.generated`. Note the **storage account names** and **VM IP** — you'll
need them later.

> **Cost note:** `Standard_D4s_v5` costs ~$0.19/hr. Remember to tear down when
> done (Step 7).

### Customisation

Override any default before running:

```bash
export VM_SIZE=Standard_D8s_v5    # bigger VM
export LOCATION_A=eastus          # different region
./infra/01-provision.sh
```

All configurable variables are in `infra/00-env.sh`.

---

## Step 2 — Generate & Upload Synthetic Dataset

**Run from:** your laptop

```bash
./infra/02-gen-dataset.sh
```

This:
1. Generates 20 WebDataset TAR shards (each containing 100 synthetic JPEG +
   label pairs matching the `shard-NNNNNN.tar` / `XXXXXXXX.jpg` + `XXXXXXXX.cls`
   format expected by `internal/dataset`)
2. Uploads **even shards** (`shard-000000.tar`, `shard-000002.tar`, …) → Canada Central
3. Uploads **odd shards** (`shard-000001.tar`, `shard-000003.tar`, …) → West US 3

Customize shard count or image size:

```bash
export NUM_SHARDS=50
export IMAGES_PER_SHARD=200
./infra/02-gen-dataset.sh
```

### Verify uploads

```bash
# Even shards in Canada Central
az storage blob list \
  --account-name "$STORAGE_ACCOUNT_A" \
  --container-name coco2017-wds \
  --prefix train/ \
  --auth-mode login \
  --output table

# Odd shards in West US 3
az storage blob list \
  --account-name "$STORAGE_ACCOUNT_B" \
  --container-name coco2017-wds \
  --prefix train/ \
  --auth-mode login \
  --output table
```

---

## Step 3 — Set Up the VM

**Run from:** the Azure VM

```bash
# SSH into the VM (IP was printed in Step 1)
ssh azureuser@<VM_IP>
```

Copy the repo to the VM. You can `scp`, `git clone`, or use VS Code Remote-SSH:

```bash
# Option A: scp from your laptop
scp -r warpdrive-forge azureuser@<VM_IP>:~/warpdrive-forge

# Option B: clone (if pushed to a remote)
git clone <your-repo-url> ~/warpdrive-forge
```

Then run the setup script:

```bash
cd ~/warpdrive-forge
./infra/03-vm-setup.sh
```

This installs:
- **Go 1.24.4** (required by WarpDrive)
- **fuse3 / libfuse3-dev** (FUSE kernel support)
- Clones and builds [WarpDrive](https://github.com/vpatelsj/WarpDrive) → `~/warpdrive/bin/warpdrive-mount`, `~/warpdrive/bin/warpdrive-ctl`
- Builds warpdrive-forge → `~/warpdrive-forge/warpdrive-forge`
- Creates mount point at `/wd` and cache directory

Expected output at the end:

```
╔══════════════════════════════════════════════════════════╗
║  VM setup complete!                                      ║
╠══════════════════════════════════════════════════════════╣
║  Go           : go1.24.4
║  FUSE         : fusermount3 version 3.x.x
║  WarpDrive    : /home/azureuser/warpdrive/bin/
║  Forge        : /home/azureuser/warpdrive-forge/warpdrive-forge
║  Mount point  : /wd
║  Cache dir    : /tmp/warpdrive-cache
╚══════════════════════════════════════════════════════════╝
```

---

## Step 4 — Generate WarpDrive Config

**Run from:** the Azure VM

Pass in the storage account names from Step 1:

```bash
export STORAGE_ACCOUNT_A="<canadacentral account name from Step 1>"
export STORAGE_ACCOUNT_B="<westus3 account name from Step 1>"
./infra/04-gen-warpdrive-config.sh
```

This writes `/etc/warpdrive/config.yaml` with:

```yaml
mount_point: /wd
allow_other: true

cache:
  path: /tmp/warpdrive-cache
  max_size: 50GB
  block_size: 4MB
  readahead_blocks: 8
  max_parallel_fetch: 32

backends:
  - name: datasets-cac          # Canada Central
    type: azureblob
    mount_path: /datasets-cac
    config:
      account: <STORAGE_ACCOUNT_A>
      container: coco2017-wds
    auth:
      method: managed_identity   # Uses the VM's system-assigned identity

  - name: datasets-wus3         # West US 3
    type: azureblob
    mount_path: /datasets-wus3
    config:
      account: <STORAGE_ACCOUNT_B>
      container: coco2017-wds
    auth:
      method: managed_identity
```

After mounting, the POSIX paths will be:
- `/wd/datasets-cac/train/shard-000000.tar` (even shards)
- `/wd/datasets-wus3/train/shard-000001.tar` (odd shards)

These match exactly what `configs/demo.yaml` and the demo scripts expect.

---

## Step 5 — Run the Training Workload

**Run from:** the Azure VM

```bash
./infra/05-run.sh
```

This orchestrates the full pipeline:

1. **Starts WarpDrive** — `warpdrive-mount` creates a FUSE filesystem at `/wd`,
   presenting both Azure Blob backends as local directories
2. **Warms the cache** — `warpdrive-ctl warm` pre-fetches all shard blocks
   to local NVMe/disk so the first training epoch is fast
3. **Runs warpdrive-forge** — 2000 training steps, batch size 64, 8 data
   loader workers, reading paired `.jpg`/`.cls` files from TAR shards through
   the WarpDrive POSIX mount
4. **Unmounts** cleanly on completion

### Expected output

```
==> Starting WarpDrive FUSE mount...
    warpdrive-mount PID: 12345
    Mount ready.
==> Mount contents:
datasets-cac  datasets-wus3
    Canada Central shards:
shard-000000.tar  shard-000002.tar  shard-000004.tar  ...
    West US 3 shards:
shard-000001.tar  shard-000003.tar  shard-000005.tar  ...
==> Warming cache (datasets-cac)...
    Done: Cache warming complete in 2.3s
==> Warming cache (datasets-wus3)...
    Done: Cache warming complete in 2.1s
==> Starting warpdrive-forge training...
step=100  images_per_sec=920.4  data_ms=12.50  compute_ms=8.10  loss=1.8324
step=200  images_per_sec=1042.1 data_ms=3.20   compute_ms=7.90  loss=1.6512
...
step=2000 images_per_sec=1105.3 data_ms=2.10   compute_ms=7.80  loss=0.9841
==> Training complete. Unmounting WarpDrive...
Done.
```

Key things to observe:
- **`data_ms` drops significantly** after warmup (cache hits vs. cold fetches)
- **`images_per_sec` increases** as the WarpDrive cache warms up
- Both regions' shards are consumed seamlessly through a single POSIX interface

---

## Step 6 — Monitor WarpDrive Metrics (Optional)

In a **separate SSH session** while training is running:

```bash
./demo/03_watch_warpdrive_metrics.sh
```

This scrapes `http://localhost:9090/metrics` every 5 seconds and shows:

```
---- 2026-02-08T10:30:00Z ----
warpdrive_cache_hit_total 48231
warpdrive_cache_miss_total 412
warpdrive_cache_size_bytes 419430400
warpdrive_backend_request_duration_seconds_bucket{backend="datasets-cac",...}
warpdrive_readahead_hit_total 3842
```

You can also run cold vs. warm comparison:

```bash
# Terminal 1: Cold run (first touch)
./demo/01_train_cold.sh

# Terminal 2: Warm run (cache populated)
./demo/02_train_warm.sh

# Compare:
diff demo/logs/cold.log demo/logs/warm.log
```

---

## Step 7 — Tear Down

**Run from:** your laptop

```bash
./infra/06-teardown.sh
```

This deletes the entire `warpdrive-forge-rg` resource group and all resources
within it (VM, storage accounts, networking, disks).

---

## Architecture Diagram

```
┌──────────────────────────────────────────────────────────┐
│                    Azure VM (Ubuntu 24.04)                │
│                                                          │
│  ┌────────────────────┐    ┌──────────────────────────┐  │
│  │  warpdrive-forge    │    │  warpdrive-mount (FUSE)  │  │
│  │  (Go training loop) │    │                          │  │
│  │                     │    │  /wd/                    │  │
│  │  POSIX read() ──────┼───►│  ├─ datasets-cac/train/ │  │
│  │  on /wd/...         │    │  │  └─ shard-000000.tar  │  │
│  │                     │    │  │  └─ shard-000002.tar  │  │
│  │                     │    │  └─ datasets-wus3/train/ │  │
│  │                     │    │     └─ shard-000001.tar  │  │
│  │                     │    │     └─ shard-000003.tar  │  │
│  └─────────────────────┘    └──────────┬───────────────┘  │
│                                        │                  │
│                              ┌─────────▼────────────┐     │
│                              │  NVMe Block Cache     │     │
│                              │  (4 MB blocks, LRU)   │     │
│                              └─────────┬────────────┘     │
│                                        │                  │
│                    ┌───────────────────┴──────────────┐   │
│                    │ Managed Identity (auto-refresh)  │   │
│                    └───────────────────┬──────────────┘   │
└────────────────────────────────────────┼──────────────────┘
                     ┌───────────────────┴──────────────┐
                     │                                  │
          ┌──────────▼──────────┐           ┌──────────▼──────────┐
          │  Azure Blob Storage  │           │  Azure Blob Storage  │
          │  Canada Central      │           │  West US 3           │
          │  (even shards)       │           │  (odd shards)        │
          └─────────────────────┘           └─────────────────────┘
```

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `az login` fails | Make sure Azure CLI is installed: `brew install azure-cli` |
| VM can't read blobs | Check RBAC: `az role assignment list --assignee <VM_PRINCIPAL_ID>` — should show `Storage Blob Data Reader` on both accounts |
| WarpDrive mount fails | Verify fuse3 is installed: `fusermount3 --version`. Check `/etc/fuse.conf` has `user_allow_other` |
| No shards discovered | Check paths: `ls /wd/datasets-cac/train/` — should show `shard-*.tar` files. If empty, verify WarpDrive config account/container names |
| Permission denied on mount | WarpDrive mount requires `sudo` for `allow_other` FUSE option |
| `warpdrive-mount` exits immediately | Check logs: `sudo journalctl -u warpdrive-agent` or run in foreground for debug output |
| `images_per_sec` very low | Check if cache is warming: `curl -s localhost:9090/metrics \| grep cache_hit`. If miss rate is high, run `warpdrive-ctl warm` first |
| Python has no Pillow | `pip install Pillow` — the dataset generator falls back to minimal JPEG without it, but Pillow produces more realistic images |
