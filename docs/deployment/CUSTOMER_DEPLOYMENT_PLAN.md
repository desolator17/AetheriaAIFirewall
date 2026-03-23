# Aetheria — Customer Deployment Plan
**Version:** 0.0.0-dev
**Last Updated:** 2026-03-10

> **Aetheria is closed-source commercial software.** A valid license key is
> required. Obtain your license and installer bundle from
> **https://portal.aetheria.io** — see `GETTING_SOFTWARE.md` for the full
> download and verification procedure before following this guide.

This document defines three supported deployment methods for Aetheria customers.
Choose the method that best fits your environment and team capability.

---

## WebUI Access and HA

### Important: Always access the WebUI via the VIP, never via direct node IPs

Once your Aetheria cluster is deployed, the **WebUI and API are highly available** through a floating Virtual IP (VIP). Always use this VIP for operator access:

- **WebUI URL:** `https://<CTRL_VIP>/`
- **API Base URL:** `https://<CTRL_VIP>/api/v1/`

Direct node IPs (e.g., `<CTRL1_IP>`, `<CTRL2_IP>`) are **for SSH administration only**. If you access the WebUI directly on a node IP and that node fails, you will lose WebUI access until the other node's failover is complete. By accessing via the VIP, failover is transparent to you.

### Automatic Failover

Aetheria CTRL nodes use keepalived VRRP and Patroni PostgreSQL HA for automatic failover:

- If CTRL1 fails, the VIP moves to CTRL2 automatically (typically within ~4 seconds)
- PostgreSQL promotion happens transparently (standby → primary)
- The API reconnects to the new primary without manual intervention
- **No user action is required** — failover is fully automatic

For complete details on CTRL HA architecture, manual failover simulation, and troubleshooting, see `docs/operations/ctrl-ha.md`.

---

## Prerequisites (all methods)

### Hardware / VM requirements per node role

| Role | Count | Min vCPU | Min RAM | Min Disk | OS |
|------|-------|----------|---------|----------|----|
| Edge | 2 | 2 | 2 GB | 20 GB | Alpine Linux 3.21 (aarch64 or x86_64) |
| Brain | 2 | 4 | 8 GB | 40 GB | Rocky Linux 9 Minimal |
| CTRL | 1–2 | 2 | 4 GB | 30 GB | Rocky Linux 9 Minimal |

> **Brain nodes need extra RAM for llama.cpp server.** `qwen3:4b` GGUF ~3.8 GB (250MB less than Ollama).

### Network requirements

- All nodes must reach each other on the management CIDR (default `192.168.100.0/24`).
- Edge nodes need one WAN-facing interface and one LAN/management interface.
- TCP 22 (SSH), TCP 50051 (gRPC), TCP 3000 (Gitea), TCP 443 (WebUI), UDP 51820 (WireGuard) must be open within the management CIDR.
- DNS resolution must work on all nodes (for package manager and Gitea hostname).

### Software requirements (management host)

```bash
# Python 3.11+, Ansible 9.x, questionary
pip3 install ansible questionary
# Packer 1.10+ (for golden image builds only)
# Git
```

---

## Method A — Git Pull on CTRL1 → Ansible Push

**Best for:** Ops teams comfortable with Ansible, staged rollout, enterprise customers.

**Flow:**
```
Management Host ──git clone──► CTRL1
                                 │
                     ./aetheria-setup wizard
                                 │
              ┌──────────────────┼──────────────────┐
              │                  │                  │
           CTRL2              EDGE1,2           BRAIN1,2
        (ansible push)     (ansible push)    (ansible push)
              │
        Patroni replication confirmed
```

### Step 1 — Prepare fresh VMs

Provision 6–7 fresh VMs:
- 2× Alpine 3.21 for EDGE nodes
- 2× Rocky 9 Minimal for BRAIN nodes
- 1–2× Rocky 9 Minimal for CTRL nodes

Ensure all VMs:
- Have SSH enabled with root/sudo access
- Are reachable from the management host
- Have Python 3 installed (`dnf install python3` / `apk add python3`)

### Step 2 — Extract the installer bundle on the management host

```bash
# Transfer the bundle from your workstation if needed
# scp aetheria-<version>-installer.tar.gz user@management-host:~

# Verify integrity first (see GETTING_SOFTWARE.md for GPG verification)
sha256sum -c aetheria-<version>-installer.tar.gz.sha256

# Extract
tar xzf aetheria-<version>-installer.tar.gz
cd aetheria-installer
pip3 install questionary
```

### Step 3 — Run the interactive wizard

```bash
./aetheria-setup wizard
```

The wizard will prompt for:
- **Platform** (`vmware_fusion`, `proxmox`, `esxi`, `baremetal`, `aws`)
- **Deployment size** (`lab` = 1E/1B/1C, `standard` = 2E/2B/1C, `enterprise` = 2E/2B/2C)
- **Management CIDR** (e.g., `10.0.50.0/24`)
- **Auto-assign IPs** or enter each IP manually
- **LLM model** (`phi3:mini`, `qwen2.5:0.5b`, `llama3.2:3b`)
- **TLS inspection** enabled/disabled
- **WireGuard mesh** enabled/disabled

Output: `ansible/inventory.yml` and `ansible/group_vars/all.yml` are written.

### Step 4 — Configure secrets (vault)

```bash
# Copy the skeleton vault file
cp ansible/group_vars/vault.yml.skeleton ansible/group_vars/vault.yml

# Edit plaintext values
vim ansible/group_vars/vault.yml

# Encrypt with a strong passphrase
ansible-vault encrypt ansible/group_vars/vault.yml

# Write the vault passphrase to a file (never commit this)
echo "your-vault-passphrase" > ~/.vault_pass
chmod 600 ~/.vault_pass
export ANSIBLE_VAULT_PASSWORD_FILE=~/.vault_pass
```

Minimum vault entries to set:

```yaml
vault_keepalived_auth_secret: "<random 32-char string>"
vault_wireguard_psk: "<output of: wg genpsk>"
vault_ctrl_admin_password: "<strong-password>"
vault_database_password: "<strong-password>"
vault_postgres_password: "<strong-password>"
```

### Step 5 — Distribute SSH keys

```bash
# Generate a deploy key if not already present
ssh-keygen -t ed25519 -f ~/.ssh/aetheria_deploy -N ""

# Copy to all nodes (use the bootstrap password 'aetheria' for fresh images,
# or your provisioning password)
MGMT_PASS="aetheria"
for host in <EDGE1_IP> <EDGE2_IP> <BRAIN1_IP> <BRAIN2_IP> <CTRL1_IP> <CTRL2_IP>; do
    ssh-copy-id -i ~/.ssh/aetheria_deploy.pub root@${host} 2>/dev/null || \
    ssh-copy-id -i ~/.ssh/aetheria_deploy.pub rocky@${host}
done

# Add to SSH config
cat >> ~/.ssh/config <<EOF
Host aedge1
  HostName <EDGE1_IP>
  User root
  IdentityFile ~/.ssh/aetheria_deploy
Host aedge2
  HostName <EDGE2_IP>
  User root
  IdentityFile ~/.ssh/aetheria_deploy
Host abrain1
  HostName <BRAIN1_IP>
  User rocky
  IdentityFile ~/.ssh/aetheria_deploy
Host abrain2
  HostName <BRAIN2_IP>
  User rocky
  IdentityFile ~/.ssh/aetheria_deploy
Host actrl1
  HostName <CTRL1_IP>
  User rocky
  IdentityFile ~/.ssh/aetheria_deploy
Host actrl2
  HostName <CTRL2_IP>
  User rocky
  IdentityFile ~/.ssh/aetheria_deploy
EOF
```

### Step 6 — Deploy CTRL1 first (primary)

```bash
# Deploy CTRL1 only first (Patroni primary + Gitea must be up before CTRL2)
ANSIBLE_SSH_PASS="aetheria" ANSIBLE_SUDO_PASS="aetheria" \
  ansible-playbook -i ansible/inventory.yml ansible/site.yml \
  --limit ctrl1
```

Verify PostgreSQL/Patroni is running as primary on CTRL1:

```bash
ssh actrl1 "sudo docker exec aetheria-patroni patronictl -c /etc/patroni/patroni.yml list"
```

Expected output:
```
+ Cluster: aetheria-ctrl +----+-----------+
| Member | Host        | Role   | State   | TL | Lag in MB |
+--------+-------------+--------+---------+----+-----------+
| ctrl1  | 10.99.0.30  | Leader | running |  1 |           |
+--------+-------------+--------+---------+----+-----------+
```

### Step 7 — Deploy CTRL2 (standby + replication)

```bash
ANSIBLE_SSH_PASS="aetheria" ANSIBLE_SUDO_PASS="aetheria" \
  ansible-playbook -i ansible/inventory.yml ansible/ctrl2-provision.yml
```

Verify streaming replication from CTRL2:

```bash
ssh actrl2 "sudo docker exec aetheria-postgres psql -U aetheria_admin -c 'SELECT * FROM pg_stat_wal_receiver;'"
# Should show 'streaming' status and sender_host = ctrl1 WireGuard IP
```

Confirm Patroni cluster sees both nodes:

```bash
ssh actrl1 "sudo docker exec aetheria-patroni patronictl -c /etc/patroni/patroni.yml list"
```

Expected:
```
+ Cluster: aetheria-ctrl +------+-----------+
| Member | Host        | Role    | State   | TL | Lag in MB |
+--------+-------------+---------+---------+----+-----------+
| ctrl1  | 10.99.0.30  | Leader  | running |  1 |           |
| ctrl2  | 10.99.0.31  | Replica | running |  1 |         0 |
+--------+-------------+---------+---------+----+-----------+
```

### Step 8 — Deploy EDGE and BRAIN nodes

```bash
# Full remaining site deploy (edge1, edge2, brain1, brain2)
ANSIBLE_SSH_PASS="aetheria" ANSIBLE_SUDO_PASS="aetheria" \
  ansible-playbook -i ansible/inventory.yml ansible/wireguard.yml

ANSIBLE_SSH_PASS="aetheria" ANSIBLE_SUDO_PASS="aetheria" \
  ansible-playbook -i ansible/inventory.yml ansible/site.yml \
  --limit edges,brains
```

Or use the convenience wrapper for the full site:

```bash
ANSIBLE_SSH_PASS="aetheria" ANSIBLE_SUDO_PASS="aetheria" \
  ./aetheria-setup deploy
```

### Step 9 — Post-deploy validation

```bash
./aetheria-setup verify

# Check CTRL Web UI
curl -k -I https://<CTRL_VIP_IP>/    # Expect HTTP/2 200

# Check API login
curl -sk -X POST https://<CTRL_VIP_IP>/api/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"<vault_ctrl_admin_password>","site_id":"default"}' \
  | python3 -m json.tool

# Check edge VRRP VIP
ssh aedge1 "ip addr show | grep 'inet.*172'"   # should show the VIP
```

---

## Method B — Golden Image (Packer)

**Best for:** Customers who want repeatable, clean-slate VM provisioning. Reduces first-boot setup time.

### What the golden images contain

| Image | File | Contents |
|-------|------|----------|
| `aetheria-edge-base` | Alpine VMDK / QCOW2 | Alpine 3.21 + all packages (clang, libbpf, nftables, suricata, keepalived, Ansible, Go) + /opt/aetheria layout |
| `aetheria-rocky-base` | Rocky VMDK / QCOW2 | Rocky 9 + docker-ce, python3, Go, clang, ansible + /opt/aetheria layout |

The golden images are **not role-configured** — they provide a fully-bootstrapped OS with all dependencies. Role configuration is applied via Ansible push after first boot.

### Step 1 — Build golden images

```bash
cd /path/to/aetheria

# Place ISOs in ~/isos/
# Alpine: alpine-virt-3.21.0-aarch64.iso  (or x86_64 variant)
# Rocky:  Rocky-9-arm64-minimal.iso

# Validate templates
make packer-validate

# Build Alpine edge image (VMware + QEMU/KVM)
packer build -var "version=$(cat VERSION)" \
  -var "alpine_iso=~/isos/alpine-virt-3.21.0-aarch64.iso" \
  packer/alpine-edge-base.pkr.hcl

# Build Rocky base image (brain + ctrl)
packer build -var "version=$(cat VERSION)" \
  -var "rocky_iso=~/isos/Rocky-9-arm64-minimal.iso" \
  packer/rocky-base.pkr.hcl
```

Output artifacts in `packer/output/`:
- `aetheria-edge-base-<version>-vmware/` — VMDK + VMX
- `aetheria-edge-base-<version>-qcow2/` — QCOW2
- `aetheria-rocky-base-<version>-vmware/` — VMDK + VMX
- `aetheria-rocky-base-<version>-qcow2/` — QCOW2

### Step 2 — Import and provision VMs from images

#### VMware Fusion / ESXi
```bash
# Import VMDK into Fusion (or upload to ESXi datastore)
# Clone VM template:
#   - Edge × 2:  use aetheria-edge-base VMDK, set 2 NICs (WAN + mgmt)
#   - Brain × 2: use aetheria-rocky-base VMDK
#   - CTRL × 2:  use aetheria-rocky-base VMDK
# Apply any vmx patches from vmware/vmx-patches/ if present
# Power on and verify SSH is reachable
```

#### Proxmox
```bash
# Import QCOW2 disk
qm importdisk <VMID> packer/output/aetheria-edge-base-<version>-qcow2/*.qcow2 <storage>
# Configure cloud-init or set static network via VM console on first boot
```

#### Bare metal / KVM
```bash
# Write QCOW2 to target disk
dd if=packer/output/aetheria-rocky-base-<version>-qcow2/*.qcow2 of=/dev/sdX bs=4M status=progress
# Or use qemu-img convert for a raw image
```

### Step 3 — Configure networking on each VM

After first boot from the golden image, set a static management IP using the node-init script (Method C) or manually:

```bash
# Alpine (edge node)
cat > /etc/network/interfaces <<EOF
auto eth0
iface eth0 inet static
  address <EDGE_IP>
  netmask 255.255.255.0
  gateway <GATEWAY>
EOF
echo "nameserver <DNS>" > /etc/resolv.conf
rc-service networking restart

# Rocky (brain/ctrl)
nmcli con mod eth0 ipv4.method manual \
  ipv4.addresses <IP>/24 \
  ipv4.gateway <GATEWAY> \
  ipv4.dns <DNS>
nmcli con up eth0
```

### Step 4 — Continue with Method A from Step 2

After VMs are up with static IPs and SSH reachable, clone the repo on the management host and follow Method A from Step 2 onward.

---

## Method C — Per-VM Node Init Script

**Best for:** Customer self-install, no management host needed, interactive guided setup.

This is the `scripts/node-init.sh` script included in the repository. It runs directly on each fresh VM and handles the complete provisioning workflow:

1. Detects the OS (Alpine vs Rocky)
2. Prompts for role, hostname, and full network configuration
3. Applies network settings
4. Installs Aetheria packages and pulls the repo
5. Runs the appropriate Ansible roles locally (ansible-pull)
6. Registers the node and signals readiness to CTRL

See full usage in `scripts/node-init.sh` and below.

### Quick-start

```bash
# Transfer the installer bundle to each VM, then:
tar xzf aetheria-<version>-installer.tar.gz
cd aetheria-installer
sudo bash scripts/node-init.sh
```

### What it asks

```
Aetheria Node Initializer v0.0.0-dev
=====================================

[1/7] Node role:
  1) edge       — Alpine: nftables/IDS/eBPF firewall node
  2) brain      — Rocky:  LLM inference + threat analysis node
  3) ctrl       — Rocky:  Control plane primary (API/DB/Gitea)
  4) ctrl-standby — Rocky: Control plane standby (Patroni replica)

[2/7] Node name (e.g. edge1, brain2, ctrl1): edge1

[3/7] Management interface (default: eth0): eth0

[4/7] Management IP address (CIDR, e.g. 192.168.100.170/24): 192.168.100.170/24

[5/7] Default gateway: 192.168.100.1

[6/7] DNS server(s) (space-separated): 8.8.8.8 8.8.4.4

[7/7] Aetheria CTRL IP (for ansible-pull config source): 192.168.100.190

Confirm configuration?
  Role:      edge
  Hostname:  edge1
  Interface: eth0
  IP/CIDR:   192.168.100.170/24
  Gateway:   192.168.100.1
  DNS:       8.8.8.8 8.8.4.4
  CTRL:      192.168.100.190
[y/N]: y

[INFO] Applying network configuration...
[INFO] Installing Aetheria packages...
[INFO] Cloning Aetheria repository...
[INFO] Running Ansible roles for: edge
[INFO] Node edge1 provisioned successfully.
```

### Deployment order with node-init

When using Method C:

1. Run `node-init.sh` on **CTRL1** first — the script installs the repo, initialises Postgres (Patroni primary), and starts Gitea.
2. Run `node-init.sh` on **CTRL2** — connects to CTRL1's Patroni cluster as replica. Confirms replication lag = 0 before exiting.
3. Run `node-init.sh` on **BRAIN1**, **BRAIN2** — joins the etcd cluster, starts llama.cpp server and brain-daemon.
4. Run `node-init.sh` on **EDGE1**, **EDGE2** — configures nftables, Suricata, VRRP; node registers with CTRL API.

---

## Recommended Deployment Order (all methods)

```
CTRL1 → CTRL2 → BRAIN1 → BRAIN2 → EDGE1 → EDGE2
```

**Why this order:**
- CTRL1 must be up before CTRL2 can replicate (Patroni primary/standby).
- CTRL must be up before Brain nodes connect via gRPC.
- Gitea on CTRL must be up before Edge nodes start ansible-pull.
- EDGE nodes last — they are the traffic enforcement point; configure them after the control plane is stable.

---

## Post-Deployment Checklist

- [ ] CTRL Web UI accessible at `https://<CTRL_VIP>/`
- [ ] Admin login succeeds; `must_change_password` changed to a strong value
- [ ] Patroni shows both CTRL nodes: Leader + Replica with Lag = 0
- [ ] WireGuard mesh: all nodes can ping each other on `10.99.0.x`
- [ ] llama.cpp server running on Brain nodes (`curl -s http://127.0.0.1:11434/health` returns `{"status":"ok"}`)
- [ ] Brain daemon running (`systemctl status aetheria-brain` or `docker ps | grep brain`)
- [ ] Edge VRRP VIP active on one edge node (`ip addr show | grep 172`)
- [ ] Suricata running on both edge nodes
- [ ] Test alert: generate a signature match → verify it appears in CTRL Threats page
- [ ] ansible-pull cron active on edge nodes (`crontab -l | grep ansible`)
- [ ] Gitea repo `aetheria/edge-config` exists and is accessible

---

## Upgrade and Rollback

```bash
# Rolling upgrade to a new version
./aetheria-setup upgrade

# Rollback to previous version
./aetheria-setup upgrade --rollback

# Or with Ansible directly
ansible-playbook -i ansible/inventory.yml ansible/upgrade.yml
ansible-playbook -i ansible/inventory.yml ansible/upgrade.yml -e rollback=true
```

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| CTRL1 unreachable | Verify static IP, Docker running, Patroni service |
| CTRL2 not replicating | `pg_stat_wal_receiver` on CTRL2; check WireGuard between .30 and .31 |
| Brain daemon not starting | Check llama.cpp server is running and model is loaded at `/var/lib/aetheria/models/aetheria-analyst-current.gguf` |
| Edge ansible-pull failing | Check Gitea URL in `all.yml`, vault password file on edge nodes |
| WebUI returns 502 | Check `docker ps` on CTRL1 — aetheria-api container may be down |
| Suricata not alerting | Check interface name matches `edge_wan_interface` in `all.yml` |

For full runbook see `docs/deployment/user-deploy-runbook.md`.
