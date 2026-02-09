#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# Environment variables for the WarpDrive Forge Azure deployment.
# Source this file before running any other infra script.
# Override any variable before sourcing to customise.
# ──────────────────────────────────────────────────────────────

# ── Azure basics ──────────────────────────────────────────────
export RESOURCE_GROUP="${RESOURCE_GROUP:-warpdrive-forge-rg}"
export LOCATION_A="${LOCATION_A:-canadacentral}"       # even shards
export LOCATION_B="${LOCATION_B:-westus3}"              # odd  shards

# ── Storage accounts (must be globally unique, lowercase, no dashes) ──
export STORAGE_ACCOUNT_A="${STORAGE_ACCOUNT_A:-wdforgedatacac$(openssl rand -hex 3)}"
export STORAGE_ACCOUNT_B="${STORAGE_ACCOUNT_B:-wdforgedatawus$(openssl rand -hex 3)}"
export CONTAINER_NAME="${CONTAINER_NAME:-coco2017-wds}"

# ── VM ────────────────────────────────────────────────────────
export VM_NAME="${VM_NAME:-warpdrive-forge-vm}"
export VM_SIZE="${VM_SIZE:-Standard_L8s_v3}"            # NVMe SSD for WarpDrive cache
export VM_IMAGE="${VM_IMAGE:-Canonical:ubuntu-24_04-lts:server:latest}"
export ADMIN_USER="${ADMIN_USER:-azureuser}"

# ── Dataset ───────────────────────────────────────────────────
export NUM_SHARDS="${NUM_SHARDS:-100}"                   # total shard count (split even/odd)
export IMAGES_PER_SHARD="${IMAGES_PER_SHARD:-500}"      # image–label pairs per shard
export IMAGE_WIDTH="${IMAGE_WIDTH:-224}"
export IMAGE_HEIGHT="${IMAGE_HEIGHT:-224}"
export NUM_CLASSES="${NUM_CLASSES:-10}"

# ── WarpDrive mount paths (as seen on the VM) ────────────────
export WD_MOUNT_POINT="${WD_MOUNT_POINT:-/wd}"
export WD_CACHE_DIR="${WD_CACHE_DIR:-/mnt/nvme/warpdrive-cache}"  # NVMe on L-series VMs

# ── Repo URLs ─────────────────────────────────────────────────
export WARPDRIVE_REPO="${WARPDRIVE_REPO:-https://github.com/vpatelsj/WarpDrive.git}"
export FORGE_REPO="${FORGE_REPO:-https://github.com/YOU/warpdrive-forge.git}"
