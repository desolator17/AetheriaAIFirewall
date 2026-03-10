#!/usr/bin/env bash
set -euo pipefail

info() { printf "[INFO] %s\n" "$*"; }
warn() { printf "[WARN] %s\n" "$*"; }
err() { printf "[ERR ] %s\n" "$*" >&2; exit 1; }

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

discover_installers() {
  local roots=()
  roots+=("$PWD")
  roots+=("$PWD/downloads")
  roots+=("$HOME")
  roots+=("$HOME/downloads")
  roots+=("/root")
  roots+=("/root/downloads")
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
    # broad fallback scan
    while IFS= read -r file; do
      found+=("$file")
    done < <(find / -maxdepth 6 -type f \( -name "aetheria-*-installer.tar.gz" -o -name "aetheria-*-installer.tgz" -o -name "aetheria-*-installer.tar" -o -name "*installer*.tar.gz" -o -name "*installer*.tgz" -o -name "*installer*.tar" \) 2>/dev/null)
  fi

  if [[ ${#found[@]} -eq 0 ]]; then
    echo ""
    return
  fi

  # de-duplicate while preserving order
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

  # Auto-select the newest tarball by modification time.
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

install_missing_tools

USE_PORTAL=0
for arg in "$@"; do
  case "$arg" in
    --use-portal)
      USE_PORTAL=1
      ;;
    *)
      err "Unknown argument: $arg (supported: --use-portal)"
      ;;
  esac
done

WORK_DIR="${PWD}/downloads"
mkdir -p "$WORK_DIR"

echo "Aetheria Full Cluster Deployment"
echo "================================"
echo "This script can deploy FULL cluster or only CTRL/BRAIN/EDGE node groups"
if [[ "$USE_PORTAL" -eq 1 ]]; then
  info "Installer source mode: portal URL (--use-portal)"
else
  info "Installer source mode: local auto-detect (default)"
fi
echo

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
  [[ -n "$INSTALLER_TGZ" ]] || err "No local installer tarball found. Put installer in /root, /opt, /tmp, /var/tmp, /mnt, or current directory. To download from portal, rerun with --use-portal."
  [[ -f "$INSTALLER_TGZ" ]] || err "Installer tarball not found: $INSTALLER_TGZ"
  info "Auto-selected installer: $INSTALLER_TGZ"
fi

read -r -p "Management interface [eth0]: " MGMT_IFACE
MGMT_IFACE="${MGMT_IFACE:-eth0}"

read -r -p "Gateway IP: " MGMT_GW
[[ -n "$MGMT_GW" ]] || err "Gateway is required"

read -r -p "DNS servers (space separated): " MGMT_DNS
[[ -n "$MGMT_DNS" ]] || err "DNS servers are required"

read -r -p "Aetheria license key (eyJ...): " AETHERIA_LICENSE_KEY
[[ -n "$AETHERIA_LICENSE_KEY" ]] || err "License key is required"

echo
echo "Deployment scope"
echo "----------------"
echo "  1) FULL  (CTRL1, CTRL2, BRAIN1, BRAIN2, EDGE1, EDGE2)"
echo "  2) CTRL only"
echo "  3) BRAIN only"
echo "  4) EDGE only"
read -r -p "Select scope [1-4]: " DEPLOY_SCOPE

roles=()
names=()

case "$DEPLOY_SCOPE" in
  1)
    roles=("ctrl" "ctrl-standby" "brain" "brain" "edge" "edge")
    names=("ctrl1" "ctrl2" "brain1" "brain2" "edge1" "edge2")
    ;;
  2)
    read -r -p "Deploy both CTRL nodes (primary+standby)? [Y/n]: " BOTH_CTRL
    if [[ "${BOTH_CTRL:-Y}" =~ ^[Nn]$ ]]; then
      echo "  1) ctrl (primary)"
      echo "  2) ctrl-standby"
      read -r -p "Select CTRL role [1-2]: " CTRL_ROLE_PICK
      if [[ "$CTRL_ROLE_PICK" == "1" ]]; then
        roles=("ctrl")
        names=("ctrl1")
      elif [[ "$CTRL_ROLE_PICK" == "2" ]]; then
        roles=("ctrl-standby")
        names=("ctrl2")
      else
        err "Invalid CTRL role selection"
      fi
    else
      roles=("ctrl" "ctrl-standby")
      names=("ctrl1" "ctrl2")
    fi
    ;;
  3)
    read -r -p "Number of BRAIN nodes to deploy [2]: " BRAIN_COUNT
    BRAIN_COUNT="${BRAIN_COUNT:-2}"
    [[ "$BRAIN_COUNT" =~ ^[0-9]+$ ]] || err "BRAIN count must be numeric"
    (( BRAIN_COUNT >= 1 )) || err "BRAIN count must be at least 1"
    for i in $(seq 1 "$BRAIN_COUNT"); do
      roles+=("brain")
      names+=("brain${i}")
    done
    ;;
  4)
    read -r -p "Number of EDGE nodes to deploy [2]: " EDGE_COUNT
    EDGE_COUNT="${EDGE_COUNT:-2}"
    [[ "$EDGE_COUNT" =~ ^[0-9]+$ ]] || err "EDGE count must be numeric"
    (( EDGE_COUNT >= 1 )) || err "EDGE count must be at least 1"
    for i in $(seq 1 "$EDGE_COUNT"); do
      roles+=("edge")
      names+=("edge${i}")
    done
    ;;
  *)
    err "Invalid scope selection"
    ;;
esac

declare -a NODE_CIDR NODE_SSH

echo
echo "Enter node connection and management values:"
for i in "${!roles[@]}"; do
  role="${roles[$i]}"
  def_name="${names[$i]}"
  echo
  echo "Node $((i+1))/6: role=${role} default-name=${def_name}"
  read -r -p "  Node name [${def_name}]: " input_name
  input_name="${input_name:-$def_name}"
  names[$i]="$input_name"

  read -r -p "  Management IP/CIDR (e.g. 192.168.100.190/24): " ip_cidr
  [[ -n "$ip_cidr" ]] || err "Management IP/CIDR is required"
  NODE_CIDR[$i]="$ip_cidr"

  if [[ "$role" == "edge" ]]; then
    default_ssh="root@${ip_cidr%%/*}"
  else
    default_ssh="rocky@${ip_cidr%%/*}"
  fi
  read -r -p "  SSH target user@host [${default_ssh}]: " ssh_target
  ssh_target="${ssh_target:-$default_ssh}"
  [[ "$ssh_target" == *"@"* ]] || err "SSH target must be in user@host format"
  NODE_SSH[$i]="$ssh_target"
done

CTRL1_IP=""
for i in "${!roles[@]}"; do
  if [[ "${roles[$i]}" == "ctrl" ]]; then
    CTRL1_IP="${NODE_CIDR[$i]%%/*}"
    break
  fi
done
if [[ -z "$CTRL1_IP" ]]; then
  read -r -p "CTRL1 management IP (required for non-CTRL nodes or standby): " CTRL1_IP
  [[ -n "$CTRL1_IP" ]] || err "CTRL1 IP is required"
fi

echo
echo "Deployment plan summary"
echo "-----------------------"
for i in "${!roles[@]}"; do
  printf "%s  role=%-12s  name=%-8s  ip=%-18s  ssh=%s\n" \
    "$((i+1))." "${roles[$i]}" "${names[$i]}" "${NODE_CIDR[$i]}" "${NODE_SSH[$i]}"
done
echo "Gateway: $MGMT_GW"
echo "DNS:     $MGMT_DNS"
echo "Iface:   $MGMT_IFACE"
echo
read -r -p "Proceed with deployment? [y/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || err "Aborted by user"

for i in "${!roles[@]}"; do
  role="${roles[$i]}"
  name="${names[$i]}"
  ip_cidr="${NODE_CIDR[$i]}"
  ssh_target="${NODE_SSH[$i]}"
  remote_user="${ssh_target%@*}"
  remote_home="/home/${remote_user}"
  if [[ "$remote_user" == "root" ]]; then
    remote_home="/root"
  fi
  remote_stage_dir="${remote_home}/.aetheria-bootstrap"

  info "[$name] Copying installer to $ssh_target (${remote_stage_dir})"
  ssh -o StrictHostKeyChecking=accept-new "$ssh_target" "mkdir -p '${remote_stage_dir}'"
  scp -o StrictHostKeyChecking=accept-new "$INSTALLER_TGZ" "$ssh_target:${remote_stage_dir}/installer.tar.gz"

  info "[$name] Running node-init non-interactive"
  ssh -o StrictHostKeyChecking=accept-new "$ssh_target" "set -euo pipefail; \
    cd '${remote_stage_dir}'; \
    rm -rf aetheria-installer; \
    tar xzf installer.tar.gz; \
    cd aetheria-installer; \
    sudo env \
      AETHERIA_LICENSE_KEY='${AETHERIA_LICENSE_KEY}' \
      AETHERIA_ROLE='${role}' \
      AETHERIA_HOSTNAME='${name}' \
      AETHERIA_IFACE='${MGMT_IFACE}' \
      AETHERIA_IP_CIDR='${ip_cidr}' \
      AETHERIA_GATEWAY='${MGMT_GW}' \
      AETHERIA_DNS='${MGMT_DNS}' \
      AETHERIA_CTRL_IP='${CTRL1_IP}' \
      bash node-init.sh --non-interactive"

  info "[$name] Completed"

  if [[ "$role" == "ctrl-standby" ]]; then
    info "Checking CTRL replication status on CTRL1"
    ctrl1_ssh=""
    for j in "${!roles[@]}"; do
      if [[ "${roles[$j]}" == "ctrl" ]]; then
        ctrl1_ssh="${NODE_SSH[$j]}"
        break
      fi
    done
    if [[ -z "$ctrl1_ssh" ]]; then
      read -r -p "CTRL1 SSH target for replication check (user@host): " ctrl1_ssh
      [[ "$ctrl1_ssh" == *"@"* ]] || err "Invalid CTRL1 SSH target"
    fi
    ssh -o StrictHostKeyChecking=accept-new "$ctrl1_ssh" \
      "sudo docker exec aetheria-patroni patronictl -c /etc/patroni/patroni.yml list" || \
      warn "Could not verify Patroni status automatically"
    if [[ "$DEPLOY_SCOPE" == "1" ]]; then
      read -r -p "Continue to Brain nodes? [y/N]: " CONTINUE_AFTER_CTRL2
      [[ "$CONTINUE_AFTER_CTRL2" =~ ^[Yy]$ ]] || err "Stopped after CTRL2 by operator"
    fi
  fi
done

echo
info "Full deployment sequence completed"
info "Access WebUI on CTRL VIP or CTRL1 IP after services stabilize"
