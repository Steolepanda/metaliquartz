#!/bin/zsh

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
output_directory="${1:-/tmp/MetaliquartzAlpha}"
work_directory="$(mktemp -d "${TMPDIR%/}/MetaliquartzArchive.XXXXXX")"
archive_path="$work_directory/Metaliquartz.xcarchive"
zip_path="$output_directory/Metaliquartz-alpha-arm64.zip"

cleanup() {
    rm -rf "$work_directory"
}
trap cleanup EXIT

cd "$project_root"
./Scripts/verify.sh

xcodebuild \
    -quiet \
    -project Metaliquartz.xcodeproj \
    -scheme Metaliquartz \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "$archive_path" \
    archive

app_path="$archive_path/Products/Applications/Metaliquartz.app"
codesign --verify --deep --strict "$app_path"

mkdir -p "$output_directory"
ditto -c -k --norsrc --keepParent "$app_path" "$zip_path"
shasum -a 256 "$zip_path" > "$zip_path.sha256"

echo "Alpha archive: $zip_path"
echo "Checksum: $zip_path.sha256"
