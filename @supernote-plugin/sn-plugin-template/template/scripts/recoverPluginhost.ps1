[CmdletBinding()]
param(
    [switch]$Yes,
    [string]$Device = $env:DEVICE_SERIAL
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Resolve-Path (Join-Path $ScriptDir '..') | Select-Object -ExpandProperty Path
$PluginHostPackage = "com.ratta.supernote.pluginhost"
$DevicePluginDir = "/storage/emulated/0/MyStyle"

$AdbBin = if ($env:ADB_BIN) { $env:ADB_BIN } else { 'adb' }

function Write-Log([string]$Message) {
    Write-Host "[recovery] $Message"
}

function Write-Die([string]$Message) {
    Write-Error "[recovery] Error: $Message"
    exit 1
}

function Require-Command([string]$Cmd) {
    if (-not (Get-Command $Cmd -ErrorAction SilentlyContinue)) {
        Write-Die "$Cmd was not found in PATH"
    }
}

function Invoke-AdbDevice {
    if ($Device) {
        & $AdbBin -s $Device $args
    } else {
        & $AdbBin $args
    }
}

function Select-Device {
    Require-Command $AdbBin

    if ($Device) {
        $state = & $AdbBin -s $Device get-state 2>&1
        if ($state -notmatch 'device') {
            Write-Die "ADB device $Device is not connected and authorized"
        }
        return
    }

    $adbOut = & $AdbBin devices
    $devices = @()
    foreach ($line in $adbOut) {
        if ($line -match '^([^\s]+)\s+device$') {
            $devices += $matches[1]
        }
    }

    if ($devices.Count -eq 0) {
        Write-Die "no connected and authorized Android device was found"
    } elseif ($devices.Count -eq 1) {
        $script:Device = $devices[0]
    } else {
        Write-Die "multiple devices are connected; pass -Device SERIAL or set DEVICE_SERIAL"
    }
}

if (-not $Yes) {
    Write-Die "recovery clears all PluginHost data; collect diagnostics, then rerun with -Yes"
}

Select-Device

# Read plugin name if available
$pluginName = ""
$configPath = Join-Path $ProjectRoot "PluginConfig.json"
if (Test-Path $configPath) {
    try {
        $config = Get-Content $configPath | ConvertFrom-Json
        $pluginName = $config.name
    } catch { }
}

Write-Log "Stopping PluginHost and clearing all of its application data on $Device..."
Invoke-AdbDevice shell am force-stop $PluginHostPackage 2>&1 | Out-Null
$clearResult = (Invoke-AdbDevice shell pm clear $PluginHostPackage) -join "" -replace "`r", ""
if ($clearResult -ne "Success") {
    Write-Die "pm clear returned: $clearResult"
}
Invoke-AdbDevice shell pm enable $PluginHostPackage | Out-Null

if (-not [string]::IsNullOrWhiteSpace($pluginName)) {
    Invoke-AdbDevice shell rm -f "$DevicePluginDir/$pluginName.snplg"
    Write-Log "Removed uploaded package: $pluginName.snplg"
}

Invoke-AdbDevice logcat -c

# Clean local build directories
$buildDirs = @(
    (Join-Path $ProjectRoot "build"),
    (Join-Path $ProjectRoot "android\build"),
    (Join-Path $ProjectRoot "android\app\build")
)
foreach ($dir in $buildDirs) {
    if (Test-Path $dir) {
        Remove-Item -Path $dir -Recurse -Force
        Write-Log "Removed local build output: $dir"
    }
}

Write-Log "Recovery complete. User source and installed dependencies were preserved."
