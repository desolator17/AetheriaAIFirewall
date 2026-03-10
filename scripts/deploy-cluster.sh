#!/usr/bin/env bash
set -euo pipefail

info() { printf "[INFO] %s\n" "$*"; }
warn() { printf "[WARN] %s\n" "$*"; }
err() { printf "[ERR ] %s\n" "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || err "Missing required command: $1"
}

require_cmd bash
require_cmd ssh
require_cmd scp
require_cmd curl
require_cmd tar

WORK_DIR="${PWD}/downloads"
mkdir -p "$WORK_DIR"

echo "Aetheria Full Cluster Deployment"
echo "================================"
echo "This script deploys: CTRL1 -> CTRL2 -> BRAIN1 -> BRAIN2 -> EDGE1 -> EDGE2"
echo

read -r -p "Use portal download URL for installer? [Y/n]: " USE_URL
USE_URL="${USE_URL:-Y}"

INSTALLER_TGZ=""

if [[ "$USE_URL" =~ ^[Yy]$ ]]; then
  read -r -p "Portal installer URL (.tar.gz): " INSTALLER_URL
  [[ -n "$INSTALLER_URL" ]] || err "Installer URL is required"
  BASE_NAME="$(basename "$INSTALLER_URL")"
  [[ "$BASE_NAME" == *.tar.gz ]] || err "Installer URL must end with .tar.gz"

  INSTALLER_TGZ="$WORK_DIR/$BASE_NAME"
  info "Downloading installer bundle"
  curl -fL "$INSTALLER_URL" -o "$INSTALLER_TGZ"

  info "Downloading checksum and signature"
  curl -fL "${INSTALLER_URL}.sha256" -o "${INSTALLER_TGZ}.sha256" || warn "Could not download .sha256"
  curl -fL "${INSTALLER_URL}.asc" -o "${INSTALLER_TGZ}.asc" || warn "Could not download .asc"
else
  read -r -p "Local installer tarball path: " INSTALLER_TGZ
  [[ -f "$INSTALLER_TGZ" ]] || err "Installer tarball not found: $INSTALLER_TGZ"
fi

read -r -p "Management interface [eth0]: " MGMT_IFACE
MGMT_IFACE="${MGMT_IFACE:-eth0}"

read -r -p "Gateway IP: " MGMT_GW
[[ -n "$MGMT_GW" ]] || err "Gateway is required"

read -r -p "DNS servers (space separated): " MGMT_DNS
[[ -n "$MGMT_DNS" ]] || err "DNS servers are required"

read -r -p "Aetheria license key (eyJ...): " AETHERIA_LICENSE_KEY
[[ -n "$AETHERIA_LICENSE_KEY" ]] || err "License key is required"

roles=("ctrl" "ctrl-standby" "brain" "brain" "edge" "edge")
names=("ctrl1" "ctrl2" "brain1" "brain2" "edge1" "edge2")

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
  NODE_SSH[$i]="${ssh_target:-$default_ssh}"
done

CTRL1_IP="${NODE_CIDR[0]%%/*}"

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
  host_ip="${ip_cidr%%/*}"

  info "[$name] Copying installer to $ssh_target"
  ssh -o StrictHostKeyChecking=accept-new "$ssh_target" "mkdir -p /tmp/aetheria-installer"
  scp -o StrictHostKeyChecking=accept-new "$INSTALLER_TGZ" "$ssh_target:/tmp/aetheria-installer/installer.tar.gz"

  info "[$name] Running node-init non-interactive"
  ssh -o StrictHostKeyChecking=accept-new "$ssh_target" "set -euo pipefail; \
    cd /tmp/aetheria-installer; \
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
    ctrl1_ssh="${NODE_SSH[0]}"
    ssh -o StrictHostKeyChecking=accept-new "$ctrl1_ssh" \
      "sudo docker exec aetheria-patroni patronictl -c /etc/patroni/patroni.yml list" || \
      warn "Could not verify Patroni status automatically"
    read -r -p "Continue to Brain nodes? [y/N]: " CONTINUE_AFTER_CTRL2
    [[ "$CONTINUE_AFTER_CTRL2" =~ ^[Yy]$ ]] || err "Stopped after CTRL2 by operator"
  fi
done

echo
info "Full deployment sequence completed"
info "Access WebUI on CTRL VIP or CTRL1 IP after services stabilize"
