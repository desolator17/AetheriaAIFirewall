# Customer Deployment Plan (Single-Script)

This repository supports a single operator entrypoint for full cluster deployment:

```bash
bash scripts/deploy-cluster.sh
```

The script drives the full sequence with interactive prompts and deploys nodes in
this enforced order:

1. `CTRL1` (primary)
2. `CTRL2` (standby)
3. `BRAIN1`
4. `BRAIN2`
5. `EDGE1`
6. `EDGE2`

## What the script prompts for

- Installer source:
  - portal download URL **or** local installer tarball path
- Shared network defaults:
  - management interface
  - gateway
  - DNS servers
- Per-node values:
  - role (`ctrl`, `ctrl-standby`, `brain`, `edge`)
  - node name
  - management IP/CIDR
  - SSH target (`user@host`)
- License key (`eyJ...`) used for all node bootstrap runs

The script then copies the installer to each VM, extracts it, and runs
`node-init.sh --non-interactive` with the prompted values.

Installer staging path is user-home based on the SSH account you provide:
- `root@...` -> `/root/.aetheria-bootstrap`
- `rocky@...` -> `/home/rocky/.aetheria-bootstrap`

## Prerequisites

- Management host has: `bash`, `ssh`, `scp`, `curl`, `tar`
- SSH connectivity from management host to all six nodes
- Sudo/root privileges available on target nodes
- Installer bundle available (downloaded via portal URL or already local)

## Mandatory checkpoint after CTRL2

After CTRL2 deploy, replication status is checked on CTRL1 with:

```bash
docker exec aetheria-patroni patronictl -c /etc/patroni/patroni.yml list
```

Continue only when CTRL2 is `Replica` and lag is `0`.

## Non-goals of this public repo

- No private source code
- No internal Ansible implementation roles
- No private CI/CD assets
- No secrets/signing keys
