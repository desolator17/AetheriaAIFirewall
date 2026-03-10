# Aetheria AI Firewall - Public Customer Bootstrap

This repository is the public customer bootstrap surface for Aetheria.

It is intentionally limited to deployment guides and a single interactive script
for full six-node rollout.

## One Script Deployment

```bash
sudo bash install-aetheria
```

That's it. The script:
1. Finds or builds the node installer bundle automatically
2. Prompts for deployment scope, node details, and license key
3. Deploys nodes in order: `CTRL1 → CTRL2 → BRAIN1 → BRAIN2 → EDGE1 → EDGE2`

All flags are passed through to the underlying deployment engine:

```bash
sudo bash install-aetheria --use-portal       # download installer from portal URL
sudo bash install-aetheria --identity FILE    # use SSH key for all connections
sudo bash install-aetheria --resume           # skip nodes already marked DONE
```

If the installer bundle cannot be found or built automatically, the script
prints clear instructions for providing it manually.

## Command-line flags

| Flag / Env var              | Description |
|-----------------------------|-------------|
| (none)                      | Local installer auto-detect mode |
| `--use-portal`              | Download installer from portal URL |
| `--identity FILE`           | SSH private key for all connections |
| `--resume`                  | Skip nodes already marked DONE in `.deploy-state` |
| `--force`                   | Re-deploy even if marked DONE |
| `--skip-preflight`          | Skip SSH connectivity pre-flight |
| `AETHERIA_INSTALLER_DIR`    | Directory to search first for the installer tarball |

## SSH setup

All target VMs must have SSH enabled with root access before running the script.
For Rocky Linux: enable root SSH during OS installation.
For Alpine Linux: run `setup-alpine` and enable SSH.

For key-based auth:
```bash
ssh-keygen -t ed25519 -f ~/.ssh/aetheria_deploy -N ""
ssh-copy-id -i ~/.ssh/aetheria_deploy.pub root@<each_vm_ip>
bash ./deploy-cluster.sh --identity ~/.ssh/aetheria_deploy
```

## Repository scope

Included:
- customer-safe docs
- bootstrap deployment script
- security contact guidance

Excluded:
- private source code
- internal CI/CD and engineering assets
- secrets and signing private keys

## Documentation

- `docs/deployment/GETTING_SOFTWARE.md`
- `docs/deployment/CUSTOMER_DEPLOYMENT_PLAN.md`
- `docs/deployment/SANITIZED_INSTALLER_IMPLEMENTATION_PLAN.md`
- `docs/deployment/PUBLIC_REPO_AUDIT_2026-03-10.md`
