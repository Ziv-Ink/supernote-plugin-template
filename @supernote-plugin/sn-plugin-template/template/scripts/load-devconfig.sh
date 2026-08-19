#!/bin/bash
# load-devconfig.sh — Source this file to apply devconfig.json settings.
# Exports JAVA_HOME, ANDROID_HOME, ANDROID_SDK_ROOT, and ADB_BIN for the
# current process only.  Does nothing when devconfig.json is absent.

_devconfig_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_devconfig_project_root="$(cd "$_devconfig_script_dir/.." && pwd)"
_devconfig_file="$_devconfig_project_root/devconfig.json"

if [[ ! -f "$_devconfig_file" ]]; then
    unset _devconfig_script_dir _devconfig_project_root _devconfig_file
    return 0 2>/dev/null || true
fi

# ------------------------------------------------------------------
# Read all three values in a single subprocess.
# ------------------------------------------------------------------
_devconfig_java_home=""
_devconfig_android_sdk=""
_devconfig_adb=""

if command -v python3 >/dev/null 2>&1; then
    {
        IFS= read -r _devconfig_java_home
        IFS= read -r _devconfig_android_sdk
        IFS= read -r _devconfig_adb
    } < <(python3 -c "
import json, sys
c = json.load(open(sys.argv[1], encoding='utf-8-sig'))
for k in ('javaHome', 'androidSdk', 'adb'):
    v = c.get(k)
    print(v if v else '')
" "$_devconfig_file" 2>/dev/null)
elif command -v jq >/dev/null 2>&1; then
    _devconfig_java_home="$(jq -r '.javaHome // empty' "$_devconfig_file" 2>/dev/null)"
    _devconfig_android_sdk="$(jq -r '.androidSdk // empty' "$_devconfig_file" 2>/dev/null)"
    _devconfig_adb="$(jq -r '.adb // empty' "$_devconfig_file" 2>/dev/null)"
fi

# ------------------------------------------------------------------
# Java
# ------------------------------------------------------------------
if [[ -n "$_devconfig_java_home" && -d "$_devconfig_java_home" ]]; then
    export JAVA_HOME="$_devconfig_java_home"
    export PATH="$JAVA_HOME/bin:$PATH"
fi

# ------------------------------------------------------------------
# Android SDK
# ------------------------------------------------------------------
if [[ -n "$_devconfig_android_sdk" && -d "$_devconfig_android_sdk" ]]; then
    export ANDROID_HOME="$_devconfig_android_sdk"
    export ANDROID_SDK_ROOT="$_devconfig_android_sdk"

    # Update android/local.properties — only the sdk.dir line, preserve the rest.
    _devconfig_local_props="$_devconfig_project_root/android/local.properties"
    mkdir -p "$(dirname "$_devconfig_local_props")"
    if [[ -f "$_devconfig_local_props" ]] && grep -q '^sdk\.dir=' "$_devconfig_local_props" 2>/dev/null; then
        awk -v sdk="$_devconfig_android_sdk" \
            '/^sdk\.dir=/{print "sdk.dir=" sdk; next}{print}' \
            "$_devconfig_local_props" > "${_devconfig_local_props}.tmp" \
            && mv "${_devconfig_local_props}.tmp" "$_devconfig_local_props"
    else
        printf 'sdk.dir=%s\n' "$_devconfig_android_sdk" >> "$_devconfig_local_props"
    fi
    unset _devconfig_local_props
fi

# ------------------------------------------------------------------
# ADB
# ------------------------------------------------------------------
if [[ -n "$_devconfig_adb" ]]; then
    export ADB_BIN="$_devconfig_adb"
fi

# ------------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------------
unset _devconfig_java_home _devconfig_android_sdk _devconfig_adb
unset _devconfig_script_dir _devconfig_project_root _devconfig_file
