[CmdletBinding()]
param(
    [string]$Device = $env:DEVICE_SERIAL
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Resolve-Path (Join-Path $ScriptDir '..') | Select-Object -ExpandProperty Path

# Load devconfig.json if present
$_loadDevconfig = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'load-devconfig.ps1'
if (Test-Path $_loadDevconfig) { . $_loadDevconfig }
$DeviceUiXml = "/sdcard/supernote-deploy-window.xml"
$NoteComponent = "com.ratta.supernote.note/.view.NoteInsidePagesActivity"
$PluginHostPackage = "com.ratta.supernote.pluginhost"

$AdbBin = if ($env:ADB_BIN) { $env:ADB_BIN } else { 'adb' }
$UiSettleSeconds = if ($env:UI_SETTLE_SECONDS) { [int]$env:UI_SETTLE_SECONDS } else { 1 }
$UiTimeoutSeconds = if ($env:UI_TIMEOUT_SECONDS) { [int]$env:UI_TIMEOUT_SECONDS } else { 20 }
$RuntimeTimeoutSeconds = if ($env:RUNTIME_TIMEOUT_SECONDS) { [int]$env:RUNTIME_TIMEOUT_SECONDS } else { 30 }

$TmpDir = ""
$UiXml = ""

function Write-Log([string]$Message) {
    Write-Host "[run_plugin] $Message"
}

function Write-Die([string]$Message) {
    Write-Error "[run_plugin] Error: $Message"
    exit 1
}

function Invoke-AdbDevice {
    if ($Device) {
        & $AdbBin -s $Device $args
    } else {
        & $AdbBin $args
    }
}

function Require-Command([string]$Cmd) {
    if (-not (Get-Command $Cmd -ErrorAction SilentlyContinue)) {
        Write-Die "$Cmd was not found in PATH"
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

function Read-ProjectMetadata {
    $configPath = Join-Path $ProjectRoot "PluginConfig.json"
    if (-not (Test-Path $configPath)) {
        Write-Die "missing $configPath (Run 'npm run build' first)"
    }

    $config = Get-Content $configPath | ConvertFrom-Json
    $script:PluginName = $config.name

    if ([string]::IsNullOrWhiteSpace($script:PluginName)) { Write-Die "PluginConfig.json has no name" }

    $labelFile = Join-Path $ProjectRoot ".supernote-launch-label"
    if (-not $env:PLUGIN_LAUNCH_LABEL -and (Test-Path $labelFile)) {
        $script:LaunchLabel = (Get-Content $labelFile -TotalCount 1).Trim()
    } else {
        $script:LaunchLabel = $env:PLUGIN_LAUNCH_LABEL
    }
    if ([string]::IsNullOrWhiteSpace($script:LaunchLabel)) {
        $script:LaunchLabel = $script:PluginName
    }
}

function Get-ForegroundWindow {
    $out = Invoke-AdbDevice shell dumpsys window
    foreach ($line in $out) {
        if ($line -match 'mCurrentFocus=') {
            return $line.Trim()
        }
    }
    return ""
}

function Wait-ForForeground([string]$Expected) {
    $deadline = (Get-Date).AddSeconds($UiTimeoutSeconds)
    while ((Get-Date) -le $deadline) {
        $current = Get-ForegroundWindow
        if ($current -match [regex]::Escape($Expected)) {
            return $true
        }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Try-DumpUi {
    $deadline = (Get-Date).AddSeconds($UiTimeoutSeconds)
    while ((Get-Date) -le $deadline) {
        Invoke-AdbDevice shell rm -f $DeviceUiXml | Out-Null
        $out = Invoke-AdbDevice shell uiautomator dump $DeviceUiXml 2>&1
        $outStr = $out -join "`n"
        if ($outStr -match 'UI hierchary dumped to:' -or $outStr -match 'UI hierarchy dumped to:') {
            Invoke-AdbDevice exec-out cat $DeviceUiXml > $UiXml
            if ((Test-Path $UiXml) -and ((Get-Item $UiXml).Length -gt 0)) {
                $content = Get-Content $UiXml -Raw
                if ($content -match '<hierarchy') {
                    return $true
                }
            }
        }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Dump-Ui {
    if (-not (Try-DumpUi)) {
        Write-Die "Android UI hierarchy was unavailable for ${UiTimeoutSeconds}s"
    }
}

function Get-NodesMatching([string]$Attribute, [string]$Value) {
    $content = Get-Content $UiXml -Raw
    $pattern = '(?s)<node[^>]*' + [regex]::Escape($Attribute) + '="' + [regex]::Escape($Value) + '"[^>]*>'
    $matches = [regex]::Matches($content, $pattern)
    $results = @()
    foreach ($m in $matches) {
        $results += $m.Value
    }
    return $results
}

function Get-UniqueBounds([string]$Attribute, [string]$Value) {
    $nodes = Get-NodesMatching $Attribute $Value
    if ($nodes.Count -ne 1) {
        Write-Die "expected one UI node with $Attribute=`"$Value`", found $($nodes.Count)"
    }
    
    if ($nodes[0] -match 'bounds="(\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\])"') {
        return $matches[1]
    }
    Write-Die "UI node $Attribute=`"$Value`" has no usable bounds"
}

function Tap-BoundsCenter([string]$Bounds) {
    if ($Bounds -match '^\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]$') {
        $x1 = [int]$matches[1]
        $y1 = [int]$matches[2]
        $x2 = [int]$matches[3]
        $y2 = [int]$matches[4]
        $cx = [math]::Truncate(($x1 + $x2) / 2)
        $cy = [math]::Truncate(($y1 + $y2) / 2)
        Invoke-AdbDevice shell input tap $cx $cy
    } else {
        Write-Die "invalid UI bounds: $Bounds"
    }
}

function Tap-UniqueNode([string]$Attribute, [string]$Value) {
    $bounds = Get-UniqueBounds $Attribute $Value
    Write-Log "Tapping $Attribute=`"$Value`" at $bounds"
    Tap-BoundsCenter $bounds
    Start-Sleep -Seconds $UiSettleSeconds
}

function Test-HasUniqueNode([string]$Attribute, [string]$Value) {
    $nodes = Get-NodesMatching $Attribute $Value
    return ($nodes.Count -eq 1)
}

function Get-PluginHostPid {
    $pidStr = Invoke-AdbDevice shell pidof $PluginHostPackage
    return ($pidStr -join "").Trim()
}

function Get-PluginLaunchEventCount {
    $log = Invoke-AdbDevice logcat -d -v brief
    $eventPattern = 'sendMenuItemEvent menuItem:PluginSideButton'
    $pluginNamePattern = "pluginName='$PluginName'"
    $count = 0
    foreach ($line in $log) {
        if ($line.Contains($eventPattern) -and $line.Contains($pluginNamePattern)) {
            $count++
        }
    }
    return $count
}

function Wait-ForNewPluginLaunchEvent([int]$PreviousCount) {
    $deadline = (Get-Date).AddSeconds($RuntimeTimeoutSeconds)
    while ((Get-Date) -le $deadline) {
        $currentCount = Get-PluginLaunchEventCount
        if ($currentCount -gt $PreviousCount) {
            return $true
        }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Invoke-LaunchPlugin {
    Write-Log "Opening NOTE to launch the installed plugin..."
    Invoke-AdbDevice shell am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -n $NoteComponent | Out-Null
    
    if (-not (Wait-ForForeground "com.ratta.supernote.note/")) {
        Write-Die "NOTE did not produce a foreground window for plugin launch"
    }
    Start-Sleep -Seconds $UiSettleSeconds

    Dump-Ui
    Tap-UniqueNode "content-desc" "plugins"
    
    Dump-Ui
    if (-not (Test-HasUniqueNode "text" $LaunchLabel)) {
        Write-Die "NOTE plugin popup did not list launch label $LaunchLabel exactly once"
    }

    $previousEventCount = Get-PluginLaunchEventCount
    Tap-UniqueNode "text" $LaunchLabel

    if (-not (Wait-ForNewPluginLaunchEvent $previousEventCount)) {
        Write-Die "PluginHost did not acknowledge launch of $PluginName within ${RuntimeTimeoutSeconds}s"
    }

    $currentPid = Get-PluginHostPid
    if ([string]::IsNullOrWhiteSpace($currentPid)) {
        Write-Die "PluginHost exited while launching the plugin"
    }
    Write-Log "Launched $PluginName through NOTE (PluginHost PID $currentPid)."
}

try {
    $script:TmpDir = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "supernote-run-" + [guid]::NewGuid().ToString().Substring(0,8))
    New-Item -ItemType Directory -Path $script:TmpDir | Out-Null
    $script:UiXml = Join-Path $script:TmpDir "window.xml"

    Select-Device
    Read-ProjectMetadata
    Write-Log "Using device: $Device"
    Invoke-LaunchPlugin
} finally {
    if (-not [string]::IsNullOrWhiteSpace($script:TmpDir) -and (Test-Path $script:TmpDir)) {
        Remove-Item -Path $script:TmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
