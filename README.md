# Distributed AOSP Building

A system for accelerating Android Open Source Project (AOSP) builds by distributing compilation across multiple machines using distcc, sccache, and Redis.

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Architecture](#architecture)
- [Installation & Setup](#installation--setup)
  - [Step 1: Passwordless SSH Setup](#step-1-passwordless-ssh-setup)
  - [Step 2: Master Node Configuration](#step-2-master-node-configuration)
  - [Step 3: Worker Node Configuration](#step-3-worker-node-configuration)
  - [Step 4: Building AOSP](#step-4-building-aosp)
- [Configuration Details](#configuration-details)
- [Troubleshooting](#troubleshooting)
- [Security Considerations](#security-considerations)
- [Performance Tuning](#performance-tuning)
- [Advanced Usage](#advanced-usage)
- [Limitations](#limitations)

## Overview

This project enables significant reduction in AOSP build times by leveraging multiple machines in a master-worker architecture:

- **Master Node**: Orchestrates builds, distributes compilation tasks
- **Worker Nodes**: Execute distributed compilation jobs
- **Shared Cache**: Redis-backed sccache for compiler cache sharing
- **Source Synchronization**: rsync-based source distribution

### Key Technologies

- **distcc**: Distributed C/C++ compiler
- **distcc pump**: Preprocessor distribution for improved performance
- **sccache**: Shared compiler cache with Redis backend
- **Redis**: Cache coordination server
- **rsync**: Efficient source code synchronization

## Prerequisites

### System Requirements

**All Machines (Master and Workers):**
- Ubuntu/Debian Linux (apt-based)
- Same username across all machines
- sudo access
- Network connectivity between all machines
- OpenSSH server installed

**Master Node:**
- Minimum: 8GB RAM, 4 CPU cores
- Storage: Full AOSP source (~100GB) + build artifacts (~200GB)
- Network: Gigabit recommended for source distribution

**Worker Nodes:**
- Minimum: 4GB RAM, 2 CPU cores
- Storage: AOSP source directory (synced from master)

### Software Dependencies

**Required on Master:**
```bash
# These will be installed by setup_master.sh
distcc, rsync, redis-server, openssh-client, sccache
```

**Required on Workers:**
```bash
# These will be installed by setup_worker.sh
distcc, rsync, openssh-server
```

### AOSP Requirements

- AOSP source code already downloaded on master node
- Recommended: Use `repo` tool to sync source before running setup

## Architecture

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Master    │────▶│   Worker 1  │────▶│   Worker N  │
│   Node      │     │   Node      │     │   Node      │
│             │     │             │     │             │
│ - distcc    │     │ - distccd   │     │ - distccd   │
│ - sccache   │     │ - rsync     │     │ - rsync     │
│ - Redis     │     │             │     │             │
│ - pump mode │     │             │     │             │
└─────────────┘     └─────────────┘     └─────────────┘
       │
       ▼
┌─────────────────────────────────────────────────────┐
│              AOSP Build Process                     │
│                                                     │
│ 1. Source sync via rsync                           │
│ 2. Build orchestration via pump m                   │
│ 3. Distributed compilation via distcc              │
│ 4. Shared caching via sccache + Redis              │
└─────────────────────────────────────────────────────┘
```

## Installation & Setup

### Step 1: Passwordless SSH Setup

**Purpose**: Enable bidirectional passwordless SSH access between all machines.

**Run on Master Node:**
```bash
./setup_passwordless_ssh.sh
```

**Prompts:**
- Username (must be same on all machines)
- SSH password (temporary, for initial setup)
- All machine IP addresses (space-separated, including master)

**What happens:**
1. Generates Ed25519 SSH keys on all machines (if missing)
2. Collects all public keys
3. Distributes keys to all machines for bidirectional access
4. Tests connectivity

**Verification:**
```bash
# From master
ssh username@worker1_ip hostname
ssh username@worker2_ip hostname

# Should return hostnames without password prompts
```

### Step 2: Master Node Configuration

**Purpose**: Install and configure master services (distcc, Redis, sccache).

**Run on Master Node:**
```bash
./setup_master.sh /path/to/your/aosp/source
```

**Parameters:**
- `/path/to/your/aosp/source`: Absolute path to AOSP source directory

**Prompts:**
- Worker IP addresses (space-separated)

**What happens:**
1. Installs dependencies: distcc, rsync, redis-server, openssh-client
2. Downloads and installs sccache v0.8.2 to /usr/local/bin/
3. Configures and starts Redis server
4. Tests SSH connectivity to all workers
5. Creates environment configuration at `$AOSP_DIR/.distbuild_env`
6. Calculates job counts (8 for master + 64 per worker)

**Generated Environment File (`.distbuild_env`):**
```bash
export DISTCC_HOSTS="localhost/8 worker1_ip/lpf worker2_ip/lpf ..."
export DISTCC_PUMP=1
export USE_CCACHE=1
export CCACHE_EXEC=/usr/local/bin/sccache
export SCCACHE_REDIS="redis://localhost:6379"
export TOTAL_JOBS=136  # Example: 8 + (64 * 2 workers)
export WORKER_IPS="worker1_ip worker2_ip ..."
```

### Step 3: Worker Node Configuration

**Purpose**: Install and configure worker services (distccd).

**Run on EACH Worker Node:**
```bash
./setup_worker.sh /path/to/your/aosp/source
```

**Parameters:**
- `/path/to/your/aosp/source`: Same absolute path as on master

**Prompts:**
- Master IP address

**What happens:**
1. Installs dependencies: distcc, rsync, openssh-server
2. Auto-detects CPU cores and calculates job count (cores × 2)
3. Configures `/etc/default/distcc`:
   - Sets `allowed` to master IP only
   - Sets `MAX_JOBS` to calculated value
4. Starts and enables distccd service
5. Creates AOSP directory if missing

**Verification on Workers:**
```bash
sudo systemctl status distccd
# Should show "active (running)"
```

### Step 4: Building AOSP

**Purpose**: Synchronize source and execute distributed build.

**Run on Master Node:**
```bash
./sync_and_build.sh
```

**Prerequisites:**
- `.distbuild_env` must exist (created by setup_master.sh)
- Script assumes it's in parent directory of AOSP root

**What happens:**
1. Sources the distributed build environment
2. Syncs AOSP source to all workers via rsync (excludes: out/, .ccache/, .sccache/)
3. Sources AOSP build environment
4. Configures build target: `lunch aosp_arm64-eng`
5. Starts distributed build: `pump m -j$TOTAL_JOBS`
6. Displays sccache statistics after completion

**Expected Output:**
```
Syncing source to workers (excluding out/, caches)...
Syncing to 192.168.1.101...
Syncing to 192.168.1.102...
Starting build with -j136 (pump distcc + sccache)...
[Build output...]
Build complete. Stats: sccache --show-stats
```

## Configuration Details

### Master Configuration Files

**Environment File (`.distbuild_env`)**
```bash
# Host configuration for distributed compilation
export DISTCC_HOSTS="localhost/8 192.168.1.101/lpf 192.168.1.102/lpf"
export DISTCC_PUMP=1

# Cache configuration
export USE_CCACHE=1
export CCACHE_EXEC=/usr/local/bin/sccache
export SCCACHE_REDIS="redis://localhost:6379"

# Build configuration
export TOTAL_JOBS=136
export WORKER_IPS="192.168.1.101 192.168.1.102"
```

**Redis Configuration**
- Default config: `/etc/redis/redis.conf`
- Port: 6379
- No password authentication (security consideration)
- Persistence disabled by default

### Worker Configuration Files

**distcc Configuration (`/etc/default/distcc`)**
```bash
# Generated by setup_worker.sh
STARTDISTCC="true"
ALLOWEDNETS="192.168.1.100"  # Master IP only
LISTENER="127.0.0.1"  # Localhost
NICE="10"
ZEROCONF="false"
MAX_JOBS="8"  # Auto-calculated: cores × 2
```

## Troubleshooting

### Common Issues

#### SSH Connection Failures
```bash
# Test connectivity manually
ssh -o BatchMode=yes -o ConnectTimeout=5 worker_ip echo "OK"

# If fails, re-run passwordless setup
./setup_passwordless_ssh.sh
```

#### distcc Connection Issues
```bash
# Check distccd status on workers
ssh worker_ip "sudo systemctl status distccd"

# Check if distccd is listening
ssh worker_ip "sudo netstat -tlnp | grep :3632"

# Test distcc from master
distcc --show-hosts
```

#### Redis Connection Issues
```bash
# Check Redis status on master
sudo systemctl status redis-server

# Test Redis connectivity
redis-cli ping
# Should return "PONG"

# Check Redis logs
sudo journalctl -u redis-server -f
```

#### Build Failures
```bash
# Check sccache status
sccache --show-stats

# Monitor distributed compilation
distccmon-text 1

# Check distcc logs
tail -f ~/.distcc/distcc.log
```

### Debugging Commands

**Master Node Debugging:**
```bash
# Verify environment
source /path/to/aosp/.distbuild_env
echo $DISTCC_HOSTS
echo $TOTAL_JOBS

# Test Redis
redis-cli info keyspace

# Monitor sccache
sccache --show-stats --json | jq .

# Check distcc
distcc --version
distcc --show-hosts
```

**Worker Node Debugging:**
```bash
# Check distccd logs
sudo journalctl -u distccd -f

# Check system load
htop
iostat -x 1

# Test distcc locally
echo "int main(){}" | distcc gcc -x c - -o /tmp/test
```

### Performance Issues

**Network Bottlenecks:**
```bash
# Test network throughput
iperf3 -c worker_ip

# Monitor rsync sync times
rsync -a --stats --progress source/ worker_ip:dest/
```

**CPU/Memory Issues:**
```bash
# Monitor CPU usage during build
htop
mpstat 1

# Check memory usage
free -h
```

## Security Considerations

### Current Security Model

⚠️ **This system is designed for trusted networks, not production security.**

- **SSH Keys**: Bidirectional trust established via setup script
- **Redis**: No authentication, localhost only
- **distccd**: Allows master IP only, no encryption
- **Password Exposure**: `sshpass` uses plaintext passwords temporarily

### Hardening Recommendations

**For Production Use:**
1. **Network Isolation**: Use VPN or private network
2. **Redis Security**:
   ```bash
   # Add password to redis.conf
   requirepass your_strong_password
   # Update .distbuild_env
   export SCCACHE_REDIS="redis://:password@localhost:6379"
   ```
3. **SSH Hardening**:
   ```bash
   # Use SSH keys only, disable password auth
   PasswordAuthentication no
   PermitRootLogin no
   ```
4. **distcc Security**:
   ```bash
   # Use SSH tunnel for distcc traffic
   # Configure with DISTCC_HOSTS="@/8"
   ```

### Access Control

**Current Approach**: All-or-nothing bidirectional access

**Alternative Approaches**:
- Master-only SSH access (asymmetric keys)
- Network segmentation
- Per-service authentication

## Performance Tuning

### Job Count Optimization

**Current Formula**:
- Master: 8 jobs
- Each Worker: 64 jobs (hardcoded assumption)
- Total: `8 + 64 × num_workers`

**Optimization**:
```bash
# Detect actual worker cores
ssh worker_ip "nproc --all"
# Adjust MAX_JOBS in /etc/default/distcc
# Common formula: jobs = cores × 2
```

### Network Optimization

**rsync Tuning**:
```bash
# For faster initial sync, modify sync_and_build.sh
rsync -a --delete --compress --stats \
  --exclude='out/' --exclude='.ccache/' --exclude='.sccache/' \
  "$AOSP_DIR"/ "$ip":"$AOSP_DIR"/
```

**Bandwidth Limiting**:
```bash
# Limit rsync to 50MB/s
rsync --bwlimit=50000 ...
```

### Cache Optimization

**Redis Persistence**:
```bash
# Enable Redis persistence for cache durability
sudo sed -i 's/save ""/#save ""/' /etc/redis/redis.conf
sudo sed -i 's/#save 900 1/save 900 1/' /etc/redis/redis.conf
sudo systemctl restart redis-server
```

**sccache Tuning**:
```bash
# Set cache size limits
export SCCACHE_CACHE_SIZE="10G"
export SCCACHE_MAX_FRAME_LEN=20000000
```

## Advanced Usage

### Custom Build Targets

**Modify sync_and_build.sh**:
```bash
# Replace hardcoded target
read -p "Enter build target (default: aosp_arm64-eng): " TARGET
TARGET=${TARGET:-"aosp_arm64-eng"}
lunch $TARGET
```

### Partial Builds

**Build Specific Modules**:
```bash
# After sourcing .distbuild_env
cd $AOSP_DIR
source build/envsetup.sh
lunch aosp_arm64-eng
pump m -j$TOTAL_JOBS framework
```

### Monitoring and Observability

**Real-time Monitoring**:
```bash
# Terminal 1: distcc monitoring
distccmon-text 1

# Terminal 2: build monitoring
watch -n 1 'sccache --show-stats'

# Terminal 3: system monitoring
htop
```

**Log Aggregation**:
```bash
# Collect logs from all machines
mkdir -p logs
scp worker_ip:~/.distcc/distcc.log logs/distcc-worker1.log
scp worker2_ip:~/.distcc/distcc.log logs/distcc-worker2.log
journalctl -u distccd > logs/distccd-master.log
```

## Limitations

### Known Limitations

1. **Ubuntu/Debian Only**: Uses `apt` package manager
2. **Fixed Job Count**: Workers hardcoded to 64 jobs
3. **Single Build Target**: Hardcoded `aosp_arm64-eng`
4. **No Teardown**: No cleanup script provided
5. **Network Assumption**: Assumes gigabit or better network
6. **Security**: Designed for trusted networks only

### Scalability Limits

**Network Bottleneck**: Source distribution becomes bottleneck with many workers
**Memory Usage**: Each worker needs full AOSP source in memory
**Diminishing Returns**: Performance gains plateau after ~8-10 workers

### Platform Compatibility

**Supported**: Ubuntu 18.04+, Debian 10+
**Unsupported**: CentOS/RHEL, macOS, Windows
**Tested**: AOSP master branch, Android 12+

## Contributing

For bug reports and feature requests, please use the project's issue tracker.

## License

See [LICENSE](LICENSE) file for details.