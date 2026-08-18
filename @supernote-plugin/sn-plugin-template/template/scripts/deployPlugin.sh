#!/usr/bin/env bash

set -euo pipefail

readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly DEVICE_PLUGIN_DIR="/storage/emulated/0/MyStyle"
readonly DEVICE_UI_XML="/sdcard/supernote-deploy-window.xml"
readonly PLUGIN_MANAGER_ACTION="com.ratta.settings.application.PluginManagerFragment"
readonly PLUGIN_MANAGER_COMPONENT="com.ratta.settings/.SettingsActivity"
readonly NOTE_COMPONENT="com.ratta.supernote.note/.view.NoteInsidePagesActivity"
readonly PLUGIN_HOST_PACKAGE="com.ratta.supernote.pluginhost"

ADB_BIN="${ADB_BIN:-adb}"
DEVICE_SERIAL="${DEVICE_SERIAL:-}"
SKIP_BUILD=0
STOP_AFTER_PUSH=0
STOP_BEFORE_INSTALL=0
NO_LAUNCH=0
PACKAGE_OVERRIDE=""
LAUNCH_LABEL="${PLUGIN_LAUNCH_LABEL:-}"
UI_SETTLE_SECONDS="${UI_SETTLE_SECONDS:-1}"
UI_TIMEOUT_SECONDS="${UI_TIMEOUT_SECONDS:-20}"
INSTALL_TIMEOUT_SECONDS="${INSTALL_TIMEOUT_SECONDS:-120}"
RUNTIME_TIMEOUT_SECONDS="${RUNTIME_TIMEOUT_SECONDS:-30}"

TMP_DIR=""
UI_XML=""
PLUGIN_NAME=""
PLUGIN_ID=""
PLUGIN_FILE=""
DEVICE_PLUGIN_PATH=""

log() {
    printf '[deploy] %s\n' "$*"
}

die() {
    printf '[deploy] Error: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: ./deploy_plugin.sh [options]

Build, copy, install, and launch this plugin through the normal Supernote UI.

Options:
  --device SERIAL        Use one exact ADB device (or set DEVICE_SERIAL).
  --package PATH         Deploy this existing .snplg instead of building.
  --skip-build           Use the existing build/outputs/<name>.snplg package.
  --stop-after-push      Stop after verifying the package copied to MyStyle.
  --stop-before-install  Select the package, but do not press Install.
  --no-launch            Install the package, but do not launch it from NOTE.
  --launch-label LABEL   NOTE sidebar label to tap (defaults to plugin name).
  -h, --help             Show this help.

The script fails closed if a device, UI control, package, or destination state
is ambiguous. Supernote firmware-specific routes are verified after opening.
EOF
}

cleanup() {
    if [[ -n "$DEVICE_SERIAL" ]]; then
        adb_device shell rm -f "$DEVICE_UI_XML" >/dev/null 2>&1 || true
    fi
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        rm -f -- "$TMP_DIR"/* 2>/dev/null || true
        rmdir "$TMP_DIR" 2>/dev/null || true
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --device)
                [[ $# -ge 2 ]] || die '--device requires a serial'
                DEVICE_SERIAL="$2"
                shift 2
                ;;
            --skip-build)
                SKIP_BUILD=1
                shift
                ;;
            --package)
                [[ $# -ge 2 ]] || die '--package requires a path'
                PACKAGE_OVERRIDE="$2"
                SKIP_BUILD=1
                shift 2
                ;;
            --stop-after-push)
                STOP_AFTER_PUSH=1
                shift
                ;;
            --stop-before-install)
                STOP_BEFORE_INSTALL=1
                shift
                ;;
            --no-launch)
                NO_LAUNCH=1
                shift
                ;;
            --launch-label)
                [[ $# -ge 2 ]] || die '--launch-label requires a value'
                LAUNCH_LABEL="$2"
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
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "$1 was not found in PATH"
}

adb_device() {
    "$ADB_BIN" -s "$DEVICE_SERIAL" "$@"
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
        *) die 'multiple devices are connected; pass --device SERIAL' ;;
    esac
}

read_project_metadata() {
    require_command jq
    [[ -f "$PROJECT_ROOT/PluginConfig.json" ]] ||
        die "missing $PROJECT_ROOT/PluginConfig.json"

    PLUGIN_NAME="$(jq -er '.name | select(type == "string" and length > 0)' \
        "$PROJECT_ROOT/PluginConfig.json")" || die 'PluginConfig.json has no name'
    PLUGIN_ID="$(jq -er '.pluginID | select(type == "string" and length > 0)' \
        "$PROJECT_ROOT/PluginConfig.json")" || die 'PluginConfig.json has no pluginID'

    [[ "$PLUGIN_NAME" != */* && "$PLUGIN_NAME" != *'"'* ]] ||
        die "unsupported plugin name for deployment: $PLUGIN_NAME"
    [[ "$PLUGIN_ID" != *"'"* && "$PLUGIN_ID" != *'"'* ]] ||
        die "unsupported plugin ID for deployment: $PLUGIN_ID"

    if [[ -n "$PACKAGE_OVERRIDE" ]]; then
        local package_directory package_basename
        package_directory="$(cd "$(dirname "$PACKAGE_OVERRIDE")" 2>/dev/null && pwd)" ||
            die "package directory does not exist: $(dirname "$PACKAGE_OVERRIDE")"
        package_basename="$(basename "$PACKAGE_OVERRIDE")"
        PLUGIN_FILE="$package_directory/$package_basename"
    else
        PLUGIN_FILE="$PROJECT_ROOT/build/outputs/${PLUGIN_NAME}.snplg"
    fi
    DEVICE_PLUGIN_PATH="$DEVICE_PLUGIN_DIR/${PLUGIN_NAME}.snplg"

    if [[ -z "$LAUNCH_LABEL" && -f "$PROJECT_ROOT/.supernote-launch-label" ]]; then
        IFS= read -r LAUNCH_LABEL < "$PROJECT_ROOT/.supernote-launch-label" || true
    fi
    [[ -n "$LAUNCH_LABEL" ]] || LAUNCH_LABEL="$PLUGIN_NAME"
}

verify_package() {
    local package_path="$1"
    [[ -f "$package_path" ]] || die "plugin package not found: $package_path"
    [[ -s "$package_path" ]] || die "plugin package is empty: $package_path"

    require_command unzip
    unzip -tqq "$package_path" || die "plugin package is not a valid ZIP: $package_path"

    local packaged_config="$TMP_DIR/PluginConfig.json"
    unzip -p "$package_path" PluginConfig.json > "$packaged_config" ||
        die 'plugin package does not contain PluginConfig.json'

    local packaged_name packaged_id
    packaged_name="$(jq -er '.name' "$packaged_config")" ||
        die 'packaged PluginConfig.json has no name'
    packaged_id="$(jq -er '.pluginID' "$packaged_config")" ||
        die 'packaged PluginConfig.json has no pluginID'
    [[ "$packaged_name" == "$PLUGIN_NAME" ]] ||
        die "package name mismatch: expected $PLUGIN_NAME, found $packaged_name"
    [[ "$packaged_id" == "$PLUGIN_ID" ]] ||
        die "package pluginID mismatch: expected $PLUGIN_ID, found $packaged_id"

    if [[ -f "$PROJECT_ROOT/scripts/verifyPluginPackage.sh" ]]; then
        log 'Running the complete package inspection...'
        bash "$PROJECT_ROOT/scripts/verifyPluginPackage.sh" "$package_path"
    fi
}

build_plugin() {
    local build_marker="$TMP_DIR/build-start"
    : > "$build_marker"

    [[ -x "$PROJECT_ROOT/android/gradlew" ]] ||
        die 'android/gradlew is missing or not executable'

    log 'Running strict Android build gate...'
    "$PROJECT_ROOT/android/gradlew" \
        -p "$PROJECT_ROOT/android" \
        :app:buildCustomApkDebug \
        --no-daemon

    log 'Packaging the plugin...'
    (
        cd "$PROJECT_ROOT"
        bash ./scripts/buildPlugin.sh
    )

    # The official template may create PluginConfig.json during the first
    # package build. Read metadata only after packaging so a fresh project can
    # be deployed by this one command.
    read_project_metadata

    [[ -f "$PLUGIN_FILE" && "$PLUGIN_FILE" -nt "$build_marker" ]] ||
        die "build did not produce a fresh package: $PLUGIN_FILE"
}

local_sha256() {
    local path="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$path" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$path" | awk '{print $1}'
    else
        return 1
    fi
}

push_and_verify_package() {
    log "Copying $(basename "$PLUGIN_FILE") to $DEVICE_PLUGIN_DIR on $DEVICE_SERIAL..."
    adb_device shell mkdir -p "$DEVICE_PLUGIN_DIR"
    adb_device push "$PLUGIN_FILE" "$DEVICE_PLUGIN_PATH"

    local local_size remote_size
    local_size="$(wc -c < "$PLUGIN_FILE" | tr -d '[:space:]')"
    remote_size="$(adb_device shell stat -c %s "$DEVICE_PLUGIN_PATH" 2>/dev/null | tr -d '\r[:space:]')"
    [[ -n "$remote_size" && "$remote_size" == "$local_size" ]] ||
        die "device package size mismatch: local=$local_size remote=${remote_size:-unknown}"

    local local_hash remote_hash
    local_hash="$(local_sha256 "$PLUGIN_FILE" 2>/dev/null || true)"
    remote_hash="$(adb_device shell sha256sum "$DEVICE_PLUGIN_PATH" 2>/dev/null | awk '{print $1}' | tr -d '\r')"
    if [[ -n "$local_hash" && -n "$remote_hash" ]]; then
        [[ "$remote_hash" == "$local_hash" ]] ||
            die "device package SHA-256 mismatch: local=$local_hash remote=$remote_hash"
        log "Verified device SHA-256: $local_hash"
    else
        log "Verified device size: $local_size bytes (SHA-256 unavailable on one side)"
    fi
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

wake_and_unlock_device() {
    log 'Waking the Supernote and dismissing its unsecured keyguard...'
    adb_device shell input keyevent KEYCODE_WAKEUP
    adb_device shell wm dismiss-keyguard >/dev/null 2>&1 || true
    sleep "$UI_SETTLE_SECONDS"
}

ensure_note_foreground() {
    local current
    current="$(foreground_window 2>/dev/null || true)"
    if [[ "$current" == *'com.ratta.supernote.note/'* ]]; then
        log 'NOTE is already the foreground app.'
        return
    fi

    if [[ "$current" == *'com.ratta.supernote.pluginhost'* ]]; then
        log 'A plugin window is open; closing it through its visible close control...'
        if try_dump_ui && ui_has_unique_node content-desc '✕'; then
            tap_unique_node content-desc '✕'
            if wait_for_foreground 'com.ratta.supernote.note/'; then
                log 'Closed the plugin window and returned to NOTE.'
                return
            fi
        fi
        log 'The plugin window did not close cleanly; trying the NOTE activity route.'
    fi

    log 'NOTE is not in the foreground; opening it before deployment...'
    adb_device shell am start \
        -a android.intent.action.MAIN \
        -c android.intent.category.LAUNCHER \
        -n "$NOTE_COMPONENT" >/dev/null
    wait_for_foreground 'com.ratta.supernote.note/' ||
        die 'NOTE did not reach the foreground before deployment'
    log 'Verified NOTE is the foreground app.'
    sleep "$UI_SETTLE_SECONDS"
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

verify_plugin_manager_page() {
    wait_for_foreground 'com.ratta.settings/com.ratta.settings.SettingsActivity' ||
        return 1
    try_dump_ui || return 1
    [[ "$(foreground_window 2>/dev/null || true)" == \
       *'com.ratta.settings/com.ratta.settings.SettingsActivity'* ]] ||
        return 1
    ui_has_unique_node text 'Plugins' || return 1
    ui_has_unique_node text 'Add Plugin' || return 1
}

wait_for_installed_plugin() {
    local deadline current installing_logged=0
    deadline="$(( $(date +%s) + INSTALL_TIMEOUT_SECONDS ))"
    while (( $(date +%s) <= deadline )); do
        current="$(foreground_window 2>/dev/null || true)"
        if [[ "$current" == \
              *'com.ratta.settings/com.ratta.settings.SettingsActivity'* ]] &&
           try_dump_ui; then
            if ui_has_unique_node text 'Plugins' &&
               ui_has_unique_node text 'Add Plugin' &&
               ui_has_unique_node text "$PLUGIN_NAME"; then
                return 0
            fi
            if ui_has_unique_node text 'Installing…' &&
               [[ "$installing_logged" == 0 ]]; then
                log "Supernote is installing $PLUGIN_NAME; waiting up to ${INSTALL_TIMEOUT_SECONDS}s..."
                installing_logged=1
            fi
        fi
        sleep 1
    done
    return 1
}

pluginhost_pid() {
    adb_device shell pidof "$PLUGIN_HOST_PACKAGE" 2>/dev/null |
        tr -d '\r' |
        awk '{print $1}'
}

wait_for_pluginhost_available() {
    local deadline current_pid
    deadline="$(( $(date +%s) + RUNTIME_TIMEOUT_SECONDS ))"
    while (( $(date +%s) <= deadline )); do
        current_pid="$(pluginhost_pid || true)"
        if [[ -n "$current_pid" ]]; then
            printf '%s\n' "$current_pid"
            return 0
        fi
        sleep 1
    done
    return 1
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

open_plugin_manager_fallback() {
    log 'Direct Plugin Manager route was unavailable; using the NOTE toolbar fallback...'
    adb_device shell am start \
        -a android.intent.action.MAIN \
        -c android.intent.category.LAUNCHER \
        -n "$NOTE_COMPONENT" >/dev/null
    wait_for_foreground 'com.ratta.supernote.note/' ||
        die 'NOTE did not produce a foreground window for the Plugin Manager fallback'
    sleep "$UI_SETTLE_SECONDS"
    dump_ui
    tap_unique_node content-desc plugins
    dump_ui
    tap_unique_node text 'Manage Plugins'
    sleep "$UI_SETTLE_SECONDS"
    verify_plugin_manager_page ||
        die 'NOTE toolbar fallback did not reach the Supernote Plugins page'
}

open_plugin_manager() {
    log 'Opening the Supernote Plugins page...'
    if adb_device shell am start \
        -a "$PLUGIN_MANAGER_ACTION" \
        -n "$PLUGIN_MANAGER_COMPONENT" >/dev/null 2>&1; then
        sleep "$UI_SETTLE_SECONDS"
        if verify_plugin_manager_page; then
            log 'Verified direct Supernote Plugin Manager route.'
            return
        fi
    fi
    open_plugin_manager_fallback
}

open_package_picker() {
    tap_unique_node text 'Add Plugin'
    wait_for_foreground \
        'com.ratta.supernote.inbox/com.ratta.supernote.explorer.SelectFileActivity' ||
        die 'Select Plugin picker did not produce a foreground window'
    dump_ui
    [[ "$(foreground_window 2>/dev/null || true)" == \
       *'com.ratta.supernote.inbox/com.ratta.supernote.explorer.SelectFileActivity'* ]] ||
        die 'Select Plugin picker did not reach the foreground'
    ui_has_unique_node text 'Select Plugin' || die 'Select Plugin title was not found'
    ui_has_unique_node text 'MyStyle' || die 'Select Plugin picker did not open in MyStyle'
}

select_device_package() {
    local filename
    filename="$(basename "$DEVICE_PLUGIN_PATH")"
    dump_ui
    tap_unique_node text "$filename"
    dump_ui
    ui_has_unique_node text "$filename" ||
        die "selected package disappeared from the picker: $filename"
    ui_has_unique_node text 'Install' || die 'Install action was not found'
    log "Selected exact package: $filename"
}

install_selected_package() {
    local previous_pid current_pid
    previous_pid="$(pluginhost_pid || true)"
    tap_unique_node text 'Install'

    wait_for_installed_plugin ||
        die "Install did not list $PLUGIN_NAME on the verified Supernote Plugins page within ${INSTALL_TIMEOUT_SECONDS}s"

    current_pid="$(wait_for_pluginhost_available || true)"
    [[ -n "$current_pid" ]] ||
        die "PluginHost was not available within ${RUNTIME_TIMEOUT_SECONDS}s after Install"
    if [[ -n "$previous_pid" && "$current_pid" == "$previous_pid" ]]; then
        log "Installed $PLUGIN_NAME in the existing PluginHost PID $current_pid."
    elif [[ -n "$previous_pid" ]]; then
        log "Installed $PLUGIN_NAME; PluginHost restarted from PID $previous_pid to $current_pid."
    else
        log "Installed $PLUGIN_NAME; PluginHost is PID $current_pid."
    fi
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
    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/supernote-deploy.XXXXXX")"
    UI_XML="$TMP_DIR/window.xml"
    trap cleanup EXIT

    if [[ "$SKIP_BUILD" == 0 ]]; then
        build_plugin
    elif [[ -n "$PACKAGE_OVERRIDE" ]]; then
        read_project_metadata
        log "Using supplied package without rebuilding: $PLUGIN_FILE"
    else
        read_project_metadata
        log 'Skipping build; the existing package will be verified before use.'
    fi

    select_device
    log "Using device: $DEVICE_SERIAL"
    verify_package "$PLUGIN_FILE"
    push_and_verify_package

    if [[ "$STOP_AFTER_PUSH" == 1 ]]; then
        log 'Stopped after verified push as requested.'
        return
    fi

    wake_and_unlock_device
    ensure_note_foreground
    open_plugin_manager
    open_package_picker
    select_device_package

    if [[ "$STOP_BEFORE_INSTALL" == 1 ]]; then
        log 'Stopped before Install as requested.'
        return
    fi

    install_selected_package
}

main "$@"
