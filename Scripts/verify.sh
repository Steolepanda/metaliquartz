#!/bin/zsh

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
derived_data_dir="$(mktemp -d "${TMPDIR%/}/MetaliquartzDerivedData.XXXXXX")"

cleanup() {
    rm -rf "$derived_data_dir"
}
trap cleanup EXIT

cd "$project_root"

echo "Checking the Metal compiler..."
if ! xcrun metal --version; then
    metal_component_json="$(xcodebuild -showComponent MetalToolchain -json 2>/dev/null || true)"
    metal_toolchain_identifier="$(
        printf '%s' "$metal_component_json" \
            | plutil -extract toolchainIdentifier raw -o - - 2>/dev/null \
            || true
    )"
    if [[ -z "$metal_toolchain_identifier" ]]; then
        echo "The Metal Toolchain is unavailable. Install it with:" >&2
        echo "  xcodebuild -downloadComponent MetalToolchain" >&2
        exit 1
    fi
    export TOOLCHAINS="$metal_toolchain_identifier"
    xcrun metal --version
fi

echo "Linting Swift sources..."
xcrun swift-format lint --strict --configuration .swift-format --recursive Sources Tests UITests

# The public six-patch schema fixture makes this check reproducible from a clean checkout.
echo "Checking generated Quartz Composer definitions..."
if command -v python3 >/dev/null 2>&1; then
    python3 Scripts/generate-swift-color-patches.py --check
else
    echo "python3 is required for the generated-definition check" >&2
    exit 1
fi

# Structural documentation gate. This proves links, anchors, the decision registry and fixture
# hashes are consistent; it never proves prose matches the runtime. See docs/verification/README.md.
echo "Checking documentation structure..."
if [[ -x Scripts/verify-docs ]]; then
    Scripts/verify-docs --strict
else
    echo "Scripts/verify-docs is unavailable; skipping the documentation check" >&2
fi

common_arguments=(
    -quiet
    -project Metaliquartz.xcodeproj
    -scheme Metaliquartz
    -destination "platform=macOS,arch=arm64"
    -derivedDataPath "$derived_data_dir"
)

echo "Building Debug..."
xcodebuild "${common_arguments[@]}" -configuration Debug build

echo "Running unit and UI tests..."
xcodebuild "${common_arguments[@]}" -configuration Debug -parallel-testing-enabled NO test

echo "Building Release..."
xcodebuild "${common_arguments[@]}" -configuration Release build

echo "Metaliquartz verification passed."
