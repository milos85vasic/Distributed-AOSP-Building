#!/bin/bash

set -e

AOSP_DIR=\( (realpath " \)(dirname "$0")"/..)  # Assume in AOSP root or adjust

if [[ -f "$AOSP_DIR/.distbuild_env" ]]; then
  source "$AOSP_DIR/.distbuild_env"
else
  echo "Run setup_master.sh first."
  exit 1
fi

# Sync to workers
echo "Syncing source to workers (excluding out/, caches)..."
for ip in $WORKER_IPS; do
  echo "Syncing to $ip..."
  rsync -a --delete -e ssh \
    --exclude='out/' --exclude='.ccache/' --exclude='.sccache/' \
    "$AOSP_DIR"/ "$ip":"$AOSP_DIR"/
done

# Source AOSP env
cd "$AOSP_DIR"
source build/envsetup.sh
lunch aosp_arm64-eng  # Or your target; adjust or prompt

# Build with distcc pump
echo "Starting build with -j$TOTAL_JOBS (pump distcc + sccache)..."
pump m -j"\( TOTAL_JOBS" " \)@"

echo "Build complete. Stats: sccache --show-stats"
sccache --show-stats
