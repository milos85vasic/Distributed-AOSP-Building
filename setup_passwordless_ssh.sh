#!/bin/bash

set -e  # Exit on error

# Prompt for details
read -p "Enter username (same on all machines): " USERNAME
read -s -p "Enter SSH password (same on all machines): " PASSWORD
echo
read -p "Enter all machine IPs (space-separated, including this master): " -a ALL_IPS

if [[ ${#ALL_IPS[@]} -lt 2 ]]; then
  echo "Need at least 2 IPs for bidirectional setup."
  exit 1
fi

MY_IP=$(hostname -I | awk '{print $1}')  # First IP, adjust if needed
TEMP_DIR=$(mktemp -d /tmp/ssh_keys.XXXXXX)
echo "Temp dir: $TEMP_DIR"

# Function to run command on remote via sshpass
remote_cmd() {
  local ip=$1
  local cmd=$2
  if [[ "$ip" == "localhost" || "$ip" == "$MY_IP" ]]; then
    eval "$cmd"
  else
    sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no "$USERNAME@$ip" "$cmd"
  fi
}

# Function to scp file via sshpass
remote_scp_to() {
  local src=$1
  local ip=$2
  local dest=$3
  if [[ "$ip" == "localhost" || "$ip" == "$MY_IP" ]]; then
    cp "$src" "$dest"
  else
    sshpass -p "$PASSWORD" scp -o StrictHostKeyChecking=no "$src" "$USERNAME@$ip":"$dest"
  fi
}

remote_scp_from() {
  local ip=$1
  local src=$2
  local dest=$3
  if [[ "$ip" == "localhost" || "$ip" == "$MY_IP" ]]; then
    cp "$src" "$dest"
  else
    sshpass -p "$PASSWORD" scp -o StrictHostKeyChecking=no "$USERNAME@$ip":"$src" "$dest"
  fi
}

echo "Step 1: Generating keys on all machines (if missing)..."
for ip in "${ALL_IPS[@]}"; do
  echo "Processing $ip..."
  remote_cmd "$ip" "mkdir -p ~/.ssh && chmod 700 ~/.ssh"
  remote_cmd "$ip" "if [ ! -f ~/.ssh/id_ed25519 ]; then ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N '' -C 'aosp-build@\$(hostname)'; fi"
  remote_cmd "$ip" "chmod 600 ~/.ssh/id_ed25519"
done

echo "Step 2: Collecting all public keys..."
for ip in "${ALL_IPS[@]}"; do
  pub_file="$TEMP_DIR/${ip}.pub"
  remote_scp_from "$ip" "~/.ssh/id_ed25519.pub" "$pub_file"
  echo "Collected from $ip"
done

echo "Step 3: Distributing all public keys to all machines..."
for ip in "${ALL_IPS[@]}"; do
  echo "Distributing to $ip..."
  for pub in "$TEMP_DIR"/*.pub; do
    remote_scp_to "$pub" "$ip" "~/.ssh/authorized_keys.tmp"
    remote_cmd "$ip" "cat ~/.ssh/authorized_keys.tmp >> ~/.ssh/authorized_keys && rm ~/.ssh/authorized_keys.tmp"
    remote_cmd "$ip" "sort -u ~/.ssh/authorized_keys -o ~/.ssh/authorized_keys"  # Dedupe
    remote_cmd "$ip" "chmod 600 ~/.ssh/authorized_keys"
  done
done

echo "Step 4: Cleanup..."
rm -rf "$TEMP_DIR"

echo "Passwordless SSH setup complete (bidirectional)!"
echo "Test: ssh $USERNAME@some-other-ip hostname"

