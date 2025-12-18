#!/bin/bash

set -e  # Exit on error

AOSP_DIR="$1"

if [[ -z "$AOSP_DIR" ]]; then
  echo "Usage: $0 <aosp_directory>"
  exit 1
fi

AOSP_DIR=$(realpath "$AOSP_DIR")

if [[ ! -d "$AOSP_DIR/build/soong" ]]; then
  echo "Error: $AOSP_DIR does not look like an AOSP root (missing build/soong)."
  exit 1
fi

# Prompt for master IP if not set
read -p "Enter master IP address: " MASTER_IP
if [[ -z "$MASTER_IP" ]]; then
  echo "Master IP required."
  exit 1
fi

# Install dependencies
echo "Installing distcc and dependencies..."
sudo apt update
sudo apt install -y distcc rsync openssh-server

# Auto-detect cores
CORES=$(nproc --all)
JOBS=$((CORES * 2))  # Conservative overcommit

# Configure distccd
echo "Configuring distccd to allow $MASTER_IP, jobs: $JOBS"
sudo sed -i "/^allowed/c\allowed = $MASTER_IP" /etc/default/distcc
sudo sed -i "/^MAX_JOBS/c\MAX_JOBS = $JOBS" /etc/default/distcc  # Or empty for unlimited

# Start and enable distccd
sudo systemctl enable distccd
sudo systemctl restart distccd
echo "distccd started with $JOBS jobs."

# Create AOSP dir if missing
mkdir -p "$AOSP_DIR"

echo "Worker setup complete for $AOSP_DIR."
echo "distccd status: $(systemctl is-active distccd)"
