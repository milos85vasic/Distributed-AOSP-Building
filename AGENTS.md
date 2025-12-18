# AGENTS.md: Distributed AOSP Build System Guide

This document captures everything an agent needs to know to work effectively in this repository.

---

## Project Purpose

Distribute AOSP builds across multiple machines using:
- `distcc` for distributed compilation
- `sccache` with Redis for compiler cache
- `rsync` for source synchronization
- Passwordless SSH for machine coordination

Architecture: **Master-worker**, where:
- Master runs the build (`m`), distributes work via `distcc pump`
- Workers run `distccd` to accept compile jobs
- Redis (on master) coordinates `sccache`

---

## Essential Commands

### Setup Workflow (Run in Order)

1. **Set up passwordless SSH (once per cluster)**:
   ```bash
   ./setup_passwordless_ssh.sh
   ```
   - Prompts for username, password, and all machine IPs (including master)
   - Uses `sshpass` to automate key exchange bidirectionally
   - Generates Ed25519 keys if missing

2. **Configure master node**:
   ```bash
   ./setup_master.sh /path/to/aosp
   ```
   - Installs: `distcc`, `rsync`, `redis-server`, `sccache`
   - Prompts for worker IPs
   - Tests SSH connectivity
   - Sets up Redis and writes environment to `$AOSP_DIR/.distbuild_env`
   - Exports: `DISTCC_HOSTS`, `SCCACHE_REDIS`, `TOTAL_JOBS`, etc.

3. **Configure each worker node**:
   ```bash
   ./setup_worker.sh /path/to/aosp
   ```
   - Installs: `distcc`, `rsync`
   - Prompts for master IP
   - Configures `/etc/default/distcc` to allow master
   - Starts and enables `distccd` service

4. **Sync and build**:
   ```bash
   ./sync_and_build.sh
   ```
   - Sources `.distbuild_env`
   - Syncs source to workers (excludes `out/`, `.ccache/`, `.sccache/`)
   - Runs `lunch aosp_arm64-eng`
   - Starts build with `pump m -j$TOTAL_JOBS`
   - Shows `sccache` stats at end

### Debugging Commands

```bash
# Check distcc status on workers
ssh worker_ip "sudo systemctl status distccd"

# Check Redis status on master
sudo systemctl status redis-server
redis-cli ping

# Verify sccache connectivity
sccache --show-stats

# Check distcc monitor
distccmon-text 1  # Monitor distributed compilation
```

---

## Code Organization

- Root scripts:
  - `setup_master.sh`: Master setup, installs deps and configures environment
  - `setup_worker.sh`: Worker setup, configures distccd service
  - `setup_passwordless_ssh.sh`: SSH automation using sshpass
  - `sync_and_build.sh`: Build orchestration and source sync
- `Upstreams/`: Contains remote tracking info
  - `GitHub.sh`: Sets `UPSTREAMABLE_REPOSITORY`

---

## Naming Conventions & Patterns

- All scripts use `snake_case`
- Scripts prefixed by role: `setup_*.sh`, `sync_and_build.sh`
- Environment variables in `.distbuild_env` are exported and used across scripts
- `$AOSP_DIR` must be consistent across all machines
- All scripts use `set -e` for error handling
- Error messages are descriptive and include usage instructions

---

## Testing Approach

- No test suite exists
- Relies on script safety:
  - `set -e` ensures exit on error
  - Manual validation via `systemctl is-active`, `sccache --show-stats`, SSH tests
- Build validation happens during AOSP compilation

---

## Gotchas & Non-Obvious Patterns

### 1. **Security Risks**
- `sshpass` uses plaintext passwords — avoid in production
- Redis runs without password/auth — exposed on localhost
- `distccd` allows master IP only — ensure network isolation

### 2. **Environment Assumptions**
- All machines must:
  - Use same `$AOSP_DIR` path
  - Have same username
  - Be on same network
  - Allow SSH and Redis ports
- AOSP source must already exist on master

### 3. **Build Distribution**
- Only **compilation** is distributed via `distcc`
- Full build (`m`) runs on master — master must have AOSP env sourced
- `pump` mode requires `distcc` on master and `distccd` on workers

### 4. **Caching**
- `sccache` uses Redis on master (`redis://localhost:6379`)
- Cache survives rebuilds but not Redis restarts (unless persistence enabled)

### 5. **Job Count Calculation**
- Master: 8 jobs
- Each worker: assumed 64 jobs (hardcoded) — may not reflect actual cores
- Total: `8 + 64 * N` — may overload network or CPU

### 6. **No Cleanup**
- No script to remove SSH keys, disable services, or uninstall tools
- Manual cleanup required:
  ```bash
  sudo systemctl disable --now distccd redis-server
  # Remove ~/.ssh/authorized_keys entries
  ```

### 7. **Script Path Assumptions**
- `sync_and_build.sh` assumes it's in parent directory of AOSP root (line 5)
- All scripts expect absolute AOSP paths via `realpath`

### 8. **Distribution-Specific Commands**
- Scripts use `apt` package manager (Ubuntu/Debian)
- Use `systemctl` for service management

---

## Project-Specific Context

- Upstream repo: `git@github.com:milos85vasic/Distributed-AOSP-Building.git`
- Designed for **local clusters or cloud VMs** with trusted network
- Optimized for fast AOSP builds — not secure by default
- Assumes user has sudo access on all machines
- Target platform: `aosp_arm64-eng` (hardcoded in sync_and_build.sh)

---

## Future Improvements (Optional)

- Replace `sshpass` with manual key copy or Ansible
- Add Redis password and TLS
- Auto-detect worker core count instead of assuming 64
- Add `--target` flag to `sync_and_build.sh` instead of hardcoding `aosp_arm64-eng`
- Add error recovery and rollback
- Add `teardown.sh` script
- Support for other package managers (yum, dnf)
- Add configuration file support instead of interactive prompts