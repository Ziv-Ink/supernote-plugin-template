[CmdletBinding()]
param(
    [string]$Device = $env:DEVICE_SERIAL,
    [string]$Package = "",
    [switch]$SkipBuild,
    [switch]$StopAfterPush,
    [switch]$StopBeforeInstall
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Resolve-Path (Join-Path $ScriptDir '..') | Select-Object -ExpandProperty Path

# Load devconfig.json if present
$_loadDevconfig = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'load-devconfig.ps1'
if (Test-Path $_loadDevconfig) { . $_loadDevconfig }

$DevicePluginDir = "/storage/emulated/0/MyStyle"
$DeviceUiXml = "/sdcard/supernote-deploy-window.xml"
$PluginManagerAction = "com.ratta.settings.application.PluginManagerFragment"
$PluginManagerComponent = "com.ratta.settings/.SettingsActivity"
$NoteComponent = "com.ratta.supernote.note/.view.NoteInsidePagesActivity"
$PluginHostPackage = "com.ratta.supernote.pluginhost"

$AdbBin = if ($env:ADB_BIN) { $env:ADB_BIN } else { 'adb' }
$UiSettleSeconds = if ($env:UI_SETTLE_SECONDS) { [int]$env:UI_SETTLE_SECONDS } else { 1 }
$UiTimeoutSeconds = if ($env:UI_TIMEOUT_SECONDS) { [int]$env:UI_TIMEOUT_SECONDS } else { 20 }
$InstallTimeoutSeconds = if ($env:INSTALL_TIMEOUT_SECONDS) { [int]$env:INSTALL_TIMEOUT_SECONDS } else { 120 }
$RuntimeTimeoutSeconds = if ($env:RUNTIME_TIMEOUT_SECONDS) { [int]$env:RUNTIME_TIMEOUT_SECONDS } else { 30 }

$TmpDir = ""
$UiXml = ""
$PluginName = ""
$PluginId = ""
$PluginFile = ""
$DevicePluginPath = ""

if (-not [string]::IsNullOrWhiteSpace($Package)) {
    $SkipBuild = $true
}

function Write-Log([string]$Message) {
    Write-Host "[deploy] $Message"
}

function Write-Die([string]$Message) {
    Write-Error "[deploy] Error: $Message"
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

function Read-ProjectMetadata {
    $configPath = Join-Path $ProjectRoot "PluginConfig.json"
    if (-not (Test-Path $configPath)) {
        Write-Die "missing $configPath"
    }

    $config = Get-Content $configPath | ConvertFrom-Json
    $script:PluginName = $config.name
    $script:PluginId = $config.pluginID

    if ([string]::IsNullOrWhiteSpace($script:PluginName)) { Write-Die "PluginConfig.json has no name" }
    if ([string]::IsNullOrWhiteSpace($script:PluginId)) { Write-Die "PluginConfig.json has no pluginID" }

    if ($script:PluginName -match '[/"]') {
        Write-Die "unsupported plugin name for deployment: $($script:PluginName)"
    }
    if ($script:PluginId -match '[''`"]') {
        Write-Die "unsupported plugin ID for deployment: $($script:PluginId)"
    }

    if (-not [string]::IsNullOrWhiteSpace($Package)) {
        $script:PluginFile = Resolve-Path $Package -ErrorAction Stop | Select-Object -ExpandProperty Path
    } else {
        $script:PluginFile = Join-Path $ProjectRoot "build\outputs\$($script:PluginName).snplg"
    }
    $script:DevicePluginPath = "$DevicePluginDir/$($script:PluginName).snplg"

}

function Test-PluginPackage([string]$PkgPath) {
    if (-not (Test-Path $PkgPath)) { Write-Die "plugin package not found: $PkgPath" }
    if ((Get-Item $PkgPath).Length -eq 0) { Write-Die "plugin package is empty: $PkgPath" }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($PkgPath)
    } catch {
        Write-Die "plugin package is not a valid ZIP: $PkgPath"
    }

    $configEntry = $zip.Entries | Where-Object { $_.FullName -eq 'PluginConfig.json' }
    if (-not $configEntry) {
        $zip.Dispose()
        Write-Die "plugin package does not contain PluginConfig.json"
    }

    $tmpConfig = Join-Path $TmpDir "PluginConfig.json"
    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($configEntry, $tmpConfig)
    $zip.Dispose()

    $pkgConfig = Get-Content $tmpConfig | ConvertFrom-Json
    if ($pkgConfig.name -ne $PluginName) {
        Write-Die "package name mismatch: expected $PluginName, found $($pkgConfig.name)"
    }
    if ($pkgConfig.pluginID -ne $PluginId) {
        Write-Die "package pluginID mismatch: expected $PluginId, found $($pkgConfig.pluginID)"
    }

    # Run extended verification if available
    $verifyScript = Join-Path $ScriptDir "verifyPluginPackage.ps1"
    $verifyShScript = Join-Path $ScriptDir "verifyPluginPackage.sh"
    if (Test-Path $verifyScript) {
        Write-Log "Running the complete package inspection..."
        & pwsh -File $verifyScript -PackagePath $PkgPath
    } elseif ((Test-Path $verifyShScript) -and (Get-Command bash -ErrorAction SilentlyContinue)) {
        Write-Log "Running the complete package inspection..."
        & bash $verifyShScript $PkgPath
    }
}

function Build-Plugin {
    $buildMarker = Join-Path $TmpDir "build-start"
    "" | Set-Content $buildMarker

    $gradlew = Join-Path $ProjectRoot "android\gradlew"
    if ($IsWindows) { $gradlew = Join-Path $ProjectRoot "android\gradlew.bat" }
    if (-not (Test-Path $gradlew)) {
        Write-Die "android/gradlew is missing"
    }

    Write-Log "Running strict Android build gate..."
    & $gradlew -p (Join-Path $ProjectRoot "android") :app:buildCustomApkDebug --no-daemon
    if ($LASTEXITCODE -ne 0) { Write-Die "Android build failed" }

    Write-Log "Packaging the plugin..."
    Push-Location $ProjectRoot
    try {
        $buildScript = Join-Path $ScriptDir "buildPlugin.ps1"
        $buildShScript = Join-Path $ScriptDir "buildPlugin.sh"
        if (Test-Path $buildScript) {
            & pwsh -File $buildScript
        } elseif ((Test-Path $buildShScript) -and (Get-Command bash -ErrorAction SilentlyContinue)) {
            & bash $buildShScript
        } else {
            Write-Die "No build script found"
        }
        if ($LASTEXITCODE -ne 0) { Write-Die "Plugin packaging failed" }
    } finally {
        Pop-Location
    }

    Read-ProjectMetadata

    if (-not (Test-Path $PluginFile) -or (Get-Item $PluginFile).LastWriteTime -lt (Get-Item $buildMarker).LastWriteTime) {
        Write-Die "build did not produce a fresh package: $PluginFile"
    }
}

function Push-AndVerifyPackage {
    Write-Log "Copying $(Split-Path -Leaf $PluginFile) to $DevicePluginDir on $Device..."
    Invoke-AdbDevice shell mkdir -p $DevicePluginDir
    Invoke-AdbDevice push $PluginFile $DevicePluginPath

    $localSize = (Get-Item $PluginFile).Length
    $remoteSize = (Invoke-AdbDevice shell stat -c %s $DevicePluginPath 2>&1) -join "" -replace "`r", "" -replace "\s", ""
    if ($remoteSize -ne $localSize.ToString()) {
        Write-Die "device package size mismatch: local=$localSize remote=$remoteSize"
    }

    $localHash = (Get-FileHash -Path $PluginFile -Algorithm SHA256).Hash.ToLower()
    $remoteHashLine = (Invoke-AdbDevice shell sha256sum $DevicePluginPath 2>&1) -join ""
    $remoteHash = if ($remoteHashLine -match '^([a-f0-9]{64})') { $matches[1] } else { "" }
    if (-not [string]::IsNullOrWhiteSpace($remoteHash)) {
        if ($remoteHash -ne $localHash) {
            Write-Die "device package SHA-256 mismatch: local=$localHash remote=$remoteHash"
        }
        Write-Log "Verified device SHA-256: $localHash"
    } else {
        Write-Log "Verified device size: $localSize bytes (SHA-256 unavailable on device)"
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
        if ($current -match [regex]::Escape($Expected)) { return $true }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Invoke-WakeAndUnlock {
    Write-Log "Waking the Supernote and dismissing its unsecured keyguard..."
    Invoke-AdbDevice shell input keyevent KEYCODE_WAKEUP
    Invoke-AdbDevice shell wm dismiss-keyguard 2>&1 | Out-Null
    Start-Sleep -Seconds $UiSettleSeconds
}

function Invoke-EnsureNoteForeground {
    $current = Get-ForegroundWindow
    if ($current -match [regex]::Escape('com.ratta.supernote.note/')) {
        Write-Log "NOTE is already the foreground app."
        return
    }

    if ($current -match [regex]::Escape('com.ratta.supernote.pluginhost')) {
        Write-Log "A plugin window is open; closing it through its visible close control..."
        if ((Try-DumpUi) -and (Test-HasUniqueNode 'content-desc' ([char]0x2715).ToString())) {
            Tap-UniqueNode 'content-desc' ([char]0x2715).ToString()
            if (Wait-ForForeground 'com.ratta.supernote.note/') {
                Write-Log "Closed the plugin window and returned to NOTE."
                return
            }
        }
        Write-Log "The plugin window did not close cleanly; trying the NOTE activity route."
    }

    Write-Log "NOTE is not in the foreground; opening it before deployment..."
    Invoke-AdbDevice shell am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -n $NoteComponent | Out-Null
    if (-not (Wait-ForForeground 'com.ratta.supernote.note/')) {
        Write-Die "NOTE did not reach the foreground before deployment"
    }
    Write-Log "Verified NOTE is the foreground app."
    Start-Sleep -Seconds $UiSettleSeconds
}

function Try-DumpUi {
    $deadline = (Get-Date).AddSeconds($UiTimeoutSeconds)
    while ((Get-Date) -le $deadline) {
        Invoke-AdbDevice shell rm -f $DeviceUiXml 2>&1 | Out-Null
        $out = Invoke-AdbDevice shell uiautomator dump $DeviceUiXml 2>&1
        $outStr = $out -join "`n"
        if ($outStr -match 'UI hierchary dumped to:|UI hierarchy dumped to:') {
            Invoke-AdbDevice exec-out cat $DeviceUiXml > $UiXml
            if ((Test-Path $UiXml) -and ((Get-Item $UiXml).Length -gt 0)) {
                $content = Get-Content $UiXml -Raw
                if ($content -match '<hierarchy') { return $true }
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
    $nodeMatches = [regex]::Matches($content, $pattern)
    $results = @()
    foreach ($m in $nodeMatches) { $results += $m.Value }
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
        $x1 = [int]$matches[1]; $y1 = [int]$matches[2]
        $x2 = [int]$matches[3]; $y2 = [int]$matches[4]
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

function Test-HasUniqueNodeWithAttribute(
    [string]$Attribute,
    [string]$Value,
    [string]$RequiredAttribute,
    [string]$RequiredValue
) {
    $nodes = @(Get-NodesMatching $Attribute $Value | Where-Object {
        $_.Contains("$RequiredAttribute=`"$RequiredValue`"")
    })
    return ($nodes.Count -eq 1)
}

function Test-PluginManagerControlsPresent {
    if ((Test-HasUniqueNode 'text' 'Plugins') -and
        (Test-HasUniqueNode 'text' 'Add Plugin')) {
        return $true
    }

    return ((Test-HasUniqueNode 'resource-id' 'com.ratta.settings:id/plugin_manage_title_bar') -and
            (Test-HasUniqueNode 'text' 'Choose Installation Package'))
}

function Test-InstalledPluginDetailPresent {
    return ((Test-HasUniqueNodeWithAttribute `
                'resource-id' `
                'com.ratta.settings:id/plugin_detail_title' `
                'text' `
                $PluginName) -and
            (Test-HasUniqueNodeWithAttribute `
                'resource-id' `
                'com.ratta.settings:id/plugin_detail_delete' `
                'text' `
                'Uninstall'))
}

function Test-PluginManagerPage {
    if (-not (Wait-ForForeground 'com.ratta.settings/com.ratta.settings.SettingsActivity')) { return $false }
    if (-not (Try-DumpUi)) { return $false }
    $current = Get-ForegroundWindow
    if ($current -notmatch [regex]::Escape('com.ratta.settings/com.ratta.settings.SettingsActivity')) { return $false }
    return (Test-PluginManagerControlsPresent)
}

function Wait-ForInstalledPlugin {
    $deadline = (Get-Date).AddSeconds($InstallTimeoutSeconds)
    $installingLogged = $false
    while ((Get-Date) -le $deadline) {
        $current = Get-ForegroundWindow
        if ($current -match [regex]::Escape('com.ratta.settings/com.ratta.settings.SettingsActivity')) {
            if (Try-DumpUi) {
                if (Test-InstalledPluginDetailPresent) {
                    return $true
                }
                if ((Test-PluginManagerControlsPresent) -and
                    (Test-HasUniqueNode 'text' $PluginName)) {
                    return $true
                }
                if ((Test-HasUniqueNode 'text' 'Installing…') -and -not $installingLogged) {
                    Write-Log "Supernote is installing $PluginName; waiting up to ${InstallTimeoutSeconds}s..."
                    $installingLogged = $true
                }
            }
        }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Get-PluginHostPid {
    $pidStr = Invoke-AdbDevice shell pidof $PluginHostPackage
    return ($pidStr -join "").Trim()
}

function Wait-ForPluginHostAvailable {
    $deadline = (Get-Date).AddSeconds($RuntimeTimeoutSeconds)
    while ((Get-Date) -le $deadline) {
        $pid = Get-PluginHostPid
        if (-not [string]::IsNullOrWhiteSpace($pid)) { return $pid }
        Start-Sleep -Seconds 1
    }
    return ""
}

function Open-PluginManagerFallback {
    Write-Log "Direct Plugin Manager route was unavailable; using the NOTE toolbar fallback..."
    Invoke-AdbDevice shell am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -n $NoteComponent | Out-Null
    if (-not (Wait-ForForeground 'com.ratta.supernote.note/')) {
        Write-Die "NOTE did not produce a foreground window for the Plugin Manager fallback"
    }
    Start-Sleep -Seconds $UiSettleSeconds
    Dump-Ui
    Tap-UniqueNode 'content-desc' 'plugins'
    Dump-Ui
    Tap-UniqueNode 'text' 'Manage Plugins'
    Start-Sleep -Seconds $UiSettleSeconds
    if (-not (Test-PluginManagerPage)) {
        Write-Die "NOTE toolbar fallback did not reach the Supernote Plugins page"
    }
}

function Open-PluginManager {
    Write-Log "Opening the Supernote Plugins page..."
    $startResult = Invoke-AdbDevice shell am start -a $PluginManagerAction -n $PluginManagerComponent 2>&1
    Start-Sleep -Seconds $UiSettleSeconds
    if (Test-PluginManagerPage) {
        Write-Log "Verified direct Supernote Plugin Manager route."
        return
    }
    Open-PluginManagerFallback
}

function Open-PackagePicker {
    Dump-Ui
    if (Test-HasUniqueNode 'text' 'Choose Installation Package') {
        Tap-UniqueNode 'text' 'Choose Installation Package'
    } elseif (Test-HasUniqueNode 'text' 'Add Plugin') {
        Tap-UniqueNode 'text' 'Add Plugin'
    } else {
        Write-Die "Plugin installation package action was not found"
    }
    if (-not (Wait-ForForeground 'com.ratta.supernote.inbox/com.ratta.supernote.explorer.SelectFileActivity')) {
        Write-Die "Select Plugin picker did not produce a foreground window"
    }
    Dump-Ui
    $current = Get-ForegroundWindow
    if ($current -notmatch [regex]::Escape('com.ratta.supernote.inbox/com.ratta.supernote.explorer.SelectFileActivity')) {
        Write-Die "Select Plugin picker did not reach the foreground"
    }
    if (-not (Test-HasUniqueNode 'text' 'Select Plugin')) { Write-Die "Select Plugin title was not found" }
    if (-not (Test-HasUniqueNode 'text' 'MyStyle')) { Write-Die "Select Plugin picker did not open in MyStyle" }
}

function Select-DevicePackage {
    $filename = Split-Path -Leaf $DevicePluginPath
    Dump-Ui
    Tap-UniqueNode 'text' $filename
    Dump-Ui
    if (-not (Test-HasUniqueNode 'text' $filename)) {
        Write-Die "selected package disappeared from the picker: $filename"
    }
    if (-not (Test-HasUniqueNode 'text' 'Install')) { Write-Die "Install action was not found" }
    Write-Log "Selected exact package: $filename"
}

function Install-SelectedPackage {
    $previousPid = Get-PluginHostPid
    Tap-UniqueNode 'text' 'Install'

    if (-not (Wait-ForInstalledPlugin)) {
        Write-Die "Install did not confirm $PluginName in Supernote Settings within ${InstallTimeoutSeconds}s"
    }

    $currentPid = Wait-ForPluginHostAvailable
    if ([string]::IsNullOrWhiteSpace($currentPid)) {
        Write-Die "PluginHost was not available within ${RuntimeTimeoutSeconds}s after Install"
    }
    if (-not [string]::IsNullOrWhiteSpace($previousPid) -and $currentPid -eq $previousPid) {
        Write-Log "Installed $PluginName in the existing PluginHost PID $currentPid."
    } elseif (-not [string]::IsNullOrWhiteSpace($previousPid)) {
        Write-Log "Installed $PluginName; PluginHost restarted from PID $previousPid to $currentPid."
    } else {
        Write-Log "Installed $PluginName; PluginHost is PID $currentPid."
    }
}

# --- Main ---
try {
    $script:TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("supernote-deploy-" + [guid]::NewGuid().ToString().Substring(0,8))
    New-Item -ItemType Directory -Path $script:TmpDir | Out-Null
    $script:UiXml = Join-Path $script:TmpDir "window.xml"

    if (-not $SkipBuild) {
        Build-Plugin
    } elseif (-not [string]::IsNullOrWhiteSpace($Package)) {
        Read-ProjectMetadata
        Write-Log "Using supplied package without rebuilding: $PluginFile"
    } else {
        Read-ProjectMetadata
        Write-Log "Skipping build; the existing package will be verified before use."
    }

    Select-Device
    Write-Log "Using device: $Device"
    Test-PluginPackage $PluginFile
    Push-AndVerifyPackage

    if ($StopAfterPush) {
        Write-Log "Stopped after verified push as requested."
        return
    }

    Invoke-WakeAndUnlock
    Invoke-EnsureNoteForeground
    Open-PluginManager
    Open-PackagePicker
    Select-DevicePackage

    if ($StopBeforeInstall) {
        Write-Log "Stopped before Install as requested."
        return
    }

    Install-SelectedPackage
} finally {
    if (-not [string]::IsNullOrWhiteSpace($Device)) {
        try { Invoke-AdbDevice shell rm -f $DeviceUiXml 2>&1 | Out-Null } catch { }
    }
    if (-not [string]::IsNullOrWhiteSpace($script:TmpDir) -and (Test-Path $script:TmpDir)) {
        Remove-Item -Path $script:TmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
