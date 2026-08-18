#!/usr/bin/env bash

set -euo pipefail

readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PLUGIN_HOST_PACKAGE="com.ratta.supernote.pluginhost"
readonly DEVICE_PLUGIN_DIR="/storage/emulated/0/MyStyle"

ADB_BIN="${ADB_BIN:-adb}"
DEVICE_SERIAL="${DEVICE_SERIAL:-}"
CONFIRMED=0

log() {
    printf '[recovery] %s\n' "$*"
}

die() {
    printf '[recovery] Error: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: ./recover_pluginhost.sh --yes [--device SERIAL]

Emergency recovery for a confirmed PluginHost crash or restart loop.

WARNING: this clears ALL PluginHost application data, including every installed
plugin. Collect diagnostics first with collectPluginhostDiagnostics.sh.

Options:
  --yes            Confirm the destructive PluginHost data clear.
  --device SERIAL  Use one exact ADB device (or set DEVICE_SERIAL).
  -h, --help       Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes)
            CONFIRMED=1
            shift
            ;;
        --device)
            [[ $# -ge 2 ]] || die '--device requires a serial'
            DEVICE_SERIAL="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

[[ "$CONFIRMED" == 1 ]] ||
    die 'recovery clears all PluginHost data; collect diagnostics, then rerun with --yes'
command -v "$ADB_BIN" >/dev/null 2>&1 || die "$ADB_BIN was not found in PATH"

adb_device() {
    "$ADB_BIN" -s "$DEVICE_SERIAL" "$@"
}

select_device() {
    if [[ -n "$DEVICE_SERIAL" ]]; then
        [[ "$(adb_device get-state 2>/dev/null || true)" == device ]] ||
            die "ADB device $DEVICE_SERIAL is not connected and authorized"
        return
    fi

    local devices=()
    while IFS= read -r serial; do
        [[ -n "$serial" ]] && devices+=("$serial")
    done < <("$ADB_BIN" devices | awk 'NR > 1 && $2 == "device" {print $1}')

    case "${#devices[@]}" in
        0) die 'no connected and authorized Android device was found' ;;
        1) DEVICE_SERIAL="${devices[0]}" ;;
        *) die 'multiple devices are connected; pass --device SERIAL' ;;
    esac
}

select_device

plugin_name=""
if [[ -f "$PROJECT_ROOT/PluginConfig.json" ]] && command -v jq >/dev/null 2>&1; then
    plugin_name="$(jq -er '.name | select(type == "string" and length > 0)' \
        "$PROJECT_ROOT/PluginConfig.json" 2>/dev/null || true)"
fi

log "Stopping PluginHost and clearing all of its application data on $DEVICE_SERIAL..."
adb_device shell am force-stop "$PLUGIN_HOST_PACKAGE" || true
clear_result="$(adb_device shell pm clear "$PLUGIN_HOST_PACKAGE" | tr -d '\r')"
[[ "$clear_result" == Success ]] || die "pm clear returned: $clear_result"
adb_device shell pm enable "$PLUGIN_HOST_PACKAGE" >/dev/null

if [[ -n "$plugin_name" ]]; then
    adb_device shell rm -f "$DEVICE_PLUGIN_DIR/${plugin_name}.snplg"
    log "Removed uploaded package: ${plugin_name}.snplg"
fi

adb_device logcat -c

for build_dir in \
    "$PROJECT_ROOT/build" \
    "$PROJECT_ROOT/android/build" \
    "$PROJECT_ROOT/android/app/build"
do
    if [[ -d "$build_dir" ]]; then
        rm -rf -- "$build_dir"
        log "Removed local build output: $build_dir"
    fi
done

log 'Recovery complete. User source and installed dependencies were preserved.'
