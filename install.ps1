#Requires -Version 5.1
<#
.SYNOPSIS
    TaylorFab Studio Installer - Installs the TaylorFab Studio frame generator plugin for AutoCAD.
.DESCRIPTION
    Detects installed AutoCAD versions, downloads the latest release, places the
    plugin (both runtime flavors), model library and assets, and registers for
    autoload. AutoCAD 2025/2026 load the .NET 8 flavor; AutoCAD 2027+ loads the
    .NET 10 flavor — selection happens per-version via the bundle manifest and
    the per-version registry entries this installer writes.

    AutoCAD 2024 and earlier are NOT supported by v10.0+ (they host .NET
    Framework, which cannot load these builds). The last release supporting
    AutoCAD 2024 is v9.x.

    Close AutoCAD first: the installer refuses to run while the installed
    plugin is loaded, and it never touches the previous install until the new
    one has been downloaded, validated and staged in full (a failure at any
    point leaves the previous version in place).
.NOTES
    Run with: iex (irm https://raw.githubusercontent.com/EJLDesign/TaylorFab_Studio_release/main/install.ps1)
    Or: .\install.ps1
#>

$ErrorActionPreference = 'Stop'

trap {
    Write-Host ""
    Write-Host "  ERROR: $_" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Press any key to exit..." -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

# -- Config -------------------------------------------------------------------
$RepoOwner   = "EJLDesign"
$RepoName    = "TaylorFab_Studio_release"
$PluginName  = "TaylorFabStudio"
$BundleDir   = Join-Path $env:APPDATA "Autodesk\ApplicationPlugins\TaylorFabStudio.bundle"
$ContentsDir = Join-Path $BundleDir "Contents"
# Pre-rename (BMFrameGenCAD) install locations, removed on install so AutoCAD
# never double-loads the old and new plugin side by side.
$LegacyPluginName = "BMFrameGenCAD"
$LegacyBundleDir  = Join-Path $env:APPDATA "Autodesk\ApplicationPlugins\BMFrameGenCAD.bundle"

# -- Functions ----------------------------------------------------------------

function Write-Banner {
    Write-Host ""
    Write-Host "  +--------------------------------------------+" -ForegroundColor Cyan
    Write-Host "  |     TaylorFab Studio Plugin Installer       |" -ForegroundColor Cyan
    Write-Host "  |     Frame Generator for AutoCAD             |" -ForegroundColor Cyan
    Write-Host "  +--------------------------------------------+" -ForegroundColor Cyan
    Write-Host ""
}

# Which plugin flavor an AutoCAD engine series loads. R25.0/R25.1 (2025/2026)
# host .NET 8; anything newer hosts .NET 10 (AutoCAD 2027 = the R26 engine;
# R25.2+ is also mapped to net10 defensively). R24.x and older host .NET
# Framework and cannot load either flavor.
function Get-FlavorForSeries([string]$versionId) {
    if ($versionId -match '^R(\d+)\.(\d+)$') {
        $major = [int]$Matches[1]
        $minor = [int]$Matches[2]
        if ($major -lt 25) { return $null }
        if ($major -eq 25 -and $minor -le 1) { return 'net8' }
        return 'net10'
    }
    return $null
}

function Get-InstalledAutoCADVersions {
    $versions = @()
    $acadKey = "HKLM:\SOFTWARE\Autodesk\AutoCAD"

    if (-not (Test-Path $acadKey)) {
        return $versions
    }

    Get-ChildItem $acadKey | ForEach-Object {
        $versionKey = $_
        $versionId = $versionKey.PSChildName  # e.g. R25.1
        Get-ChildItem $versionKey.PSPath | ForEach-Object {
            $productKey = $_
            $productId = $productKey.PSChildName  # e.g. ACAD-9101:409
            $props = Get-ItemProperty $productKey.PSPath -ErrorAction SilentlyContinue
            $productName = $props.ProductName
            $installPath = $props.AcadLocation

            if ($productName -and $installPath -and (Test-Path $installPath)) {
                $versions += [PSCustomObject]@{
                    Name        = $productName
                    VersionId   = $versionId
                    ProductId   = $productId
                    InstallPath = $installPath
                    Flavor      = Get-FlavorForSeries $versionId
                }
            }
        }
    }
    return $versions
}

function Get-LatestRelease {
    Write-Host "  Checking for latest release..." -ForegroundColor Gray
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$RepoOwner/$RepoName/releases/latest" -UseBasicParsing
        $asset = $release.assets | Where-Object { $_.name -like "*.zip" } | Select-Object -First 1

        if (-not $asset) {
            throw "No zip asset found in latest release."
        }

        return [PSCustomObject]@{
            TagName     = $release.tag_name
            DownloadUrl = $asset.browser_download_url
            AssetName   = $asset.name
        }
    }
    catch {
        throw "Could not fetch latest release. Make sure a release exists at https://github.com/$RepoOwner/$RepoName/releases -- $_"
    }
}

# True when any plugin DLL under $dir is held open by another process (AutoCAD with the
# plugin loaded). A locked DLL is what used to leave a half-deleted bundle behind: the old
# installer removed the bundle FIRST, the delete got through Models\ / assets\ / net10\
# and then died on the locked net8 DLL, and the next AutoCAD start loaded a plugin with
# no model library (2026-09-18).
function Test-PluginLocked([string]$dir) {
    if (-not (Test-Path $dir)) { return $false }
    $dlls = Get-ChildItem $dir -Filter "*.dll" -Recurse -File -ErrorAction SilentlyContinue
    foreach ($dll in $dlls) {
        try {
            $fs = [System.IO.File]::Open($dll.FullName, 'Open', 'ReadWrite', 'None')
            $fs.Close()
        }
        catch { return $true }
    }
    return $false
}

function Install-Plugin {
    param(
        [string]$DownloadUrl,
        [string]$TagName
    )

    # Refuse up front while AutoCAD holds the installed plugin: nothing is touched, the
    # previous install keeps working, and the message says what to do.
    foreach ($dir in @($BundleDir, $LegacyBundleDir)) {
        if (Test-PluginLocked $dir) {
            $acad = @(Get-Process -Name acad -ErrorAction SilentlyContinue)
            $hint = if ($acad.Count -gt 0) { "AutoCAD is running ($($acad.Count) window(s))." } else { "Another program has it open." }
            throw "The installed plugin at '$dir' is in use. $hint Close AutoCAD completely, then run the installer again."
        }
    }

    $pluginsRoot = Split-Path $BundleDir -Parent
    New-Item -Path $pluginsRoot -ItemType Directory -Force | Out-Null

    # Best-effort cleanup of debris from older runs (never reuse these paths --
    # a failed delete or an antivirus handle on them must not break this run)
    Get-ChildItem $env:TEMP -Filter "$PluginName-extract*" -Directory -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Get-ChildItem $env:TEMP -Filter "$PluginName-v*.zip" -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem $pluginsRoot -Filter "TaylorFabStudio.bundle.*-*" -Directory -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    # Download and extract FIRST, using paths unique to this run so leftovers from a
    # previous attempt (possibly still locked by antivirus) can't collide. The previous
    # install is not touched until the new one is complete and verified below.
    $runId = Get-Random
    $tempZip = Join-Path $env:TEMP "$PluginName-$TagName-$runId.zip"
    Write-Host "  Downloading $TagName..." -ForegroundColor Gray
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $tempZip -UseBasicParsing

    # Extract with retries: antivirus scanners often hold just-written files
    # briefly, which makes Expand-Archive fail spuriously
    $tempExtract = Join-Path $env:TEMP "$PluginName-extract-$runId"
    for ($attempt = 1; ; $attempt++) {
        try {
            Expand-Archive -Path $tempZip -DestinationPath $tempExtract -Force
            break
        }
        catch {
            if ($attempt -ge 3) { throw }
            Write-Host "  Extraction attempt $attempt failed (antivirus may be scanning); retrying..." -ForegroundColor Yellow
            Start-Sleep -Seconds 3
            Remove-Item $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
            $tempExtract = Join-Path $env:TEMP "$PluginName-extract-$runId-$attempt"
        }
    }

    # Validate the archive BEFORE anything is staged: the plugin resolves license.lic,
    # EULA.txt and assets\ BESIDE the loaded DLL, so each flavor folder is self-contained
    # (DLL + license + EULA + assets). The model library is shared: the plugin resolves
    # Contents\Models from the loaded DLL's folder (Contents\net8 or Contents\net10) --
    # it is not a setting and cannot be changed by the user.
    $lic  = Get-ChildItem $tempExtract -Filter "license.lic" -Recurse | Select-Object -First 1
    $eula = Get-ChildItem $tempExtract -Filter "EULA.txt" -Recurse | Select-Object -First 1
    $assetsSource = Get-ChildItem $tempExtract -Directory -Filter "assets" -Recurse | Select-Object -First 1
    $modelsSource = Get-ChildItem $tempExtract -Directory -Filter "Models" -Recurse | Select-Object -First 1
    if (-not $modelsSource -or (Get-ChildItem $modelsSource.FullName -Filter "TaylorFab_*.dwg" -File).Count -eq 0) {
        throw "The release archive has no model library (Models\TaylorFab_*.dwg). Nothing was changed -- report this release ($TagName)."
    }
    $flavorDlls = @{}
    foreach ($flavor in @('net8', 'net10')) {
        $dll = Get-ChildItem (Join-Path $tempExtract $flavor) -Filter "$PluginName.dll" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($dll) { $flavorDlls[$flavor] = $dll } else { Write-Host "  WARNING: $flavor\$PluginName.dll not found in the release archive." -ForegroundColor Yellow }
    }
    if ($flavorDlls.Count -eq 0) {
        throw "No plugin flavor found in the release archive (expected net8\ and net10\ folders). Nothing was changed."
    }
    if (-not $lic) {
        Write-Host "  NOTE: No license.lic in release -- existing license (if any) stays in effect." -ForegroundColor Yellow
    }
    if (-not $assetsSource) {
        Write-Host "  WARNING: No assets folder found in release -- sheet labels will not appear." -ForegroundColor Yellow
    }

    # Build the COMPLETE new bundle beside the live one (same volume, so the swap below is
    # a rename), then swap. $newBundle/$oldBundle carry the run id so debris never collides;
    # any failure while staging removes the staging folder and leaves the live install alone.
    $newBundle   = "$BundleDir.new-$runId"
    $oldBundle   = "$BundleDir.old-$runId"
    $newContents = Join-Path $newBundle "Contents"
    try {
    New-Item -Path $newContents -ItemType Directory -Force | Out-Null

    # Write PackageContents.xml for AutoCAD bundle autoload. Two series-gated
    # components: AutoCAD picks the flavor matching its own engine series.
    $packageXml = @"
<?xml version="1.0" encoding="utf-8"?>
<ApplicationPackage SchemaVersion="1.0"
  Name="TaylorFabStudio"
  Description="TaylorFab Studio - Frame Generator for AutoCAD"
  AppVersion="1.0.0"
  ProductCode="{3B7AA669-9896-AB28-814B-0145E746B3DF}">
  <CompanyDetails Name="Taylor Manufacturing Industries Inc."/>
  <RuntimeRequirements OS="Win64" Platform="AutoCAD"/>
  <Components Description="AutoCAD 2025-2026 (.NET 8)">
    <RuntimeRequirements OS="Win64" Platform="AutoCAD" SeriesMin="R25.0" SeriesMax="R25.1"/>
    <ComponentEntry AppName="TaylorFabStudio"
      ModuleName="./Contents/net8/TaylorFabStudio.dll"
      AppType="Managed"
      LoadOnAutoCADStartup="True"/>
  </Components>
  <Components Description="AutoCAD 2027+ (.NET 10)">
    <RuntimeRequirements OS="Win64" Platform="AutoCAD" SeriesMin="R25.2"/>
    <ComponentEntry AppName="TaylorFabStudio"
      ModuleName="./Contents/net10/TaylorFabStudio.dll"
      AppType="Managed"
      LoadOnAutoCADStartup="True"/>
  </Components>
</ApplicationPackage>
"@
    Set-Content (Join-Path $newBundle "PackageContents.xml") $packageXml -Encoding UTF8

    foreach ($flavor in $flavorDlls.Keys) {
        $flavorDir = Join-Path $newContents $flavor
        New-Item -Path $flavorDir -ItemType Directory -Force | Out-Null
        Copy-Item $flavorDlls[$flavor].FullName -Destination $flavorDir

        if ($lic)  { Copy-Item $lic.FullName  -Destination $flavorDir }
        if ($eula) { Copy-Item $eula.FullName -Destination $flavorDir }
        if ($assetsSource) {
            Copy-Item $assetsSource.FullName -Destination (Join-Path $flavorDir "assets") -Recurse
        }
        Write-Host "  Staged $flavor flavor." -ForegroundColor Gray
    }

    # Models (shared between flavors, resolved by the plugin beside its own folder)
    $modelsDest = Join-Path $newContents "Models"
    Copy-Item $modelsSource.FullName -Destination $modelsDest -Recurse
    $modelCount = (Get-ChildItem $modelsDest -Filter "*.dwg" -File).Count
    if ($modelCount -eq 0) { throw "Copying the model library failed (0 files at '$modelsDest'). Nothing was changed." }
    Write-Host "  Staged $modelCount model files." -ForegroundColor Gray

    # Swap: the previous install is renamed aside (a rename is refused as a whole if anything
    # inside is still open -- nothing is half-deleted), the new bundle takes its place, and
    # the old one is removed best-effort. A failure here leaves the previous install in place.
    if (Test-Path $BundleDir) {
        Write-Host "  Replacing previous installation..." -ForegroundColor Yellow
        try { Rename-Item -Path $BundleDir -NewName (Split-Path $oldBundle -Leaf) -ErrorAction Stop }
        catch {
            throw "Could not replace the previous installation at '$BundleDir' (it is in use). Close AutoCAD and any Explorer windows in that folder, then run the installer again. The previous version is still installed."
        }
        # Even if the old copy cannot be fully removed below, it must never look like a
        # bundle to AutoCAD (the folder name no longer ends in .bundle; this is belt and braces).
        Remove-Item (Join-Path $oldBundle "PackageContents.xml") -Force -ErrorAction SilentlyContinue
    }
    try { Rename-Item -Path $newBundle -NewName (Split-Path $BundleDir -Leaf) -ErrorAction Stop }
    catch {
        # Put the old one back so the machine is never left without a plugin.
        if (Test-Path $oldBundle) { Rename-Item -Path $oldBundle -NewName (Split-Path $BundleDir -Leaf) -ErrorAction SilentlyContinue }
        throw "Could not move the new installation into place: $_  The previous version was restored."
    }
    }
    catch {
        Remove-Item $newBundle -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
    if (Test-Path $oldBundle) {
        Remove-Item $oldBundle -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path $oldBundle) { Write-Host "  NOTE: the previous version's folder could not be fully removed ($oldBundle); it is inert and will be cleaned up next run." -ForegroundColor Yellow }
    }
    if (Test-Path $LegacyBundleDir) {
        Write-Host "  Removing legacy installation at $LegacyBundleDir..." -ForegroundColor Yellow
        Remove-Item $LegacyBundleDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Remove legacy per-product autoload registry entries (pre-rename BMFrameGenCAD).
    # Leaving them would make AutoCAD try to load the deleted old DLL on startup.
    Get-ChildItem "HKCU:\SOFTWARE\Autodesk\AutoCAD" -ErrorAction SilentlyContinue | ForEach-Object {
        Get-ChildItem $_.PSPath -ErrorAction SilentlyContinue | ForEach-Object {
            foreach ($legacyName in @($LegacyPluginName)) {
                $legacyKey = Join-Path $_.PSPath "Applications\$legacyName"
                if (Test-Path $legacyKey) {
                    Remove-Item $legacyKey -Recurse -Force -ErrorAction SilentlyContinue
                    Write-Host "  Removed legacy autoload registry entry." -ForegroundColor Yellow
                }
            }
            # Pre-v10 TaylorFabStudio entries point at the old single-DLL layout
            # (Contents\TaylorFabStudio.dll) which no longer exists — Register-AutoLoad
            # rewrites entries for detected versions, but stale entries for versions
            # no longer installed would error at their next startup; drop them all.
            $tfabKey = Join-Path $_.PSPath "Applications\$PluginName"
            if (Test-Path $tfabKey) {
                Remove-Item $tfabKey -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # Settings: migrate the pre-rename file so users keep their LED/elevation/tower
    # preferences across the rename. The model library is NOT a setting any more (the
    # plugin resolves Contents\Models beside its own folder); a LibraryPath line left by
    # an older installer is ignored by the plugin -- drop it so nobody is misled by it.
    $settingsFile = Join-Path $env:APPDATA "taylorfabstudio_settings.txt"
    $legacySettings = Join-Path $env:APPDATA "bmframegen_settings.txt"
    if (-not (Test-Path $settingsFile) -and (Test-Path $legacySettings)) {
        Copy-Item $legacySettings $settingsFile
        Write-Host "  Migrated settings from bmframegen_settings.txt." -ForegroundColor Gray
    }
    if (Test-Path $settingsFile) {
        try {
            $kept = @(Get-Content $settingsFile | Where-Object { $_ -notmatch '^LibraryPath=' })
            Set-Content $settingsFile $kept
        }
        catch { Write-Host "  NOTE: could not tidy $settingsFile ($_) -- harmless." -ForegroundColor Yellow }
    }

    # Clean up temp files
    Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
    Remove-Item $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
}

function Register-AutoLoad {
    param(
        [array]$AutoCADVersions
    )

    $registered = 0

    foreach ($acad in $AutoCADVersions) {
        if (-not $acad.Flavor) { continue }  # unsupported series — reported by the caller

        $dllPath = Join-Path $ContentsDir "$($acad.Flavor)\$PluginName.dll"

        # Write to HKCU (no admin needed) - same structure as HKLM autoload
        $regPath = "HKCU:\SOFTWARE\Autodesk\AutoCAD\$($acad.VersionId)\$($acad.ProductId)\Applications\$PluginName"

        New-Item -Path $regPath -Force | Out-Null
        Set-ItemProperty -Path $regPath -Name "DESCRIPTION" -Value "TaylorFab Studio for AutoCAD"
        Set-ItemProperty -Path $regPath -Name "LOADCTRLS" -Value 2 -Type DWord
        Set-ItemProperty -Path $regPath -Name "LOADER" -Value $dllPath
        Set-ItemProperty -Path $regPath -Name "MANAGED" -Value 1 -Type DWord

        Write-Host "  Registered autoload for $($acad.Name) ($($acad.Flavor))" -ForegroundColor Green
        $registered++
    }

    return $registered
}

function Test-Installation {
    param([array]$AutoCADVersions)

    $ok = $true
    $neededFlavors = $AutoCADVersions | Where-Object { $_.Flavor } | ForEach-Object { $_.Flavor } | Sort-Object -Unique

    foreach ($flavor in $neededFlavors) {
        $flavorDir = Join-Path $ContentsDir $flavor

        if (Test-Path (Join-Path $flavorDir "$PluginName.dll")) {
            Write-Host "  [OK] Plugin DLL installed ($flavor)" -ForegroundColor Green
        } else {
            Write-Host "  [FAIL] Plugin DLL missing ($flavor)" -ForegroundColor Red
            $ok = $false
        }

        $symbolsPath = Join-Path $flavorDir "assets\symbols"
        if ((Test-Path $symbolsPath) -and (Get-ChildItem $symbolsPath -Filter "*.dwg").Count -gt 0) {
            Write-Host "  [OK] Sheet-label symbols installed ($flavor)" -ForegroundColor Green
        } else {
            Write-Host "  [WARN] Sheet-label symbols missing ($flavor) -- generated sheets will have no labels" -ForegroundColor Yellow
        }
    }

    # Check Models -- the plugin cannot generate without it, so this is a FAIL, not a warning.
    $modelsPath = Join-Path $ContentsDir "Models"
    $modelCount = if (Test-Path $modelsPath) { (Get-ChildItem $modelsPath -Filter "TaylorFab_*.dwg" -File).Count } else { 0 }
    if ($modelCount -gt 0) {
        Write-Host "  [OK] Model library installed ($modelCount frame/post files)" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] Model library missing or empty at $modelsPath -- the plugin will refuse to generate" -ForegroundColor Red
        $ok = $false
    }

    # Check registry entries
    foreach ($acad in $AutoCADVersions) {
        if (-not $acad.Flavor) { continue }
        $regPath = "HKCU:\SOFTWARE\Autodesk\AutoCAD\$($acad.VersionId)\$($acad.ProductId)\Applications\$PluginName"
        if (Test-Path $regPath) {
            Write-Host "  [OK] Registry entry for $($acad.Name)" -ForegroundColor Green
        } else {
            Write-Host "  [FAIL] Registry entry missing for $($acad.Name)" -ForegroundColor Red
            $ok = $false
        }
    }

    return $ok
}

# -- Main ---------------------------------------------------------------------

Write-Banner

Write-Host "  Detecting installed AutoCAD versions..." -ForegroundColor Gray
$acadVersions = Get-InstalledAutoCADVersions

if ($acadVersions.Count -eq 0) {
    Write-Host ""
    Write-Host "  No AutoCAD installations detected." -ForegroundColor Red
    Write-Host "  AutoCAD must be installed before running this installer." -ForegroundColor Red
    Write-Host ""
    Write-Host "  Press any key to exit..." -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

Write-Host "  Found AutoCAD installations:" -ForegroundColor Green
foreach ($v in $acadVersions) {
    if ($v.Flavor) {
        Write-Host "    - $($v.Name)  [$($v.Flavor)]" -ForegroundColor White
    } else {
        Write-Host "    - $($v.Name)  [NOT SUPPORTED]" -ForegroundColor Yellow
    }
}

$supported = @($acadVersions | Where-Object { $_.Flavor })
if ($supported.Count -eq 0) {
    Write-Host ""
    Write-Host "  None of the detected AutoCAD versions are supported by this release." -ForegroundColor Red
    Write-Host "  TaylorFab Studio v10.0+ requires AutoCAD 2025 or later." -ForegroundColor Red
    Write-Host "  The last release supporting AutoCAD 2024 and earlier is v9.x:" -ForegroundColor Red
    Write-Host "  https://github.com/$RepoOwner/$RepoName/releases" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Press any key to exit..." -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}
if ($supported.Count -lt $acadVersions.Count) {
    Write-Host ""
    Write-Host "  NOTE: unsupported (pre-2025) AutoCAD versions above will be skipped." -ForegroundColor Yellow
}
Write-Host ""

# Get latest release
$release = Get-LatestRelease
Write-Host "  Latest version: $($release.TagName)" -ForegroundColor Cyan
Write-Host ""

# Confirm
Write-Host "  Install TaylorFab Studio $($release.TagName)? (Y/n) " -ForegroundColor White -NoNewline
$key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
Write-Host $key.Character
if ($key.Character -eq 'n' -or $key.Character -eq 'N') {
    Write-Host "  Installation cancelled." -ForegroundColor Yellow
    Write-Host "  Press any key to exit..." -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 0
}

Write-Host ""

# Install files
Install-Plugin -DownloadUrl $release.DownloadUrl -TagName $release.TagName

# Register autoload in registry for each detected AutoCAD version
Write-Host ""
Write-Host "  Registering plugin with AutoCAD..." -ForegroundColor Gray
$regCount = Register-AutoLoad -AutoCADVersions $acadVersions

# Verify
Write-Host ""
Write-Host "  Verifying installation..." -ForegroundColor Gray
$passed = Test-Installation -AutoCADVersions $acadVersions

Write-Host ""
if ($passed) {
    Write-Host "  Installation complete!" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Plugin location: $BundleDir" -ForegroundColor Gray
    Write-Host "  Registered for $regCount AutoCAD version(s)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Next steps:" -ForegroundColor Cyan
    Write-Host "    1. Launch (or restart) AutoCAD" -ForegroundColor White
    Write-Host '    2. Type "TFAB" in the command line to start' -ForegroundColor White
    Write-Host ""
}
else {
    Write-Host "  Installation completed with errors. Check the messages above." -ForegroundColor Red
}

Write-Host "  Press any key to exit..." -ForegroundColor Gray
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
