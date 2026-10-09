#!/usr/bin/env bash
# Downloads the pinned universal macOS PDFium build into vendor/pdfium.
# PDFium is BSD-3/Apache-2 licensed; the archive's LICENSE is kept alongside it.
set -euo pipefail

PDFIUM_RELEASE="${PDFIUM_RELEASE:-chromium/8086}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/vendor/pdfium"

if [[ -f "$DEST/lib/libpdfium.dylib" && "${1:-}" != "--force" ]]; then
  echo "PDFium already present at $DEST"
  exit 0
fi

rm -rf "$DEST"
mkdir -p "$DEST"
curl -fsSL "https://github.com/bblanchon/pdfium-binaries/releases/download/${PDFIUM_RELEASE}/pdfium-mac-univ.tgz" \
  | tar -xz -C "$DEST"
echo "$PDFIUM_RELEASE" > "$DEST/RELEASE"
echo "Installed PDFium $PDFIUM_RELEASE to $DEST"
