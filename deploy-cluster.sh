#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Aetheria Single-Node Deployment Script
# Public bootstrap orchestrator — deploys one node role per VM.
# Runs on the management host to provision individual CTRL/BRAIN/EDGE nodes.
# Source: https://github.com/desolator17/AetheriaAIFirewall
# =============================================================================

info() { printf "[INFO] %s\n" "$*"; }
warn() { printf "[WARN] %s\n" "$*"; }
err()  { printf "[ERR ] %s\n" "$*" >&2; exit 1; }

PUBLIC_REPO="desolator17/AetheriaAIFirewall"
PUBLIC_RELEASE_API="https://api.github.com/repos/${PUBLIC_REPO}/releases/latest"
STATE_FILE="./.deploy-state"

# ---------------------------------------------------------------------------
# Parse flags
# ---------------------------------------------------------------------------
USE_PORTAL=0
SSH_IDENTITY_FILE=""
SKIP_PREFLIGHT=0
RESUME=0
FORCE=0

_prev_arg=""
for arg in "$@"; do
  if [[ "$_prev_arg" == "--identity" ]]; then
    SSH_IDENTITY_FILE="$arg"
    _prev_arg=""
    continue
  fi
  case "$arg" in
    --use-portal)     USE_PORTAL=1 ;;
    --skip-preflight) SKIP_PREFLIGHT=1 ;;
    --resume)         RESUME=1 ;;
    --force)          FORCE=1 ;;
    --identity)       _prev_arg="--identity" ;;
    --identity=*)     SSH_IDENTITY_FILE="${arg#--identity=}" ;;
    *)                err "Unknown argument: $arg (supported: --use-portal --identity FILE --resume --force --skip-preflight)" ;;
  esac
done

# Validate identity file if provided
if [[ -n "$SSH_IDENTITY_FILE" ]]; then
  [[ -f "$SSH_IDENTITY_FILE" ]] || err "Identity file not found: $SSH_IDENTITY_FILE"
  [[ -r "$SSH_IDENTITY_FILE" ]] || err "Identity file not readable: $SSH_IDENTITY_FILE"
fi

# Build SSH/SCP option arrays
SSH_OPTS=(
  -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=15
  -o ServerAliveInterval=30
)
SCP_OPTS=(
  -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=15
)
if [[ -n "$SSH_IDENTITY_FILE" ]]; then
  SSH_OPTS+=(-i "$SSH_IDENTITY_FILE")
  SCP_OPTS+=(-i "$SSH_IDENTITY_FILE")
fi

ssh_cmd() {
  ssh "${SSH_OPTS[@]}" "$@"
}

scp_cmd() {
  scp "${SCP_OPTS[@]}" "$@"
}

# ---------------------------------------------------------------------------
# State file helpers
# ---------------------------------------------------------------------------
node_done() {
  local name="$1"
  grep -q "^${name}:DONE$" "$STATE_FILE" 2>/dev/null
}

mark_done() {
  local name="$1"
  echo "${name}:DONE" >> "$STATE_FILE"
}

mark_failed() {
  local name="$1"
  echo "${name}:FAILED" >> "$STATE_FILE"
}

# ---------------------------------------------------------------------------
# WireGuard IP assignment
# ---------------------------------------------------------------------------
assign_wg_ip() {
  local role="$1" role_idx="$2"
  case "$role" in
    edge)         echo "10.99.0.$((10 + role_idx))" ;;
    brain)        echo "10.99.0.$((20 + role_idx))" ;;
    ctrl)         echo "10.99.0.30" ;;
    ctrl-standby) echo "10.99.0.31" ;;
    *)            echo "" ;;
  esac
}

# ---------------------------------------------------------------------------
# License key validation
# ---------------------------------------------------------------------------
validate_license_key() {
  local key="$1"
  local dots
  dots=$(printf "%s" "$key" | tr -cd '.' | wc -c)
  [[ "$dots" -eq 2 ]] || err "License key does not look like a JWT (expected 3 segments separated by dots). Verify at https://portal.aetheria.io"
  [[ "${key:0:3}" == "eyJ" ]] || err "License key must start with 'eyJ'. Verify at https://portal.aetheria.io"
}

# ---------------------------------------------------------------------------
# Pre-flight SSH connectivity check
# ---------------------------------------------------------------------------
preflight_check() {
  local target="$1" name="$2"
  info "[$name] Pre-flight SSH check → $target"
  if ssh_cmd -o BatchMode=yes "$target" "echo ok" >/dev/null 2>&1; then
    info "[$name] SSH OK"
    return 0
  else
    warn "[$name] SSH FAILED: cannot reach $target"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# SCP with retry
# ---------------------------------------------------------------------------
scp_with_retry() {
  local src="$1" dst="$2" name="$3"
  local attempt=1 max=3
  while (( attempt <= max )); do
    info "[$name] Copying installer (attempt ${attempt}/${max})"
    scp_cmd "$src" "$dst" && return 0
    warn "[$name] SCP failed (attempt ${attempt})"
    (( attempt++ ))
    sleep 5
  done
  err "[$name] SCP failed after ${max} attempts. Check SSH connectivity."
}

# ---------------------------------------------------------------------------
# CTRL1 health check before deploying ctrl-standby
# ---------------------------------------------------------------------------
wait_for_ctrl1_health() {
  local ctrl1_ssh="$1"
  local attempts=0 max=12
  info "Waiting for CTRL1 API to be healthy (up to 2 minutes)..."
  while (( attempts < max )); do
    if ssh_cmd "$ctrl1_ssh" "curl -sk https://localhost/ -o /dev/null -w '%{http_code}'" 2>/dev/null | grep -q "200\|302"; then
      info "CTRL1 API is responding."
      return 0
    fi
    (( attempts++ ))
    sleep 10
  done
  warn "CTRL1 API did not respond after ${max} attempts. CTRL2 deploy may fail."
  read -r -p "Continue anyway? [y/N]: " cont
  [[ "$cont" =~ ^[Yy]$ ]] || err "Aborted by operator."
}

# ---------------------------------------------------------------------------
# Prerequisite tools
# ---------------------------------------------------------------------------
require_cmd() {
  command -v "$1" >/dev/null 2>&1
}

install_missing_tools() {
  local missing=()
  for c in bash ssh scp curl tar; do
    require_cmd "$c" || missing+=("$c")
  done

  [[ ${#missing[@]} -eq 0 ]] && return 0

  warn "Missing required tools: ${missing[*]}"
  info "Attempting to install prerequisites on this management host"

  if require_cmd dnf; then
    sudo dnf install -y tar curl openssh-clients || err "Failed to install prerequisites via dnf"
  elif require_cmd yum; then
    sudo yum install -y tar curl openssh-clients || err "Failed to install prerequisites via yum"
  elif require_cmd apt-get; then
    sudo apt-get update && sudo apt-get install -y tar curl openssh-client || err "Failed to install prerequisites via apt-get"
  elif require_cmd apk; then
    sudo apk add --no-cache tar curl openssh-client || err "Failed to install prerequisites via apk"
  else
    err "Unsupported package manager. Install manually: tar curl ssh scp"
  fi

  for c in bash ssh scp curl tar; do
    require_cmd "$c" || err "Missing required command after install: $c"
  done
}

# ---------------------------------------------------------------------------
# Installer discovery
# ---------------------------------------------------------------------------
discover_installers() {
  local roots=()
  # Operator-specified directory takes priority
  [[ -n "${AETHERIA_INSTALLER_DIR:-}" ]] && roots+=("$AETHERIA_INSTALLER_DIR")
  roots+=("$PWD")
  roots+=("$PWD/downloads")
  roots+=("$HOME")
  roots+=("$HOME/downloads")
  roots+=("/root")
  roots+=("/root/downloads")
  roots+=("/var/cache/aetheria")
  roots+=("/opt")
  roots+=("/tmp")
  roots+=("/var/tmp")
  roots+=("/mnt")

  local found=()
  local root
  for root in "${roots[@]}"; do
    [[ -d "$root" ]] || continue
    while IFS= read -r file; do
      found+=("$file")
    done < <(find "$root" -maxdepth 6 -type f \( -name "aetheria-*-installer.tar.gz" -o -name "aetheria-*-installer.tgz" -o -name "aetheria-*-installer.tar" -o -name "*installer*.tar.gz" -o -name "*installer*.tgz" -o -name "*installer*.tar" -o -name "*.tar.gz" -o -name "*.tgz" -o -name "*.tar" \) 2>/dev/null)
  done

  if [[ ${#found[@]} -eq 0 ]]; then
    while IFS= read -r file; do
      found+=("$file")
    done < <(find / -maxdepth 6 -type f \( -name "aetheria-*-installer.tar.gz" -o -name "aetheria-*-installer.tgz" -o -name "aetheria-*-installer.tar" -o -name "*installer*.tar.gz" -o -name "*installer*.tgz" -o -name "*installer*.tar" \) 2>/dev/null)
  fi

  if [[ ${#found[@]} -eq 0 ]]; then
    echo ""
    return
  fi

  local unique=()
  local f
  for f in "${found[@]}"; do
    local seen=0
    local u
    for u in "${unique[@]}"; do
      [[ "$u" == "$f" ]] && seen=1 && break
    done
    [[ "$seen" -eq 0 ]] && unique+=("$f")
  done

  local newest=""
  local newest_mtime=0
  local file mtime
  for file in "${unique[@]}"; do
    mtime=$(stat -c %Y "$file" 2>/dev/null || echo 0)
    if (( mtime > newest_mtime )); then
      newest_mtime=$mtime
      newest="$file"
    fi
  done

  echo "$newest"
}

self_update_from_public_repo() {
  if [[ -d .git ]] && require_cmd git; then
    info "Refreshing deployment files from public repo"
    git pull --ff-only >/dev/null 2>&1 || warn "Could not auto-update from git remote; continuing"
  fi
}

download_installer_from_public_release() {
  local release_json asset_url base_name
  info "Attempting to auto-download installer from public repo release"
  release_json="$(curl -fsSL "$PUBLIC_RELEASE_API" 2>/dev/null || true)"
  [[ -n "$release_json" ]] || return 1

  asset_url="$(printf "%s" "$release_json" | grep -Eo 'https://[^"[:space:]]+aetheria-[^"[:space:]]+-installer\.(tar\.gz|tgz|tar)' | head -n1)"
  [[ -n "$asset_url" ]] || return 1

  base_name="$(basename "$asset_url")"
  INSTALLER_TGZ="$WORK_DIR/$base_name"
  curl -fL "$asset_url" -o "$INSTALLER_TGZ"
  curl -fL "${asset_url}.sha256" -o "${INSTALLER_TGZ}.sha256" || warn "Could not download .sha256"
  curl -fL "${asset_url}.asc" -o "${INSTALLER_TGZ}.asc" || warn "Could not download .asc"
  info "Downloaded installer from public release: $INSTALLER_TGZ"
  return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
install_missing_tools
self_update_from_public_repo

WORK_DIR="${PWD}/downloads"
mkdir -p "$WORK_DIR"

echo "Aetheria Full Cluster Deployment"
echo "================================"
echo "This script can deploy a FULL cluster or only CTRL/BRAIN/EDGE node groups."
if [[ "$USE_PORTAL" -eq 1 ]]; then
  info "Installer source mode: portal URL (--use-portal)"
else
  info "Installer source mode: local auto-detect (default)"
fi
echo

# ---------------------------------------------------------------------------
# State file handling
# ---------------------------------------------------------------------------
if [[ -f "$STATE_FILE" ]] && [[ "$RESUME" -eq 0 ]] && [[ "$FORCE" -eq 0 ]]; then
  echo "Existing deploy state found at $STATE_FILE."
  read -r -p "Use --resume to skip completed nodes, or press Enter to start fresh (will delete $STATE_FILE): " _state_cont
  if [[ -z "$_state_cont" ]]; then
    rm -f "$STATE_FILE"
    info "Starting fresh — deleted $STATE_FILE"
  else
    err "Re-run with --resume to skip completed nodes, or with --force to re-deploy all."
  fi
fi

# ---------------------------------------------------------------------------
# Installer source
# ---------------------------------------------------------------------------
INSTALLER_TGZ=""

if [[ "$USE_PORTAL" -eq 1 ]]; then
  INSTALLER_URL="${AETHERIA_INSTALLER_URL:-}"
  while [[ -z "$INSTALLER_URL" ]]; do
    read -r -p "Portal installer URL (.tar.gz/.tgz/.tar): " INSTALLER_URL
  done
  [[ -n "$INSTALLER_URL" ]] || err "Installer URL is required"
  BASE_NAME="$(basename "$INSTALLER_URL")"
  case "$BASE_NAME" in
    *.tar.gz|*.tgz|*.tar) ;;
    *) err "Installer URL must end with .tar.gz, .tgz, or .tar" ;;
  esac

  INSTALLER_TGZ="$WORK_DIR/$BASE_NAME"
  info "Downloading installer bundle"
  curl -fL "$INSTALLER_URL" -o "$INSTALLER_TGZ"

  info "Downloading checksum and signature"
  curl -fL "${INSTALLER_URL}.sha256" -o "${INSTALLER_TGZ}.sha256" || warn "Could not download .sha256"
  curl -fL "${INSTALLER_URL}.asc" -o "${INSTALLER_TGZ}.asc" || warn "Could not download .asc"
else
  INSTALLER_TGZ="$(discover_installers)"
  if [[ -z "$INSTALLER_TGZ" ]]; then
    download_installer_from_public_release || true
  fi
  [[ -n "$INSTALLER_TGZ" ]] || err "No local installer tarball found and no installer release asset detected in ${PUBLIC_REPO}. Publish installer artifact to public releases or rerun with --use-portal."
  [[ -f "$INSTALLER_TGZ" ]] || err "Installer tarball not found: $INSTALLER_TGZ"
  info "Auto-selected installer: $INSTALLER_TGZ"
fi

# ---------------------------------------------------------------------------
# Network defaults — auto-detect management interface
# ---------------------------------------------------------------------------
# Detect first non-loopback interface for Rocky/Alpine
DETECTED_IFACE=""
if command -v ip >/dev/null 2>&1; then
  DETECTED_IFACE=$(ip link show | grep "^[0-9]" | grep -v "lo:" | head -1 | awk '{print $2}' | sed 's/:$//')
fi
IFACE_DEFAULT="${DETECTED_IFACE:-eth0}"

read -r -p "Management interface [$IFACE_DEFAULT]: " MGMT_IFACE
MGMT_IFACE="${MGMT_IFACE:-$IFACE_DEFAULT}"

read -r -p "Gateway IP: " MGMT_GW
[[ -n "$MGMT_GW" ]] || err "Gateway is required"

read -r -p "DNS servers (space separated): " MGMT_DNS
[[ -n "$MGMT_DNS" ]] || err "DNS servers are required"

# ---------------------------------------------------------------------------
# License key (validated before any SSH)
# ---------------------------------------------------------------------------
read -r -p "Aetheria license key (eyJ...) [Enter for 30-day evaluation]: " AETHERIA_LICENSE_KEY
if [[ -n "$AETHERIA_LICENSE_KEY" ]]; then
  validate_license_key "$AETHERIA_LICENSE_KEY"
  info "License key format OK."
else
  info "No license key — nodes will start in 30-day evaluation mode."
  info "Obtain a license at https://portal.aetheria.io"
fi

# ---------------------------------------------------------------------------
# Node role selection (single node only)
# ---------------------------------------------------------------------------
echo
echo "Select node role to deploy on this VM"
echo "-------------------------------------"
echo "  1) CTRL primary (ctrl1)"
echo "  2) CTRL secondary (ctrl2 - standby)"
echo "  3) BRAIN node"
echo "  4) EDGE node"
read -r -p "Select role [1-4]: " NODE_ROLE_SELECT

roles=()
names=()

case "$NODE_ROLE_SELECT" in
  1)
    roles=("ctrl")
    names=("ctrl1")
    ;;
  2)
    roles=("ctrl-standby")
    names=("ctrl2")
    ;;
  3)
    read -r -p "BRAIN node number (e.g. 1 for brain1, 2 for brain2): " BRAIN_NUM
    BRAIN_NUM="${BRAIN_NUM:-1}"
    [[ "$BRAIN_NUM" =~ ^[0-9]+$ ]] || err "Node number must be numeric"
    (( BRAIN_NUM >= 1 )) || err "Node number must be at least 1"
    roles=("brain")
    names=("brain${BRAIN_NUM}")
    ;;
  4)
    read -r -p "EDGE node number (e.g. 1 for edge1, 2 for edge2): " EDGE_NUM
    EDGE_NUM="${EDGE_NUM:-1}"
    [[ "$EDGE_NUM" =~ ^[0-9]+$ ]] || err "Node number must be numeric"
    (( EDGE_NUM >= 1 )) || err "Node number must be at least 1"
    roles=("edge")
    names=("edge${EDGE_NUM}")
    ;;
  *)
    err "Invalid role selection"
    ;;
esac

info "Deploying single node: ${names[0]} (role: ${roles[0]})"

# ---------------------------------------------------------------------------
# Node details + WireGuard IP assignment
# ---------------------------------------------------------------------------
declare -a NODE_CIDR NODE_SSH NODE_WG_IP
declare -A ROLE_COUNTER

echo
info "For fresh Rocky Linux installs: use root@host (root SSH must be enabled during OS install)."
info "The script will create the operator account automatically during provisioning."
echo "Enter node connection and management values:"

for i in "${!roles[@]}"; do
  role="${roles[$i]}"
  def_name="${names[$i]}"
  echo
  echo "Node $((i+1))/${#roles[@]}: role=${role} default-name=${def_name}"
  read -r -p "  Node name [${def_name}]: " input_name
  input_name="${input_name:-$def_name}"
  names[$i]="$input_name"

  read -r -p "  Management IP/CIDR (e.g. 192.168.100.190/24): " ip_cidr
  [[ -n "$ip_cidr" ]] || err "Management IP/CIDR is required"
  NODE_CIDR[$i]="$ip_cidr"

  default_ssh="root@${ip_cidr%%/*}"
  read -r -p "  SSH target user@host [${default_ssh}]: " ssh_target
  ssh_target="${ssh_target:-$default_ssh}"
  [[ "$ssh_target" == *"@"* ]] || err "SSH target must be in user@host format"
  NODE_SSH[$i]="$ssh_target"

  # Assign WireGuard IP based on role and per-role index
  ROLE_COUNTER[$role]=$(( ${ROLE_COUNTER[$role]:-0} ))
  NODE_WG_IP[$i]=$(assign_wg_ip "$role" "${ROLE_COUNTER[$role]}")
  ROLE_COUNTER[$role]=$(( ${ROLE_COUNTER[$role]} + 1 ))
done

# ---------------------------------------------------------------------------
# CTRL1 IP
# ---------------------------------------------------------------------------
CTRL1_IP=""
CTRL1_SSH=""
for i in "${!roles[@]}"; do
  if [[ "${roles[$i]}" == "ctrl" ]]; then
    CTRL1_IP="${NODE_CIDR[$i]%%/*}"
    CTRL1_SSH="${NODE_SSH[$i]}"
    break
  fi
done
if [[ -z "$CTRL1_IP" ]]; then
  read -r -p "CTRL1 management IP (required for non-CTRL nodes or standby): " CTRL1_IP
  [[ -n "$CTRL1_IP" ]] || err "CTRL1 IP is required"
fi

# ---------------------------------------------------------------------------
# Deployment plan summary
# ---------------------------------------------------------------------------
echo
echo "Deployment plan summary"
echo "-----------------------"
for i in "${!roles[@]}"; do
  printf "%s  role=%-12s  name=%-8s  wg_ip=%-14s  ip=%-18s  ssh=%s\n" \
    "$((i+1))." "${roles[$i]}" "${names[$i]}" "${NODE_WG_IP[$i]}" \
    "${NODE_CIDR[$i]}" "${NODE_SSH[$i]}"
done
echo "Gateway: $MGMT_GW"
echo "DNS:     $MGMT_DNS"
echo "Iface:   $MGMT_IFACE"
echo
read -r -p "Proceed with deployment? [y/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || err "Aborted by user"

# ---------------------------------------------------------------------------
# Pre-flight SSH checks
# ---------------------------------------------------------------------------
if [[ "$SKIP_PREFLIGHT" -eq 0 ]]; then
  info "Running pre-flight SSH connectivity checks..."
  preflight_failed=0
  for i in "${!roles[@]}"; do
    preflight_check "${NODE_SSH[$i]}" "${names[$i]}" || preflight_failed=1
  done
  [[ "$preflight_failed" -eq 0 ]] || err "Pre-flight failed. Fix SSH connectivity before deploying."
  info "All pre-flight checks passed."
else
  warn "Skipping pre-flight SSH checks (--skip-preflight)"
fi

# ---------------------------------------------------------------------------
# Deployment loop
# ---------------------------------------------------------------------------
for i in "${!roles[@]}"; do
  role="${roles[$i]}"
  name="${names[$i]}"
  ip_cidr="${NODE_CIDR[$i]}"
  ssh_target="${NODE_SSH[$i]}"
  wg_ip="${NODE_WG_IP[$i]}"
  remote_user="${ssh_target%@*}"
  remote_home="/home/${remote_user}"
  if [[ "$remote_user" == "root" ]]; then
    remote_home="/root"
  fi
  remote_stage_dir="${remote_home}/.aetheria-bootstrap"

  # Resume: skip nodes already completed
  if [[ "$RESUME" -eq 1 ]] && [[ "$FORCE" -eq 0 ]] && node_done "$name"; then
    info "[$name] Already DONE — skipping (use --force to re-deploy)"
    continue
  fi

  # CTRL1 health check before deploying ctrl-standby
  if [[ "$role" == "ctrl-standby" ]] && [[ -n "$CTRL1_SSH" ]]; then
    wait_for_ctrl1_health "$CTRL1_SSH"
  fi

  info "[$name] Staging installer on $ssh_target (${remote_stage_dir})"
  ssh_cmd "$ssh_target" "mkdir -p '${remote_stage_dir}'"
  scp_with_retry "$INSTALLER_TGZ" "$ssh_target:${remote_stage_dir}/installer.tar.gz" "$name"

  info "[$name] Running node-init non-interactive"
  if ssh_cmd "$ssh_target" "set -euo pipefail; \
    cd '${remote_stage_dir}'; \
    rm -rf aetheria-installer; \
    mkdir -p aetheria-installer; \
    tar xzf installer.tar.gz -C aetheria-installer --strip-components=1; \
    AETHERIA_LICENSE_KEY='${AETHERIA_LICENSE_KEY}' \
    AETHERIA_ROLE='${role}' \
    AETHERIA_HOSTNAME='${name}' \
    AETHERIA_IFACE='${MGMT_IFACE}' \
    AETHERIA_IP_CIDR='${ip_cidr}' \
    AETHERIA_GATEWAY='${MGMT_GW}' \
    AETHERIA_DNS='${MGMT_DNS}' \
    AETHERIA_CTRL_IP='${CTRL1_IP}' \
    AETHERIA_WG_IP='${wg_ip}' \
    bash '${remote_stage_dir}/aetheria-installer/scripts/node-init.sh' --non-interactive"; then
    info "[$name] Completed successfully"
    mark_done "$name"
  else
    warn "[$name] node-init.sh exited with errors"
    mark_failed "$name"
    warn "[$name] Fix and re-run with --resume."
  fi

  if [[ "$role" == "ctrl-standby" ]]; then
    info "Checking CTRL replication status on CTRL1"
    if [[ -n "$CTRL1_SSH" ]]; then
      ssh_cmd "$CTRL1_SSH" \
        "sudo docker exec aetheria-patroni patronictl -c /etc/patroni/patroni.yml list" || \
        warn "Could not verify Patroni status automatically"
    else
      warn "CTRL1 SSH target not known — skipping Patroni replication check"
    fi
    if [[ "$DEPLOY_SCOPE" == "1" ]]; then
      read -r -p "Continue to Brain nodes? [y/N]: " CONTINUE_AFTER_CTRL2
      [[ "$CONTINUE_AFTER_CTRL2" =~ ^[Yy]$ ]] || err "Stopped after CTRL2 by operator"
    fi
  fi
done

# ---------------------------------------------------------------------------
# Post-deployment summary
# ---------------------------------------------------------------------------
echo ""
echo "Deployment Summary"
echo "=================="
for i in "${!roles[@]}"; do
  status="FAILED/SKIPPED"
  grep -q "^${names[$i]}:DONE$" "$STATE_FILE" 2>/dev/null && status="DONE"
  printf "  %-8s  %-12s  %-15s  %s\n" "${names[$i]}" "${roles[$i]}" "${NODE_CIDR[$i]%%/*}" "$status"
done
echo ""
info "Access CTRL Web UI at: https://${CTRL1_IP}/"
info "Deployment log for each node: /var/log/aetheria/node-init.log (on each VM)"
echo ""
info "Full deployment sequence completed."
