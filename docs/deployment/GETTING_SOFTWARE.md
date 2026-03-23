# Getting Aetheria — Software Delivery Guide

Aetheria is **closed-source commercial software**. It is not available via public
GitHub clone or any free download. This guide explains the complete process from
purchase to a running production deployment.

---

## 1. Purchase a License

Go to **https://portal.aetheria.io** and select your license tier:

| Tier | Best for |
|------|---------|
| **PRO** | Single organisation, up to 5 sites, SSO, compliance reporting |
| **Enterprise** | Unlimited sites/nodes, air-gap, professional services, SLA |
| **Trial** | 30-day evaluation, max 1 site, single CTRL |

After purchase you will receive two items by email:
- Your **license key** — a JWT string beginning with `eyJ...`
- A link to your **portal account** where you can download the installer

---

## 2. Download the Installer Bundle

Log in to [https://portal.aetheria.io](https://portal.aetheria.io) with your account
credentials. Under **Downloads**, select the version that matches your support contract
and download:

```
aetheria-<version>-installer.tar.gz
aetheria-<version>-installer.tar.gz.sha256
aetheria-<version>-installer.tar.gz.asc
```

> Download links are time-limited (24 hours). Regenerate from the portal if they expire.

---

## 3. Verify the Bundle (mandatory)

Before extracting or running anything, verify the cryptographic integrity of the bundle.

### Import the Aetheria release signing key

```bash
# Download the Aetheria release public key from the portal
# (also embedded inside the bundle once extracted)
gpg --import aetheria-release-key.asc

# Verify the fingerprint matches what is shown in your portal account
gpg --fingerprint releases@aetheria.io
```

### Verify GPG signature and checksum

```bash
# GPG signature check
gpg --verify aetheria-<version>-installer.tar.gz.asc \
             aetheria-<version>-installer.tar.gz

# SHA256 checksum
sha256sum -c aetheria-<version>-installer.tar.gz.sha256
```

Expected output:
```
aetheria-<version>-installer.tar.gz: OK
gpg: Good signature from "Aetheria Releases <releases@aetheria.io>"
```

**Do not proceed if either check fails.** Contact [support@aetheria.io](mailto:support@aetheria.io).

---

## 4. Prepare Your VMs

Aetheria requires the following fresh VMs, provisioned and reachable over SSH
before running the installer:

| Node | Count | OS | Min vCPU | Min RAM | Min Disk |
|------|-------|----|----------|---------|----------|
| CTRL | 2 | Rocky Linux 9 Minimal | 2 | 4 GB | 30 GB |
| Brain | 2 | Alpine Linux 3.21 | 4 | 8 GB | 40 GB |
| Edge | 2 | Alpine Linux 3.21 | 2 | 2 GB | 20 GB |

> **Brain nodes need enough RAM for the LLM model.** `phi3:mini` ≈ 1.5 GB VRAM/RAM.
> `qwen3:4b` ≈ 4 GB. Size accordingly.

Requirements for all VMs:
- Static management IP configured
- SSH enabled (root on Alpine; `rocky` user with sudo NOPASSWD on Rocky)
- Python 3 installed (`dnf install python3` / `apk add python3`)
- All nodes must reach each other and your management host on the chosen management CIDR

---

## 5. Choose Your Installation Method

### Method A — Interactive per-VM script (recommended for most customers)

Run `node-init.sh` directly on each VM. The script handles everything interactively.
No separate management host is required.

### Method B — Wizard + Ansible push from a management host

Run `aetheria-setup wizard` on a management host that has SSH access to all target VMs,
then run `aetheria-setup deploy` to push the full configuration in one operation.

---

## 6A. Install Using node-init.sh (per-VM method)

### Transfer the bundle to CTRL1

```bash
# From your laptop or jump host:
scp aetheria-<version>-installer.tar.gz rocky@<CTRL1_IP>:~
```

### Extract and run on CTRL1

```bash
ssh rocky@<CTRL1_IP>
tar xzf aetheria-<version>-installer.tar.gz
cd aetheria-installer

sudo bash node-init.sh
```

The script will prompt for:

```
Aetheria Node Initializer v<version>
=====================================

[1/8] License key (from portal.aetheria.io): eyJ...

[2/8] Node role:
  1) ctrl         — Rocky: Control plane primary (API/DB/Gitea/WebUI)
  2) ctrl-standby — Rocky: Control plane standby (Patroni replica)
  3) brain        — Alpine: LLM inference + threat analysis node
  4) edge         — Alpine: nftables/IDS/eBPF firewall node

[3/8] Node name (e.g. ctrl1): ctrl1

[4/8] Management interface (default: eth0): eth0

[5/8] Management IP address with prefix (e.g. 192.168.10.10/24): 192.168.10.10/24

[6/8] Default gateway: 192.168.10.1

[7/8] DNS server(s) (space-separated): 8.8.8.8 1.1.1.1

[8/8] CTRL primary IP (for ansible-pull / other nodes to register):
      (Press Enter if this IS the CTRL primary): 192.168.10.10

Confirm and proceed? [y/N]: y

[INFO] Validating license key...
[INFO] Applying network configuration...
[INFO] Installing Aetheria packages...
[INFO] Extracting pre-compiled binaries...
[INFO] Running Ansible roles for: ctrl
[INFO] Initialising PostgreSQL (Patroni primary)...
[INFO] Starting Gitea...
[INFO] Starting API and WebUI...
[INFO] Node ctrl1 provisioned successfully.

Next steps:
  1. Access Web UI: https://192.168.10.10/
  2. Login:         admin / <generated-password shown above>
  3. Deploy CTRL2:  run node-init.sh on CTRL2 VM, choose ctrl-standby
```

### Deploy remaining nodes in order

Repeat `node-init.sh` on each VM, selecting the appropriate role:

```
CTRL2  → role: ctrl-standby
BRAIN1 → role: brain
BRAIN2 → role: brain
EDGE1  → role: edge
EDGE2  → role: edge
```

**Transfer the bundle to each VM first:**
```bash
scp aetheria-<version>-installer.tar.gz root@<BRAIN1_IP>:~
scp aetheria-<version>-installer.tar.gz root@<EDGE1_IP>:~
# etc.
```

### Verify CTRL2 replication before continuing

After CTRL2 is provisioned, confirm Patroni streaming replication is healthy before
deploying Brain and Edge nodes:

```bash
ssh rocky@<CTRL1_IP>
sudo docker exec aetheria-patroni \
  patronictl -c /etc/patroni/patroni.yml list
```

Expected:
```
+ Cluster: aetheria-ctrl +--------+----+-----------+
| Member | Host        | Role    | State   | TL | Lag in MB |
+--------+-------------+---------+---------+----+-----------+
| ctrl1  | 10.99.0.30  | Leader  | running |  1 |           |
| ctrl2  | 10.99.0.31  | Replica | running |  1 |         0 |
+--------+-------------+---------+---------+----+-----------+
```

**Lag must be 0** before you proceed. If lag is non-zero, wait for replication to catch up.

---

## 6B. Install Using aetheria-setup (management host method)

### Extract on management host

```bash
tar xzf aetheria-<version>-installer.tar.gz
cd aetheria-installer
pip3 install questionary
```

### Run the wizard

```bash
./aetheria-setup wizard
```

The wizard will ask for:
- Platform (`vmware_fusion`, `proxmox`, `esxi`, `baremetal`, `aws`)
- Deployment size (`standard` = 2E/2B/2C, `enterprise` = custom)
- Management CIDR (e.g. `192.168.10.0/24`)
- IP addresses for each node (manual or auto-assign from CIDR)
- LLM model selection
- Feature flags (TLS inspection, WireGuard mesh)

Output: `ansible/inventory.yml` and `ansible/group_vars/all.yml`

### Configure secrets

```bash
cp ansible/group_vars/vault.yml.skeleton ansible/group_vars/vault.yml
vim ansible/group_vars/vault.yml       # fill in vault_* values
ansible-vault encrypt ansible/group_vars/vault.yml
echo "your-vault-passphrase" > ~/.vault_pass
chmod 600 ~/.vault_pass
```

Minimum required vault entries:
```yaml
vault_keepalived_auth_secret: "<32+ random chars>"
vault_wireguard_psk: "<output of: wg genpsk>"
vault_ctrl_admin_password: "<strong password>"
vault_postgres_password: "<strong password>"
vault_bootstrap_ssh_password: "<strong replacement for default image ssh password>"
vault_aetheria_license_key: "<license key JWT>"
```

Before exposing any node to production networks, ensure the bootstrap image SSH
password is rotated via `vault_bootstrap_ssh_password` during first Ansible run.

### Distribute SSH keys

```bash
ssh-keygen -t ed25519 -f ~/.ssh/aetheria_deploy -N ""
for host in <CTRL1> <CTRL2> <BRAIN1> <BRAIN2> <EDGE1> <EDGE2>; do
    ssh-copy-id -i ~/.ssh/aetheria_deploy.pub rocky@${host} 2>/dev/null || \
    ssh-copy-id -i ~/.ssh/aetheria_deploy.pub root@${host}
done
```

### Deploy — CTRL1 first

```bash
# CTRL1 primary (Patroni leader must be up before CTRL2 replica)
ANSIBLE_SSH_PASS="<ssh-password>" \
  ansible-playbook -i ansible/inventory.yml ansible/site.yml --limit ctrl1
```

Verify CTRL1 is healthy:
```bash
curl -k -I https://<CTRL1_IP>/      # expect HTTP/2 200
```

### Deploy — CTRL2 (verify replication)

```bash
ANSIBLE_SSH_PASS="<ssh-password>" \
  ansible-playbook -i ansible/inventory.yml ansible/ctrl2-provision.yml
```

Verify replication lag = 0 (see patronictl list command above).

### Deploy — BRAIN and EDGE nodes

```bash
# Full site deploy for remaining nodes
ANSIBLE_SSH_PASS="<ssh-password>" \
  ./aetheria-setup deploy
```

Or using the convenience wrapper which handles the correct playbook order:
```bash
ANSIBLE_SSH_PASS="<ssh-password>" ANSIBLE_SUDO_PASS="<sudo-password>" \
  ./aetheria-setup deploy
```

---

## 7. Post-Installation Checklist

Run through each item before considering the installation complete:

- [ ] CTRL Web UI accessible at `https://<CTRL_VIP>/` (must use VIP, not direct node IP)
- [ ] Direct node IPs redirect to VIP: `curl -L -I https://192.168.100.190/ | grep Location` should show 301 redirect
- [ ] Cluster power controls work: "Bring Cluster Offline" button shows confirmation dialog requiring "CONFIRM" text
- [ ] Admin login succeeds; change the generated password immediately
- [ ] Patroni shows Leader + Replica with Lag = 0
- [ ] WireGuard mesh: all nodes ping each other on `10.99.0.x`
- [ ] `curl -s http://127.0.0.1:11434/health` on both Brain nodes returns `{"status":"ok"}` (llama.cpp server health check)
- [ ] brain-daemon running: `docker ps | grep brain-daemon`
- [ ] Edge VRRP VIP active: `ip addr show | grep <VIP>`
- [ ] Suricata running on both Edge nodes
- [ ] ansible-pull cron active on Edge nodes: `crontab -l | grep ansible`
- [ ] Gitea repo `aetheria/edge-config` present and accessible
- [ ] License key accepted (no 402 errors in API logs)
- [ ] Generate a test threat alert and verify it appears in CTRL → Threats

---

## 8. First Login and License Activation

```
URL:      https://<CTRL_VIP>/
Username: admin
Password: (shown at end of node-init.sh, or check /etc/aetheria/admin-credentials)
```

On first login you will be prompted to:
1. Change the admin password
2. Enter your license key (if not already injected via Ansible Vault)
3. Configure the site name and basic settings

---

## 9. Accessing Documentation Offline

Full documentation is bundled with the installer:

```bash
cd aetheria-installer
pip3 install mkdocs mkdocs-material
mkdocs serve -f docs/mkdocs.yml
# Open http://127.0.0.1:8000 in your browser
```

---

## 10. Support

| Channel | Details |
|---------|---------|
| Portal | https://portal.aetheria.io — license management, downloads, tickets |
| Email | support@aetheria.io |
| Security | security@aetheria.io (vulnerabilities only) |
| Sales | sales@aetheria.io |

Include your **license key hash** and **Aetheria version** in all support requests.
Retrieve these with:
```bash
cat /opt/aetheria/VERSION
cat /etc/aetheria/license.key | cut -d. -f2 | base64 -d 2>/dev/null | python3 -m json.tool | grep -E '"tier|issued_to|expires'
```

---

## Cluster Offline/Online Operational Semantics

- `Take cluster offline` is a **service-only** workflow: EDGE and BRAIN services are stopped in sequence, but VMs remain powered on.
- CTRL control-plane services stay available during offline maintenance: WebUI/API/nginx and PostgreSQL remain running so operators can monitor and issue `Bring cluster online` directly from the dashboard.
- `Bring cluster online` restores services; it does not assume hosts were powered off.
- The WebUI dashboard provides a cluster power control panel:
  - Green "Bring Cluster Online" button when cluster is offline
  - Red "Bring Cluster Offline" button when cluster is online
  - Status output area below the button showing success (green) or failure (red) messages

### VIP-Only Cluster Power Controls

- **Access via VIP URL** (`https://<CTRL_VIP>/`): The "Bring Cluster Offline" button is enabled. Clicking it shows an inline confirmation dialog asking you to type `CONFIRM` (case-sensitive) before the offline action executes. This prevents accidental cluster shutdown.
- **Access via direct node IP** (e.g., `https://192.168.100.190/`):
  - nginx automatically redirects with a **301 permanent redirect** to the VIP URL using a catch-all `server_name _` block.
  - The API detects direct node IP access via the HTTP `Host` header and returns `vip_holder: false` from the health endpoint.
  - The "Bring Cluster Offline" button is disabled with a warning banner instructing operators to use the VIP URL for cluster power controls.

### How VIP Detection Works

The API endpoint `GET /api/v1/health` detects VIP access by comparing the HTTP request `Host` header to the `CTRL_VIP_IP` environment variable. This method works reliably inside Docker containers, unlike querying `ip addr show` which is affected by network namespace isolation. The response field `vip_holder` is `true` only when accessed via the VIP.

---

## Troubleshooting

| Symptom | First check |
|---------|-------------|
| `402 License required` | License key in `/etc/aetheria/license.key`; restart aetheria-api container |
| CTRL2 not replicating | `patronictl list` on CTRL1; check WireGuard link .30 ↔ .31 |
| Brain daemon crash loop | `docker logs aetheria-brain-daemon`; verify llama.cpp server has model loaded at `/var/lib/aetheria/models/aetheria-analyst-current.gguf` |
| Edge ansible-pull failing | Gitea URL in `group_vars/all.yml`; vault pass file on edge |
| WebUI 502 | `docker logs aetheria-api` first; if you see `Connect call failed ('192.168.100.195', 5432)` or `no pg_hba.conf entry for host`, set CTRL API DB URL to `host.docker.internal:5432` and ensure pg_hba allows Docker bridges (172.16/12) |
| GPG verify failed | Re-download from portal; contact support if issue persists |

For full runbook see `docs/deployment/user-deploy-runbook.md`.
