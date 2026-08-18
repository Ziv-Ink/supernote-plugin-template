#!/usr/bin/env bash

set -euo pipefail

readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PACKAGE_PATH="${1:-}"
TMP_DIR=""

log() {
    printf '[verify-package] %s\n' "$*"
}

die() {
    printf '[verify-package] Error: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: ./verify_plugin_package.sh [PACKAGE.snplg]

Validate a Supernote plugin package, its nested app.npk, metadata, ABI layout,
and host-owned native-library exclusions. With no path, use the package named
by PluginConfig.json under build/outputs.
EOF
}

if [[ "$PACKAGE_PATH" == -h || "$PACKAGE_PATH" == --help ]]; then
    usage
    exit 0
fi
[[ $# -le 1 ]] || die 'expected zero or one package path'

for command_name in jq unzip; do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "$command_name was not found in PATH"
done

if [[ -z "$PACKAGE_PATH" ]]; then
    [[ -f "$PROJECT_ROOT/PluginConfig.json" ]] ||
        die 'PluginConfig.json is missing; pass an explicit package path'
    plugin_name="$(jq -er '.name | select(type == "string" and length > 0)' \
        "$PROJECT_ROOT/PluginConfig.json")" || die 'PluginConfig.json has no name'
    PACKAGE_PATH="$PROJECT_ROOT/build/outputs/${plugin_name}.snplg"
fi

package_directory="$(cd "$(dirname "$PACKAGE_PATH")" 2>/dev/null && pwd)" ||
    die "package directory does not exist: $(dirname "$PACKAGE_PATH")"
PACKAGE_PATH="$package_directory/$(basename "$PACKAGE_PATH")"

[[ -f "$PACKAGE_PATH" ]] || die "package not found: $PACKAGE_PATH"
[[ -s "$PACKAGE_PATH" ]] || die "package is empty: $PACKAGE_PATH"
unzip -tqq "$PACKAGE_PATH" || die 'outer .snplg is not a valid ZIP archive'

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/supernote-package.XXXXXX")"
cleanup() {
    rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT

unzip -p "$PACKAGE_PATH" PluginConfig.json > "$TMP_DIR/PluginConfig.json" ||
    die 'outer package does not contain PluginConfig.json'
jq -e 'type == "object"' "$TMP_DIR/PluginConfig.json" >/dev/null ||
    die 'packaged PluginConfig.json is not a JSON object'
packaged_name="$(jq -er '.name | select(type == "string" and length > 0)' \
    "$TMP_DIR/PluginConfig.json")" || die 'packaged PluginConfig.json has no name'
packaged_id="$(jq -er '.pluginID | select(type == "string" and length > 0)' \
    "$TMP_DIR/PluginConfig.json")" || die 'packaged PluginConfig.json has no pluginID'

if [[ -f "$PROJECT_ROOT/PluginConfig.json" ]]; then
    expected_name="$(jq -er '.name | select(type == "string" and length > 0)' \
        "$PROJECT_ROOT/PluginConfig.json")" || die 'project PluginConfig.json has no name'
    expected_id="$(jq -er '.pluginID | select(type == "string" and length > 0)' \
        "$PROJECT_ROOT/PluginConfig.json")" || die 'project PluginConfig.json has no pluginID'
    [[ "$packaged_name" == "$expected_name" ]] ||
        die "package name mismatch: expected $expected_name, found $packaged_name"
    [[ "$packaged_id" == "$expected_id" ]] ||
        die "package pluginID mismatch: expected $expected_id, found $packaged_id"
fi

has_native=0
if jq -e '.nativeCodePackage | type == "string" and length > 0' "$TMP_DIR/PluginConfig.json" >/dev/null 2>&1; then
    has_native=1
fi

native_libraries=""
if [[ "$has_native" == 1 ]]; then
    unzip -p "$PACKAGE_PATH" app.npk > "$TMP_DIR/app.npk" ||
        die 'outer package does not contain app.npk (required because nativeCodePackage is declared)'
    [[ -s "$TMP_DIR/app.npk" ]] || die 'nested app.npk is empty'
    unzip -tqq "$TMP_DIR/app.npk" || die 'nested app.npk is not a valid ZIP archive'
    unzip -Z1 "$TMP_DIR/app.npk" > "$TMP_DIR/app-npk-inventory.txt"

    if grep -Eq '^lib/(armeabi-v7a|x86|x86_64)/' "$TMP_DIR/app-npk-inventory.txt"; then
        die 'nested app.npk contains an unsupported non-arm64 native ABI'
    fi

    if grep -Eq \
        '^lib/arm64-v8a/(libjsi|libreactnative|libhermes|libfbjni|libc\+\+_shared)\.so$' \
        "$TMP_DIR/app-npk-inventory.txt"; then
        die 'nested app.npk packages a PluginHost-owned native library'
    fi

    native_libraries="$(grep -E '^lib/[^/]+/[^/]+\.so$' \
        "$TMP_DIR/app-npk-inventory.txt" || true)"
fi

if command -v sha256sum >/dev/null 2>&1; then
    package_hash="$(sha256sum "$PACKAGE_PATH" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
    package_hash="$(shasum -a 256 "$PACKAGE_PATH" | awk '{print $1}')"
else
    package_hash='unavailable'
fi

log "Package: $PACKAGE_PATH"
log "Plugin: $packaged_name ($packaged_id)"
log "SHA-256: $package_hash"
if [[ -n "$native_libraries" ]]; then
    log 'Native libraries:'
    printf '%s\n' "$native_libraries"
else
    log 'Native libraries: none'
fi
log 'Package structure and native-library policy passed.'
