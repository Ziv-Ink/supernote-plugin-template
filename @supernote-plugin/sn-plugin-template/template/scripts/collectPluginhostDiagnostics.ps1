[CmdletBinding()]
param(
    [string]$Device = $env:DEVICE_SERIAL,
    [string]$Output = ""
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Resolve-Path (Join-Path $ScriptDir '..') | Select-Object -ExpandProperty Path
$PluginHostPackage = "com.ratta.supernote.pluginhost"
$DeviceUiXml = "/sdcard/supernote-plugin-diagnostics.xml"

$AdbBin = if ($env:ADB_BIN) { $env:ADB_BIN } else { 'adb' }
if ([string]::IsNullOrWhiteSpace($Output)) {
    $Output = if ($env:DIAGNOSTICS_DIR) { $env:DIAGNOSTICS_DIR } else { Join-Path $ProjectRoot "build\pluginhost-diagnostics" }
}

function Write-Log([string]$Message) {
    Write-Host "[diagnostics] $Message"
}

function Write-Die([string]$Message) {
    Write-Error "[diagnostics] Error: $Message"
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

$timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$runDir = Join-Path $Output $timestamp
New-Item -ItemType Directory -Path $runDir -Force | Out-Null

Write-Log "Collecting evidence from $Device in $runDir"

Invoke-AdbDevice get-state > (Join-Path $runDir "device-state.txt")
& $AdbBin devices -l > (Join-Path $runDir "adb-devices.txt")
Invoke-AdbDevice shell getprop > (Join-Path $runDir "device-properties.txt") 2>&1
Invoke-AdbDevice shell pidof $PluginHostPackage > (Join-Path $runDir "pluginhost-pid.txt") 2>&1
Invoke-AdbDevice shell dumpsys activity processes > (Join-Path $runDir "activity-processes.txt") 2>&1
Invoke-AdbDevice shell dumpsys window > (Join-Path $runDir "window.txt") 2>&1
Invoke-AdbDevice logcat -d -v threadtime > (Join-Path $runDir "logcat.txt") 2>&1

try {
    $screenshotBytes = Invoke-AdbDevice exec-out screencap -p
    if ($screenshotBytes) {
        [System.IO.File]::WriteAllBytes((Join-Path $runDir "screenshot.png"), [System.Text.Encoding]::GetEncoding(28591).GetBytes(($screenshotBytes -join "`n")))
    }
} catch { }

Invoke-AdbDevice shell rm -f $DeviceUiXml 2>&1 | Out-Null
try {
    $dumpResult = Invoke-AdbDevice shell uiautomator dump $DeviceUiXml 2>&1
    if ($dumpResult -join "`n" -match 'UI hierchary dumped to:|UI hierarchy dumped to:') {
        Invoke-AdbDevice exec-out cat $DeviceUiXml > (Join-Path $runDir "ui.xml") 2>&1
    }
} catch { }
Invoke-AdbDevice shell rm -f $DeviceUiXml 2>&1 | Out-Null

# Extract error patterns from logcat
$logcatPath = Join-Path $runDir "logcat.txt"
$errorsPath = Join-Path $runDir "pluginhost-errors.txt"
$errorPatterns = @(
    'FATAL EXCEPTION',
    'Fatal signal',
    'Process: com.ratta.supernote.pluginhost',
    'SIGABRT',
    'SIGSEGV',
    'UnsatisfiedLinkError',
    'No implementation found',
    'dlopen failed',
    'PluginHost.*crash',
    'PluginHost.*restart',
    'ReactNativeJS.*error',
    'ReactNativeJS.*fatal'
)
$combinedPattern = ($errorPatterns | ForEach-Object { "($_)" }) -join '|'

if (Test-Path $logcatPath) {
    $errorLines = Get-Content $logcatPath | Where-Object { $_ -match $combinedPattern }
    if ($errorLines) {
        $errorLines | Set-Content $errorsPath
    } else {
        "" | Set-Content $errorsPath
    }
    $errorCount = if ($errorLines) { $errorLines.Count } else { 0 }
} else {
    $errorCount = 0
    "" | Set-Content $errorsPath
}

Write-Log "PluginHost/runtime error-pattern lines: $errorCount"
if ($errorCount -ge 10) {
    Write-Log "WARNING: repeated errors may indicate a crash or restart loop."
}
Write-Log "Evidence saved to $runDir"
Write-Log "No process was stopped and no device data was cleared."
