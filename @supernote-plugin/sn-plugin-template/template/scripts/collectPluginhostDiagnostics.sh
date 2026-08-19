#!/usr/bin/env bash

set -euo pipefail

# Load devconfig.json if present
_load_devconfig="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/load-devconfig.sh"
[[ -f "$_load_devconfig" ]] && source "$_load_devconfig"
unset _load_devconfig

readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PLUGIN_HOST_PACKAGE="com.ratta.supernote.pluginhost"
readonly DEVICE_UI_XML="/sdcard/supernote-plugin-diagnostics.xml"

ADB_BIN="${ADB_BIN:-adb}"
DEVICE_SERIAL="${DEVICE_SERIAL:-}"
OUTPUT_ROOT="${DIAGNOSTICS_DIR:-$PROJECT_ROOT/build/pluginhost-diagnostics}"

log() {
    printf '[diagnostics] %s\n' "$*"
}

die() {
    printf '[diagnostics] Error: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: ./collect_pluginhost_diagnostics.sh [options]

Collect PluginHost, Android-window, UI, screenshot, and logcat evidence without
stopping PluginHost or clearing any device data.

Options:
  --device SERIAL  Use one exact ADB device (or set DEVICE_SERIAL).
  --output DIR     Store evidence in DIR instead of build/pluginhost-diagnostics.
  -h, --help       Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --device)
            [[ $# -ge 2 ]] || die '--device requires a serial'
            DEVICE_SERIAL="$2"
            shift 2
            ;;
        --output)
            [[ $# -ge 2 ]] || die '--output requires a directory'
            OUTPUT_ROOT="$2"
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

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
run_dir="$OUTPUT_ROOT/$timestamp"
mkdir -p "$run_dir"

log "Collecting evidence from $DEVICE_SERIAL in $run_dir"

adb_device get-state > "$run_dir/device-state.txt"
"$ADB_BIN" devices -l > "$run_dir/adb-devices.txt"
adb_device shell getprop > "$run_dir/device-properties.txt" 2>&1 || true
adb_device shell pidof "$PLUGIN_HOST_PACKAGE" > "$run_dir/pluginhost-pid.txt" 2>&1 || true
adb_device shell dumpsys activity processes > "$run_dir/activity-processes.txt" 2>&1 || true
adb_device shell dumpsys window > "$run_dir/window.txt" 2>&1 || true
adb_device logcat -d -v threadtime > "$run_dir/logcat.txt" 2>&1
adb_device exec-out screencap -p > "$run_dir/screenshot.png" 2>/dev/null || true

adb_device shell rm -f "$DEVICE_UI_XML" >/dev/null 2>&1 || true
if adb_device shell uiautomator dump "$DEVICE_UI_XML" >/dev/null 2>&1; then
    adb_device exec-out cat "$DEVICE_UI_XML" > "$run_dir/ui.xml" 2>/dev/null || true
fi
adb_device shell rm -f "$DEVICE_UI_XML" >/dev/null 2>&1 || true

grep -Ei \
    'FATAL EXCEPTION|Fatal signal|Process: com\.ratta\.supernote\.pluginhost|SIGABRT|SIGSEGV|UnsatisfiedLinkError|No implementation found|dlopen failed|PluginHost.*(crash|restart)|ReactNativeJS.*(error|fatal)' \
    "$run_dir/logcat.txt" > "$run_dir/pluginhost-errors.txt" || true

error_count="$(awk 'END {print NR + 0}' "$run_dir/pluginhost-errors.txt")"
log "PluginHost/runtime error-pattern lines: $error_count"
if (( error_count >= 10 )); then
    log 'WARNING: repeated errors may indicate a crash or restart loop.'
fi
log "Evidence saved to $run_dir"
log 'No process was stopped and no device data was cleared.'
