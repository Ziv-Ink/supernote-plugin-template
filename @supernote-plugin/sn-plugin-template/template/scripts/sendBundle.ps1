[CmdletBinding()]
param(
    [string]$Device = $env:DEVICE_SERIAL
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Resolve-Path (Join-Path $ScriptDir '..') | Select-Object -ExpandProperty Path

$AdbBin = if ($env:ADB_BIN) { $env:ADB_BIN } else { 'adb' }

function Write-Die([string]$Message) {
    Write-Error "[send_bundle] Error: $Message"
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

Select-Device
Require-Command "npx"

$configPath = Join-Path $ProjectRoot "PluginConfig.json"
if (-not (Test-Path $configPath)) {
    Write-Die "missing $configPath (Run 'npm run build' first)"
}

$config = Get-Content $configPath | ConvertFrom-Json
$pluginId = $config.pluginID
$bundleName = $config.name

if ([string]::IsNullOrWhiteSpace($pluginId)) {
    Write-Die "Plugin ID not found in PluginConfig.json"
}
if ([string]::IsNullOrWhiteSpace($bundleName)) {
    Write-Die "Bundle name not found in PluginConfig.json"
}

$localBundleDir = Join-Path $ProjectRoot "build\generated"
$localBundlePath = Join-Path $localBundleDir "$bundleName.bundle"
$deviceBundlePath = "/sdcard/EXPORT/$bundleName.bundle"

if (-not (Test-Path $localBundleDir)) {
    New-Item -ItemType Directory -Path $localBundleDir | Out-Null
}

Write-Host "Bundling to: $localBundlePath"
Push-Location $ProjectRoot
try {
    & npx react-native bundle --entry-file index.js --bundle-output $localBundlePath --platform android --assets-dest $localBundleDir --dev false
    if ($LASTEXITCODE -ne 0) {
        Write-Die "Bundling failed"
    }
} finally {
    Pop-Location
}

Write-Host "Pushing bundle to device: $deviceBundlePath"
Invoke-AdbDevice push $localBundlePath $deviceBundlePath

Write-Host "Installing bundle via broadcast (plugin_id=$pluginId)"
$broadcastOutput = Invoke-AdbDevice shell am broadcast -a com.ratta.supernote.plugin.action.DEBUG -n com.ratta.supernote.pluginhost/.receiver.PluginReceiver --es bundle_path $deviceBundlePath --es plugin_id $pluginId 2>&1
$broadcastOutputStr = $broadcastOutput -join "`n"

Write-Host $broadcastOutputStr

if ($broadcastOutputStr -notmatch 'Broadcast completed: result=0(?:\s|$)') {
    Write-Host "Bundle installation was rejected by the plugin host" -ForegroundColor Red
    exit 1
}

Write-Host "Bundle successfully sent to device and installed via broadcast." -ForegroundColor Green
