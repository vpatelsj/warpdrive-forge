#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# 03-vm-setup.sh
# Run this ON the Azure VM (ssh azureuser@<vm-ip>).
# Installs all dependencies and builds WarpDrive + warpdrive-forge.
# ──────────────────────────────────────────────────────────────
set -euo pipefail

echo "==> Updating packages..."
sudo apt-get update -qq
sudo apt-get install -y -qq fuse3 libfuse3-dev git curl build-essential

# ── Install Go (>= 1.24 for WarpDrive) ───────────────────────
GO_VERSION="${GO_VERSION:-1.24.4}"
if ! command -v go &>/dev/null || [[ "$(go version)" != *"$GO_VERSION"* ]]; then
  echo "==> Installing Go $GO_VERSION..."
  curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" \
    | sudo tar -C /usr/local -xz
  echo 'export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin' >> ~/.bashrc
  export PATH="$PATH:/usr/local/go/bin:$HOME/go/bin"
fi
echo "    Go: $(go version)"

# ── Enable FUSE allow_other ──────────────────────────────────
if ! grep -q "^user_allow_other" /etc/fuse.conf 2>/dev/null; then
  echo "==> Enabling user_allow_other in /etc/fuse.conf"
  echo "user_allow_other" | sudo tee -a /etc/fuse.conf >/dev/null
fi

# ── Clone & build WarpDrive ──────────────────────────────────
WARPDRIVE_DIR="$HOME/warpdrive"
WARPDRIVE_REPO="${WARPDRIVE_REPO:-https://github.com/vpatelsj/WarpDrive.git}"

if [[ ! -d "$WARPDRIVE_DIR" ]]; then
  echo "==> Cloning WarpDrive..."
  git clone "$WARPDRIVE_REPO" "$WARPDRIVE_DIR"
else
  echo "==> Updating WarpDrive..."
  cd "$WARPDRIVE_DIR" && git pull --ff-only
fi

echo "==> Building WarpDrive..."
cd "$WARPDRIVE_DIR"
make build
echo "    warpdrive-mount: $(ls -lh bin/warpdrive-mount | awk '{print $5}')"
echo "    warpdrive-ctl  : $(ls -lh bin/warpdrive-ctl   | awk '{print $5}')"

# ── Clone & build warpdrive-forge ────────────────────────────
FORGE_DIR="$HOME/warpdrive-forge"
FORGE_REPO="${FORGE_REPO:-}"

if [[ -n "$FORGE_REPO" && ! -d "$FORGE_DIR" ]]; then
  echo "==> Cloning warpdrive-forge..."
  git clone "$FORGE_REPO" "$FORGE_DIR"
elif [[ -d "$FORGE_DIR" ]]; then
  echo "==> warpdrive-forge already present at $FORGE_DIR"
else
  echo "NOTE: Set FORGE_REPO to auto-clone, or scp the repo to $FORGE_DIR"
fi

if [[ -d "$FORGE_DIR" ]]; then
  echo "==> Building warpdrive-forge..."
  cd "$FORGE_DIR"
  mkdir -p bin
  go build -o bin/warpdrive-forge ./cmd/warpdrive-forge
  echo "    warpdrive-forge: $(ls -lh bin/warpdrive-forge | awk '{print $5}')"
fi

# ── Create the WarpDrive mount point ─────────────────────────
WD_MOUNT_POINT="${WD_MOUNT_POINT:-/wd}"
sudo mkdir -p "$WD_MOUNT_POINT"
sudo chown "$(whoami)" "$WD_MOUNT_POINT"

# ── Create cache directory ───────────────────────────────────
WD_CACHE_DIR="${WD_CACHE_DIR:-/tmp/warpdrive-cache}"
mkdir -p "$WD_CACHE_DIR"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  VM setup complete!                                      ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Go           : $(go version | awk '{print $3}')"
echo "║  FUSE         : $(fusermount3 --version 2>&1 | head -1)"
echo "║  WarpDrive    : $WARPDRIVE_DIR/bin/"
echo "║  Forge        : $FORGE_DIR/bin/warpdrive-forge"
echo "║  Mount point  : $WD_MOUNT_POINT"
echo "║  Cache dir    : $WD_CACHE_DIR"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "Next: generate the WarpDrive config, then run ./infra/05-run.sh"
