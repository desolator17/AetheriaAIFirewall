# Aetheria AI Firewall - Public Installer Access

This repository is the **public customer bootstrap repo** for Aetheria deployments.
It intentionally excludes private source code and internal engineering assets.

Use this repo to:
- pull the signed installer bundle,
- verify integrity/signature,
- follow the deployment order for `CTRL1 -> CTRL2 -> BRAIN1 -> BRAIN2 -> EDGE1 -> EDGE2`.

## What is in this repo

- `scripts/pull-installer.sh` - helper to download installer artifacts from your portal URL
- `docs/deployment/GETTING_SOFTWARE.md` - software acquisition and verification guide
- `docs/deployment/CUSTOMER_DEPLOYMENT_PLAN.md` - end-to-end deployment sequence

## What is NOT in this repo

- private source code
- internal build pipelines
- internal test assets
- signing private keys or vault secrets

## Quick start

1. Get your license and download URL from `https://portal.aetheria.io`.
2. Download artifacts:
   ```bash
   bash scripts/pull-installer.sh \
     --url "<portal-download-url>/aetheria-<version>-installer.tar.gz" \
     --out ./downloads
   ```
3. Verify and deploy using:
   - `docs/deployment/GETTING_SOFTWARE.md`
   - `docs/deployment/CUSTOMER_DEPLOYMENT_PLAN.md`
