# load-devconfig.ps1 — Dot-source this file to apply devconfig.json settings.
# Sets JAVA_HOME, ANDROID_HOME, ANDROID_SDK_ROOT, and ADB_BIN for the
# current process only.  Does nothing when devconfig.json is absent.

$_DevConfigScriptDir = $PSScriptRoot
if (-not $_DevConfigScriptDir) {
    $_DevConfigScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if (-not $_DevConfigScriptDir) { return }

$_DevConfigDir = Split-Path -Parent $_DevConfigScriptDir
$_DevConfigFile = Join-Path $_DevConfigDir 'devconfig.json'

if (-not (Test-Path $_DevConfigFile)) { return }

try {
    $_Config = Get-Content $_DevConfigFile -Raw -ErrorAction Stop | ConvertFrom-Json
} catch {
    return
}

# ------------------------------------------------------------------
# Java
# ------------------------------------------------------------------
if ($_Config.javaHome -and (Test-Path $_Config.javaHome -PathType Container -ErrorAction SilentlyContinue)) {
    $env:JAVA_HOME = $_Config.javaHome
    $env:PATH = (Join-Path $_Config.javaHome 'bin') + [IO.Path]::PathSeparator + $env:PATH
}

# ------------------------------------------------------------------
# Android SDK
# ------------------------------------------------------------------
if ($_Config.androidSdk -and (Test-Path $_Config.androidSdk -PathType Container -ErrorAction SilentlyContinue)) {
    $env:ANDROID_HOME = $_Config.androidSdk
    $env:ANDROID_SDK_ROOT = $_Config.androidSdk

    # Update android/local.properties — only the sdk.dir line, preserve the rest.
    $_LocalProps = Join-Path $_DevConfigDir 'android' 'local.properties'
    $_SdkDirValue = $_Config.androidSdk -replace '\\', '/'
    $_SdkDirLine = "sdk.dir=$_SdkDirValue"

    $_PropsDir = Split-Path $_LocalProps -Parent
    if (-not (Test-Path $_PropsDir)) {
        New-Item -ItemType Directory -Path $_PropsDir -Force | Out-Null
    }

    if (Test-Path $_LocalProps) {
        $_Lines = [System.IO.File]::ReadAllLines($_LocalProps)
        $_Found = $false
        $_NewLines = [System.Collections.Generic.List[string]]::new()
        foreach ($_Line in $_Lines) {
            if ($_Line -match '^sdk\.dir=') {
                $_NewLines.Add($_SdkDirLine)
                $_Found = $true
            } else {
                $_NewLines.Add($_Line)
            }
        }
        if (-not $_Found) {
            $_NewLines.Add($_SdkDirLine)
        }
        [System.IO.File]::WriteAllLines($_LocalProps, $_NewLines)
    } else {
        [System.IO.File]::WriteAllText($_LocalProps, "$_SdkDirLine`n")
    }
}

# ------------------------------------------------------------------
# ADB
# ------------------------------------------------------------------
if ($_Config.adb) {
    $env:ADB_BIN = $_Config.adb
}
