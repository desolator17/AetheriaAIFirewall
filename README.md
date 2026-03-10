# Aetheria AI Firewall - Public Customer Bootstrap

This repository is the public customer bootstrap surface for Aetheria.

It is intentionally limited to deployment guides and a single interactive script
for full six-node rollout.

## One Script Deployment

Use exactly one script for full deployment:

```bash
bash ./deploy-cluster.sh
```

Default mode is local/private artifact auto-detection.
Use portal mode only when needed:

```bash
bash ./deploy-cluster.sh --use-portal
```

The script prompts for:
- installer source (portal URL or local tarball)
- deployment scope (FULL, CTRL-only, BRAIN-only, EDGE-only)
- node role/name/IP/SSH target
- management network defaults
- license key

Then it deploys in order:

`CTRL1 -> CTRL2 -> BRAIN1 -> BRAIN2 -> EDGE1 -> EDGE2`

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
