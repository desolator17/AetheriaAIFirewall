#!/usr/bin/env bash
set -euo pipefail

URL=""
OUT_DIR="./downloads"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)
      URL="$2"
      shift 2
      ;;
    --out)
      OUT_DIR="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$URL" ]]; then
  echo "Usage: $0 --url <installer-tarball-url> [--out <directory>]" >&2
  exit 2
fi

mkdir -p "$OUT_DIR"

BASE_NAME="$(basename "$URL")"
if [[ "$BASE_NAME" != *.tar.gz ]]; then
  echo "Expected installer URL ending with .tar.gz" >&2
  exit 2
fi

SHA_URL="${URL}.sha256"
ASC_URL="${URL}.asc"

echo "Downloading installer bundle..."
curl -fL "$URL" -o "$OUT_DIR/$BASE_NAME"

echo "Downloading checksum..."
curl -fL "$SHA_URL" -o "$OUT_DIR/${BASE_NAME}.sha256"

echo "Downloading signature..."
curl -fL "$ASC_URL" -o "$OUT_DIR/${BASE_NAME}.asc"

echo "Downloaded artifacts to: $OUT_DIR"
echo "Next: verify with docs/deployment/GETTING_SOFTWARE.md"
