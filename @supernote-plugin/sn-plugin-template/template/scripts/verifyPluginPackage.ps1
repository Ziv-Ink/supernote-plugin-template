[CmdletBinding()]
param(
    [string]$PackagePath = ""
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Resolve-Path (Join-Path $ScriptDir '..') | Select-Object -ExpandProperty Path

function Write-Log([string]$Message) {
    Write-Host "[verify-package] $Message"
}

function Write-Die([string]$Message) {
    Write-Error "[verify-package] Error: $Message"
    exit 1
}

function Require-Command([string]$Cmd) {
    if (-not (Get-Command $Cmd -ErrorAction SilentlyContinue)) {
        Write-Die "$Cmd was not found in PATH"
    }
}

# Resolve package path
if ([string]::IsNullOrWhiteSpace($PackagePath)) {
    $configPath = Join-Path $ProjectRoot "PluginConfig.json"
    if (-not (Test-Path $configPath)) {
        Write-Die "PluginConfig.json is missing; pass an explicit package path"
    }
    $config = Get-Content $configPath | ConvertFrom-Json
    $pluginName = $config.name
    if ([string]::IsNullOrWhiteSpace($pluginName)) {
        Write-Die "PluginConfig.json has no name"
    }
    $PackagePath = Join-Path $ProjectRoot "build\outputs\$pluginName.snplg"
}

$PackagePath = Resolve-Path $PackagePath -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Path
if (-not $PackagePath -or -not (Test-Path $PackagePath)) {
    Write-Die "package not found: $PackagePath"
}
if ((Get-Item $PackagePath).Length -eq 0) {
    Write-Die "package is empty: $PackagePath"
}

# Create temp dir
$TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("supernote-package-" + [guid]::NewGuid().ToString().Substring(0,8))
New-Item -ItemType Directory -Path $TmpDir | Out-Null

try {
    # Extract and validate outer package
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($PackagePath)
    } catch {
        Write-Die "outer .snplg is not a valid ZIP archive"
    }

    # Extract PluginConfig.json
    $configEntry = $zip.Entries | Where-Object { $_.FullName -eq 'PluginConfig.json' }
    if (-not $configEntry) {
        $zip.Dispose()
        Write-Die "outer package does not contain PluginConfig.json"
    }
    $configDest = Join-Path $TmpDir "PluginConfig.json"
    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($configEntry, $configDest)

    $packagedConfig = Get-Content $configDest | ConvertFrom-Json
    $packagedName = $packagedConfig.name
    $packagedId = $packagedConfig.pluginID
    if ([string]::IsNullOrWhiteSpace($packagedName)) { Write-Die "packaged PluginConfig.json has no name" }
    if ([string]::IsNullOrWhiteSpace($packagedId)) { Write-Die "packaged PluginConfig.json has no pluginID" }

    # Cross-check with project config if available
    $projectConfigPath = Join-Path $ProjectRoot "PluginConfig.json"
    if (Test-Path $projectConfigPath) {
        $projConfig = Get-Content $projectConfigPath | ConvertFrom-Json
        $expectedName = $projConfig.name
        $expectedId = $projConfig.pluginID
        if ([string]::IsNullOrWhiteSpace($expectedName)) { Write-Die "project PluginConfig.json has no name" }
        if ([string]::IsNullOrWhiteSpace($expectedId)) { Write-Die "project PluginConfig.json has no pluginID" }
        if ($packagedName -ne $expectedName) {
            Write-Die "package name mismatch: expected $expectedName, found $packagedName"
        }
        if ($packagedId -ne $expectedId) {
            Write-Die "package pluginID mismatch: expected $expectedId, found $packagedId"
        }
    }

    $hasNative = -not [string]::IsNullOrWhiteSpace($packagedConfig.nativeCodePackage)

    $nativeLibs = $null
    if ($hasNative) {
        # Extract app.npk
        $npkEntry = $zip.Entries | Where-Object { $_.FullName -eq 'app.npk' }
        if (-not $npkEntry) {
            $zip.Dispose()
            Write-Die "outer package does not contain app.npk (required because nativeCodePackage is declared)"
        }
        $npkDest = Join-Path $TmpDir "app.npk"
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($npkEntry, $npkDest)

        if ((Get-Item $npkDest).Length -eq 0) { Write-Die "nested app.npk is empty" }

        # Validate app.npk contents
        try {
            $npkZip = [System.IO.Compression.ZipFile]::OpenRead($npkDest)
        } catch {
            Write-Die "nested app.npk is not a valid ZIP archive"
        }

        $inventory = $npkZip.Entries | ForEach-Object { $_.FullName }

        # Check for unsupported ABIs
        $unsupportedAbis = $inventory | Where-Object { $_ -match '^lib/(armeabi-v7a|x86|x86_64)/' }
        if ($unsupportedAbis) {
            $npkZip.Dispose()
            Write-Die "nested app.npk contains an unsupported non-arm64 native ABI"
        }

        # Check for host-owned libraries
        $hostLibs = $inventory | Where-Object { $_ -match '^lib/arm64-v8a/(libjsi|libreactnative|libhermes|libfbjni|libc\+\+_shared)\.so$' }
        if ($hostLibs) {
            $npkZip.Dispose()
            Write-Die "nested app.npk packages a PluginHost-owned native library"
        }

        # Gather native libraries for report
        $nativeLibs = $inventory | Where-Object { $_ -match '^lib/[^/]+/[^/]+\.so$' }

        $npkZip.Dispose()
    }
    $zip.Dispose()

    # SHA-256
    $hash = (Get-FileHash -Path $PackagePath -Algorithm SHA256).Hash.ToLower()

    Write-Log "Package: $PackagePath"
    Write-Log "Plugin: $packagedName ($packagedId)"
    Write-Log "SHA-256: $hash"
    if ($nativeLibs) {
        Write-Log "Native libraries:"
        $nativeLibs | ForEach-Object { Write-Host $_ }
    } else {
        Write-Log "Native libraries: none"
    }
    Write-Log "Package structure and native-library policy passed."
} finally {
    if (Test-Path $TmpDir) {
        Remove-Item -Path $TmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
