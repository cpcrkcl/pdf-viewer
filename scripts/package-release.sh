#!/bin/bash
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
VERSION="${VERSION:-1.0.0}"
OUTPUT_DIRECTORY="${OUTPUT_DIRECTORY:-$PROJECT_DIRECTORY/dist}"
OUTPUT_DMG="$OUTPUT_DIRECTORY/PDFViewer-$VERSION.dmg"
CHECKSUM_FILE="$OUTPUT_DMG.sha256"
SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:--}"
NOTARY_KEYCHAIN_PROFILE="${NOTARY_PROFILE:-}"
PACKAGE_WORK_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/PDFViewer-Package.XXXXXX")"
ARCHIVE_PATH="$PACKAGE_WORK_DIRECTORY/PDFViewer.xcarchive"
STAGING_DIRECTORY="$PACKAGE_WORK_DIRECTORY/dmg"
STAGED_APP="$STAGING_DIRECTORY/PDFViewer.app"

cleanup() {
  if [[ -n "$PACKAGE_WORK_DIRECTORY" && "$PACKAGE_WORK_DIRECTORY" == *PDFViewer-Package.* ]]; then
    rm -rf "$PACKAGE_WORK_DIRECTORY"
  fi
}
trap cleanup EXIT

mkdir -p "$OUTPUT_DIRECTORY"
if [[ -e "$OUTPUT_DMG" || -e "$CHECKSUM_FILE" ]]; then
  if [[ "${OVERWRITE:-0}" != "1" ]]; then
    echo "Release artifact already exists: $OUTPUT_DMG" >&2
    echo "Set OVERWRITE=1 only after confirming that replacement is intended." >&2
    exit 2
  fi
  rm -f "$OUTPUT_DMG" "$CHECKSUM_FILE"
fi

cd "$PROJECT_DIRECTORY"
xcodebuild \
  -project PDFViewer.xcodeproj \
  -scheme PDFViewer \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  archive \
  CODE_SIGNING_ALLOWED=NO

mkdir -p "$STAGING_DIRECTORY"
ditto "$ARCHIVE_PATH/Products/Applications/PDFViewer.app" "$STAGED_APP"
ln -s /Applications "$STAGING_DIRECTORY/Applications"

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  codesign \
    --force \
    --options runtime \
    --sign - \
    --entitlements "$PROJECT_DIRECTORY/PDFViewer/PDFViewer.entitlements" \
    "$STAGED_APP"
else
  codesign \
    --force \
    --timestamp \
    --options runtime \
    --sign "$SIGNING_IDENTITY" \
    --entitlements "$PROJECT_DIRECTORY/PDFViewer/PDFViewer.entitlements" \
    "$STAGED_APP"
fi

codesign --verify --deep --strict --verbose=2 "$STAGED_APP"
codesign --display --entitlements - "$STAGED_APP"

hdiutil create \
  -volname "PDFViewer $VERSION" \
  -srcfolder "$STAGING_DIRECTORY" \
  -format UDZO \
  -ov \
  "$OUTPUT_DMG"

if [[ "$SIGNING_IDENTITY" != "-" ]]; then
  codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$OUTPUT_DMG"
  codesign --verify --verbose=2 "$OUTPUT_DMG"
fi

if [[ -n "$NOTARY_KEYCHAIN_PROFILE" ]]; then
  if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    echo "NOTARY_PROFILE requires a Developer ID CODE_SIGN_IDENTITY." >&2
    exit 3
  fi
  xcrun notarytool submit \
    "$OUTPUT_DMG" \
    --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
    --wait
  xcrun stapler staple "$OUTPUT_DMG"
  xcrun stapler validate "$OUTPUT_DMG"
fi

shasum -a 256 "$OUTPUT_DMG" > "$CHECKSUM_FILE"
echo "Created $OUTPUT_DMG"
echo "Created $CHECKSUM_FILE"
