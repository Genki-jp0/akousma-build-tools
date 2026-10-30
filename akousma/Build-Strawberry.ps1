#Requires -Version 7.0
<#
.SYNOPSIS
  Strawberry MSVC build wrapper for the Akousma build tools. This repository is upstream
  strawberry-msvc-build-tools @ 4c8c65c with the patched StrawberryMSVCBuild.ps1 (custom parameters +
  package-level parallelism) already committed, so this script builds with the repository it is in
  (the folder above akousma\): no clone of upstream, no checkout, no script swap.

  Every path is a parameter; defaults hang off
  a work root, C:\ unless -WorkRoot is passed (the same C:\data\projects\strawberry\... and
  C:\strawberry_msvc_<arch>_<build type> folders upstream's script uses), wherever this script is run from.

  Every *.patch and *.diff in the patches folder next to this script is applied automatically, whatever its name: to the
  package its name starts with (qtbase-*.patch -> qtbase, gstreamer-*.patch -> gst-plugins-good, ...), everything else to
  strawberry (see -NoAutoPatches). The list of patch files found is printed at the start and at the top of the log, and the
  build stops if one fails to apply. Pass -NoPlaylistLock to build without patches\strawberry-playlist-lock.patch.

  Change detection: every package's build is stamped with what went into it (version / git commit, patch hashes, build
  recipe). A run skips what is up to date, rebuilds what changed (dependencies from a clean copy, strawberry incrementally)
  and prints the decision for every package before it builds. See -ForceRebuild, -NoChangeDetection, -RebuildDependents.

.DESCRIPTION
    1. Redirects TEMP / pip cache / cargo / rustup
    2. Copies existing .cargo / .rustup to the new locations (once)
    3. Uses the build tools repository this script is in (its StrawberryMSVCBuild.ps1 is already the patched one)
    4. Downloads jom.exe if missing
    5. Copies missing downloaded archives from the old downloads folder (once), kills leftover compilers, removes partial
       OpenSSL trees
    6. Builds what is missing or changed (strawberry itself is cloned and pinned to -StrawberryRef by the build script),
       logs to -LogPath, per-package logs to -LogDir; stamps go to <BuildPath>\.stamps

  Tools the build script expects (Git, Strawberry Perl, nasm, CMake, 7-Zip, Python, win_flex_bison,
  Meson) are installed programs. That script finds them on PATH first, then through the registry and
  the usual install folders; add other folders (';'-separated) with $env:SMB_TOOL_PATHS. The root and
  Program Files of every fixed drive are searched too (e.g. F:\Strawberry). Missing tools are all
  reported together before anything is built; Git's MSYS perl does not count as Strawberry Perl.

  Requires PowerShell 7 (pwsh): the patched script starts pwsh child processes for parallel builds.

.PARAMETER StrawberryRef      Strawberry tag/branch/commit to build (any ref -- e.g. 1.2.31, 19d8c0b, master). Empty = strawberry master.
.PARAMETER MsvcToolsRef       Not needed any more; kept so old command lines still work. This repository is based on upstream
                              strawberry-msvc-build-tools 4c8c65c, so only 4c8c65c (or a longer form of that commit) is accepted.
                              To move to a newer upstream commit, merge or rebase it into this repository (see akousma\BUILD.txt).
.PARAMETER Jobs               Parallel jobs in total (split between parallel packages).
.PARAMETER ParallelPackages   Packages built at the same time. 0 = auto (half the jobs, min 2). 1 = sequential like upstream.
.PARAMETER Only / -Skip       Build only / never build these components (when they need building).
.PARAMETER List               Print the per-package decision (skip / adopt / build / rebuild and why) and the build queue, then exit.
                              Writes nothing.
.PARAMETER ForceRebuild       Rebuild these packages even when they are up to date, e.g. -ForceRebuild gst-plugins-good,strawberry
                              ('all' = everything). Dependencies get a clean copy; strawberry a fresh copy of its source and an
                              empty build folder (a full rebuild; without -ForceRebuild strawberry is always built incrementally).
.PARAMETER NoChangeDetection  Decide like before: build what has no output, skip everything else, whatever changed (strawberry is
                              still rebuilt when its build tree is not at -StrawberryRef). Stamps are still written after builds.
.PARAMETER RebuildDependents  When a package is rebuilt because it changed, also rebuild the packages that link it directly
                              (e.g. after a version bump that renames a DLL). Without it, only dependents of header-only packages
                              are rebuilt; strawberry is relinked and StrawberrySetup re-created after any rebuild either way.
.PARAMETER VersionOverrides   e.g. -VersionOverrides @{ qt_version = '6.11.2' }
.PARAMETER GitRefs            e.g. -GitRefs @{ 'gst-plugins-rs' = '0.15.3' }. glib-networking is pinned automatically to the
                              commit this repository's patches\glib-networking.patch applies to; an entry here wins.
.PARAMETER VersionsFile       Alternative StrawberryPackageVersions.txt.
.PARAMETER CiVersionsFile     strawberry-msvc-dependencies build.yaml (path/URL) whose *_version values win.
.PARAMETER CiVersionsRef      Fetch strawberry-msvc-dependencies' build.yaml automatically (ignored when -CiVersionsFile is given).
                              'auto'   = the newest build.yaml commit that existed when -StrawberryRef was committed (GitHub API;
                                         set $env:GITHUB_TOKEN if you hit the unauthenticated rate limit),
                              'master' / a tag / a commit = that exact revision.
                              Empty = no CI file. The download is cached in <TempPath> and passed on as -CiVersionsFile.
.PARAMETER SkipBuild          Do everything except the build.
.PARAMETER RemoveOldCDrive    Delete the old C: build tree, prefix and downloads.
.PARAMETER WorkRoot          Drive/folder everything is built under. Empty = C:\ (fixed: it does not follow the drive this
                              script is on, nor $env:STRAWBERRY_ROOT). Pass e.g. -WorkRoot E:\ to build on another drive.
.PARAMETER StrawberryPatch    One or more .patch files (-p1) applied, in order, to strawberry's own source before it is built
                              (e.g. .\patches\strawberry-custom-framerate.patch). Passing it turns off the automatic
                              discovery of strawberry patches in the patches folder; patches\strawberry-playlist-lock.patch is still appended
                              after these (not added twice if you list it yourself); see -NoPlaylistLock.
                              Git binary diffs (e.g. new icons) are applied with git apply, the rest with patch.
                              Before the patches are applied the strawberry build tree is reset to the -StrawberryRef commit, so
                              a patch that was removed or edited is undone / redone too; files that end up identical keep their
                              timestamps, so only what changed is recompiled.
.PARAMETER NoPlaylistLock     Build without patches\strawberry-playlist-lock.patch (neither discovered nor appended; a lock patch
                              you list in -StrawberryPatch yourself is still applied). Strawberry is rebuilt without it.
.PARAMETER GstGoodPatch      A .patch file (-p1, relative to the gst-plugins-good root) applied to gst-plugins-good before it is built
                              (e.g. .\patches\gstreamer-flacparse-invalid-frame.patch). Passing it turns off the automatic
                              patches\gstreamer-*.patch / gst-plugins-good-*.patch discovery.
.PARAMETER NoAutoPatches      Don't apply the patches folder automatically (only -StrawberryPatch / -GstGoodPatch and the playlist lock).
                              Otherwise EVERY patches\*.patch and patches\*.diff is applied, whatever its name:
                                gstreamer-*.patch, gst-plugins-good-*.patch -> gst-plugins-good
                                <package>-*.patch                           -> that package (longest name wins: glib-networking-x.patch
                                                                               -> glib-networking), e.g. qtbase-*.patch, gst-plugins-bad-*.patch
                                any other name (strawberry-*.patch, x.diff) -> strawberry
                              and patches\<package>\*.patch / *.diff to that package (use patches\gstreamer\ for GStreamer core
                              itself; a subfolder that is not a package name stops the run). A file with no diff in it stops the
                              run too. Each file, its package and whether it is applied is printed at the start and in the log;
                              while building, each patch is logged as applied / skipped (already applied) and a patch that fails
                              stops the build.
                              Per package they are applied in name order (numbers sort naturally; an optional leading number,
                              e.g. 10-strawberry-x.patch, sorts first and is ignored for the package match), after the build
                              tools' own patches. Local patches work for strawberry and every package built with CMake or Meson;
                              the build stops before building if one is given for another package (openssl, icu4c, sqlite,
                              lame, fftw3, sparsehash, strawberry-setup).
.PARAMETER SrcPath           Where git sources (strawberry, qt*, gstreamer, ...) are cloned. Empty = same folder as -DownloadsPath.
.PARAMETER ProjectRoot, MsvcRoot, DownloadsPath, BuildPath, PrefixPath, JomDir, TempPath,
           PipCachePath, CargoHome, RustupHome, LogPath, LogDir
                              New locations. Empty = <work root>\data\projects\strawberry, ...
                              where <work root> is -WorkRoot, else C:\. With no path parameters the defaults are:
                                ProjectRoot   C:\data\projects\strawberry   (build.log; the build tools are this repository)
                                DownloadsPath C:\data\projects\strawberry\msvc_\downloads   (SrcPath: same)
                                BuildPath     C:\data\projects\strawberry\msvc_\build_<arch>_<build type>   (LogDir: ...\logs)
                                PrefixPath    C:\strawberry_msvc_<arch>_<build type>   (e.g. C:\strawberry_msvc_x86_64_release)
                                JomDir        C:\data\projects\strawberry\strawberry-msvc\tools\jom   (only when jom.exe is not on PATH; where the
                                              old wrapper's build tools clone kept it, so an existing jom.exe is reused)
                                TempPath C:\temp, PipCachePath C:\cache\pip, CargoHome C:\cargo, RustupHome C:\rustup,
                                LogPath C:\data\projects\strawberry\build.log
.PARAMETER OldCargoHome, OldRustupHome, OldDownloads, OldBuildPath, OldPrefixPath
                              Old locations to migrate from / clean. Empty = the usual old spots
                              (%USERPROFILE%\.cargo, <system drive>\data\..., ...); skipped if absent.
.PARAMETER GitBinPath         Git's bin folder, added to PATH. Empty = found through git.exe on PATH.

.EXAMPLE
  # From the akousma folder of this repository.
  # Everything in patches\ (custom framerate, playlist lock, flacparse fix) is applied automatically; everything goes to C:
  .\Build-Strawberry.ps1 -StrawberryRef 1.2.31
  # Same without the playlist lock, built on E: instead of C:
  .\Build-Strawberry.ps1 -StrawberryRef 1.2.31 -NoPlaylistLock -WorkRoot E:\
  # Only the custom framerate patch for strawberry (no discovery for strawberry; the lock is still appended unless -NoPlaylistLock)
  .\Build-Strawberry.ps1 -StrawberryRef 1.2.31 -StrawberryPatch .\patches\strawberry-custom-framerate.patch
  # What would be rebuilt and why, without building anything
  .\Build-Strawberry.ps1 -StrawberryRef 1.2.31 -List
  # Rebuild gst-plugins-good from scratch even though nothing changed (strawberry is relinked, StrawberrySetup re-created)
  .\Build-Strawberry.ps1 -StrawberryRef 1.2.31 -ForceRebuild gst-plugins-good
  .\Build-Strawberry.ps1 -ParallelPackages 2 -Jobs 12 -List
#>

[CmdletBinding()]
param(
  # versions / options
  [string]$BuildType        = "release",
  [string]$Arch              = "x86_64",
  [string]$StrawberryRef    = "1.2.30",
  [string]$MsvcToolsRef     = "4c8c65c",
  [int]$Jobs                = [Environment]::ProcessorCount,
  [int]$ParallelPackages    = 0,
  [string[]]$Only           = @(),
  [string[]]$Skip           = @(),
  [switch]$List,
  [string[]]$ForceRebuild   = @(),
  [switch]$NoChangeDetection,
  [switch]$RebuildDependents,
  [hashtable]$VersionOverrides = @{},
  [hashtable]$GitRefs       = @{},
  [string]$VersionsFile     = "",
  [string]$CiVersionsFile   = "",
  [string]$CiVersionsRef    = "",
  [switch]$SkipBuild,
  [switch]$RemoveOldCDrive,

  # locations: empty = derived in step 0 (see .NOTES); pass a value to override
  [string]$WorkRoot      = "",
  [string]$ProjectRoot   = "",
  [string]$MsvcRoot      = "",
  [string]$DownloadsPath = "",
  [string]$SrcPath       = "",
  [string[]]$StrawberryPatch = @(),
  [switch]$NoPlaylistLock,
  [switch]$NoAutoPatches,
  [string]$GstGoodPatch  = "",
  [string]$BuildPath     = "",
  [string]$PrefixPath    = "",
  [string]$JomDir        = "",
  [string]$TempPath      = "",
  [string]$PipCachePath  = "",
  [string]$CargoHome     = "",
  [string]$RustupHome    = "",
  [string]$LogPath       = "",
  [string]$LogDir        = "",

  # old locations (sources to migrate from / clean-up targets); empty = the usual old spots, skipped if absent
  [string]$OldCargoHome  = "",
  [string]$OldRustupHome = "",
  [string]$OldDownloads  = "",
  [string]$OldBuildPath  = "",
  [string]$OldPrefixPath = "",

  # tools
  [string]$GitBinPath    = ""   # empty = <Git root>\bin, found through git.exe on PATH
)

# Remember where the user started; restored in the finally block at the very end (success, failure or Ctrl+C).
$StartLocation = (Get-Location).Path
# Same for the environment: this script (Path, TEMP/TMP, PIP_CACHE_DIR, CARGO_HOME, RUSTUP_HOME, STRAWBERRY_ROOT, SMB_*) and the
# build script it runs in this session (Visual Studio dev shell: Path, INCLUDE, LIB, ...) change environment variables. Without a
# restore, every run in the same window prepended to Path again until cmd failed with "The input line is too long".
$StartEnv = [hashtable]::new($(if ($IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }))   # names compare like the OS does
foreach ($e in [Environment]::GetEnvironmentVariables().GetEnumerator()) { $StartEnv[[string]$e.Key] = [string]$e.Value }
try {

# ---------------------------------------------------------------------
# Relative paths in the parameters (e.g. .\patches\x.patch) are relative to the folder the script was
# started from. The steps below Set-Location to -ProjectRoot and the build tools repo, so make every
# user-supplied path absolute now, before any Set-Location, instead of looking it up in the wrong folder.
# ---------------------------------------------------------------------
function Resolve-UserPath([string]$p) {
  # Empty = not passed (the default is derived later); a bare 'E:' stays the drive root; URLs are left alone.
  if ([string]::IsNullOrWhiteSpace($p) -or $p -match '^[A-Za-z]:$' -or $p -match '^[A-Za-z][A-Za-z0-9+.-]+://') { return $p }
  return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($p)
}
$StrawberryPatch = @(foreach ($patch in $StrawberryPatch | Where-Object { $_ }) {
  $full = Resolve-UserPath $patch
  if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "-StrawberryPatch file not found: $patch (looked for $full)" }
  $full
})
if ($GstGoodPatch) {
  $full = Resolve-UserPath $GstGoodPatch
  if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "-GstGoodPatch file not found: $GstGoodPatch (looked for $full)" }
  $GstGoodPatch = $full
}

# ---------------------------------------------------------------------
# Local patches per package: -StrawberryPatch / -GstGoodPatch, else the patches folder next to this script.
# ---------------------------------------------------------------------
# Every package the build scripts know (union over the known build-tools refs), for routing patches\<package>-*.patch.
$KnownPackages = @(
  'pkgconf', 'yasm', 'proxy-libintl', 'getopt-win', 'zlib', 'openssl', 'libpng', 'libjpeg-turbo', 'pcre2', 'bzip2', 'xz', 'brotli',
  'uchardet', 'icu4c', 'pixman', 'expat', 'boost', 'libxml2', 'nghttp2', 'libffi', 'dlfcn-win32', 'libpsl', 'orc', 'sqlite', 'glib',
  'libsoup', 'glib-networking', 'freetype', 'harfbuzz', 'jasper', 'tiff', 'libwebp', 'ogg', 'vorbis', 'flac', 'wavpack', 'opus',
  'opusfile', 'speex', 'mpg123', 'lame', 'fftw3', 'musepack', 'libopenmpt', 'libgme', 'fdk-aac', 'faad2', 'faac', 'utfcpp', 'taglib',
  'libbs2b', 'libebur128', 'ffmpeg', 'chromaprint', 'gstreamer', 'gst-plugins-base', 'gst-plugins-good', 'gst-plugins-bad',
  'gst-plugins-ugly', 'gst-libav', 'gst-plugins-rs', 'abseil-cpp', 'protobuf', 'qtbase', 'qttools', 'qtimageformats', 'qtgrpc',
  'kdsingleapplication', 'qtsparkle', 'sparsehash', 'glew', 'libprojectm', 'tinysvcmdns', 'pe-parse', 'pe-util', 'strawberry',
  'strawberry-setup'
)
function Get-NaturalSortKey([string]$s) {
  return [regex]::Replace($s.ToLowerInvariant(), '\d+', { param($m) $m.Value.PadLeft(12, '0') })
}
function Get-PatchTarget([string]$Path, [string]$PatchDir, [string[]]$Packages) {
  # patches\<package>\x.patch -> <package> ($null if the folder is not a package name);
  # patches\x.patch -> the package its name starts with (see -NoAutoPatches), anything else -> strawberry.
  $dir = Split-Path -Parent $Path
  if (-not ([System.IO.Path]::GetFullPath($dir).TrimEnd('\', '/') -ieq [System.IO.Path]::GetFullPath($PatchDir).TrimEnd('\', '/'))) {
    $leafDir = Split-Path -Leaf $dir
    return ($Packages | Where-Object { $_ -ieq $leafDir } | Select-Object -First 1)
  }
  $base = [System.IO.Path]::GetFileNameWithoutExtension($Path) -replace '^\d+[-_.]', ''
  if ($base -match '^(?i)gstreamer-') { return 'gst-plugins-good' }   # e.g. gstreamer-flacparse-invalid-frame.patch; core: patches\gstreamer\
  $match = $Packages | Where-Object { $base -ieq $_ -or $base.StartsWith("$_-", [StringComparison]::OrdinalIgnoreCase) } |
           Sort-Object Length -Descending | Select-Object -First 1
  if ($match) { return $match }
  return 'strawberry'   # every other name: a strawberry patch (e.g. sidebar.patch, mica.diff)
}
function Get-PatchFiles([string]$PatchDir) {
  # Every *.patch and *.diff directly in the patches folder and in its subfolders (one level), in a fixed order.
  $isPatch = { $_.Extension -ieq '.patch' -or $_.Extension -ieq '.diff' }
  $files = @(Get-ChildItem -LiteralPath $PatchDir -File | Where-Object $isPatch) +
           @(Get-ChildItem -LiteralPath $PatchDir -Directory | Sort-Object Name |
             ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -File | Where-Object $isPatch })
  return @($files | Sort-Object { Get-NaturalSortKey $_.Name }, { $_.FullName })
}
function Assert-PatchFile([string]$Path) {
  # A file that holds no diff would be "applied" without changing anything: stop instead.
  $text = [System.IO.File]::ReadAllText($Path).Replace("`r`n", "`n")
  if (-not ($text -match '(?m)^\+\+\+ ' -or $text.Contains("`nGIT binary patch`n"))) {
    throw "$Path is not a patch (no '+++ ' file header and no GIT binary patch in it). Fix or remove it; every *.patch / *.diff in the patches folder is applied."
  }
}
function Get-PackagePatches {
  # Returns @{ Patches = [ordered]@{ package = full paths in order }; Sources = [ordered]@{ package = where they came from };
  #            Found = @( @{ Name; Path; Target; Status } for every file in the patches folder ) }.
  param([string]$PatchDir, [string[]]$StrawberryPatch = @(), [string]$GstGoodPatch = "", [switch]$NoPlaylistLock,
        [switch]$NoAutoPatches, [string[]]$Packages)
  $patches = [ordered]@{}
  $sources = [ordered]@{}
  $report = [System.Collections.Generic.List[object]]::new()
  if ($StrawberryPatch.Count -gt 0) { $patches['strawberry'] = @($StrawberryPatch); $sources['strawberry'] = '-StrawberryPatch' }
  if ($GstGoodPatch) { $patches['gst-plugins-good'] = @($GstGoodPatch); $sources['gst-plugins-good'] = '-GstGoodPatch' }
  $lockName = 'strawberry-playlist-lock.patch'
  if (-not $NoAutoPatches -and (Test-Path -LiteralPath $PatchDir -PathType Container)) {
    $found = [ordered]@{}
    foreach ($f in @(Get-PatchFiles $PatchDir)) {
      $rel = [System.IO.Path]::GetRelativePath($PatchDir, $f.FullName)
      $target = Get-PatchTarget -Path $f.FullName -PatchDir $PatchDir -Packages $Packages
      if (-not $target) {
        throw "$($f.FullName): the folder '$(Split-Path -Leaf (Split-Path -Parent $f.FullName))' is not a package name, so this patch can't be routed. " +
              "Move it to the patches folder itself (it then goes to strawberry, or to the package its name starts with) or to patches\<package>\."
      }
      Assert-PatchFile $f.FullName
      $status = 'apply'
      if ($sources.Contains($target)) { $status = "skip ($($sources[$target]) was passed, so the patches folder is not used for $target)" }
      elseif ($NoPlaylistLock -and $f.Name -ieq $lockName) { $status = 'skip (-NoPlaylistLock)' }
      $report.Add(@{ Name = $rel; Path = $f.FullName; Target = $target; Status = $status })
      if ($status -ne 'apply') { continue }
      if (-not $found.Contains($target)) { $found[$target] = [System.Collections.Generic.List[object]]::new() }
      $found[$target].Add($f)
    }
    foreach ($t in $found.Keys) {
      $patches[$t] = @($found[$t] | Sort-Object { Get-NaturalSortKey $_.Name }, { $_.FullName } | ForEach-Object { $_.FullName })
      $sources[$t] = 'patches folder'
    }
  }
  # The playlist-lock patch shipped next to this script is always applied to strawberry (last, when it wasn't found or listed
  # already: same file, or a file with the same name from elsewhere) unless -NoPlaylistLock.
  if (-not $NoPlaylistLock) {
    $lockPatch = [System.IO.Path]::GetFullPath((Join-Path $PatchDir $lockName))
    if (Test-Path -LiteralPath $lockPatch -PathType Leaf) {
      $list = @(if ($patches.Contains('strawberry')) { $patches['strawberry'] })
      $listed = $list | Where-Object { ([System.IO.Path]::GetFullPath($_) -ieq $lockPatch) -or ((Split-Path -Leaf $_) -ieq $lockName) }
      if (-not $listed) {
        $patches['strawberry'] = @($list + $lockPatch)
        if (-not $sources.Contains('strawberry')) { $sources['strawberry'] = 'patches folder' }
        foreach ($r in $report) { if ($r.Path -ieq $lockPatch) { $r.Status = 'apply (appended after -StrawberryPatch)' } }
      }
    }
  }
  return @{ Patches = $patches; Sources = $sources; Found = @($report) }
}
$PatchDir = Join-Path $PSScriptRoot 'patches'
$patchPlan = Get-PackagePatches -PatchDir $PatchDir -StrawberryPatch $StrawberryPatch -GstGoodPatch $GstGoodPatch `
                                -NoPlaylistLock:$NoPlaylistLock -NoAutoPatches:$NoAutoPatches -Packages $KnownPackages
$PackagePatches = $patchPlan.Patches
# Every patch file in the folder, so a missing (or misrouted) patch is obvious: printed here and again at the top of the log.
function Write-PatchSummary {
  if ($NoAutoPatches) { Write-Host "Patches folder: not used (-NoAutoPatches)" -ForegroundColor Cyan }
  elseif (-not (Test-Path -LiteralPath $PatchDir -PathType Container)) { Write-Warning "Patches folder not found: $PatchDir (no local patches from it)" }
  else {
    Write-Host "Patch files found in ${PatchDir}: $($patchPlan.Found.Count)" -ForegroundColor Cyan
    foreach ($r in $patchPlan.Found) {
      Write-Host ("  {0,-45} -> {1,-18} {2}" -f $r.Name, $r.Target, $r.Status) -ForegroundColor $(if ($r.Status -like 'apply*') { 'Cyan' } else { 'Yellow' })
    }
  }
  if ($PackagePatches.Count -gt 0) {
    Write-Host "Local patches (-p1, in this order, after the build tools' own):" -ForegroundColor Cyan
    foreach ($pkg in $PackagePatches.Keys) {
      Write-Host ("  {0,-18} {1}   ({2})" -f $pkg, ((@($PackagePatches[$pkg]) | ForEach-Object { Split-Path -Leaf $_ }) -join ', '), $patchPlan.Sources[$pkg]) -ForegroundColor Cyan
    }
  }
  else { Write-Host "Local patches: none" -ForegroundColor Cyan }
}
Write-PatchSummary
# The other file/folder parameters are only made absolute here; they are checked (or created) where they are used.
foreach ($name in 'VersionsFile', 'CiVersionsFile', 'WorkRoot', 'ProjectRoot', 'MsvcRoot', 'DownloadsPath', 'SrcPath',
                  'BuildPath', 'PrefixPath', 'JomDir', 'TempPath', 'PipCachePath', 'CargoHome', 'RustupHome', 'LogPath', 'LogDir',
                  'OldCargoHome', 'OldRustupHome', 'OldDownloads', 'OldBuildPath', 'OldPrefixPath', 'GitBinPath') {
  Set-Variable -Name $name -Value (Resolve-UserPath (Get-Variable -Name $name -ValueOnly))
}

# ---------------------------------------------------------------------
# The build tools are this repository: upstream strawberry-msvc-build-tools @ 4c8c65c with the patched
# StrawberryMSVCBuild.ps1 committed, so nothing is cloned or swapped. -MsvcToolsRef is only checked, for old command lines.
# GlibNetworkingRef: the glib-networking commit this repository's patches\glib-networking.patch was written against
# (see the pin in step 6).
# ---------------------------------------------------------------------
$MsvcToolsBase     = "4c8c65c6b1b2c7f2fb0fa6fc04151962d9ed0145"   # upstream 2026-10-04 'Update dependencies'
$GlibNetworkingRef = "2616c9ea3392c908a4f46826c319f8fddc2ee2a1"   # "openssl: consult errno on syscall failure"; patch from a824b0f (2026-09-25)
if ($MsvcToolsRef -and -not $MsvcToolsBase.StartsWith($MsvcToolsRef.Trim().ToLowerInvariant())) {
  throw "-MsvcToolsRef '$MsvcToolsRef': this repository is based on strawberry-msvc-build-tools $($MsvcToolsBase.Substring(0, 7)) and always " +
        "builds with that (the patched StrawberryMSVCBuild.ps1 is committed here). Leave -MsvcToolsRef out. To use a newer " +
        "upstream commit, merge it into this repository first (see akousma\BUILD.txt)."
}
$MsvcToolsRef = $MsvcToolsBase.Substring(0, 7)
$GitRefs = $GitRefs.Clone()   # pins are added below; don't change the caller's hashtable

$ErrorActionPreference = "Stop"
function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Magenta }
function Copy-Tree($src, $dst) {
  robocopy $src $dst /E /NFL /NDL /NJH /NJS | Out-Null   # exit codes 0-7 = success
  if ($LASTEXITCODE -ge 8) { throw "robocopy $src -> $dst failed ($LASTEXITCODE)" }
  $global:LASTEXITCODE = 0
}

# ---------------------------------------------------------------------
# 0. Resolve locations (no drive letter or install folder is fixed in this script)
# ---------------------------------------------------------------------
# Work root: -WorkRoot if passed, else C:\ -- a fixed default, wherever this script is started from.
# Every location below that you did not pass as a parameter hangs off it. Pass -WorkRoot (or
# -ProjectRoot / -PrefixPath / ...) to build on a different drive. $env:STRAWBERRY_ROOT is no longer read
# here: this script sets it below, so a value left in the session by an earlier run would otherwise win.
function Normalize-Path([string]$p) {
  $p = $p.Replace('/', '\')
  if ($p -notmatch '^[A-Za-z]:\\$') { $p = $p.TrimEnd('\') }
  return $p
}
function Resolve-Default([string]$Value, [string]$Default) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return (Normalize-Path $Default) }
  return (Normalize-Path $Value)
}
function Test-SamePath($a, $b) {
  if (-not (Test-Path -LiteralPath $a) -or -not (Test-Path -LiteralPath $b)) { return $false }
  return ((Resolve-Path -LiteralPath $a).Path.TrimEnd('\') -ieq (Resolve-Path -LiteralPath $b).Path.TrimEnd('\'))
}

$WorkRoot = if ($WorkRoot) { $WorkRoot } else { 'C:\' }
if ([string]::IsNullOrEmpty($WorkRoot) -or $WorkRoot.StartsWith('\\')) { $WorkRoot = "$env:SystemDrive\" }
$WorkRoot = (Normalize-Path $WorkRoot).TrimEnd('\')
# The build script (and the pwsh children it starts) derive their tool search folders from the same root.
$env:STRAWBERRY_ROOT = $WorkRoot

$ProjectRoot   = Resolve-Default $ProjectRoot   "$WorkRoot\data\projects\strawberry"
$MsvcRoot      = Resolve-Default $MsvcRoot      "$ProjectRoot\msvc_"
$DownloadsPath = Resolve-Default $DownloadsPath "$MsvcRoot\downloads"
$SrcPath       = Resolve-Default $SrcPath       "$DownloadsPath"
$BuildPath     = Resolve-Default $BuildPath     "$MsvcRoot\build_${Arch}_${BuildType}"
$PrefixPath    = Resolve-Default $PrefixPath    "$WorkRoot\strawberry_msvc_${Arch}_${BuildType}"
$JomDir        = Resolve-Default $JomDir        "$ProjectRoot\strawberry-msvc\tools\jom"
$TempPath      = Resolve-Default $TempPath      "$WorkRoot\temp"
$PipCachePath  = Resolve-Default $PipCachePath  "$WorkRoot\cache\pip"
$CargoHome     = Resolve-Default $CargoHome     "$WorkRoot\cargo"
$RustupHome    = Resolve-Default $RustupHome    "$WorkRoot\rustup"
$LogPath       = Resolve-Default $LogPath       "$ProjectRoot\build.log"
$LogDir        = Resolve-Default $LogDir        "$BuildPath\logs"

# Old locations (migration sources / clean-up targets). They are skipped when they do not exist or
# are the same folder as the new location. The C: style defaults are where upstream's script puts things.
$OldCargoHome  = Resolve-Default $OldCargoHome  "$env:USERPROFILE\.cargo"
$OldRustupHome = Resolve-Default $OldRustupHome "$env:USERPROFILE\.rustup"
$OldDownloads  = Resolve-Default $OldDownloads  "$env:SystemDrive\data\projects\strawberry\msvc_\downloads"
$OldBuildPath  = Resolve-Default $OldBuildPath  "$env:SystemDrive\data\projects\strawberry\msvc_\build_${Arch}_${BuildType}"
$OldPrefixPath = Resolve-Default $OldPrefixPath "$env:SystemDrive\strawberry_msvc_${Arch}_${BuildType}"

# Git: found on PATH (git.exe may be in cmd\, bin\ or mingw64\bin\); the build folder added to PATH is <Git root>\bin.
if ([string]::IsNullOrWhiteSpace($GitBinPath)) {
  $gitCmd = Get-Command git.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $gitCmd) { throw "git.exe not found on PATH. Install Git for Windows (https://git-scm.com/) or pass -GitBinPath." }
  $gitDir = Split-Path -Parent $gitCmd.Source
  $gitRoot = $null
  $d = $gitDir
  for ($i = 0; $i -lt 3 -and $d; $i++) {
    if (Test-Path -LiteralPath (Join-Path $d 'usr\bin') -PathType Container) { $gitRoot = $d; break }
    $d = Split-Path -Parent $d
  }
  $GitBinPath = if ($gitRoot -and (Test-Path -LiteralPath (Join-Path $gitRoot 'bin') -PathType Container)) { Join-Path $gitRoot 'bin' } else { $gitDir }
}
$GitBinPath = Normalize-Path $GitBinPath

# ---------------------------------------------------------------------
# 1. Redirect temp and caches
# ---------------------------------------------------------------------
# Every target drive must exist: fail early with a clear message instead of a cryptic New-Item error.
$locations = [ordered]@{
  ProjectRoot = $ProjectRoot; DownloadsPath = $DownloadsPath; SrcPath = $SrcPath; BuildPath = $BuildPath; PrefixPath = $PrefixPath
  JomDir = $JomDir; TempPath = $TempPath; PipCachePath = $PipCachePath; CargoHome = $CargoHome
  RustupHome = $RustupHome; LogPath = $LogPath; LogDir = $LogDir
}
foreach ($k in $locations.Keys) {
  $driveRoot = [System.IO.Path]::GetPathRoot($locations[$k])
  if ($driveRoot -and -not $driveRoot.StartsWith('\\') -and -not (Test-Path -LiteralPath $driveRoot)) {
    throw "Drive '$driveRoot' for -$k ($($locations[$k])) does not exist or is not ready. Pass a different -$k."
  }
}

Write-Step "Redirecting temp/caches"
# All folders are created when missing, including the log folders (Tee-Object does not create the folder of -LogPath).
New-Item -ItemType Directory -Force $TempPath, $PipCachePath, $CargoHome, $RustupHome, $ProjectRoot, $DownloadsPath, $SrcPath, $BuildPath, $PrefixPath, $LogDir, (Split-Path -Parent $LogPath) | Out-Null
$env:TEMP = $TempPath; $env:TMP = $TempPath
$env:PIP_CACHE_DIR = $PipCachePath

# ---------------------------------------------------------------------
# 2. Copy existing Rust state once so cargo/cargo-c keep working
# ---------------------------------------------------------------------
Write-Step "Copying Rust state (if present)"
if ((Test-Path $OldCargoHome)  -and -not (Test-SamePath $OldCargoHome  $CargoHome))  { Copy-Tree $OldCargoHome  $CargoHome }
if ((Test-Path $OldRustupHome) -and -not (Test-SamePath $OldRustupHome $RustupHome)) { Copy-Tree $OldRustupHome $RustupHome }
$env:CARGO_HOME = $CargoHome; $env:RUSTUP_HOME = $RustupHome

# ---------------------------------------------------------------------
# 3. Build tools: this repository (the folder above akousma\), patched StrawberryMSVCBuild.ps1 included
# ---------------------------------------------------------------------
$RepoPath   = Split-Path -Parent $PSScriptRoot
$ScriptPath = Join-Path $RepoPath "StrawberryMSVCBuild.ps1"
Write-Step "Using the build tools in $RepoPath"
if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
  throw "StrawberryMSVCBuild.ps1 not found in $RepoPath. Run this script from the akousma folder of the Akousma build tools repository."
}
# Only the patched script has -package_patches; upstream's own would ignore the local patches and the parallel build options.
if (-not (Select-String -LiteralPath $ScriptPath -Pattern '\$package_patches\b' -Quiet)) {
  throw "$ScriptPath is not the patched build script (no -package_patches parameter). Restore it with: git -C `"$RepoPath`" checkout -- StrawberryMSVCBuild.ps1"
}
# A zip download carries the downloaded-file (Mark of the Web) flag, which trips the execution policy.
foreach ($f in $ScriptPath, (Join-Path $RepoPath "CopyDLLDependencies.ps1")) { Unblock-File -LiteralPath $f -ErrorAction SilentlyContinue }
$repoHead = if (Test-Path -LiteralPath (Join-Path $RepoPath ".git")) { git -C $RepoPath rev-parse --short HEAD 2>$null } else { $null }
Write-Host ("Build tools: strawberry-msvc-build-tools $MsvcToolsRef + Akousma changes" + $(if ($repoHead) { ", repository at $repoHead" } else { "" })) -ForegroundColor Cyan

# ---------------------------------------------------------------------
# 4. jom (parallel nmake replacement)
# ---------------------------------------------------------------------
Write-Step "Checking for jom"
$jomCmd  = Get-Command jom.exe -ErrorAction SilentlyContinue
$jomPath = if ($jomCmd) { $jomCmd.Source } else { Join-Path $JomDir "jom.exe" }

if (-not (Test-Path $jomPath)) {
  Write-Host "jom.exe not found; downloading..."
  New-Item -ItemType Directory -Path $JomDir -Force | Out-Null
  $jomZip = Join-Path $TempPath "jom.zip"
  try {
    Invoke-WebRequest -Uri "https://download.qt.io/official_releases/jom/jom.zip" -OutFile $jomZip -UseBasicParsing
    Expand-Archive -Path $jomZip -DestinationPath $JomDir -Force
  }
  catch {
    throw "Could not download jom ($_). Get it from https://download.qt.io/official_releases/jom/ and put jom.exe in '$JomDir'."
  }
  finally { Remove-Item $jomZip -ErrorAction SilentlyContinue }
}
if (-not (Test-Path $jomPath)) { throw "jom.exe still missing at '$jomPath'." }
Write-Host "Using jom at: $jomPath"

# ---------------------------------------------------------------------
# 5. Reuse old downloads, kill leftovers, clean partial OpenSSL trees
# ---------------------------------------------------------------------
Write-Step "Migrating downloads and cleaning partial OpenSSL builds"
if ((Test-Path $OldDownloads) -and ((Resolve-Path $OldDownloads).Path -ne (Resolve-Path $DownloadsPath).Path)) {
  # Once per old folder (recorded in <DownloadsPath>\.migrated-downloads.txt), and only the downloaded files directly in it
  # that are missing here: never the git clones upstream's layout keeps next to them (they belong in -SrcPath), never an overwrite.
  $migratedList = Join-Path $DownloadsPath '.migrated-downloads.txt'
  $migrated = @(if (Test-Path -LiteralPath $migratedList) { Get-Content -LiteralPath $migratedList })
  if ($migrated -contains $OldDownloads) {
    Write-Host "Downloads from $OldDownloads were copied by an earlier run (delete $migratedList to copy missing ones again)."
  }
  else {
    $missing = @(Get-ChildItem -LiteralPath $OldDownloads -File | Where-Object {
      $_.Name -notlike '*.part' -and -not (Test-Path -LiteralPath (Join-Path $DownloadsPath $_.Name))
    })
    foreach ($f in $missing) {
      $dest = Join-Path $DownloadsPath $f.Name
      Copy-Item -LiteralPath $f.FullName -Destination "$dest.copy.part" -Force   # renamed into place: never a half-copied archive
      Move-Item -LiteralPath "$dest.copy.part" -Destination $dest
    }
    Add-Content -LiteralPath $migratedList -Value $OldDownloads
    Write-Host "Copied $($missing.Count) missing download(s) from $OldDownloads (files only, one time)"
  }
}

Get-Process cl, nmake, jom, mspdbsrv -ErrorAction SilentlyContinue | Stop-Process -Force

$stale = foreach ($r in @($BuildPath, $OldBuildPath) | Select-Object -Unique | Where-Object { Test-Path $_ }) {
  Get-ChildItem -Path $r -Directory -Filter "openssl-*" -ErrorAction SilentlyContinue |
    Where-Object { Test-Path (Join-Path $_.FullName "Configure") }
}
if ($stale) { $stale | ForEach-Object { Write-Host "Removing: $($_.FullName)"; Remove-Item $_.FullName -Recurse -Force } }
else        { Write-Host "No partial OpenSSL tree found." }

if ($RemoveOldCDrive) {
  Write-Step "Removing old build tree, prefix and downloads"
  foreach ($p in $OldBuildPath, $OldPrefixPath, $OldDownloads) {
    if ((Test-Path $p) -and $p -notin @($BuildPath, $PrefixPath, $DownloadsPath)) { Write-Host "Removing: $p"; Remove-Item $p -Recurse -Force }
  }
}

# ---------------------------------------------------------------------
# 6. Build
# ---------------------------------------------------------------------
if ($SkipBuild) { Write-Step "Done (build skipped)."; return }

# ---------------------------------------------------------------------
# CI versions: fetch strawberry-msvc-dependencies' build.yaml for the release (-CiVersionsRef)
# ---------------------------------------------------------------------
if (-not $CiVersionsFile -and $CiVersionsRef) {
  $depsRepo = "strawberrymusicplayer/strawberry-msvc-dependencies"
  $depsRef  = $CiVersionsRef
  if ($depsRef -eq 'auto') {
    if (-not $StrawberryRef) {
      $depsRef = 'master'
    }
    else {
      Write-Step "Resolving the dependency versions that were current at strawberry @ $StrawberryRef"
      $ghHeaders = @{ 'User-Agent' = 'Build-Strawberry.ps1'; 'Accept' = 'application/vnd.github+json' }
      if ($env:GITHUB_TOKEN) { $ghHeaders['Authorization'] = "Bearer $env:GITHUB_TOKEN" }
      $sc = Invoke-RestMethod -Headers $ghHeaders -Uri "https://api.github.com/repos/strawberrymusicplayer/strawberry/commits/$StrawberryRef"
      $until = ([datetime]$sc.commit.committer.date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
      $dc = @(Invoke-RestMethod -Headers $ghHeaders -Uri "https://api.github.com/repos/$depsRepo/commits?path=.github/workflows/build.yaml&until=$until&per_page=1")
      if ($dc.Count -eq 0 -or -not $dc[0].sha) { throw "No build.yaml commit found in $depsRepo before $until" }
      $depsRef = $dc[0].sha
      Write-Host "strawberry @ $StrawberryRef was committed $until; using $depsRepo build.yaml @ $($depsRef.Substring(0, 7))"
    }
  }
  Write-Step "Fetching dependency versions (build.yaml @ $depsRef)"
  $ciUrl  = "https://raw.githubusercontent.com/$depsRepo/$depsRef/.github/workflows/build.yaml"
  $ciName = "build." + (($depsRef -replace '[^A-Za-z0-9._-]', '_')) + ".yaml"
  $CiVersionsFile = Join-Path $TempPath $ciName
  Invoke-WebRequest -Uri $ciUrl -OutFile $CiVersionsFile -UseBasicParsing
  Write-Host "Saved: $CiVersionsFile"
}

Write-Step "Building ($BuildType / $Arch, $Jobs jobs, $(if ($ParallelPackages -le 0) { "auto" } else { $ParallelPackages }) packages at once, build tools @ $MsvcToolsRef + Akousma, strawberry @ $(if ($StrawberryRef) { $StrawberryRef } else { "master" })) -> $PrefixPath"
$jomDirInUse = Split-Path $jomPath
# Prepend the build folders without duplicates: an entry already on Path (e.g. left by an older run of this script in this
# window) is moved to the front rather than added again, and repeated entries are dropped (first one wins, so lookup order is kept).
function Join-PathList([string[]]$Entries) {
  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $kept = foreach ($entry in $Entries) {
    $t = "$entry".Trim()
    if ($t -and $seen.Add($t.TrimEnd('\'))) { $t }
  }
  return ($kept -join ';')
}
$env:Path = Join-PathList (@($jomDirInUse, "$CargoHome\bin", "$PrefixPath\bin", $GitBinPath) + ($env:Path -split ';'))
Set-Location $RepoPath

$buildArgs = @{
  build_type        = $BuildType
  arch              = $Arch
  downloads_path    = $DownloadsPath.Replace('\', '/')
  src_path          = $SrcPath.Replace('\', '/')
  build_path        = $BuildPath.Replace('\', '/')
  prefix_path       = $PrefixPath.Replace('\', '/')
  jobs              = $Jobs
  parallel_packages = $ParallelPackages
  jom_path          = $jomDirInUse
  log_dir           = $LogDir.Replace('\', '/')
}
if ($StrawberryRef)          { $buildArgs.strawberry_ref   = $StrawberryRef }
if ($PackagePatches.Count -gt 0) {
  $buildArgs.package_patches = @{}
  foreach ($pkg in $PackagePatches.Keys) {
    $buildArgs.package_patches[$pkg] = [string[]]@(foreach ($patch in $PackagePatches[$pkg]) {
      if (-not (Test-Path -LiteralPath $patch)) { throw "Patch for $pkg not found: $patch" }
      (Resolve-Path -LiteralPath $patch).Path
    })
  }
}
if ($ForceRebuild.Count -gt 0) { $buildArgs.force_rebuild = $ForceRebuild }
if ($NoChangeDetection)      { $buildArgs.no_change_detection = $true }
if ($RebuildDependents)      { $buildArgs.rebuild_dependents = $true }
if ($Only.Count -gt 0)       { $buildArgs.only             = $Only }
if ($Skip.Count -gt 0)       { $buildArgs.skip             = $Skip }
if ($List)                   { $buildArgs.list             = $true }
if ($VersionsFile)           { $buildArgs.versions_file    = $VersionsFile }
if ($CiVersionsFile)         { $buildArgs.ci_versions_file = $CiVersionsFile }
if ($VersionOverrides.Count) { $buildArgs.version_overrides = $VersionOverrides }
# glib-networking is cloned from git (upstream's script builds master, unpinned) and patched with the build tools'
# patches\glib-networking.patch (OpenSSL threading fixes), which upstream regenerates whenever glib-networking master moves.
# So the right commit depends on the build tools commit, not on the strawberry version: pin the commit this repository's
# patch was written against ($GlibNetworkingRef above; the patch's 'index' blob hashes match it, and it applies with no offset
# or fuzz). For upstream 4c8c65c (and 1dfe51d) that is 2616c9e; 34e85f6 needed e23c430 (2.90.alpha). The older f54d8d6 pin
# rejected a gtlsconnection-openssl.c hunk of this patch (offset -23 lines). When you merge a newer upstream commit that
# changes patches\glib-networking.patch, update $GlibNetworkingRef to match.
# The pin wins over a 40-char glib_networking_version in the CI build.yaml: that one goes with the patch CI had at the time,
# which may not be this repository's (for strawberry 1.2.31, CI's dec75a1 has the same patched files as 2616c9e anyway).
# -GitRefs @{ 'glib-networking' = '<commit>' } overrides all of this.
$ciGlibNet = if ($CiVersionsFile -and (Test-Path -LiteralPath $CiVersionsFile) -and
  ((Get-Content -Raw -LiteralPath $CiVersionsFile) -match "(?m)^\s+glib_networking_version:\s*'?([0-9a-f]{40})\b")) { $Matches[1] } else { "" }
if (-not $GitRefs.ContainsKey('glib-networking')) {
  if ($GlibNetworkingRef) {
    $GitRefs['glib-networking'] = $GlibNetworkingRef
    if ($ciGlibNet -and $ciGlibNet -ne $GlibNetworkingRef) {
      Write-Host "glib-networking: using $($GlibNetworkingRef.Substring(0, 7)) (the base of glib-networking.patch at $MsvcToolsRef), not CI's $($ciGlibNet.Substring(0, 7))." -ForegroundColor Cyan
    }
  }
  elseif (-not $ciGlibNet) {
    Write-Warning "No glib-networking commit is known for -MsvcToolsRef '$MsvcToolsRef'; building glib-networking master. If glib-networking.patch fails, pass -GitRefs @{ 'glib-networking' = '<commit>' }."
  }
}
if ($GitRefs.Count)          { $buildArgs.git_refs         = $GitRefs }

# The inner script exports its resolved git refs as $env:SMB_GIT_REFS_JSON for its child processes, and reloads that variable when
# no refs are passed in. Since it runs in this session, a previous run's refs (e.g. glib-networking @ f54d8d6) would leak into this one.
Remove-Item Env:SMB_GIT_REFS_JSON -ErrorAction SilentlyContinue
# Same for the patch and clean lists the inner script hands its child processes, and the variables older versions of this script used.
Remove-Item Env:SMB_PACKAGE_PATCHES_JSON, Env:SMB_CLEAN_PACKAGES, Env:SMB_STRAWBERRY_PATCH, Env:SMB_GST_GOOD_PATCH -ErrorAction SilentlyContinue

$ErrorActionPreference = "Continue"   # native tools write to stderr; don't abort on that
& { Write-PatchSummary; & $ScriptPath @buildArgs } *>&1 | Tee-Object $LogPath
}
finally {
  Set-Location -LiteralPath $StartLocation
  # Put the environment back exactly as it was: drop variables added by this run, restore changed/removed ones.
  foreach ($name in @([Environment]::GetEnvironmentVariables().Keys)) {
    if (-not $StartEnv.ContainsKey([string]$name)) { [Environment]::SetEnvironmentVariable([string]$name, $null) }
  }
  foreach ($name in $StartEnv.Keys) {
    if ([Environment]::GetEnvironmentVariable($name) -cne $StartEnv[$name]) { [Environment]::SetEnvironmentVariable($name, $StartEnv[$name]) }
  }
}
