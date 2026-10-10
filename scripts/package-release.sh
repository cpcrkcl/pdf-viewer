#!/bin/bash
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
VERSION="${VERSION:-1.0.0}"
if [[ ! "$VERSION" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ || ${#VERSION} -gt 64 ]]; then
  echo "VERSION must be 1-64 letters, numbers, dots, underscores, or hyphens." >&2
  exit 2
fi
OUTPUT_DIRECTORY="${OUTPUT_DIRECTORY:-$PROJECT_DIRECTORY/dist}"
OUTPUT_DMG="$OUTPUT_DIRECTORY/PDFViewer-$VERSION.dmg"
CHECKSUM_FILE="$OUTPUT_DMG.sha256"
SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:--}"
NOTARY_KEYCHAIN_PROFILE="${NOTARY_PROFILE:-}"
PACKAGE_WORK_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/PDFViewer-Package.XXXXXX")"
FINALIZATION_DIRECTORY=""
ARCHIVE_PATH="$PACKAGE_WORK_DIRECTORY/PDFViewer.xcarchive"
STAGING_DIRECTORY="$PACKAGE_WORK_DIRECTORY/dmg"
STAGED_APP="$STAGING_DIRECTORY/PDFViewer.app"
STAGED_OFFICE_HELPER="$STAGED_APP/Contents/PlugIns/PDFViewerOfficeConversionHelper.xpc"

cleanup() {
  if [[ -n "$PACKAGE_WORK_DIRECTORY" && "$PACKAGE_WORK_DIRECTORY" == *PDFViewer-Package.* ]]; then
    rm -rf "$PACKAGE_WORK_DIRECTORY"
  fi
  if [[ -n "$FINALIZATION_DIRECTORY" && "$FINALIZATION_DIRECTORY" == "$OUTPUT_DIRECTORY"/.PDFViewer-Release.* ]]; then
    rm -rf "$FINALIZATION_DIRECTORY"
  fi
}
trap cleanup EXIT

mkdir -p "$OUTPUT_DIRECTORY"
FINALIZATION_DIRECTORY="$(mktemp -d "$OUTPUT_DIRECTORY/.PDFViewer-Release.XXXXXX")"
STAGED_DMG="$FINALIZATION_DIRECTORY/PDFViewer-$VERSION.dmg"
STAGED_CHECKSUM="$STAGED_DMG.sha256"
if [[ -d "$OUTPUT_DMG" || -d "$CHECKSUM_FILE" ]]; then
  echo "Release artifact path is a directory; refusing to replace it." >&2
  exit 2
fi
if [[ -e "$OUTPUT_DMG" || -e "$CHECKSUM_FILE" ]]; then
  if [[ "${OVERWRITE:-0}" != "1" ]]; then
    echo "Release artifact already exists: $OUTPUT_DMG" >&2
    echo "Set OVERWRITE=1 only after confirming that replacement is intended." >&2
    exit 2
  fi
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

if [[ ! -d "$STAGED_OFFICE_HELPER" ]]; then
  echo "Archived app is missing the Office conversion XPC service." >&2
  exit 4
fi

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  codesign \
    --force \
    --options runtime \
    --sign - \
    --entitlements "$PROJECT_DIRECTORY/PDFViewerOfficeConversionHelper/OfficeConversionHelper.entitlements" \
    "$STAGED_OFFICE_HELPER"
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
    --entitlements "$PROJECT_DIRECTORY/PDFViewerOfficeConversionHelper/OfficeConversionHelper.entitlements" \
    "$STAGED_OFFICE_HELPER"
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
  "$STAGED_DMG"

if [[ "$SIGNING_IDENTITY" != "-" ]]; then
  codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$STAGED_DMG"
  codesign --verify --verbose=2 "$STAGED_DMG"
fi

if [[ -n "$NOTARY_KEYCHAIN_PROFILE" ]]; then
  if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    echo "NOTARY_PROFILE requires a Developer ID CODE_SIGN_IDENTITY." >&2
    exit 3
  fi
  xcrun notarytool submit \
    "$STAGED_DMG" \
    --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
    --wait
  xcrun stapler staple "$STAGED_DMG"
  xcrun stapler validate "$STAGED_DMG"
fi

shasum -a 256 "$STAGED_DMG" | sed "s|  .*|  $(basename "$OUTPUT_DMG")|" > "$STAGED_CHECKSUM"
mv -f "$STAGED_DMG" "$OUTPUT_DMG"
mv -f "$STAGED_CHECKSUM" "$CHECKSUM_FILE"
echo "Created $OUTPUT_DMG"
echo "Created $CHECKSUM_FILE"
