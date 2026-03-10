# Getting Software

## 1) Obtain access

Purchase or activate your license at `https://portal.aetheria.io`.

You will receive access to download:
- `aetheria-<version>-installer.tar.gz`
- `aetheria-<version>-installer.tar.gz.sha256`
- `aetheria-<version>-installer.tar.gz.asc`

## 2) One-command path (recommended)

Use local mode by default:

```bash
bash ./deploy-cluster.sh
```

Use portal mode only when you need to download the installer from portal:

```bash
bash ./deploy-cluster.sh --use-portal
```

The script can download the installer artifacts for you and then continue with
cluster deployment.

## 3) Manual verification (if you downloaded separately)

```bash
gpg --import aetheria-release-key.asc
gpg --verify aetheria-<version>-installer.tar.gz.asc aetheria-<version>-installer.tar.gz
sha256sum -c aetheria-<version>-installer.tar.gz.sha256
```

If any verification step fails, stop deployment and contact support.
