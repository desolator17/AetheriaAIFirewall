# Getting Aetheria Software

1. Purchase/activate your license at `https://portal.aetheria.io`.
2. From your portal account, copy the installer URL for:
   - `aetheria-<version>-installer.tar.gz`
3. Download bundle + checksum + signature:
   ```bash
   bash scripts/pull-installer.sh \
     --url "<portal-download-url>/aetheria-<version>-installer.tar.gz" \
     --out ./downloads
   ```
4. Verify integrity:
   ```bash
   cd downloads
   gpg --import aetheria-release-key.asc
   gpg --verify aetheria-<version>-installer.tar.gz.asc aetheria-<version>-installer.tar.gz
   sha256sum -c aetheria-<version>-installer.tar.gz.sha256
   ```
5. Extract and continue with deployment plan:
   ```bash
   tar xzf aetheria-<version>-installer.tar.gz
   cd aetheria-installer
   ```

If any verification step fails, stop and contact support.
