#!/usr/bin/env bash
set -euo pipefail

readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ADB_BIN="${ADB_BIN:-adb}"
DEVICE_SERIAL="${DEVICE_SERIAL:-}"

die() {
    printf '[send_bundle] Error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "$1 was not found in PATH"
}

adb_device() {
    if [[ -n "$DEVICE_SERIAL" ]]; then
        "$ADB_BIN" -s "$DEVICE_SERIAL" "$@"
    else
        "$ADB_BIN" "$@"
    fi
}

select_device() {
    require_command "$ADB_BIN"

    if [[ -n "$DEVICE_SERIAL" ]]; then
        [[ "$(adb_device get-state 2>/dev/null || true)" == 'device' ]] ||
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
        *) die 'multiple devices are connected; pass --device SERIAL or set DEVICE_SERIAL' ;;
    esac
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --device)
                [[ $# -ge 2 ]] || die '--device requires a serial'
                DEVICE_SERIAL="$2"
                shift 2
                ;;
            *)
                die "unknown option: $1"
                ;;
        esac
    done
}

main() {
    parse_args "$@"
    select_device

    require_command jq

    local plugin_id bundle_name
    [[ -f "$PROJECT_ROOT/PluginConfig.json" ]] || die "missing $PROJECT_ROOT/PluginConfig.json (Run 'npm run build' first)"
    plugin_id="$(jq -r ".pluginID" "$PROJECT_ROOT/PluginConfig.json")"
    bundle_name="$(jq -r ".name" "$PROJECT_ROOT/PluginConfig.json")"

    if [[ -z "$plugin_id" || "$plugin_id" == "null" ]]; then
      echo "Plugin ID not found in PluginConfig.json"
      exit 1
    fi

    if [[ -z "$bundle_name" || "$bundle_name" == "null" ]]; then
      echo "Bundle name not found in PluginConfig.json"
      exit 1
    fi

    local local_bundle_dir="$PROJECT_ROOT/build/generated"
    local local_bundle_path="${local_bundle_dir}/${bundle_name}.bundle"
    local device_bundle_path="/sdcard/EXPORT/${bundle_name}.bundle"

    mkdir -p "$local_bundle_dir"

    echo "Bundling to: $local_bundle_path"
    (
        cd "$PROJECT_ROOT"
        npx react-native bundle \
          --entry-file index.js \
          --bundle-output "$local_bundle_path" \
          --platform android \
          --assets-dest "$local_bundle_dir" \
          --dev false
    )

    echo "Pushing bundle to device: $device_bundle_path"
    adb_device push "$local_bundle_path" "$device_bundle_path"

    echo "Installing bundle via broadcast (plugin_id=$plugin_id)"
    local broadcast_output=""
    if ! broadcast_output="$(adb_device shell am broadcast \
      -a com.ratta.supernote.plugin.action.DEBUG \
      -n com.ratta.supernote.pluginhost/.receiver.PluginReceiver \
      --es bundle_path "$device_bundle_path" \
      --es plugin_id "$plugin_id" 2>&1)"; then
      printf '%s\n' "$broadcast_output" >&2
      echo "Bundle installation broadcast failed" >&2
      exit 1
    fi

    printf '%s\n' "$broadcast_output"
    if ! grep -Eq 'Broadcast completed: result=0([[:space:]]|$)' <<< "$broadcast_output"; then
      echo "Bundle installation was rejected by the plugin host" >&2
      exit 1
    fi

    echo "Bundle successfully sent to device and installed via broadcast."
}

main "$@"
