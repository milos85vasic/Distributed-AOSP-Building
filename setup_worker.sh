#!/bin/bash

set -e  # Exit on error

AOSP_DIR="$1"

if [[ -z "$AOSP_DIR" ]]; then
  echo "Usage: $0 <aosp_directory>"
  exit 1
fi

AOSP_DIR=$(realpath "$AOSP_DIR")

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

# Ensure distcc user exists
sudo useradd -r -s /bin/false distcc 2>/dev/null || true

# Create systemd service for distccd if missing
if [[ ! -f /etc/systemd/system/distccd.service ]]; then
  echo "Creating distccd systemd service..."
  sudo tee /etc/systemd/system/distccd.service > /dev/null <<EOF
[Unit]
Description=distcc distributed compiler daemon
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/distccd --allow $MASTER_IP --jobs $JOBS --log-level info --verbose
User=distcc
Group=distcc

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
fi

# Auto-detect cores
CORES=$(nproc --all)
JOBS=$((CORES * 2))  # Conservative overcommit

# Configure distccd
echo "Configuring distccd to allow $MASTER_IP, jobs: $JOBS"
# Add network range to allowed networks (allows master and its subnet)
if [[ $MASTER_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  # Convert IP to /24 subnet
  ALLOWED_NETS="$MASTER_IP/24"
else
  ALLOWED_NETS="$MASTER_IP"
fi
sudo sed -i 's#^ALLOWEDNETS=.*#ALLOWEDNETS="'"$ALLOWED_NETS"'"#' /etc/default/distcc
sudo sed -i 's/^MAX_JOBS=.*/MAX_JOBS='"$JOBS"'/' /etc/default/distcc

# Configure firewall to allow distcc connections
echo "Configuring firewall for distcc..."
if command -v ufw >/dev/null 2>&1; then
  sudo ufw allow from $MASTER_IP to any port 3632 proto tcp
elif command -v iptables >/dev/null 2>&1; then
  sudo iptables -A INPUT -p tcp -s $MASTER_IP --dport 3632 -j ACCEPT
  sudo iptables-save | sudo tee /etc/iptables/rules.v4 >/dev/null 2>&1 || true
fi

# Start and enable distccd
echo "Starting distccd service..."
sudo systemctl enable distccd
sudo systemctl restart distccd

# Wait a moment and check status
sleep 2
if sudo systemctl is-active --quiet distccd; then
  echo "distccd started successfully with $JOBS jobs."
else
  echo "Warning: distccd failed to start. Checking logs..."
  # Try to show recent logs without requiring sudo
  if command -v journalctl >/dev/null 2>&1; then
    echo "Recent distccd logs:"
    echo "----------------------------------------"
    sudo journalctl -u distccd --no-pager -n 10 | tail -n 20 || echo "Cannot read logs (permission denied)"
    echo "----------------------------------------"
  fi
  echo "You may need to manually troubleshoot with: sudo journalctl -u distccd -f"
fi

echo "distccd status: $(systemctl is-active distccd 2>/dev/null || echo 'unknown')"

# Create AOSP dir if missing
mkdir -p "$AOSP_DIR"

echo "Worker setup complete for $AOSP_DIR."

if [[ ! -d "$AOSP_DIR/build/soong" ]]; then
  
  echo "Warning: $AOSP_DIR does not look like an AOSP root (missing build/soong), probably was not synced yet"
fi