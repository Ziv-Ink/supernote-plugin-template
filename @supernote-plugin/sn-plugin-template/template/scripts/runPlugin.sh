#!/usr/bin/env bash

set -euo pipefail

readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly DEVICE_UI_XML="/sdcard/supernote-deploy-window.xml"
readonly NOTE_COMPONENT="com.ratta.supernote.note/.view.NoteInsidePagesActivity"
readonly PLUGIN_HOST_PACKAGE="com.ratta.supernote.pluginhost"

ADB_BIN="${ADB_BIN:-adb}"
DEVICE_SERIAL="${DEVICE_SERIAL:-}"
UI_SETTLE_SECONDS="${UI_SETTLE_SECONDS:-1}"
UI_TIMEOUT_SECONDS="${UI_TIMEOUT_SECONDS:-20}"
RUNTIME_TIMEOUT_SECONDS="${RUNTIME_TIMEOUT_SECONDS:-30}"

TMP_DIR=""
UI_XML=""
PLUGIN_NAME=""
PLUGIN_ID=""
LAUNCH_LABEL=""

log() {
    printf '[run_plugin] %s\n' "$*"
}

die() {
    printf '[run_plugin] Error: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        rm -f -- "$TMP_DIR"/* 2>/dev/null || true
        rmdir "$TMP_DIR" 2>/dev/null || true
    fi
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

read_project_metadata() {
    require_command jq
    [[ -f "$PROJECT_ROOT/PluginConfig.json" ]] ||
        die "missing $PROJECT_ROOT/PluginConfig.json (Run 'npm run build' first)"

    PLUGIN_NAME="$(jq -er '.name | select(type == "string" and length > 0)' \
        "$PROJECT_ROOT/PluginConfig.json")" || die 'PluginConfig.json has no name'
    PLUGIN_ID="$(jq -er '.pluginID | select(type == "string" and length > 0)' \
        "$PROJECT_ROOT/PluginConfig.json")" || die 'PluginConfig.json has no pluginID'

    if [[ -z "$LAUNCH_LABEL" && -n "${PLUGIN_LAUNCH_LABEL:-}" ]]; then
        LAUNCH_LABEL="$PLUGIN_LAUNCH_LABEL"
    fi
    if [[ -z "$LAUNCH_LABEL" && -f "$PROJECT_ROOT/.supernote-launch-label" ]]; then
        IFS= read -r LAUNCH_LABEL < "$PROJECT_ROOT/.supernote-launch-label" || true
    fi
    [[ -n "$LAUNCH_LABEL" ]] || LAUNCH_LABEL="$PLUGIN_NAME"
}

foreground_window() {
    adb_device shell dumpsys window |
        grep -m 1 'mCurrentFocus=' |
        tr -d '\r'
}

wait_for_foreground() {
    local expected="$1"
    local deadline current
    deadline="$(( $(date +%s) + UI_TIMEOUT_SECONDS ))"
    while (( $(date +%s) <= deadline )); do
        current="$(foreground_window 2>/dev/null || true)"
        if [[ "$current" == *"$expected"* ]]; then
            return 0
        fi
        sleep 1
    done
    return 1
}

try_dump_ui() {
    local deadline output
    deadline="$(( $(date +%s) + UI_TIMEOUT_SECONDS ))"
    while (( $(date +%s) <= deadline )); do
        adb_device shell rm -f "$DEVICE_UI_XML" >/dev/null 2>&1 || true
        output="$(adb_device shell uiautomator dump "$DEVICE_UI_XML" 2>&1 || true)"
        if [[ "$output" == *'UI hierchary dumped to:'* ||
              "$output" == *'UI hierarchy dumped to:'* ]]; then
            if adb_device exec-out cat "$DEVICE_UI_XML" > "$UI_XML" 2>/dev/null &&
               [[ -s "$UI_XML" ]] && grep -q '<hierarchy' "$UI_XML"; then
                return 0
            fi
        fi
        sleep 1
    done
    return 1
}

dump_ui() {
    try_dump_ui ||
        die "Android UI hierarchy was unavailable for ${UI_TIMEOUT_SECONDS}s"
}

nodes_matching() {
    local attribute="$1"
    local value="$2"
    grep -o '<node [^>]*>' "$UI_XML" |
        grep -F "${attribute}=\"${value}\"" || true
}

unique_bounds() {
    local attribute="$1"
    local value="$2"
    local nodes count bounds
    nodes="$(nodes_matching "$attribute" "$value")"
    count="$(printf '%s\n' "$nodes" | awk 'NF {count++} END {print count + 0}')"
    [[ "$count" == 1 ]] ||
        die "expected one UI node with $attribute=\"$value\", found $count"
    bounds="$(printf '%s\n' "$nodes" | sed -n \
        's/.*bounds="\(\[[0-9][0-9]*,[0-9][0-9]*\]\[[0-9][0-9]*,[0-9][0-9]*\]\)".*/\1/p')"
    [[ -n "$bounds" ]] || die "UI node $attribute=\"$value\" has no usable bounds"
    printf '%s\n' "$bounds"
}

tap_bounds_center() {
    local bounds="$1"
    local coordinates x1 y1 x2 y2
    coordinates="$(printf '%s\n' "$bounds" | sed -E \
        's/^\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]$/\1 \2 \3 \4/')"
    read -r x1 y1 x2 y2 <<< "$coordinates"
    [[ "$x1" =~ ^[0-9]+$ && "$y1" =~ ^[0-9]+$ &&
       "$x2" =~ ^[0-9]+$ && "$y2" =~ ^[0-9]+$ ]] ||
        die "invalid UI bounds: $bounds"
    adb_device shell input tap "$(((x1 + x2) / 2))" "$(((y1 + y2) / 2))"
}

tap_unique_node() {
    local attribute="$1"
    local value="$2"
    local bounds
    bounds="$(unique_bounds "$attribute" "$value")"
    log "Tapping $attribute=\"$value\" at $bounds"
    tap_bounds_center "$bounds"
    sleep "$UI_SETTLE_SECONDS"
}

ui_has_unique_node() {
    local attribute="$1"
    local value="$2"
    local count
    count="$(nodes_matching "$attribute" "$value" | awk 'NF {count++} END {print count + 0}')"
    [[ "$count" == 1 ]]
}

pluginhost_pid() {
    adb_device shell pidof "$PLUGIN_HOST_PACKAGE" 2>/dev/null |
        tr -d '\r' |
        awk '{print $1}'
}

log_pattern_count() {
    local needle="$1"
    adb_device logcat -d -v brief 2>/dev/null |
        awk -v needle="$needle" 'index($0, needle) { count++ }
            END { print count + 0 }'
}

wait_for_new_log_occurrence() {
    local needle="$1"
    local previous_count="$2"
    local deadline current_count
    deadline="$(( $(date +%s) + RUNTIME_TIMEOUT_SECONDS ))"
    while (( $(date +%s) <= deadline )); do
        current_count="$(log_pattern_count "$needle" || true)"
        if [[ "$current_count" =~ ^[0-9]+$ ]] &&
           (( current_count > previous_count )); then
            return 0
        fi
        sleep 1
    done
    return 1
}

launch_plugin() {
    local event_pattern running_pattern
    local previous_event_count previous_running_count current_pid
    event_pattern="pluginID='$PLUGIN_ID', pluginName='$PLUGIN_NAME'"
    running_pattern="Running \"$PLUGIN_NAME\""

    log 'Opening NOTE to launch the installed plugin...'
    adb_device shell am start \
        -a android.intent.action.MAIN \
        -c android.intent.category.LAUNCHER \
        -n "$NOTE_COMPONENT" >/dev/null
    wait_for_foreground 'com.ratta.supernote.note/' ||
        die 'NOTE did not produce a foreground window for plugin launch'
    sleep "$UI_SETTLE_SECONDS"

    dump_ui
    tap_unique_node content-desc plugins
    dump_ui
    ui_has_unique_node text "$LAUNCH_LABEL" ||
        die "NOTE plugin popup did not list launch label $LAUNCH_LABEL exactly once"

    previous_event_count="$(log_pattern_count "$event_pattern")"
    previous_running_count="$(log_pattern_count "$running_pattern")"
    tap_unique_node text "$LAUNCH_LABEL"
    wait_for_new_log_occurrence "$event_pattern" "$previous_event_count" ||
        die "PluginHost did not receive the configured plugin ID and name within ${RUNTIME_TIMEOUT_SECONDS}s"
    wait_for_new_log_occurrence "$running_pattern" "$previous_running_count" ||
        die "PluginHost did not log '$running_pattern' within ${RUNTIME_TIMEOUT_SECONDS}s"

    current_pid="$(pluginhost_pid || true)"
    [[ -n "$current_pid" ]] || die 'PluginHost exited while launching the plugin'
    log "Launched $PLUGIN_NAME through NOTE (PluginHost PID $current_pid)."
}

main() {
    parse_args "$@"
    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/supernote-run.XXXXXX")"
    UI_XML="$TMP_DIR/window.xml"
    trap cleanup EXIT

    read_project_metadata
    select_device
    log "Using device: $DEVICE_SERIAL"
    launch_plugin
}

main "$@"
