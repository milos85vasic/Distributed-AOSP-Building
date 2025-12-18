#!/bin/bash

set -e

AOSP_DIR="$1"

if [[ -z "$AOSP_DIR" ]]; then
  echo "Usage: $0 <aosp_directory>"
  exit 1
fi

AOSP_DIR=$(realpath "$AOSP_DIR")

if [[ ! -d "$AOSP_DIR/build/soong" ]]; then
  echo "Warning: $AOSP_DIR not valid AOSP yet (will sync later)."
fi

# Prompt for worker IPs
read -p "Enter worker IP addresses (space-separated): " -a WORKER_IPS
if [[ ${#WORKER_IPS[@]} -eq 0 ]]; then
  echo "At least one worker required? Running local-only if none."
fi

# Install dependencies
echo "Installing distcc, redis, sccache..."
sudo apt update
sudo apt install -y distcc rsync redis-server openssh-client

# Download and install sccache (latest stable)
SCCACHE_VERSION="0.8.2"
SCCACHE_URL="https://github.com/mozilla/sccache/releases/download/v$SCCACHE_VERSION/sccache-v$SCCACHE_VERSION-x86_64-unknown-linux-musl.tar.gz"
if [[ ! -f /usr/local/bin/sccache ]]; then
  echo "Downloading sccache v${SCCACHE_VERSION}..."
  temp=$(mktemp -d)
  curl -L "$SCCACHE_URL" | tar xz -C "$temp"
  sudo mv "$temp"/sccache-v*/sccache /usr/local/bin/
  sudo chmod +x /usr/local/bin/sccache
  rm -rf "$temp"
fi

# Start Redis (local)
sudo systemctl enable redis-server
sudo systemctl restart redis-server

# Auto-detect cores
TOTAL_JOBS=8  # Local
DISTCC_HOSTS="localhost/8"
for ip in "${WORKER_IPS[@]}"; do
  # Test SSH
  if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$ip" echo "OK" >/dev/null 2>&1; then
    echo "Error: Passwordless SSH to $ip failed. Setup ssh-copy-id first."
    exit 1
  fi
  DISTCC_HOSTS="$DISTCC_HOSTS $ip/lpf"  # lpf = lots, parallel friendly (unlimited slots)
  TOTAL_JOBS=$((TOTAL_JOBS + 64))  # Assume high for workers
done

# Write env config
CONFIG_FILE="$AOSP_DIR/.distbuild_env"
cat <<EOF > "$CONFIG_FILE"
export DISTCC_HOSTS="$DISTCC_HOSTS"
export DISTCC_PUMP=1  # Enable pump
export USE_CCACHE=1
export CCACHE_EXEC=/usr/local/bin/sccache
export SCCACHE_REDIS="redis://localhost:6379"
export TOTAL_JOBS=$TOTAL_JOBS
export WORKER_IPS="${WORKER_IPS[*]}"
EOF

echo "Master setup complete."
echo "Config written to $CONFIG_FILE"
echo "Source it: source $CONFIG_FILE"
echo "Redis status: $(systemctl is-active redis-server)"
