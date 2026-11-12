#Requires -Version 7.0
# Akousma MSVC build script
# Copyright 2026, Genki (genki_jp0) <genki_jp0@users.noreply.github.com>
#
# Based on StrawberryMSVCBuild.ps1 from strawberry-msvc-build-tools:
# Strawberry Music Player
# Copyright 2025-2026, Jonas Kvinge <jonas@jkvinge.net>
#
# Strawberry is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Strawberry is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Strawberry.  If not, see <http://www.gnu.org/licenses/>.
#

<#
.SYNOPSIS
  Builds Akousma for Windows with MSVC: every dependency, Akousma itself and the AkousmaSetup installer.

.DESCRIPTION
  One script: it prepares the build environment and then builds, in the same run.
    1. Redirects TEMP / pip cache / cargo / rustup under the work root and copies existing .cargo / .rustup there (once)
    2. Downloads jom.exe if missing
    3. Copies missing downloaded archives from the old downloads folder (once), stops leftover compilers, removes partial
       OpenSSL trees
    4. Builds what is missing or changed, logging to -LogPath (per-package logs in -LogDir, stamps in <BuildPath>\.stamps):
       the dependencies (with the build tools' own patches\ and the local-patches\ folder), then Akousma from its git
       repository (-AkousmaRepo at -AkousmaRef) or from a local checkout (-AkousmaSource), then AkousmaSetup-*.exe.
  Run it in PowerShell 7 (pwsh) from anywhere; the build tools are the folder this script is in.

  Tools the build expects (Git, Strawberry Perl, nasm, CMake, 7-Zip, Python, win_flex_bison, Meson, NSIS with the LockedList
  plugin, Visual Studio) are installed programs. Putting each tool's folder on PATH is the recommended setup: a tool is looked
  for on PATH first, and only one that isn't there is searched for: its registry entry or usual folder, then the folders in
  $env:SMB_TOOL_PATHS (';'-separated; not for Python), then Program Files, LOCALAPPDATA\Programs, the system and work drives,
  and the root and Program Files of every other fixed drive. makensis (NSIS) and ninja (from the Visual Studio environment)
  are not searched for. The tools are checked one at a time before anything is built; the run stops at the first missing one.

  Change detection: every package's build is stamped with what went into it (version / git commit, patch hashes, build
  recipe). A run skips what is up to date, rebuilds what changed (dependencies from a clean copy, Akousma incrementally) and
  prints the decision for every package before it builds. See -ForceRebuild, -NoChangeDetection, -RebuildDependents.

  Dependency versions (-Deps, default auto): a build of an Akousma release uses that release's lock, versions\<release>.txt
  (tag 1.0.0 or v1.0.0, or the commit the lock records), so rebuilding 1.0.0 later builds the same dependency versions. Any
  other build (master, a branch, a commit, a local checkout) uses the latest versions: the newest set upstream's CI has built
  (strawberry-msvc-build-tools master's StrawberryPackageVersions.txt), with this repository's StrawberryPackageVersions.txt
  (the pinned versions) for anything upstream doesn't have or whose build tools patch upstream changed with the update. The
  run prints which versions differ from the pinned ones. -FreezeDeps 1.0.0 writes versions\1.0.0.txt from the versions of
  that run. A package whose version changed is rebuilt (its version is part of its stamp).

  Local patches: every *.patch / *.diff in local-patches\ next to this script is applied (-p1) to the dependency its name
  starts with (qtbase-*.patch -> qtbase, gstreamer-*.patch -> gst-plugins-good, glib-networking-x.patch -> glib-networking,
  ...), or to <package> for local-patches\<package>\*.patch. Akousma's own changes are commits in the Akousma repository,
  so patches for Akousma (or Strawberry) are not accepted here.

  Build settings: build-settings.json next to this script holds the architectures, the build type, the Akousma source and
  the locations. It is created with the defaults on the first run (every architecture: x86_64, x86, arm64), is your own
  (.gitignore keeps it out of git) and can be edited (JSON: write \\ for a backslash, or use /). For each setting a parameter
  passed on the command line wins, then the file, then the default; a setting missing from the file uses the default.
  Passed parameters are for that run only: add -SaveSettings to keep them in the file. In the locations, {WorkRoot},
  {ProjectRoot}, {MsvcRoot}, {DownloadsPath}, {BuildPath} (each usable in the locations below it in the file), {Arch} and
  {BuildType} stand for the resolved values; a location still at its default follows the ones it is made of (change
  WorkRoot, and everything under it moves). "" = automatic (HostPrefixPath, GitBinPath) or not used (AkousmaSource).

.PARAMETER AkousmaRepo       Git URL of the Akousma source. Default https://github.com/Genki-jp0/Akousma.git.
.PARAMETER AkousmaRef        Branch, tag or commit of -AkousmaRepo to build. Default master.
.PARAMETER AkousmaSource     A local Akousma checkout to build instead of -AkousmaRepo, as it is (uncommitted changes included).
                             It is built out of tree, in <BuildPath>\akousma\build; the checkout itself is not changed.
.PARAMETER EnableQtSparkle   Build Akousma with the QtSparkle update check. Off by default: the only QtSparkle feed is
                             upstream Strawberry's, which offers Strawberry releases, not Akousma ones.
.PARAMETER IncludeGitCommit  Show Akousma's own short git commit with the version ("Akousma 1.0.0 (git abc1234)", installer
                             AkousmaSetup-1.0.0+gitabc1234-...). Off by default: release builds say "Akousma 1.0.0" only.
                             Passed to CMake as -DAKOUSMA_INCLUDE_GIT_COMMIT=ON.
.PARAMETER BuildType          release (default) or debug.
.PARAMETER Arch               x64 (also x86_64 / amd64), x86 or arm64. Default: the Arch list in build-settings.json, which
                              is every architecture (x86_64, x86, arm64) until you change it (-SaveSettings). Several are
                              built one after the other, each in a fresh pwsh process (so one Visual Studio environment
                              never leaks into the next) and in its own folders: -Arch x64,x86 (or "x64,x86" in one
                              argument, or both = x64 + x86).
                              Every architecture has its own build tree, dependency prefix, logs and installer; downloads and
                              git clones are shared. A build that fails does not stop the next architecture; the run ends with
                              a summary and exit code 1 if any failed.
                              -Arch arm64 on an x64 PC cross-compiles: build -Arch x64 first (or -Arch x64,arm64), the
                              arm64 build runs the x64 build's tools (see -HostPrefixPath and BUILD.txt).
.PARAMETER HostPrefixPath     -Arch arm64 on an x64 PC only: the x64 dependency prefix whose programs (pkg-config, Qt's
                              moc / rcc / uic / lrelease, orcc, glib-compile-resources, ...) the cross-compile runs. Default:
                              the prefix -Arch x64 uses with the same -WorkRoot / -PrefixPath / -BuildType
                              (C:\Akousma\akousma_msvc_x86_64_release). It has to be a finished x64 build of the same
                              versions.
.PARAMETER Jobs               Parallel jobs in total (split between parallel packages). Default: logical processors.
.PARAMETER ParallelPackages   Packages built at the same time. 0 = auto (half the jobs, min 2). 1 = one after the other.
.PARAMETER Only / -Skip       Build only / never build these packages (when they need building). Akousma is "akousma", the
                              installer "akousma-setup".
.PARAMETER List               Print the per-package decision (skip / adopt / build / rebuild and why) and the build queue,
                              then exit.
.PARAMETER DryRun             Print the resolved locations, the dependency versions, the Akousma source and the local
                              patches, then exit. Changes nothing but build-settings.json (created when missing; written
                              with -SaveSettings) and, with -FreezeDeps, the lock; also runs on Linux and macOS, for checking
                              a command line.
.PARAMETER SaveSettings       Write the settings passed on this command line (-Arch, -BuildType, -AkousmaRepo, -AkousmaRef,
                              -AkousmaSource, -WorkRoot and the other locations) into build-settings.json, so later runs use
                              them without passing them. Paths are saved absolute. -Arch x64,x86 -SaveSettings: from now
                              on x64 and x86 are built; -Arch x86 alone builds x86 for that run only. With -DryRun: save,
                              don't build.
.PARAMETER ForceRebuild       Rebuild these packages even when they are up to date, e.g. -ForceRebuild gst-plugins-good,akousma
                              ('all' = everything). Dependencies get a clean copy; akousma a fresh copy of its source and an
                              empty build folder.
.PARAMETER Clean              Rebuild Akousma from scratch: a fresh copy of its source and an empty build folder (the same
                              as -ForceRebuild akousma). Without it Akousma is always built incrementally: the build folder is
                              kept, CMake runs again only when its arguments changed, and ninja recompiles only the files
                              that changed (and what includes them). A change of the MSVC toolset (VCToolsVersion) cleans
                              by itself.
.PARAMETER IncrementalLink    Release builds: link akousma.exe incrementally (/INCREMENTAL /OPT:NOREF /OPT:NOICF instead of
                              CMake's /INCREMENTAL:NO), so a relink after a small change is faster. For development only: the
                              exe gets bigger (padding, no unreferenced-code removal), so don't ship an AkousmaSetup made with
                              it. Debug builds link incrementally anyway (CMake's default). Akousma uses no /LTCG.
.PARAMETER NoChangeDetection  Build what has no output and skip everything else, whatever changed (akousma is still rebuilt
                              when its build tree is not at -AkousmaRef). Stamps are still written after builds.
.PARAMETER RebuildDependents  When a package is rebuilt because it changed, also rebuild the packages that link it directly
                              (e.g. after a version bump that renames a DLL). Without it, only dependents of header-only
                              packages are rebuilt; akousma is relinked and AkousmaSetup re-created after any rebuild either way.
.PARAMETER VersionOverrides   e.g. -VersionOverrides @{ qt_version = '6.11.2' }
.PARAMETER GitRefs            e.g. -GitRefs @{ 'gst-plugins-rs' = '0.15.3' }. glib-networking is pinned automatically to the
                              commit this repository's patches\glib-networking.patch applies to; an entry here wins.
.PARAMETER Deps               Dependency versions. auto (default; build-settings.json "Deps"): the lock of the Akousma release
                              being built, else latest. latest: upstream strawberry-msvc-build-tools master's tested versions,
                              each one only when this repository's patch for it is still upstream's (else pinned, with a
                              warning); no network = pinned, with a warning. pinned: StrawberryPackageVersions.txt (or
                              -VersionsFile) as it is. <release>, e.g. 1.0.0: versions\<release>.txt. -VersionOverrides win
                              over all of them. The versions used are written to <BuildPath>\deps-versions.txt.
.PARAMETER FreezeDeps         Write versions\<release>.txt (e.g. -FreezeDeps 1.0.0) from the versions this run uses, plus the
                              commits of the git-sourced dependencies (yasm, libffi, gst-plugins-rs, qtsparkle, pe-util), which
                              this run then builds too. Commit the file. An existing lock is never replaced. With -DryRun:
                              write the lock, build nothing.
.PARAMETER DepsUpstream       Where -Deps latest reads upstream's versions: a branch, tag or (full) commit of
                              strawberry-msvc-build-tools (default master), a raw-file URL or a folder.
.PARAMETER VersionsFile       Alternative StrawberryPackageVersions.txt (the pinned versions; -Deps auto then means pinned).
.PARAMETER CiVersionsFile     strawberry-msvc-dependencies build.yaml (path/URL) whose *_version values win.
.PARAMETER CiVersionsRef      Fetch strawberry-msvc-dependencies' build.yaml automatically (ignored with -CiVersionsFile; with
                              either, -Deps auto means pinned and the CI file's versions win).
                              'auto'   = the newest build.yaml commit that existed when the Akousma commit being built was
                                         made (GitHub API; set $env:GITHUB_TOKEN if you hit the unauthenticated rate limit),
                              'master' / a tag / a commit = that exact revision.
                              Empty = no CI file. The download is cached in <TempPath> and used as -CiVersionsFile.
.PARAMETER GstGoodPatch       A .patch file (-p1, relative to the gst-plugins-good root) for gst-plugins-good. Passing it turns
                              off the local-patches\ files for gst-plugins-good.
.PARAMETER NoAutoPatches      Don't apply local-patches\ (only -GstGoodPatch). The build tools' own patches\ are always applied.
.PARAMETER SkipBuild          Prepare everything (folders, caches, jom, downloads migration), but don't build.
.PARAMETER RemoveOldCDrive    Delete the old C: build tree, prefix and downloads (-OldBuildPath, -OldPrefixPath, -OldDownloads).
.PARAMETER WorkRoot           Drive/folder everything is built under. Default C:\Akousma, wherever this script is (created
                              when missing). Until 2026-11 it was C:\ (-WorkRoot C:\ -SaveSettings keeps those folders).
.PARAMETER ProjectRoot, MsvcRoot, DownloadsPath, SrcPath, BuildPath, PrefixPath, JomDir, TempPath,
           PipCachePath, CargoHome, RustupHome, LogPath, LogDir
                              Locations. Empty = under the work root. With no path parameters the defaults are:
                                ProjectRoot   C:\Akousma\data\projects\akousma   (build.log; x86: build_x86.log)
                                DownloadsPath C:\Akousma\data\projects\akousma\msvc_\downloads   (SrcPath: the same;
                                              Akousma is cloned to <SrcPath>\akousma)
                                BuildPath     C:\Akousma\data\projects\akousma\msvc_\build_<arch>_<build type>
                                              (LogDir: ...\logs)
                                PrefixPath    C:\Akousma\akousma_msvc_<arch>_<build type>
                                JomDir        C:\Akousma\data\projects\akousma\tools\jom   (only when jom.exe is not
                                              on PATH)
                                TempPath C:\Akousma\temp, PipCachePath C:\Akousma\cache\pip, CargoHome C:\Akousma\cargo,
                                RustupHome C:\Akousma\rustup, LogPath C:\Akousma\data\projects\akousma\build.log
                              Until 2026-11 the defaults used upstream's strawberry names (data\projects\strawberry,
                              strawberry_msvc_<arch>_<type>). Those folders are not used any more: the prefix and the build
                              trees have their absolute paths baked in, so the new folders are a full rebuild. Upstream's
                              prebuilt strawberry-msvc-<arch>-<type>.tar.xz only works at the path it was built for: extract
                              it to C:\strawberry_msvc_<arch>_<type> and pass that as -PrefixPath.
                              <arch> is x86_64, x86 or arm64. An explicit -BuildPath / -PrefixPath / -LogDir / -LogPath is used
                              as it is for x86_64 and gets _<arch> appended for x86 and arm64 (E:\build -> E:\build_x86,
                              build.log -> build_x86.log) unless its name already says the architecture, so an x64 command
                              line plus -Arch x86 never builds into the x64 folders.
.PARAMETER OldCargoHome, OldRustupHome, OldDownloads, OldBuildPath, OldPrefixPath
                              Old locations to migrate from / clean. Empty = the usual old spots (%USERPROFILE%\.cargo,
                              <system drive>\data\..., ...); skipped if absent.
.PARAMETER GitBinPath         Git's bin folder, added to PATH. Empty = found through git.exe on PATH.

.EXAMPLE
  # Akousma master, everything under C:\Akousma
  .\Build-Akousma.ps1
  # A tag or commit of Akousma, built on E:, with the dependency versions upstream's CI used at that time
  .\Build-Akousma.ps1 -AkousmaRef 7f216b8 -CiVersionsRef auto -WorkRoot E:\
  # A local checkout with uncommitted changes
  .\Build-Akousma.ps1 -AkousmaSource E:\src\Akousma
  # What would be rebuilt and why, without building anything
  .\Build-Akousma.ps1 -List
  # Rebuild gst-plugins-good from scratch (akousma is relinked, AkousmaSetup re-created)
  .\Build-Akousma.ps1 -ForceRebuild gst-plugins-good
  # Check a command line: resolved folders, source and local patches, nothing is changed
  .\Build-Akousma.ps1 -WorkRoot E:\ -AkousmaSource E:\src\Akousma -DryRun
  # Release 1.0.0: build it with the latest dependency versions and keep them (versions\1.0.0.txt; commit that file)
  .\Build-Akousma.ps1 -AkousmaRef v1.0.0 -FreezeDeps 1.0.0
  # Later: the same tag builds with the 1.0.0 versions again; master keeps following the latest versions
  .\Build-Akousma.ps1 -AkousmaRef v1.0.0
  # The versions a run would use (and what differs from StrawberryPackageVersions.txt), nothing is built
  .\Build-Akousma.ps1 -Deps latest -DryRun
  # 32-bit (x86) build, in its own folders (build_x86_release, akousma_msvc_x86_release)
  .\Build-Akousma.ps1 -Arch x86
  # x64 and x86, one after the other
  .\Build-Akousma.ps1 -Arch x64,x86
  # arm64 on an x64 PC (cross-compile; the x64 build is built first, or reused when it is up to date)
  .\Build-Akousma.ps1 -Arch x64,arm64
  # Build only x64 from now on (kept in build-settings.json), then go back to every architecture
  .\Build-Akousma.ps1 -Arch x64 -SaveSettings
  .\Build-Akousma.ps1 -Arch x64,x86,arm64 -SaveSettings -DryRun
#>

[CmdletBinding()]
param(
  # Akousma source
  [Alias('akousma_repo')]
  [string]$AkousmaRepo      = "https://github.com/Genki-jp0/Akousma.git",
  [string]$AkousmaRef       = "master",
  [Alias('akousma_source')]
  [string]$AkousmaSource    = "",
  [Alias('enable_qtsparkle')]
  [switch]$EnableQtSparkle,
  [Alias('include_git_commit')]
  [switch]$IncludeGitCommit,

  # versions / options
  [Alias('build_type')]
  [ValidateSet("debug", "release", "Debug", "Release")]
  [string]$BuildType        = "release",
  # One or more of x64 / x86_64 / amd64, x86, arm64, both (= x64,x86). Validated below, so "x64,x86" in one argument
  # (pwsh -File, cmd) works too.
  [ArgumentCompleter({ param($cmd, $param, $word) @('x64', 'x86', 'arm64', 'both', 'x86_64', 'amd64') | Where-Object { $_ -like "$word*" } })]
  [string[]]$Arch           = @("x86_64", "x86", "arm64"),
  [ValidateRange(0, 512)]
  [int]$Jobs                = 0,
  [Alias('parallel_packages')]
  [ValidateRange(0, 64)]
  [int]$ParallelPackages    = 0,
  [string[]]$Only           = @(),
  [string[]]$Skip           = @(),
  [switch]$List,
  [switch]$DryRun,
  [switch]$SaveSettings,
  [Alias('force_rebuild')]
  [string[]]$ForceRebuild   = @(),
  [switch]$Clean,
  [Alias('incremental_link')]
  [switch]$IncrementalLink,
  [Alias('no_change_detection')]
  [switch]$NoChangeDetection,
  [Alias('rebuild_dependents')]
  [switch]$RebuildDependents,
  [Alias('version_overrides')]
  [hashtable]$VersionOverrides = @{},
  [Alias('git_refs')]
  [hashtable]$GitRefs       = @{},
  [string]$Deps             = "",   # auto (default; build-settings.json), latest, pinned or a release lock (versions\<release>.txt)
  [string]$FreezeDeps       = "",
  [string]$DepsUpstream     = "",
  [Alias('versions_file')]
  [string]$VersionsFile     = "",
  [Alias('ci_versions_file')]
  [string]$CiVersionsFile   = "",
  [string]$CiVersionsRef    = "",
  [string]$GstGoodPatch     = "",
  [switch]$NoAutoPatches,
  [switch]$SkipBuild,
  [switch]$RemoveOldCDrive,

  # locations (empty = derived from -WorkRoot, see the help)
  [string]$WorkRoot         = "",
  [string]$ProjectRoot      = "",
  [string]$MsvcRoot         = "",
  [Alias('downloads_path')]
  [string]$DownloadsPath    = "",
  [Alias('src_path')]
  [string]$SrcPath          = "",
  [Alias('build_path')]
  [string]$BuildPath        = "",
  [Alias('prefix_path')]
  [string]$PrefixPath       = "",
  [string]$JomDir           = "",
  [string]$TempPath         = "",
  [string]$PipCachePath     = "",
  [string]$CargoHome        = "",
  [string]$RustupHome       = "",
  [string]$LogPath          = "",
  [Alias('log_dir')]
  [string]$LogDir           = "",
  [Alias('host_prefix_path')]   # -Arch arm64 on an x64 PC: the x64 prefix (empty = the -Arch x64 one)
  [string]$HostPrefixPath   = "",

  # old locations to migrate from / clean up
  [string]$OldCargoHome     = "",
  [string]$OldRustupHome    = "",
  [string]$OldDownloads     = "",
  [string]$OldBuildPath     = "",
  [string]$OldPrefixPath    = "",

  [string]$GitBinPath       = "",   # empty = <Git root>\bin, found through git.exe on PATH

  # Internal: one architecture of a multi-architecture run (-arch_build: the settings are resolved by the run that starts
  # it), the build itself (-inner_build, started by the preparation part of this script) and the per-package child
  # processes of the parallel build (-child_build).
  [Parameter(DontShow)]
  [switch]$arch_build,
  [Parameter(DontShow)]
  [hashtable]$deps_resolved = @{},
  [Parameter(DontShow)]
  [string]$jom_path         = "",
  [Parameter(DontShow)]
  [hashtable]$package_patches = @{},
  [Parameter(DontShow)]
  [switch]$inner_build,
  [Parameter(DontShow)]
  [switch]$child_build
)

#region Preparation
# This part runs when the script is started by the user. It resolves the locations, prepares the environment and then runs the
# build part below in the same session (-inner_build), with the output also written to -LogPath. The build part starts one
# child process per package for the parallel build (-child_build). Both skip this region.
if (-not $inner_build -and -not $child_build) {

# Remember where the user started; restored in the finally block at the very end (success, failure or Ctrl+C).
$StartLocation = (Get-Location).Path
$BuildExitCode = 0
# Same for the environment: this script (Path, TEMP/TMP, PIP_CACHE_DIR, CARGO_HOME, RUSTUP_HOME, AKOUSMA_WORK_ROOT, SMB_*) and the
# build (Visual Studio dev shell: Path, INCLUDE, LIB, ...) change environment variables. Without a restore, every run in the
# same window prepended to Path again until cmd failed with "The input line is too long".
$StartEnv = [hashtable]::new($(if ($IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }))   # names compare like the OS does
foreach ($e in [Environment]::GetEnvironmentVariables().GetEnumerator()) { $StartEnv[[string]$e.Key] = [string]$e.Value }
try {

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------
# Relative paths in the parameters (e.g. .\local-patches\x.patch) are relative to the folder the script was started from.
# The steps below Set-Location, so make every user-supplied path absolute now.
# ---------------------------------------------------------------------
function Resolve-UserPath([string]$p) {
  # Empty = not passed (the default is derived later); a bare 'E:' stays the drive root; URLs are left alone, and so is a
  # location that starts with a {placeholder} (build settings; filled in when the locations are resolved).
  if ([string]::IsNullOrWhiteSpace($p) -or $p -match '^[A-Za-z]:$' -or $p -match '^[A-Za-z][A-Za-z0-9+.-]+://' -or $p.StartsWith('{')) { return $p }
  return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($p)
}

# ---------------------------------------------------------------------
# Architectures: -Arch x64, x86, arm64, or several (-Arch x64,x86 / -Arch both), built one after the other.
# ---------------------------------------------------------------------
function ConvertTo-ArchList([string[]]$Names) {
  # Upstream's names: x86_64 (x64, amd64), x86, arm64; both = x86_64 + x86. 'a,b' in one argument counts as two (pwsh -File
  # and cmd pass a comma list as one string). Order kept, duplicates dropped.
  $list = [System.Collections.Generic.List[string]]::new()
  foreach ($n in @($Names | ForEach-Object { "$_" -split '[,;\s]+' } | Where-Object { $_ })) {
    $canonical = switch -Regex ($n.Trim().ToLowerInvariant()) {
      '^(x64|x86_64|amd64)$' { 'x86_64' }
      '^(x86|win32|i686)$'   { 'x86' }
      '^arm64$'              { 'arm64' }
      '^both$'               { 'x86_64'; 'x86' }
      default { throw "-Arch: unknown architecture '$n'. Use x64 (= x86_64, amd64), x86, arm64 or both (= x64,x86), e.g. -Arch x64,x86." }
    }
    foreach ($c in @($canonical)) { if (-not $list.Contains($c)) { $list.Add($c) } }
  }
  if ($list.Count -eq 0) { $list.Add('x86_64') }
  return ,$list.ToArray()
}

# ---------------------------------------------------------------------
# Build settings: build-settings.json next to this script (ignored by git). Created with the defaults when it is missing.
# Each setting: the parameter if passed, else the file, else the default. -SaveSettings writes the passed ones into it.
# Only the run started by the user reads or writes it: the per-architecture processes below get the resolved values.
# ---------------------------------------------------------------------
$SettingsPath = Join-Path $PSScriptRoot 'build-settings.json'
# The defaults, as written to a new file. The locations are the derived defaults of "0. Resolve locations" below; a value
# still equal to its default here is left to that derivation, so it follows -WorkRoot and the other locations.
$SettingsDefaults = [ordered]@{
  Arch           = @('x86_64', 'x86', 'arm64')
  BuildType      = 'release'
  AkousmaRepo    = 'https://github.com/Genki-jp0/Akousma.git'
  AkousmaRef     = 'master'
  AkousmaSource  = ''
  Deps           = 'auto'
  WorkRoot       = 'C:\Akousma'
  ProjectRoot    = '{WorkRoot}\data\projects\akousma'
  MsvcRoot       = '{ProjectRoot}\msvc_'
  DownloadsPath  = '{MsvcRoot}\downloads'
  SrcPath        = '{DownloadsPath}'
  BuildPath      = '{MsvcRoot}\build_{Arch}_{BuildType}'
  PrefixPath     = '{WorkRoot}\akousma_msvc_{Arch}_{BuildType}'
  HostPrefixPath = ''
  JomDir         = '{ProjectRoot}\tools\jom'
  TempPath       = '{WorkRoot}\temp'
  PipCachePath   = '{WorkRoot}\cache\pip'
  CargoHome      = '{WorkRoot}\cargo'
  RustupHome     = '{WorkRoot}\rustup'
  LogPath        = '{ProjectRoot}\build.log'
  LogDir         = '{BuildPath}\logs'
  GitBinPath     = ''
}
$SettingsPathKeys = @($SettingsDefaults.Keys | Where-Object { $_ -notin 'Arch', 'BuildType', 'AkousmaRepo', 'AkousmaRef', 'Deps' })
$SettingsApplied = [ordered]@{}   # the values taken from the file, passed on to the per-architecture processes
if (-not $arch_build) {
  $settings = [ordered]@{}
  foreach ($k in $SettingsDefaults.Keys) { $settings[$k] = $SettingsDefaults[$k] }
  $settingsExists = Test-Path -LiteralPath $SettingsPath -PathType Leaf
  if ($settingsExists) {
    $text = Get-Content -Raw -LiteralPath $SettingsPath
    $fromFile = $null
    if (-not [string]::IsNullOrWhiteSpace($text)) {
      try { $fromFile = $text | ConvertFrom-Json -AsHashtable }
      catch { throw "Build settings: $SettingsPath is not valid JSON ($($_.Exception.Message)). Fix it (a backslash is written \\ in JSON, or use /), or delete it to start again from the defaults." }
      if ($fromFile -isnot [System.Collections.IDictionary]) { throw "Build settings: $SettingsPath must hold one JSON object: { `"Arch`": [ ... ], `"BuildPath`": `"...`", ... }." }
    }
    foreach ($k in @(if ($fromFile) { $fromFile.Keys })) {
      $v = $fromFile[$k]
      if (-not $SettingsDefaults.Contains($k)) { Write-Warning "Build settings: unknown setting '$k' in $SettingsPath is ignored."; continue }
      if ($null -eq $v) { continue }   # null = the default
      if ($k -eq 'Arch') {
        if (@($v | Where-Object { $_ -isnot [string] }).Count) { throw "Build settings: Arch in $SettingsPath must be a list of names, e.g. [ `"x86_64`", `"x86`" ]." }
        try { $v = ConvertTo-ArchList @($v) } catch { throw "Build settings: Arch in ${SettingsPath}: $($_.Exception.Message)" }
      }
      elseif ($v -isnot [string]) { throw "Build settings: $k in $SettingsPath must be a string (`"...`")." }
      elseif ($k -eq 'BuildType' -and $v -notin 'debug', 'release') { throw "Build settings: BuildType in $SettingsPath must be `"release`" or `"debug`", not `"$v`"." }
      $settings[$k] = $v
    }
  }
  if ($SaveSettings) {
    # The passed settings, as this run uses them: the architectures by their canonical names, the paths absolute.
    foreach ($k in $SettingsDefaults.Keys) {
      if (-not $PSBoundParameters.ContainsKey($k)) { continue }
      $settings[$k] = if ($k -eq 'Arch') { ConvertTo-ArchList $Arch } elseif ($k -in $SettingsPathKeys) { Resolve-UserPath $PSBoundParameters[$k] } else { [string]$PSBoundParameters[$k] }
    }
  }
  if (-not $settingsExists -or $SaveSettings) {
    $savedKeys = @($SettingsDefaults.Keys | Where-Object { $SaveSettings -and $PSBoundParameters.ContainsKey($_) })
    try {
      [System.IO.File]::WriteAllText($SettingsPath, ($settings | ConvertTo-Json -Depth 4) + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
      $settingsNote = if (-not $SaveSettings) { 'created with the defaults' }
                      elseif ($savedKeys.Count) { "saved -$($savedKeys -join ', -')" } else { 'saved (no settings were passed)' }
    }
    catch {
      if ($SaveSettings) { throw "Build settings: could not write ${SettingsPath}: $($_.Exception.Message)" }
      $settingsNote = "not created ($($_.Exception.Message)); using the defaults"
    }
  }
  else { $settingsNote = 'read' }
  # Apply what is not passed on the command line. A passed -AkousmaRepo / -AkousmaRef means the repository, so a local
  # checkout in the file (AkousmaSource) is not used then. Relative paths in the file are relative to this script's folder.
  $useSettingsSource = -not ($PSBoundParameters.ContainsKey('AkousmaRepo') -or $PSBoundParameters.ContainsKey('AkousmaRef'))
  foreach ($k in $SettingsDefaults.Keys) {
    if ($PSBoundParameters.ContainsKey($k) -or ($k -eq 'AkousmaSource' -and -not $useSettingsSource)) { continue }
    $v = $settings[$k]
    if ((@($v) -join ',') -ceq (@($SettingsDefaults[$k]) -join ',')) { continue }   # the default: derived as before
    if ($k -in $SettingsPathKeys -and $v -and -not $v.StartsWith('{') -and -not [System.IO.Path]::IsPathRooted($v) -and $v -notmatch '^[A-Za-z]:') {
      $v = Join-Path $PSScriptRoot $v
    }
    Set-Variable -Name $k -Value $v
    $SettingsApplied[$k] = $v
  }
  Write-Host "Build settings: $SettingsPath ($settingsNote)" -ForegroundColor Cyan
}
# ---------------------------------------------------------------------
# Dependency versions (-Deps): StrawberryPackageVersions.txt as committed here (pinned), the newest set upstream's CI has
# built (latest), or the lock of an Akousma release (versions\<release>.txt). Resolved once, here, before the architectures
# are started: every architecture (and the x64 build an arm64 cross-compile runs) gets the same versions, even when upstream
# moves while the first one builds. The build part reads the result as its versions file (<BuildPath>\deps-versions.txt).
# ---------------------------------------------------------------------
$MsvcToolsBase = "56af2c1ebeb43d8f7bc11f85c70010fced39f678"   # upstream 2026-11-10 'Fix build directory'
$UpstreamToolsRepo = 'https://github.com/strawberrymusicplayer/strawberry-msvc-build-tools'
# sha256 (LF line endings) of upstream's StrawberryMSVCBuild.ps1 at $MsvcToolsBase. -Deps latest compares upstream's current
# one with it: a difference means upstream changed recipes since, which the latest versions may need.
$UpstreamBaseScriptSha256 = '24d2acde28e3ed2c7f827b7c8a656a74c989d4e723687a504785ccaea78532a1'
$DepsLockDir = Join-Path $PSScriptRoot 'versions'
# Dependencies built from a git clone's default branch (the URLs of GetGitRepoUrls below). -FreezeDeps records their commits
# in the lock, and a build from the lock checks those out. (ffmpeg is not here: its branch follows FFMPEG_VERSION.)
$DepsGitRepos = [ordered]@{
  'yasm'           = 'https://github.com/yasm/yasm'
  'libffi'         = 'https://gitlab.freedesktop.org/gstreamer/meson-ports/libffi'
  'gst-plugins-rs' = 'https://gitlab.freedesktop.org/gstreamer/gst-plugins-rs'
  'qtsparkle'      = 'https://github.com/strawberrymusicplayer/qtsparkle'
  'pe-util'        = 'https://github.com/gsauthof/pe-util'
}
# Patch names whose package is not named like its version (QT_VERSION builds qtbase, ...). Other patches go by their name:
# libopenmpt-cmake.patch -> LIBOPENMPT_VERSION.
$DepsPatchKeys = @{
  'qtbase' = 'QT_VERSION'; 'qttools' = 'QT_VERSION'; 'qtimageformats' = 'QT_VERSION'; 'qtsvg' = 'QT_VERSION'
  'fftw' = 'FFTW_SOURCE_VERSION'; 'fftw3' = 'FFTW_SOURCE_VERSION'; 'ogg' = 'LIBOGG_VERSION'; 'vorbis' = 'LIBVORBIS_VERSION'
  'dlfcn-win32' = 'DLFCN_VERSION'; 'pe-parse' = 'PEPARSE_VERSION'; 'gstreamer' = 'GSTREAMER_VERSION'
  'gst-plugins-base' = 'GSTREAMER_VERSION'; 'gst-plugins-good' = 'GSTREAMER_VERSION'; 'gst-plugins-bad' = 'GSTREAMER_VERSION'
  'gst-plugins-ugly' = 'GSTREAMER_VERSION'; 'gst-libav' = 'GSTREAMER_VERSION'
}

function Get-DepsTextSha256([string]$text) {
  $bytes = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($text.Replace("`r`n", "`n")))
  return ([System.BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
}
function Read-DepsVersions([string]$text) {
  # A versions file: PACKAGE_NAME=version lines (StrawberryPackageVersions.txt), and in a lock "# key: value" lines.
  $r = @{ Versions = [ordered]@{}; Meta = [ordered]@{}; GitRefs = [ordered]@{}; Patches = [ordered]@{} }
  foreach ($raw in ($text -split "`r?`n")) {
    $line = $raw.Trim()
    if ($line -cmatch '^#\s*git-ref:\s*(\S+)\s+([0-9a-f]{40})$') { $r.GitRefs[$Matches[1]] = $Matches[2]; continue }
    if ($line -cmatch '^#\s*patch:\s*(\S+)\s+([0-9a-f]{64})$') { $r.Patches[$Matches[1]] = $Matches[2]; continue }
    if ($line -cmatch '^#\s*([a-z][a-z-]*):\s*(.*)$') { $r.Meta[$Matches[1]] = $Matches[2].Trim(); continue }
    if (-not $line -or $line.StartsWith('#')) { continue }
    if ($line -match '^([^=]+)=(.*)$' -and $Matches[2].Trim()) { $r.Versions[$Matches[1].Trim().ToUpperInvariant()] = $Matches[2].Trim() }
  }
  return $r
}
function Compare-DepsVersion([string]$a, [string]$b) {
  # -1 / 0 / 1 for two dotted versions (each part compared as a number); $null when one is not a version (a git commit).
  if ($a -notmatch '^\d+(\.\d+)*$' -or $b -notmatch '^\d+(\.\d+)*$') { return $null }
  $x = $a.Split('.'); $y = $b.Split('.')
  for ($i = 0; $i -lt [Math]::Max($x.Count, $y.Count); $i++) {
    $p = if ($i -lt $x.Count) { [bigint]::Parse($x[$i]) } else { [bigint]::Zero }
    $q = if ($i -lt $y.Count) { [bigint]::Parse($y[$i]) } else { [bigint]::Zero }
    if ($p -ne $q) { return $(if ($p -lt $q) { -1 } else { 1 }) }
  }
  return 0
}
function Get-DepsPatchKey([string]$name, [string[]]$keys) {
  # The version a patch goes with, by its package name (the longest match): opusfile-cmake.patch -> OPUSFILE_VERSION.
  $base = ([System.IO.Path]::GetFileNameWithoutExtension($name)).ToLowerInvariant() -replace '^\d+[-_.]', ''
  $best = $null; $bestLength = -1
  $candidates = @($DepsPatchKeys.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Name = $_.Key; Key = $_.Value } }) +
                @($keys | Where-Object { $_ -like '*_VERSION' } | ForEach-Object { [pscustomobject]@{ Name = ($_ -replace '_VERSION$', '').ToLowerInvariant().Replace('_', '-'); Key = $_ } })
  foreach ($c in $candidates) {
    if (($base -eq $c.Name -or $base.StartsWith("$($c.Name)-")) -and $c.Name.Length -gt $bestLength) { $best = $c.Key; $bestLength = $c.Name.Length }
  }
  return $best
}
function Get-DepsChecksumKey([string]$name, [string[]]$keys) {
  # The version a checksum goes with: ZLIB_SHA256SUM -> ZLIB_VERSION, QTBASE_SHA256SUM -> QT_VERSION,
  # FFTW_MINGW_X86_64_RELEASE_SHA256SUM -> FFTW_MINGW_VERSION.
  return Get-DepsPatchKey (($name -replace '_SHA256SUM$', '').ToLowerInvariant().Replace('_', '-')) $keys
}
function Get-DepsVersionCount($versions) {
  # The versions in a set, without the checksums (<PACKAGE>_SHA256SUM) that go with them.
  return @($versions.Keys | Where-Object { $_ -notlike '*_SHA256SUM' }).Count
}
function Get-DepsPatchFiles([string[]]$keys) {
  # The build tools' patches\*.patch and the local patches (local-patches\, -GstGoodPatch), with the version each goes with.
  $list = [System.Collections.Generic.List[object]]::new()
  $toolDir = Join-Path $PSScriptRoot 'patches'
  if (Test-Path -LiteralPath $toolDir -PathType Container) {
    foreach ($f in @(Get-ChildItem -LiteralPath $toolDir -File -Filter '*.patch' | Sort-Object Name)) {
      $list.Add([pscustomobject]@{ Name = "patches/$($f.Name)"; Path = $f.FullName; Key = (Get-DepsPatchKey $f.Name $keys); Tool = $true })
    }
  }
  $localDir = Join-Path $PSScriptRoot 'local-patches'
  if (-not $NoAutoPatches -and (Test-Path -LiteralPath $localDir -PathType Container)) {
    $isPatch = { $_.Extension -ieq '.patch' -or $_.Extension -ieq '.diff' }
    $files = @(Get-ChildItem -LiteralPath $localDir -File | Where-Object $isPatch) +
             @(Get-ChildItem -LiteralPath $localDir -Directory | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -File | Where-Object $isPatch })
    foreach ($f in @($files | Sort-Object FullName)) {
      $rel = [System.IO.Path]::GetRelativePath($PSScriptRoot, $f.FullName).Replace('\', '/')
      $owner = if ($f.Directory.FullName.TrimEnd('\', '/') -ne $localDir.TrimEnd('\', '/')) { "$($f.Directory.Name)-x" } else { $f.Name }
      $list.Add([pscustomobject]@{ Name = $rel; Path = $f.FullName; Key = (Get-DepsPatchKey $owner $keys); Tool = $false })
    }
  }
  if ($GstGoodPatch) {
    $p = Resolve-UserPath $GstGoodPatch
    $list.Add([pscustomobject]@{ Name = $p; Path = $p; Key = 'GSTREAMER_VERSION'; Tool = $false })
  }
  return @($list)
}
function Get-DepsFileText([string]$path) {
  return [System.IO.File]::ReadAllText($path)
}
function ConvertTo-DepsLockName([string]$ref) {
  # v1.0.0 / refs/tags/v1.0.0 / 1.0.0 -> 1.0.0
  $n = $ref.Trim() -replace '^refs/tags/', ''
  if ($n -match '^[vV](\d.*)$') { $n = $Matches[1] }
  return $n
}
function Get-DepsLocks {
  if (-not (Test-Path -LiteralPath $DepsLockDir -PathType Container)) { return @() }
  return @(Get-ChildItem -LiteralPath $DepsLockDir -File -Filter '*.txt' | Sort-Object Name | ForEach-Object {
    [pscustomobject]@{ Name = $_.BaseName; Path = $_.FullName; Data = (Read-DepsVersions (Get-DepsFileText $_.FullName)) }
  })
}
function Invoke-DepsGit {
  # git's output lines, or @() when it fails (no network, not a repository, no git): these lookups are optional.
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return @() }
  $prompt = $env:GIT_TERMINAL_PROMPT
  $env:GIT_TERMINAL_PROMPT = '0'   # a repository that needs a login fails instead of waiting for one
  try { $out = & git @args 2>$null; $ok = $LASTEXITCODE -eq 0 }
  finally { $env:GIT_TERMINAL_PROMPT = $prompt }
  $global:LASTEXITCODE = 0
  if (-not $ok) { return @() }
  return @($out | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
}
function Get-DepsRemoteCommit([string]$url, [string]$ref) {
  # The commit of a tag (peeled), branch or other ref name in a remote repository; '' when it isn't there.
  [string[]]$patterns = if ($ref -eq 'HEAD') { 'HEAD' } else { @("refs/tags/$ref^{}", "refs/tags/$ref", "refs/heads/$ref") }
  $lines = @(Invoke-DepsGit ls-remote $url @patterns)
  foreach ($suffix in @("refs/tags/$ref^{}", "refs/tags/$ref", "refs/heads/$ref", 'HEAD')) {
    $hit = $lines | Where-Object { ($_ -split '\s+')[1] -eq $suffix } | Select-Object -First 1
    if ($hit) { return ($hit -split '\s+')[0] }
  }
  return ''
}
function Find-DepsLock($locks) {
  # The release lock for the Akousma source being built: a tag or commit with versions\<tag>.txt, or the commit a lock records.
  if (-not $locks -or @($locks).Count -eq 0) { return $null }
  $byName = { param($n) $locks | Where-Object { $_.Name -ieq (ConvertTo-DepsLockName $n) } | Select-Object -First 1 }
  $byCommit = { param($c) if ($c -match '^[0-9a-f]{7,40}$') { $locks | Where-Object { $_.Data.Meta['akousma-commit'] -and $_.Data.Meta['akousma-commit'].StartsWith($c.ToLowerInvariant()) } | Select-Object -First 1 } }
  if ($AkousmaSource) {
    $src = Resolve-UserPath $AkousmaSource
    foreach ($tag in @(Invoke-DepsGit -C $src tag --points-at HEAD)) { $l = & $byName $tag; if ($l) { return @{ Lock = $l; Why = "the local checkout is at tag $tag" } } }
    $head = @(Invoke-DepsGit -C $src rev-parse HEAD) | Select-Object -First 1
    if ($head) { $l = & $byCommit $head; if ($l) { return @{ Lock = $l; Why = "the local checkout is at $($head.Substring(0, 7)), the commit of release $($l.Name)" } } }
    return $null
  }
  $ref = if ($AkousmaRef) { $AkousmaRef } else { 'master' }
  $l = & $byName $ref
  if ($l) { return @{ Lock = $l; Why = "Akousma @ $ref is release $($l.Name)" } }
  $l = & $byCommit $ref
  if ($l) { return @{ Lock = $l; Why = "Akousma @ $ref is the commit of release $($l.Name)" } }
  # Another tag on a release commit (e.g. 1.0.0-final): only asked when a lock records a commit, so a plain build asks nothing.
  if (@($locks | Where-Object { $_.Data.Meta['akousma-commit'] }).Count -and $ref -notmatch '^[0-9a-f]{7,40}$') {
    $tagLines = @(Invoke-DepsGit ls-remote --tags $AkousmaRepo "refs/tags/$ref" "refs/tags/$ref^{}")
    $peeled = $tagLines | Where-Object { $_ -like "*refs/tags/$ref^{}" } | Select-Object -First 1
    $commit = if ($peeled) { ($peeled -split '\s+')[0] } elseif ($tagLines) { ($tagLines[0] -split '\s+')[0] } else { '' }
    if ($commit) { $l = & $byCommit $commit; if ($l) { return @{ Lock = $l; Why = "tag $ref is $($commit.Substring(0, 7)), the commit of release $($l.Name)" } } }
  }
  return $null
}
function Get-DepsUpstream {
  # Where -Deps latest reads upstream's files: a branch, tag or commit of upstream strawberry-msvc-build-tools (default master,
  # resolved to its commit, so the versions and the patches compared with them are one snapshot), a URL or a folder.
  $u = if ($DepsUpstream) { $DepsUpstream.Trim() } else { 'master' }
  if ($u -match '^https?://') { return @{ Base = $u.TrimEnd('/'); Label = $u; Commit = ''; Folder = $false } }
  $folder = Resolve-UserPath $u
  if (Test-Path -LiteralPath $folder -PathType Container) { return @{ Base = $folder; Label = $folder; Commit = ''; Folder = $true } }
  if ($u.Contains('\') -or $u.StartsWith('.') -or [System.IO.Path]::IsPathRooted($u)) { throw "-DepsUpstream: folder not found: $u" }
  if ($u -notmatch '^[0-9A-Za-z][0-9A-Za-z._/-]*$') { throw "-DepsUpstream '$u': pass a branch, tag or commit of strawberry-msvc-build-tools, a URL or a folder." }
  $commit = if ($u -match '^[0-9a-f]{40}$') { $u } else { Get-DepsRemoteCommit "$UpstreamToolsRepo.git" $u }
  if (-not $commit -and $u -match '^[0-9a-f]{7,39}$') { throw "-DepsUpstream ${u}: pass the full 40-character commit." }
  $at = if ($commit) { $commit } else { $u }   # ls-remote failed: the branch name, as raw.githubusercontent.com takes it
  return @{ Base = "https://raw.githubusercontent.com/strawberrymusicplayer/strawberry-msvc-build-tools/$at"; Folder = $false; Commit = $commit
            Label = "upstream strawberry-msvc-build-tools $u" + $(if ($commit -and $commit -ne $u) { " @ $($commit.Substring(0, 7))" } elseif (-not $commit) { ' (commit not resolved)' }) }
}
function Get-DepsUpstreamFile($upstream, [string]$rel) {
  # The file's text; $null when upstream does not have it (HTTP 404 / no such file). Other failures throw.
  if ($upstream.Folder) {
    $p = Join-Path $upstream.Base $rel
    if (Test-Path -LiteralPath $p -PathType Leaf) { return (Get-DepsFileText $p) } else { return $null }
  }
  try {
    $content = (Invoke-WebRequest -Uri "$($upstream.Base)/$rel" -UseBasicParsing -TimeoutSec 60 -Headers @{ 'User-Agent' = 'Build-Akousma.ps1' }).Content
    if ($content -is [byte[]]) { $content = [System.Text.Encoding]::UTF8.GetString($content) }
    return [string]$content
  }
  catch {
    $response = $_.Exception.Response
    if ($response -and [int]$response.StatusCode -eq 404) { return $null }
    throw
  }
}
function Resolve-DepsVersions {
  $baseFile = if ($VersionsFile) { Resolve-UserPath $VersionsFile } else { Join-Path $PSScriptRoot 'StrawberryPackageVersions.txt' }
  if (-not (Test-Path -LiteralPath $baseFile -PathType Leaf)) { throw "Package versions file not found: $baseFile" }
  $baseName = if ($VersionsFile) { $baseFile } else { 'StrawberryPackageVersions.txt' }
  $base = Read-DepsVersions (Get-DepsFileText $baseFile)
  $keys = @($base.Versions.Keys)
  $patches = @(Get-DepsPatchFiles $keys)
  $requested = if ($Deps) { $Deps.Trim() } else { 'auto' }
  $r = [ordered]@{
    Mode = ''; Label = ''; Why = ''; BaseName = $baseName; Versions = [ordered]@{}; GitRefs = [ordered]@{}; Upstream = ''
    Changes = [System.Collections.Generic.List[object]]::new(); Warnings = [System.Collections.Generic.List[string]]::new()
    Notes = [System.Collections.Generic.List[string]]::new(); Patches = $patches; Lock = $null
  }
  $lockPatches = @{}
  # The versions files a checksum can come from, in this order: upstream's (latest) or the lock, then the pinned one.
  $checksumFrom = [System.Collections.Generic.List[object]]::new()
  foreach ($k in $keys) { $r.Versions[$k] = $base.Versions[$k] }
  $locks = @(Get-DepsLocks)
  $mode = $requested
  if ($mode -ieq 'auto') {
    if ($CiVersionsFile -or $CiVersionsRef) { $mode = 'pinned'; $r.Why = '-CiVersionsRef / -CiVersionsFile set the versions' }
    elseif ($VersionsFile) { $mode = 'pinned'; $r.Why = '-VersionsFile' }
    else {
      $found = Find-DepsLock $locks
      if ($found) { $mode = $found.Lock.Name; $r.Why = $found.Why }
      else {
        $mode = 'latest'
        $what = if ($AkousmaSource) { 'the local checkout' } else { "Akousma @ $(if ($AkousmaRef) { $AkousmaRef } else { 'master' })" }
        $r.Why = "no release lock for $what"
      }
    }
    $r.Why = "auto: $($r.Why)"
  }
  elseif ($mode -ieq 'pinned' -or $mode -ieq 'latest') { $mode = $mode.ToLowerInvariant(); $r.Why = "-Deps $mode" }
  else { $r.Why = "-Deps $mode" }

  if ($mode -eq 'latest') {
    try {
      $upstream = Get-DepsUpstream
      $text = Get-DepsUpstreamFile $upstream 'StrawberryPackageVersions.txt'
      if ($null -eq $text) { throw "$($upstream.Label) has no StrawberryPackageVersions.txt" }
      $up = Read-DepsVersions $text
      if ($up.Versions.Count -eq 0) { throw "no versions in $($upstream.Label)/StrawberryPackageVersions.txt" }
    }
    catch {
      $r.Warnings.Add("-Deps latest: could not read upstream's versions ($($_.Exception.Message)). Using the pinned versions.")
      $mode = 'pinned'
      $r.Why += ', latest not available'
    }
  }
  if ($mode -eq 'latest') {
    $r.Upstream = $upstream.Label
    $r.Mode = 'latest'
    $r.Label = "latest ($($upstream.Label))"
    $checksumFrom.Add($up.Versions)
    $patchCache = @{}
    foreach ($k in $keys) {
      if ($k -like '*_YEAR' -and $base.Versions.Contains(($k -replace '_YEAR$', '_VERSION'))) { continue }   # goes with its _VERSION
      if ($k -like '*_SHA256SUM') { continue }   # goes with its package's version, below
      if (-not $up.Versions.Contains($k) -or $up.Versions[$k] -eq $base.Versions[$k]) { continue }
      $new = $up.Versions[$k]
      if ($new -notmatch '^[0-9A-Za-z][0-9A-Za-z._+-]*$') { $r.Warnings.Add("$k stays $($base.Versions[$k]): upstream's value '$new' is not a version."); continue }
      $order = Compare-DepsVersion $new $base.Versions[$k]
      if ($null -ne $order -and $order -lt 0) { $r.Notes.Add("$k stays $($base.Versions[$k]): upstream has the older $new."); continue }
      # A build tools patch for this package that upstream changed or removed with the update would not fit the new version:
      # keep the pinned version until those patches are merged from upstream.
      $held = @()
      foreach ($p in @($patches | Where-Object { $_.Tool -and $_.Key -eq $k })) {
        $rel = $p.Name
        try {
          if (-not $patchCache.ContainsKey($rel)) { $patchCache[$rel] = Get-DepsUpstreamFile $upstream $rel }
          $upText = $patchCache[$rel]
          if ($null -eq $upText) { $held += "upstream removed $rel" }
          elseif ((Get-DepsTextSha256 $upText) -ne (Get-DepsTextSha256 (Get-DepsFileText $p.Path))) { $held += "upstream changed $rel" }
        }
        catch { $held += "could not compare $rel with upstream's ($($_.Exception.Message))" }
      }
      if ($held.Count) {
        $r.Warnings.Add("$k stays $($base.Versions[$k]) (upstream: $new): $($held -join '; '). Merge upstream's build tools (git merge upstream/master) to build $new.")
        continue
      }
      $r.Versions[$k] = $new
      $yearKey = $k -replace '_VERSION$', '_YEAR'
      if ($yearKey -ne $k -and $base.Versions.Contains($yearKey) -and $up.Versions.Contains($yearKey)) { $r.Versions[$yearKey] = $up.Versions[$yearKey] }
    }
    $extra = @($up.Versions.Keys | Where-Object { -not $base.Versions.Contains($_) })
    if ($extra.Count) { $r.Notes.Add("Upstream has versions this script does not build yet (new packages): $($extra -join ', ').") }
    try {
      $upScript = Get-DepsUpstreamFile $upstream 'StrawberryMSVCBuild.ps1'
      if ($null -ne $upScript -and (Get-DepsTextSha256 $upScript) -ne $UpstreamBaseScriptSha256) {
        $compare = "$UpstreamToolsRepo/compare/$($MsvcToolsBase.Substring(0, 7))...$(if ($upstream.Commit) { $upstream.Commit.Substring(0, 7) } else { 'master' })"
        $r.Warnings.Add("Upstream's StrawberryMSVCBuild.ps1 changed since $($MsvcToolsBase.Substring(0, 7)), the upstream commit these build tools are based on: " +
                        "the latest versions may need recipe changes that are not here yet ($compare). If a package fails, use -Deps pinned.")
      }
    }
    catch { $r.Notes.Add("Could not compare upstream's StrawberryMSVCBuild.ps1 with $($MsvcToolsBase.Substring(0, 7)) ($($_.Exception.Message)).") }
  }
  elseif ($mode -eq 'pinned') {
    $r.Mode = 'pinned'
    $r.Label = "pinned ($baseName)"
    foreach ($g in $base.GitRefs.Keys) { $r.GitRefs[$g] = $base.GitRefs[$g] }   # -VersionsFile <a lock or deps-versions.txt>
  }
  else {
    $name = ConvertTo-DepsLockName $mode
    $lock = $locks | Where-Object { $_.Name -ieq $name } | Select-Object -First 1
    if (-not $lock) {
      $have = if ($locks.Count) { ($locks | ForEach-Object { $_.Name }) -join ', ' } else { 'none yet' }
      throw "-Deps ${mode}: no lock $(Join-Path $DepsLockDir "$name.txt") (locks: $have). Use -Deps auto, latest, pinned or a lock name; -FreezeDeps <release> writes one."
    }
    $r.Mode = 'lock'
    $r.Lock = $lock.Name
    $lockPatches = $lock.Data.Patches
    $checksumFrom.Add($lock.Data.Versions)
    $r.Label = "lock $($lock.Name) (versions\$($lock.Name).txt)"
    foreach ($k in $lock.Data.Versions.Keys) { $r.Versions[$k] = $lock.Data.Versions[$k] }
    $missing = @($keys | Where-Object { $_ -notlike '*_SHA256SUM' -and -not $lock.Data.Versions.Contains($_) })
    if ($missing.Count) { $r.Warnings.Add("versions\$($lock.Name).txt has no $($missing -join ', '): using the pinned versions for those (added to the build tools after the lock was frozen).") }
    foreach ($g in $lock.Data.GitRefs.Keys) { $r.GitRefs[$g] = $lock.Data.GitRefs[$g] }
    $frozenWith = $lock.Data.Meta['build-tools-commit']
    if ($frozenWith -and $frozenWith -match '^[0-9a-f]{40}$') {
      $headNow = @(Invoke-DepsGit -C $PSScriptRoot rev-parse HEAD) | Select-Object -First 1
      if ($headNow -and $headNow -ne $frozenWith) {
        $changedPatches = @(foreach ($p in $patches) {
          $was = $lock.Data.Patches[$p.Name]
          if (-not $was) { "$($p.Name) (new)" } elseif ($was -ne (Get-DepsTextSha256 (Get-DepsFileText $p.Path))) { "$($p.Name) (changed)" }
        }) + @($lock.Data.Patches.Keys | Where-Object { $_ -notin @($patches | ForEach-Object { $_.Name }) } | ForEach-Object { "$_ (removed)" })
        $note = "The lock was frozen with build tools $($frozenWith.Substring(0, 7)); these are $($headNow.Substring(0, 7))."
        if ($lock.Data.Patches.Count -and $changedPatches.Count) {
          $r.Warnings.Add("$note Patches changed since: $($changedPatches -join ', '). For the release's exact build: git -C `"$PSScriptRoot`" checkout $($frozenWith.Substring(0, 7)) (or a worktree of it) and build from there.")
        }
        else { $r.Notes.Add("$note For the release's exact build tools: git checkout $($frozenWith.Substring(0, 7)).") }
      }
    }
  }

  foreach ($k in $VersionOverrides.Keys) {
    $key = ([string]$k).ToUpperInvariant()
    if (-not $key.EndsWith('_VERSION')) { $key = "${key}_VERSION" }
    $r.Versions[$key] = [string]$VersionOverrides[$k]
  }
  # Checksums (<PACKAGE>_SHA256SUM, in the versions files since upstream 56af2c1): a checksum is for one version's archive,
  # so each one comes from a versions file that has the version used here. A version no file has a checksum for (an
  # override, a lock from before the checksums, a package upstream doesn't have) gets none: its download is not verified,
  # as before.
  $checksumFrom.Add($base.Versions)
  $unverified = @()
  foreach ($k in @($r.Versions.Keys | Where-Object { $_ -like '*_SHA256SUM' })) {
    $versionKey = Get-DepsChecksumKey $k @($r.Versions.Keys)
    if (-not $versionKey) { continue }
    $checksum = $null
    foreach ($from in $checksumFrom) {
      if ($from.Contains($k) -and $from.Contains($versionKey) -and $from[$versionKey] -eq $r.Versions[$versionKey]) { $checksum = $from[$k]; break }
    }
    if ($checksum) { $r.Versions[$k] = $checksum } else { $r.Versions.Remove($k); $unverified += $k }
  }
  if ($unverified.Count) { $r.Notes.Add("No checksum for the version used (the download is not verified): $($unverified -join ', ').") }
  foreach ($k in $r.Versions.Keys) {
    if ($k -like '*_SHA256SUM') { continue }
    $old = if ($base.Versions.Contains($k)) { $base.Versions[$k] } else { '(none)' }
    if ($old -ne $r.Versions[$k]) { $r.Changes.Add([pscustomobject]@{ Key = $k; Old = $old; New = $r.Versions[$k] }) }
  }
  # Patches of a package whose version changes were written for the pinned version (as were the local ones, presumably).
  foreach ($c in $r.Changes) {
    foreach ($p in @($patches | Where-Object { $_.Key -eq $c.Key })) {
      if ($p.Tool -and $r.Mode -eq 'latest') { continue }   # compared with upstream's above: upstream builds $c.New with it
      if ($lockPatches[$p.Name] -eq (Get-DepsTextSha256 (Get-DepsFileText $p.Path))) { continue }   # the same patch as when the lock was frozen
      $r.Warnings.Add("$($p.Name) is applied to $($c.Key -replace '_VERSION$', '') $($c.New) but was written for $($c.Old): if it no longer applies, update it (or build -Deps pinned).")
    }
  }
  return $r
}
function Write-DepsSummary($r) {
  Write-Host "Dependency versions: $($r.Label)  [$($r.Why)]" -ForegroundColor Cyan
  if ($r.Changes.Count) {
    Write-Host "  $($r.Changes.Count) of $(Get-DepsVersionCount $r.Versions) differ from the pinned ones ($($r.BaseName)):" -ForegroundColor Cyan
    foreach ($c in $r.Changes) { Write-Host ("    {0,-28} {1} -> {2}" -f $c.Key, $c.Old, $c.New) -ForegroundColor Cyan }
  }
  else { Write-Host "  all $(Get-DepsVersionCount $r.Versions) are the pinned ones ($($r.BaseName))" -ForegroundColor Cyan }
  foreach ($g in $r.GitRefs.Keys) { Write-Host ("    {0,-28} git {1}" -f $g, $r.GitRefs[$g]) -ForegroundColor Cyan }
  foreach ($n in $r.Notes) { Write-Host "  $n" -ForegroundColor DarkCyan }
  foreach ($w in $r.Warnings) { Write-Warning $w }
}
function Format-DepsFile([string[]]$header, [string[]]$versionLines, $gitRefs) {
  # A versions file the build part reads (PACKAGE_NAME=version, as StrawberryPackageVersions.txt); "# key: value" lines too.
  $lines = [System.Collections.Generic.List[string]]::new()
  foreach ($h in $header) { $lines.Add("# $h") }
  foreach ($g in @($gitRefs.Keys | Sort-Object)) { $lines.Add("# git-ref: $g $($gitRefs[$g])") }
  $lines.Add('')
  foreach ($l in $versionLines) { $lines.Add($l) }
  return (($lines -join "`n") + "`n")
}
function Get-DepsLines($versions) { return [string[]]@($versions.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) }
function Save-DepsLock($r, [string]$release) {
  $name = ConvertTo-DepsLockName $release
  if ($name -notmatch '^[0-9A-Za-z][0-9A-Za-z._+-]*$') { throw "-FreezeDeps '$release': use the Akousma release, e.g. -FreezeDeps 1.0.0." }
  if ($CiVersionsFile -or $CiVersionsRef) { throw "-FreezeDeps can't be combined with -CiVersionsRef / -CiVersionsFile: their versions are read later, by the build, and would not be in the lock." }
  $path = Join-Path $DepsLockDir "$name.txt"
  # The git-sourced dependencies: their current commits, which this build uses too, so the lock holds what is built now.
  foreach ($repo in $DepsGitRepos.Keys) {
    if ($GitRefs.ContainsKey($repo)) { if ($GitRefs[$repo] -match '^[0-9a-f]{40}$') { $r.GitRefs[$repo] = $GitRefs[$repo] }; continue }
    if ($r.GitRefs.Contains($repo)) { continue }
    $sha = Get-DepsRemoteCommit $DepsGitRepos[$repo] 'HEAD'
    if ($sha) { $r.GitRefs[$repo] = $sha } else { Write-Warning "-FreezeDeps: could not get the commit of $repo ($($DepsGitRepos[$repo])); the lock does not pin it." }
  }
  $akousmaCommit = if ($AkousmaSource) { @(Invoke-DepsGit -C (Resolve-UserPath $AkousmaSource) rev-parse HEAD) | Select-Object -First 1 }
                   elseif ($AkousmaRef -match '^[0-9a-f]{40}$') { $AkousmaRef }
                   else { Get-DepsRemoteCommit $AkousmaRepo $(if ($AkousmaRef) { $AkousmaRef } else { 'master' }) }
  $toolsCommit = @(Invoke-DepsGit -C $PSScriptRoot rev-parse HEAD) | Select-Object -First 1
  $header = @(
    "Dependency versions of Akousma $name, written by Build-Akousma.ps1 -FreezeDeps $name. Commit this file.",
    "Used when Akousma $name is built (tag $name or v$name, or the commit below), or with -Deps $name.",
    "Format: PACKAGE_NAME=version, like StrawberryPackageVersions.txt; the '# name: value' lines are read too.",
    "frozen: $([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))",
    "akousma-ref: $(if ($AkousmaSource) { "local checkout $(Resolve-UserPath $AkousmaSource)" } else { "$AkousmaRepo @ $(if ($AkousmaRef) { $AkousmaRef } else { 'master' })" })"
  )
  if ($akousmaCommit) { $header += "akousma-commit: $akousmaCommit" } else { Write-Warning "-FreezeDeps: could not get the Akousma commit; the lock is found by its name ($name / v$name) only." }
  if ($toolsCommit) { $header += "build-tools-commit: $toolsCommit" }
  $header += "resolved-from: $($r.Label)"
  foreach ($p in $r.Patches) { if ($p.Name -notmatch '^[\\/]|^[A-Za-z]:') { $header += "patch: $($p.Name) $(Get-DepsTextSha256 (Get-DepsFileText $p.Path))" } }
  $text = Format-DepsFile $header (Get-DepsLines $r.Versions) $r.GitRefs
  if (Test-Path -LiteralPath $path -PathType Leaf) {
    $old = Read-DepsVersions (Get-DepsFileText $path)
    $refLines = { param($refs) (@($refs.Keys | Sort-Object | ForEach-Object { "$_=$($refs[$_])" }) -join "`n") }
    $same = ((Get-DepsLines $old.Versions) -join "`n") -eq ((Get-DepsLines $r.Versions) -join "`n") -and (& $refLines $old.GitRefs) -eq (& $refLines $r.GitRefs)
    if ($same) { Write-Host "-FreezeDeps ${name}: $path already holds these versions; not written." -ForegroundColor Cyan; return }
    throw "-FreezeDeps ${name}: $path exists with other versions. A release's lock is not replaced: delete it first to freeze $name again."
  }
  New-Item -ItemType Directory -Force -Path $DepsLockDir | Out-Null
  [System.IO.File]::WriteAllText($path, $text, [System.Text.UTF8Encoding]::new($false))
  Write-Host "-FreezeDeps ${name}: wrote $path ($(Get-DepsVersionCount $r.Versions) versions, $($r.GitRefs.Count) git commits). Commit it; builds of Akousma $name use it from now on." -ForegroundColor Green
}
if ($deps_resolved.Count) {
  # An architecture of a multi-architecture run: the run that started it resolved the versions.
  $DepsResolved = $deps_resolved
  Write-Host "Dependency versions: $($DepsResolved.Label) (as resolved for all architectures)" -ForegroundColor Cyan
}
else {
  $resolved = Resolve-DepsVersions
  if ($FreezeDeps) { Save-DepsLock $resolved $FreezeDeps }
  Write-DepsSummary $resolved
  $depsGitRefs = @{}
  foreach ($g in $resolved.GitRefs.Keys) { $depsGitRefs[$g] = $resolved.GitRefs[$g] }
  $DepsResolved = @{ Label = $resolved.Label; Mode = $resolved.Mode; Why = $resolved.Why; GitRefs = $depsGitRefs; Lines = (Get-DepsLines $resolved.Versions) }
}

$ArchList = ConvertTo-ArchList $Arch
if ($ArchList.Count -gt 1) {
  # Several architectures: one fresh pwsh per architecture, one after the other. Each starts from this window's environment,
  # so the Visual Studio environment (Path, INCLUDE, LIB, ...) of one architecture never reaches the next, and each builds in
  # its own folders (they follow from -Arch, see -BuildPath). All other parameters are passed on as they are, relative paths
  # made absolute first. A failed architecture does not stop the next one.
  $pwsh = (Get-Process -Id $PID).Path
  $pathParams = @('GstGoodPatch', 'AkousmaSource', 'VersionsFile', 'CiVersionsFile', 'WorkRoot', 'ProjectRoot', 'MsvcRoot',
                  'DownloadsPath', 'SrcPath', 'BuildPath', 'PrefixPath', 'JomDir', 'TempPath', 'PipCachePath', 'CargoHome',
                  'RustupHome', 'LogPath', 'LogDir', 'OldCargoHome', 'OldRustupHome', 'OldDownloads', 'OldBuildPath',
                  'OldPrefixPath', 'GitBinPath', 'HostPrefixPath')
  $forward = [ordered]@{}
  foreach ($k in @($PSBoundParameters.Keys)) {
    if ($k -in 'Arch', 'SaveSettings', 'Deps', 'FreezeDeps', 'DepsUpstream') { continue }   # the versions are resolved above
    $v = $PSBoundParameters[$k]
    if ($v -is [System.Management.Automation.SwitchParameter]) { $v = $v.IsPresent }
    elseif ($k -in $pathParams) { $v = Resolve-UserPath $v }
    $forward[$k] = $v
  }
  # The values from build-settings.json too: each architecture's process uses them as passed and never opens the file.
  foreach ($k in $SettingsApplied.Keys) { if ($k -notin 'Arch', 'Deps') { $forward[$k] = $SettingsApplied[$k] } }
  $forward['arch_build'] = $true
  $forward['deps_resolved'] = $DepsResolved
  $scriptLiteral = $PSCommandPath.Replace("'", "''")
  $results = [ordered]@{}
  $clock = [Diagnostics.Stopwatch]::StartNew()
  Write-Host "Architectures: $($ArchList -join ', ') (one after the other, each in its own folders and pwsh process)" -ForegroundColor Cyan
  for ($i = 0; $i -lt $ArchList.Count; $i++) {
    $a = $ArchList[$i]
    Write-Host "`n==> [$($i + 1)/$($ArchList.Count)] $a" -ForegroundColor Magenta
    $forward['Arch'] = $a
    # The parameters travel as JSON (hashtables such as -VersionOverrides can't be passed on a command line), in an environment
    # variable the new process reads and removes before it starts the script. Not inside the encoded command any more: with the
    # checksums (upstream 56af2c1) the resolved versions are 7 KB of JSON, which made that command 27000 characters or more,
    # and Windows starts no process with a command line over 32767.
    $env:AKOUSMA_ARCH_PARAMS_JSON = ($forward | ConvertTo-Json -Compress -Depth 8)
    $command = "`$p = `$env:AKOUSMA_ARCH_PARAMS_JSON | ConvertFrom-Json -AsHashtable; Remove-Item Env:AKOUSMA_ARCH_PARAMS_JSON; " +
               "`$global:LASTEXITCODE = 0; try { & '$scriptLiteral' @p; exit `$LASTEXITCODE } " +
               "catch { Write-Host `"Error: `$_`" -ForegroundColor Red; exit 1 }"
    $started = $clock.Elapsed
    & $pwsh -NoProfile -ExecutionPolicy Bypass -OutputFormat Text -EncodedCommand ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command)))
    $results[$a] = @{ Code = $LASTEXITCODE; Time = $clock.Elapsed - $started }
  }
  Remove-Item Env:AKOUSMA_ARCH_PARAMS_JSON -ErrorAction SilentlyContinue
  Write-Host "`n==> Architectures" -ForegroundColor Magenta
  foreach ($a in $results.Keys) {
    $r = $results[$a]
    Write-Host ("  {0,-7} {1,-22} {2:hh\:mm\:ss}" -f $a, $(if ($r.Code -eq 0) { 'ok' } else { "FAILED (exit $($r.Code))" }), $r.Time) -ForegroundColor $(if ($r.Code -eq 0) { 'Green' } else { 'Red' })
  }
  exit $(if (@($results.Values | Where-Object { $_.Code -ne 0 }).Count -gt 0) { 1 } else { 0 })
}
# One architecture from here on (a plain string, not the [string[]] parameter).
$archName = $ArchList[0]
Remove-Variable -Name Arch -Scope Script -Force
$Arch = $archName

if ($GstGoodPatch) {
  $full = Resolve-UserPath $GstGoodPatch
  if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "-GstGoodPatch file not found: $GstGoodPatch (looked for $full)" }
  $GstGoodPatch = $full
}

# ---------------------------------------------------------------------
# Akousma source: a git repository (-AkousmaRepo at -AkousmaRef, cloned to <SrcPath>\akousma) or a local checkout.
# ---------------------------------------------------------------------
if ($AkousmaSource) {
  $AkousmaSource = Resolve-UserPath $AkousmaSource
  if (-not (Test-Path -LiteralPath (Join-Path $AkousmaSource 'CMakeLists.txt') -PathType Leaf) -or
      -not (Test-Path -LiteralPath (Join-Path $AkousmaSource 'dist/windows/akousma.nsi.in') -PathType Leaf)) {
    throw "-AkousmaSource '$AkousmaSource' is not an Akousma source tree (no CMakeLists.txt and dist\windows\akousma.nsi.in in it)."
  }
}
elseif ([string]::IsNullOrWhiteSpace($AkousmaRepo)) {
  throw "Pass -AkousmaRepo (a git URL) or -AkousmaSource (a local checkout)."
}
if (-not $AkousmaSource -and [string]::IsNullOrWhiteSpace($AkousmaRef)) { $AkousmaRef = "master" }

# ---------------------------------------------------------------------
# Local patches per dependency: -GstGoodPatch, else the local-patches folder next to this script.
# ---------------------------------------------------------------------
# Every package this script builds, for routing local-patches\<package>-*.patch.
$KnownPackages = @(
  'pkgconf', 'yasm', 'proxy-libintl', 'getopt-win', 'zlib', 'openssl', 'libpng', 'libjpeg-turbo', 'pcre2', 'bzip2', 'xz', 'brotli',
  'uchardet', 'icu4c', 'pixman', 'expat', 'boost', 'libxml2', 'nghttp2', 'libffi', 'dlfcn-win32', 'libpsl', 'orc', 'sqlite', 'glib',
  'libsoup', 'glib-networking', 'freetype', 'harfbuzz', 'jasper', 'tiff', 'libwebp', 'ogg', 'vorbis', 'flac', 'wavpack', 'opus',
  'opusfile', 'speex', 'mpg123', 'lame', 'fftw3', 'musepack', 'libopenmpt', 'libgme', 'fdk-aac', 'faad2', 'faac', 'utfcpp', 'taglib',
  'libbs2b', 'libebur128', 'libcdio', 'ffmpeg', 'chromaprint', 'gstreamer', 'gst-plugins-base', 'gst-plugins-good', 'gst-plugins-bad',
  'gst-plugins-ugly', 'gst-libav', 'gst-plugins-rs', 'qtbase', 'qttools', 'qtimageformats', 'qtsvg', 'kdsingleapplication',
  'qtsparkle', 'sparsehash', 'googletest', 'pe-parse', 'pe-util'
)
function Get-NaturalSortKey([string]$s) {
  return [regex]::Replace($s.ToLowerInvariant(), '\d+', { param($m) $m.Value.PadLeft(12, '0') })
}
function Get-PatchTarget([string]$Path, [string]$PatchDir, [string[]]$Packages) {
  # local-patches\<package>\x.patch -> <package>; local-patches\x.patch -> the package its name starts with.
  # Anything else stops the run: there is no default package any more.
  $dir = Split-Path -Parent $Path
  if (-not ([System.IO.Path]::GetFullPath($dir).TrimEnd('\', '/') -ieq [System.IO.Path]::GetFullPath($PatchDir).TrimEnd('\', '/'))) {
    $leafDir = Split-Path -Leaf $dir
    $match = $Packages | Where-Object { $_ -ieq $leafDir } | Select-Object -First 1
    if (-not $match) {
      throw "${Path}: the folder '$leafDir' is not a dependency name, so this patch can't be routed. Move it to local-patches\<package>\ or name it <package>-*.patch."
    }
    return $match
  }
  $base = [System.IO.Path]::GetFileNameWithoutExtension($Path) -replace '^\d+[-_.]', ''
  if ($base -match '^(?i)(strawberry|akousma)([-_.]|$)') {
    throw "${Path}: patches for Strawberry / Akousma are not applied any more. Akousma's changes are commits in the Akousma repository (-AkousmaRepo / -AkousmaSource); commit the change there and remove this file."
  }
  if ($base -match '^(?i)gstreamer-') { return 'gst-plugins-good' }   # e.g. gstreamer-flacparse-invalid-frame.patch; core: local-patches\gstreamer\
  $match = $Packages | Where-Object { $base -ieq $_ -or $base.StartsWith("$_-", [StringComparison]::OrdinalIgnoreCase) } |
           Sort-Object Length -Descending | Select-Object -First 1
  if ($match) { return $match }
  throw "${Path}: the name doesn't start with a dependency name (qtbase-*.patch, gstreamer-*.patch, glib-networking-*.patch, ...), so it can't be routed. Rename it or move it to local-patches\<package>\."
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
    throw "$Path is not a patch (no '+++ ' file header and no GIT binary patch in it). Fix or remove it; every *.patch / *.diff in local-patches is applied."
  }
}
function Get-PackagePatches {
  # Returns @{ Patches = [ordered]@{ package = full paths in order }; Sources = [ordered]@{ package = where they came from };
  #            Found = @( @{ Name; Path; Target; Status } for every file in the patches folder ) }.
  param([string]$PatchDir, [string]$GstGoodPatch = "", [switch]$NoAutoPatches, [string[]]$Packages)
  $patches = [ordered]@{}
  $sources = [ordered]@{}
  $report = [System.Collections.Generic.List[object]]::new()
  if ($GstGoodPatch) { $patches['gst-plugins-good'] = @($GstGoodPatch); $sources['gst-plugins-good'] = '-GstGoodPatch' }
  if (-not $NoAutoPatches -and (Test-Path -LiteralPath $PatchDir -PathType Container)) {
    $found = [ordered]@{}
    foreach ($f in @(Get-PatchFiles $PatchDir)) {
      $rel = [System.IO.Path]::GetRelativePath($PatchDir, $f.FullName)
      $target = Get-PatchTarget -Path $f.FullName -PatchDir $PatchDir -Packages $Packages
      Assert-PatchFile $f.FullName
      $status = 'apply'
      if ($sources.Contains($target)) { $status = "skip ($($sources[$target]) was passed, so local-patches is not used for $target)" }
      $report.Add(@{ Name = $rel; Path = $f.FullName; Target = $target; Status = $status })
      if ($status -ne 'apply') { continue }
      if (-not $found.Contains($target)) { $found[$target] = [System.Collections.Generic.List[object]]::new() }
      $found[$target].Add($f)
    }
    foreach ($t in $found.Keys) {
      $patches[$t] = @($found[$t] | Sort-Object { Get-NaturalSortKey $_.Name }, { $_.FullName } | ForEach-Object { $_.FullName })
      $sources[$t] = 'local-patches'
    }
  }
  return @{ Patches = $patches; Sources = $sources; Found = @($report) }
}
$PatchDir = Join-Path $PSScriptRoot 'local-patches'
$patchPlan = Get-PackagePatches -PatchDir $PatchDir -GstGoodPatch $GstGoodPatch -NoAutoPatches:$NoAutoPatches -Packages $KnownPackages
$PackagePatches = $patchPlan.Patches
# Every patch file in the folder, so a missing (or misrouted) patch is obvious: printed here and again at the top of the log.
function Write-PatchSummary {
  if ($NoAutoPatches) { Write-Host "Local patches folder: not used (-NoAutoPatches)" -ForegroundColor Cyan }
  elseif (-not (Test-Path -LiteralPath $PatchDir -PathType Container)) { Write-Host "Local patches folder: none ($PatchDir does not exist)" -ForegroundColor Cyan }
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
function Write-SourceSummary {
  if ($AkousmaSource) { Write-Host "Akousma source: local checkout $AkousmaSource (built as it is, out of tree)" -ForegroundColor Cyan }
  else { Write-Host "Akousma source: $AkousmaRepo @ $AkousmaRef" -ForegroundColor Cyan }
  Write-Host "QtSparkle update check: $(if ($EnableQtSparkle) { 'on (-EnableQtSparkle)' } else { 'off' })" -ForegroundColor Cyan
  Write-Host "Git commit in the version: $(if ($IncludeGitCommit) { 'yes (-IncludeGitCommit)' } else { 'no (release version only)' })" -ForegroundColor Cyan
  $link = if ($BuildType -eq 'debug') { 'incremental (Debug)' } elseif ($IncrementalLink) { 'incremental (-IncrementalLink; for development, not for shipping)' } else { 'full (/INCREMENTAL:NO; -IncrementalLink for development)' }
  Write-Host "Akousma: $(if ($Clean) { 'clean rebuild (-Clean)' } else { 'incremental build' }); linking: $link" -ForegroundColor Cyan
}
Write-SourceSummary
Write-PatchSummary
# The other file/folder parameters are only made absolute here; they are checked (or created) where they are used.
foreach ($name in 'VersionsFile', 'CiVersionsFile', 'WorkRoot', 'ProjectRoot', 'MsvcRoot', 'DownloadsPath', 'SrcPath',
                  'BuildPath', 'PrefixPath', 'JomDir', 'TempPath', 'PipCachePath', 'CargoHome', 'RustupHome', 'LogPath', 'LogDir',
                  'OldCargoHome', 'OldRustupHome', 'OldDownloads', 'OldBuildPath', 'OldPrefixPath', 'GitBinPath',
                  'HostPrefixPath') {
  Set-Variable -Name $name -Value (Resolve-UserPath (Get-Variable -Name $name -ValueOnly))
}

# ---------------------------------------------------------------------
# The build tools are the folder this script is in: upstream strawberry-msvc-build-tools @ $MsvcToolsBase (see "Dependency
# versions" above) with the Akousma changes.
# GlibNetworkingRef: the glib-networking commit for a versions file that doesn't pin one (see below).
# ---------------------------------------------------------------------
$GlibNetworkingRef = "2616c9ea3392c908a4f46826c319f8fddc2ee2a1"   # "openssl: consult errno on syscall failure"; patch from a824b0f (2026-09-25)
$MsvcToolsRef = $MsvcToolsBase.Substring(0, 7)
$GitRefs = $GitRefs.Clone()   # pins are added below; don't change the caller's hashtable

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Magenta }
function Copy-Tree($src, $dst) {
  robocopy $src $dst /E /NFL /NDL /NJH /NJS | Out-Null   # exit codes 0-7 = success
  if ($LASTEXITCODE -ge 8) { throw "robocopy $src -> $dst failed ($LASTEXITCODE)" }
  $global:LASTEXITCODE = 0
}

# ---------------------------------------------------------------------
# 0. Resolve locations (no drive letter or install folder is fixed in this script)
# ---------------------------------------------------------------------
# Work root: -WorkRoot if passed, else C:\Akousma -- a fixed default, wherever this script is started from (created with
# the folders under it in "1. Redirect temp and caches"). Every location below that you did not pass as a parameter hangs
# off it.
function Normalize-Path([string]$p) {
  $p = $p.Replace('/', '\')
  if ($p -notmatch '^[A-Za-z]:\\$') { $p = $p.TrimEnd('\') }
  return $p
}
function Expand-LocationTokens([string]$p) {
  # {Arch}, {BuildType}, {WorkRoot}, {ProjectRoot}, {MsvcRoot}, {DownloadsPath}, {BuildPath} (build settings) -> their
  # values. The locations are resolved in that order, so each one can only use the ones before it.
  $out = $p
  foreach ($m in [regex]::Matches($p, '\{(\w+)\}')) {
    $name = $m.Groups[1].Value
    if ($name -notin 'Arch', 'BuildType', 'WorkRoot', 'ProjectRoot', 'MsvcRoot', 'DownloadsPath', 'BuildPath') {
      throw "'$p': unknown placeholder {$name}. Use {WorkRoot}, {ProjectRoot}, {MsvcRoot}, {DownloadsPath}, {BuildPath}, {Arch} or {BuildType}."
    }
    $value = [string](Get-Variable -Name $name -ValueOnly)
    if (-not $value -or $value.Contains('{')) {
      throw "'$p': {$name} is not resolved yet here; a location can only use the ones before it (WorkRoot, ProjectRoot, MsvcRoot, DownloadsPath, BuildPath)."
    }
    $out = $out.Replace($m.Value, $value)
  }
  return $out
}
function Resolve-Default([string]$Value, [string]$Default) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return (Normalize-Path $Default) }
  return (Normalize-Path (Expand-LocationTokens $Value))
}
function Test-SamePath($a, $b) {
  if (-not (Test-Path -LiteralPath $a) -or -not (Test-Path -LiteralPath $b)) { return $false }
  return ((Resolve-Path -LiteralPath $a).Path.TrimEnd('\') -ieq (Resolve-Path -LiteralPath $b).Path.TrimEnd('\'))
}

$workRootIsDefault = -not $WorkRoot
$WorkRoot = if ($WorkRoot) { $WorkRoot } else { 'C:\Akousma' }
if ($WorkRoot.StartsWith('\\')) { $WorkRoot = "$env:SystemDrive\Akousma" }   # UNC: the default folder, on the system drive
$WorkRoot = (Normalize-Path $WorkRoot).TrimEnd('\')

# The default folders are named akousma (data\projects\akousma, akousma_msvc_<arch>_<type>). Upstream's strawberry names
# are only kept where they name upstream's things (the -Old* migration sources below, release assets, repositories).
# One set of folders per architecture: the build tree, the prefix and the logs. Downloads, git clones (SrcPath), jom, temp
# and the caches are shared. The defaults carry the architecture (build_<arch>_<type>, akousma_msvc_<arch>_<type>); an
# explicit -BuildPath / -PrefixPath / -LogDir / -LogPath, and the default build.log, is used as it is for x86_64 (as before)
# and gets _<arch> appended for the other architectures, unless its name already says the architecture. So an x64 command
# line plus -Arch x86 builds next to the x64 folders, never into them.
function Add-ArchSuffix([string]$Path, [switch]$File) {
  if ([string]::IsNullOrWhiteSpace($Path) -or $Arch -eq 'x86_64' -or $Path.Contains('{Arch}')) { return $Path }
  $trimmed = if ($Path -match '^[A-Za-z]:[\\/]?$') { $Path } else { $Path.TrimEnd('\', '/') }
  $leaf = Split-Path -Leaf $trimmed
  $token = "(?i)(^|[^a-z0-9])$([regex]::Escape($Arch))$(if ($Arch -eq 'x86') { '(?!_64)' })([^a-z0-9]|$)"
  if ($leaf -match $token) { return $Path }
  if ($File) {
    $ext = [System.IO.Path]::GetExtension($trimmed)
    return $trimmed.Substring(0, $trimmed.Length - $ext.Length) + "_$Arch" + $ext
  }
  return "${trimmed}_$Arch"
}
$prefixIsDefault = [string]::IsNullOrWhiteSpace($PrefixPath)
$prefixArg = $PrefixPath   # -PrefixPath as passed (x64 uses it as it is), for -HostPrefixPath's default
$BuildPath  = Add-ArchSuffix $BuildPath
$PrefixPath = Add-ArchSuffix $PrefixPath
$LogDir     = Add-ArchSuffix $LogDir

$ProjectRoot   = Resolve-Default $ProjectRoot   "$WorkRoot\data\projects\akousma"
$MsvcRoot      = Resolve-Default $MsvcRoot      "$ProjectRoot\msvc_"
$DownloadsPath = Resolve-Default $DownloadsPath "$MsvcRoot\downloads"
$SrcPath       = Resolve-Default $SrcPath       "$DownloadsPath"
$BuildPath     = Resolve-Default $BuildPath     "$MsvcRoot\build_${Arch}_${BuildType}"
$PrefixPath    = Resolve-Default $PrefixPath    "$WorkRoot\akousma_msvc_${Arch}_${BuildType}"
$JomDir        = Resolve-Default $JomDir        "$ProjectRoot\tools\jom"
$TempPath      = Resolve-Default $TempPath      "$WorkRoot\temp"
$PipCachePath  = Resolve-Default $PipCachePath  "$WorkRoot\cache\pip"
$CargoHome     = Resolve-Default $CargoHome     "$WorkRoot\cargo"
$RustupHome    = Resolve-Default $RustupHome    "$WorkRoot\rustup"
$LogPath       = Normalize-Path (Add-ArchSuffix -File (Resolve-Default $LogPath "$ProjectRoot\build.log"))
$LogDir        = Resolve-Default $LogDir        "$BuildPath\logs"

# Old locations (migration sources / clean-up targets). They are skipped when they do not exist or
# are the same folder as the new location. The C: style defaults are where upstream's script puts things.
$OldCargoHome  = Resolve-Default $OldCargoHome  "$env:USERPROFILE\.cargo"
$OldRustupHome = Resolve-Default $OldRustupHome "$env:USERPROFILE\.rustup"
$OldDownloads  = Resolve-Default $OldDownloads  "$env:SystemDrive\data\projects\strawberry\msvc_\downloads"
$OldBuildPath  = Resolve-Default $OldBuildPath  "$env:SystemDrive\data\projects\strawberry\msvc_\build_${Arch}_${BuildType}"
$OldPrefixPath = Resolve-Default $OldPrefixPath "$env:SystemDrive\strawberry_msvc_${Arch}_${BuildType}"

# The default prefix used to be <WorkRoot>\strawberry_msvc_<arch>_<type>, and the default work root C:\ (until 2026-11, so
# C:\akousma_msvc_<arch>_<type>). Say so when an old one is still there and the new one is not, so a full dependency
# rebuild doesn't come as a surprise.
$oldDefaultPrefixes = @("$WorkRoot\strawberry_msvc_${Arch}_${BuildType}") +
  @(if ($workRootIsDefault) { "C:\akousma_msvc_${Arch}_${BuildType}", "C:\strawberry_msvc_${Arch}_${BuildType}" })
$oldDefaultPrefix = @($oldDefaultPrefixes | ForEach-Object { Normalize-Path $_ } | Where-Object { Test-Path -LiteralPath $_ }) | Select-Object -First 1
$prefixRenameNote = if ($prefixIsDefault -and $oldDefaultPrefix -and -not (Test-Path -LiteralPath (Join-Path $PrefixPath 'bin'))) {
  "The default dependency prefix is $PrefixPath now (it was $oldDefaultPrefix). Every dependency is built again there, which takes hours. $oldDefaultPrefix is not used any more; delete it once the new build works." +
  $(if ((Split-Path -Leaf $oldDefaultPrefix) -like 'akousma_msvc_*') { " To keep building in the C:\ folders instead, run once with -WorkRoot C:\ -SaveSettings." })
}

# arm64 on an x64 PC: a cross-compile. arm64 programs don't run on x64 Windows, so the programs a build runs come from the
# x64 build (-HostPrefixPath, default the prefix -Arch x64 uses with the same settings). The build part checks that they are
# there before it builds anything. (An arm64 PC runs x64 and x86 programs, so nothing else is a cross-compile here.)
$CrossBuild = $Arch -eq 'arm64' -and [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq [System.Runtime.InteropServices.Architecture]::X64
if ($CrossBuild) {
  if (-not $HostPrefixPath) {
    if ($prefixIsDefault) { $HostPrefixPath = "$WorkRoot\akousma_msvc_x86_64_${BuildType}" }
    elseif ($prefixArg.Contains('{Arch}')) { $HostPrefixPath = Expand-LocationTokens $prefixArg.Replace('{Arch}', 'x86_64') }
    elseif ((Add-ArchSuffix $prefixArg) -ne $prefixArg) { $HostPrefixPath = $prefixArg }
    else { throw "-PrefixPath '$prefixArg' names arm64, so the x64 prefix the arm64 cross-compile needs can't be derived from it. Pass -HostPrefixPath <the x64 prefix>." }
  }
  $HostPrefixPath = Normalize-Path (Expand-LocationTokens $HostPrefixPath)
}
else { $HostPrefixPath = "" }

# Git: found on PATH (git.exe may be in cmd\, bin\ or mingw64\bin\); the build folder added to PATH is <Git root>\bin.
if ([string]::IsNullOrWhiteSpace($GitBinPath)) {
  $gitCmd = Get-Command git.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($gitCmd) {
    $gitDir = Split-Path -Parent $gitCmd.Source
    $gitRoot = $null
    $d = $gitDir
    for ($i = 0; $i -lt 3 -and $d; $i++) {
      if (Test-Path -LiteralPath (Join-Path $d 'usr\bin') -PathType Container) { $gitRoot = $d; break }
      $d = Split-Path -Parent $d
    }
    $GitBinPath = if ($gitRoot -and (Test-Path -LiteralPath (Join-Path $gitRoot 'bin') -PathType Container)) { Join-Path $gitRoot 'bin' } else { $gitDir }
  }
  elseif (-not $DryRun) {
    throw "git.exe not found on PATH. Install Git for Windows (https://git-scm.com/) or pass -GitBinPath."
  }
}
if ($GitBinPath) { $GitBinPath = Normalize-Path (Expand-LocationTokens $GitBinPath) }

$locations = [ordered]@{
  ProjectRoot = $ProjectRoot; DownloadsPath = $DownloadsPath; SrcPath = $SrcPath; BuildPath = $BuildPath; PrefixPath = $PrefixPath
  JomDir = $JomDir; TempPath = $TempPath; PipCachePath = $PipCachePath; CargoHome = $CargoHome
  RustupHome = $RustupHome; LogPath = $LogPath; LogDir = $LogDir
}

if ($DryRun) {
  Write-Step "Dry run: nothing is changed"
  Write-Host ("  {0,-14} {1}" -f 'Arch', $Arch)
  Write-Host ("  {0,-14} {1}" -f 'WorkRoot', $WorkRoot)
  foreach ($k in $locations.Keys) { Write-Host ("  {0,-14} {1}" -f $k, $locations[$k]) }
  Write-Host ("  {0,-14} {1}" -f 'GitBinPath', $(if ($GitBinPath) { $GitBinPath } else { '(git.exe not found)' }))
  Write-Host ("  {0,-14} {1}" -f 'Akousma', $(if ($AkousmaSource) { $AkousmaSource } else { "$SrcPath\akousma  ($AkousmaRepo @ $AkousmaRef)" }))
  Write-Host ("  {0,-14} {1}" -f 'Akousma build', "$BuildPath\akousma\build\akousma.exe")
  Write-Host ("  {0,-14} {1}" -f 'Installer', "$BuildPath\AkousmaSetup\AkousmaSetup-<version>-msvc-$(@{ x86_64 = 'x64'; x86 = 'x86'; arm64 = 'arm64' }[$Arch]).exe")
  Write-Host ("  {0,-14} {1}" -f 'Build tools', "$PSScriptRoot (strawberry-msvc-build-tools $MsvcToolsRef + Akousma changes)")
  Write-Host ("  {0,-14} {1}" -f 'Deps', "$($DepsResolved.Label) -> $BuildPath\deps-versions.txt")
  if ($CrossBuild) { Write-Host ("  {0,-14} {1}" -f 'Cross-compile', "arm64 on an x64 PC; x64 programs from $HostPrefixPath") }
  if ($prefixRenameNote) { Write-Warning $prefixRenameNote }
  return
}

# ---------------------------------------------------------------------
# 1. Redirect temp and caches
# ---------------------------------------------------------------------
# Every target drive must exist: fail early with a clear message instead of a cryptic New-Item error.
foreach ($k in $locations.Keys) {
  $driveRoot = [System.IO.Path]::GetPathRoot($locations[$k])
  if ($driveRoot -and -not $driveRoot.StartsWith('\\') -and -not (Test-Path -LiteralPath $driveRoot)) {
    throw "Drive '$driveRoot' for -$k ($($locations[$k])) does not exist or is not ready. Pass a different -$k."
  }
}
# The build part (and the pwsh children it starts) derive their tool search folders from the same root.
$env:AKOUSMA_WORK_ROOT = $WorkRoot
if ($prefixRenameNote) { Write-Warning $prefixRenameNote }

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
# 3. Build tools: the folder this script is in
# ---------------------------------------------------------------------
Write-Step "Using the build tools in $PSScriptRoot"
# A zip download carries the downloaded-file (Mark of the Web) flag, which trips the execution policy.
foreach ($f in $PSCommandPath, (Join-Path $PSScriptRoot "CopyDLLDependencies.ps1")) { Unblock-File -LiteralPath $f -ErrorAction SilentlyContinue }
$repoHead = if (Test-Path -LiteralPath (Join-Path $PSScriptRoot ".git")) { git -C $PSScriptRoot rev-parse --short HEAD 2>$null } else { $null }
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
# Dependency versions: the set resolved at the start (-Deps), as this build's versions file. It stays in the build tree as the
# record of what was built (-Deps pinned -VersionsFile <it> builds that again; -FreezeDeps with it makes it a release lock).
# ---------------------------------------------------------------------
$DepsFile = Join-Path $BuildPath 'deps-versions.txt'
$depsHeader = @("Dependency versions of this build: $($DepsResolved.Label), $([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')).",
                "Written by Build-Akousma.ps1 on every run (-Deps; see versions\ for the release locks) and read by its build part.")
[System.IO.File]::WriteAllText($DepsFile, (Format-DepsFile $depsHeader @($DepsResolved.Lines) $DepsResolved.GitRefs), [System.Text.UTF8Encoding]::new($false))
$VersionsFile = $DepsFile
foreach ($g in @($DepsResolved.GitRefs.Keys)) { if (-not $GitRefs.ContainsKey($g)) { $GitRefs[$g] = [string]$DepsResolved.GitRefs[$g] } }

# ---------------------------------------------------------------------
# CI versions: fetch strawberry-msvc-dependencies' build.yaml (-CiVersionsRef)
# ---------------------------------------------------------------------
function Get-AkousmaCommitDate {
  # The committer date of the Akousma commit being built: from the local checkout or clone, else from the GitHub API.
  $repoDir = if ($AkousmaSource) { $AkousmaSource } else { Join-Path $SrcPath 'akousma' }
  $ref = if ($AkousmaSource) { 'HEAD' } else { $AkousmaRef }
  if (Test-Path -LiteralPath (Join-Path $repoDir '.git')) {
    if (-not $AkousmaSource) { & git -C $repoDir fetch --tags --force origin 2>$null | Out-Null }
    foreach ($spec in @("origin/$ref", $ref)) {   # a branch: the fetched remote branch, not the (stale) local one
      $date = & git -C $repoDir log -1 --format=%cI "$spec^{commit}" 2>$null
      if ($LASTEXITCODE -eq 0 -and $date) { $global:LASTEXITCODE = 0; return ([datetime]([string]@($date)[0]).Trim()).ToUniversalTime() }
    }
    $global:LASTEXITCODE = 0
  }
  if ($AkousmaRepo -match 'github\.com[/:]([^/]+)/([^/]+?)(\.git)?/?$') {
    $ghHeaders = @{ 'User-Agent' = 'Build-Akousma.ps1'; 'Accept' = 'application/vnd.github+json' }
    if ($env:GITHUB_TOKEN) { $ghHeaders['Authorization'] = "Bearer $env:GITHUB_TOKEN" }
    $commit = Invoke-RestMethod -Headers $ghHeaders -Uri "https://api.github.com/repos/$($Matches[1])/$($Matches[2])/commits/$ref"
    return ([datetime]$commit.commit.committer.date).ToUniversalTime()
  }
  throw "-CiVersionsRef auto: could not find the date of Akousma @ $ref. Pass -CiVersionsRef master or a strawberry-msvc-dependencies commit."
}
if (-not $CiVersionsFile -and $CiVersionsRef) {
  $depsRepo = "strawberrymusicplayer/strawberry-msvc-dependencies"
  $depsRef  = $CiVersionsRef
  if ($depsRef -eq 'auto') {
    Write-Step "Resolving the dependency versions that were current when the Akousma commit was made"
    $until = (Get-AkousmaCommitDate).ToString("yyyy-MM-ddTHH:mm:ssZ")
    $ghHeaders = @{ 'User-Agent' = 'Build-Akousma.ps1'; 'Accept' = 'application/vnd.github+json' }
    if ($env:GITHUB_TOKEN) { $ghHeaders['Authorization'] = "Bearer $env:GITHUB_TOKEN" }
    $dc = @(Invoke-RestMethod -Headers $ghHeaders -Uri "https://api.github.com/repos/$depsRepo/commits?path=.github/workflows/build.yaml&until=$until&per_page=1")
    if ($dc.Count -eq 0 -or -not $dc[0].sha) { throw "No build.yaml commit found in $depsRepo before $until" }
    $depsRef = $dc[0].sha
    Write-Host "The Akousma commit was made $until; using $depsRepo build.yaml @ $($depsRef.Substring(0, 7))"
  }
  Write-Step "Fetching dependency versions (build.yaml @ $depsRef)"
  $ciUrl  = "https://raw.githubusercontent.com/$depsRepo/$depsRef/.github/workflows/build.yaml"
  $ciName = "build." + (($depsRef -replace '[^A-Za-z0-9._-]', '_')) + ".yaml"
  $CiVersionsFile = Join-Path $TempPath $ciName
  Invoke-WebRequest -Uri $ciUrl -OutFile $CiVersionsFile -UseBasicParsing
  Write-Host "Saved: $CiVersionsFile"
}

$sourceText = if ($AkousmaSource) { "Akousma from $AkousmaSource" } else { "Akousma @ $AkousmaRef" }
Write-Step "Building ($BuildType / $Arch, $(if ($Jobs -gt 0) { $Jobs } else { [Environment]::ProcessorCount }) jobs, $(if ($ParallelPackages -le 0) { "auto" } else { $ParallelPackages }) packages at once, build tools @ $MsvcToolsRef + Akousma, $sourceText) -> $PrefixPath"
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
# Cross-compile: the x64 prefix's bin comes first, so a program found on PATH (pkg-config, orcc, peldd, openssl, ...) is the
# x64 one that runs here, not the arm64 one of the same name in the arm64 prefix.
$env:Path = Join-PathList (@($jomDirInUse, "$CargoHome\bin") + @(if ($CrossBuild) { "$HostPrefixPath\bin" }) + @("$PrefixPath\bin", $GitBinPath) + ($env:Path -split ';'))
Set-Location $PSScriptRoot

$buildArgs = @{
  BuildType         = $BuildType
  Arch              = $Arch
  DownloadsPath     = $DownloadsPath.Replace('\', '/')
  SrcPath           = $SrcPath.Replace('\', '/')
  BuildPath         = $BuildPath.Replace('\', '/')
  PrefixPath        = $PrefixPath.Replace('\', '/')
  Jobs              = $Jobs
  ParallelPackages  = $ParallelPackages
  jom_path          = $jomDirInUse
  LogDir            = $LogDir.Replace('\', '/')
  AkousmaRepo       = $AkousmaRepo
}
if ($CrossBuild)             { $buildArgs.HostPrefixPath   = $HostPrefixPath.Replace('\', '/') }
if ($AkousmaSource)          { $buildArgs.AkousmaSource    = $AkousmaSource.Replace('\', '/') }
else                         { $GitRefs['akousma']         = $AkousmaRef }
if ($EnableQtSparkle)        { $buildArgs.EnableQtSparkle  = $true }
if ($IncludeGitCommit)       { $buildArgs.IncludeGitCommit = $true }
if ($PackagePatches.Count -gt 0) {
  $buildArgs.package_patches = @{}
  foreach ($pkg in $PackagePatches.Keys) {
    $buildArgs.package_patches[$pkg] = [string[]]@(foreach ($patch in $PackagePatches[$pkg]) {
      if (-not (Test-Path -LiteralPath $patch)) { throw "Patch for $pkg not found: $patch" }
      (Resolve-Path -LiteralPath $patch).Path
    })
  }
}
if ($Clean -and $ForceRebuild -notcontains 'akousma' -and $ForceRebuild -notcontains 'all') { $ForceRebuild = @($ForceRebuild) + @('akousma') }
if ($ForceRebuild.Count -gt 0) { $buildArgs.ForceRebuild     = $ForceRebuild }
if ($IncrementalLink)        { $buildArgs.IncrementalLink  = $true }
if ($NoChangeDetection)      { $buildArgs.NoChangeDetection = $true }
if ($RebuildDependents)      { $buildArgs.RebuildDependents = $true }
if ($Only.Count -gt 0)       { $buildArgs.Only             = $Only }
if ($Skip.Count -gt 0)       { $buildArgs.Skip             = $Skip }
if ($List)                   { $buildArgs.List             = $true }
if ($VersionsFile)           { $buildArgs.VersionsFile     = $VersionsFile }
if ($CiVersionsFile)         { $buildArgs.CiVersionsFile   = $CiVersionsFile }
if ($VersionOverrides.Count) { $buildArgs.VersionOverrides = $VersionOverrides }
# glib-networking is cloned from git and patched with the build tools' patches\glib-networking.patch (OpenSSL threading
# fixes), so the right commit depends on the build tools commit. Since upstream b1b8e82 the versions file pins it
# (GLIB_NETWORKING_VERSION=<commit>, which upstream moves along with the patch), and that is the commit built here. A versions
# file without a commit there (an older one, e.g. -VersionsFile) gets $GlibNetworkingRef above: the commit the patch was
# written against up to upstream 4c8c65c (for 34e85f6 it was e23c430, 2.90.alpha).
# The pin wins over a 40-char glib_networking_version in the CI build.yaml: that one goes with the patch CI had at the time,
# which may not be this repository's. -GitRefs @{ 'glib-networking' = '<commit>' } overrides all of this.
$pinVersionsFile = if ($VersionsFile) { $VersionsFile } else { Join-Path $PSScriptRoot "StrawberryPackageVersions.txt" }
$GlibNetworkingRefSource = "the base of glib-networking.patch at upstream 4c8c65c"
if ((Test-Path -LiteralPath $pinVersionsFile) -and
  ((Get-Content -Raw -LiteralPath $pinVersionsFile) -match "(?m)^\s*GLIB_NETWORKING_VERSION\s*=\s*([0-9a-f]{40})\s*$")) {
  $GlibNetworkingRef = $Matches[1]
  $GlibNetworkingRefSource = "GLIB_NETWORKING_VERSION in $(Split-Path -Leaf $pinVersionsFile)"
}
$ciGlibNet = if ($CiVersionsFile -and (Test-Path -LiteralPath $CiVersionsFile) -and
  ((Get-Content -Raw -LiteralPath $CiVersionsFile) -match "(?m)^\s+glib_networking_version:\s*'?([0-9a-f]{40})\b")) { $Matches[1] } else { "" }
if (-not $GitRefs.ContainsKey('glib-networking')) {
  $GitRefs['glib-networking'] = $GlibNetworkingRef
  if ($ciGlibNet -and $ciGlibNet -ne $GlibNetworkingRef) {
    Write-Host "glib-networking: using $($GlibNetworkingRef.Substring(0, 7)) ($GlibNetworkingRefSource), not CI's $($ciGlibNet.Substring(0, 7))." -ForegroundColor Cyan
  }
}
$buildArgs.GitRefs = $GitRefs

# The build part exports its resolved git refs as $env:SMB_GIT_REFS_JSON for its child processes, and reloads that variable
# when no refs are passed in. Since it runs in this session, a previous run's refs would leak into this one.
# Same for the patch and clean lists it hands its child processes.
Remove-Item Env:SMB_GIT_REFS_JSON, Env:SMB_VERSION_OVERRIDES_JSON, Env:SMB_PACKAGE_PATCHES_JSON, Env:SMB_CLEAN_PACKAGES -ErrorAction SilentlyContinue

$ErrorActionPreference = "Continue"   # native tools write to stderr; don't abort on that
& { Write-SourceSummary; Write-PatchSummary; & $PSCommandPath @buildArgs -inner_build } *>&1 | Tee-Object $LogPath
# The build part ends with exit 0 / exit 1; pass that on (the multi-architecture run above and scripts calling this one read it).
$BuildExitCode = $LASTEXITCODE
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
  # And the Windows error mode the build part changed (arm64 cross-compile: no error dialogs), in this same session.
  if ($null -ne $global:AkousmaPreviousErrorMode) {
    try { [void][Akousma.ErrorMode]::SetErrorMode([uint32]$global:AkousmaPreviousErrorMode) } catch { }
    Remove-Variable -Name AkousmaPreviousErrorMode -Scope Global -ErrorAction SilentlyContinue
  }
}
if ($BuildExitCode) { exit $BuildExitCode }
return
}
#endregion

#region Build
# The build part: run by the preparation above (-inner_build) and by the parallel build's child processes (-child_build).
# The rest of this script is upstream's StrawberryMSVCBuild.ps1 with the Akousma changes; its variables keep upstream's names.
# It always builds one architecture: -Arch has exactly one entry here. A plain string from here on, not the [string[]] parameter.
$arch_name = [string]@($Arch)[0]
Remove-Variable -Name Arch -Scope Script -Force
$arch = $arch_name
$build_type = $BuildType
$parallel_packages = if ($PSBoundParameters.ContainsKey('ParallelPackages')) { $ParallelPackages } else { 1 }
$downloads_path = $DownloadsPath
$src_path = $SrcPath
$build_path = $BuildPath
$prefix_path = $PrefixPath
$log_dir = $LogDir
$versions_file = $VersionsFile
$ci_versions_file = $CiVersionsFile
$version_overrides = $VersionOverrides
$git_refs = $GitRefs
$force_rebuild = $ForceRebuild
$no_change_detection = $NoChangeDetection
$rebuild_dependents = $RebuildDependents
$akousma_repo = $AkousmaRepo
$akousma_source = if ($AkousmaSource) { $AkousmaSource.Replace('\', '/').TrimEnd('/') } else { "" }
$enable_qtsparkle = [bool]$EnableQtSparkle
$include_git_commit = [bool]$IncludeGitCommit
$incremental_link = [bool]$IncrementalLink

# --- patched: jobs default, hashtables handed down by the parallel scheduler ---
if ($jobs -le 0) { $jobs = [Environment]::ProcessorCount }
if ($parallel_packages -le 0) { $parallel_packages = [Math]::Max(2, [int][Math]::Ceiling($jobs / 2)) }   # 0 = auto
if ($version_overrides.Count -eq 0 -and $env:SMB_VERSION_OVERRIDES_JSON) {
  $version_overrides = $env:SMB_VERSION_OVERRIDES_JSON | ConvertFrom-Json -AsHashtable
}
if ($git_refs.Count -eq 0 -and $env:SMB_GIT_REFS_JSON) {
  $git_refs = $env:SMB_GIT_REFS_JSON | ConvertFrom-Json -AsHashtable
}
# --- patched: local patches per package (local-patches\ folder, -GstGoodPatch) ---
if ($child_build -and $package_patches.Count -eq 0 -and $env:SMB_PACKAGE_PATCHES_JSON) {
  $package_patches = $env:SMB_PACKAGE_PATCHES_JSON | ConvertFrom-Json -AsHashtable
}
$smb_package_patches = @{}
foreach ($k in @($package_patches.Keys)) {
  $patch_list = @($package_patches[$k] | Where-Object { $_ } | ForEach-Object { [string]$_ })
  if ($patch_list.Count -gt 0) { $smb_package_patches[[string]$k] = $patch_list }
}

function AppendPathToEnvPath() {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [string]$path
  )
  $path_normalized = $path.TrimEnd('\').ToLowerInvariant()
  $paths = $env:PATH -split ';' | ForEach-Object { $_.TrimEnd('\') }
  if ($paths -notcontains $path_normalized) {
    $env:PATH += ";$path"
  }
}

function PrependPathToEnvPath() {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [string]$path
  )
  $path_normalized = $path.TrimEnd('\').ToLowerInvariant()
  $paths = $env:PATH -split ';' | ForEach-Object { $_.TrimEnd('\') }
  if ($paths -notcontains $path_normalized) {
    $env:PATH = "$path;$env:PATH"
  }
}

function RemovePathFromEnvPath() {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [string]$path
  )
  $path_normalized = $path.TrimEnd('\').ToLowerInvariant()
  $env:PATH = ($env:PATH -split ';' | Where-Object { $_.TrimEnd('\').ToLowerInvariant() -ne $path_normalized }) -join ';'
}

# --- patched: no fixed drive letters or install folders ---------------------------------
# Defaults hang off AKOUSMA_WORK_ROOT (set from -WorkRoot), else C:\Akousma (the default -WorkRoot, wherever this script is). Tools are found
# on PATH first. A tool that isn't on PATH is searched for (the "Check for required tools" loop) via its registry entry or
# known folder (Git, Strawberry Perl, 7-Zip, CMake, Python), then in any folders listed in SMB_TOOL_PATHS (';'-separated;
# Get-ToolCandidateDirs puts them before the search roots; Get-PythonDirs doesn't read them), then in the usual install
# folders under Program Files / LOCALAPPDATA\Programs / the system drive / the work drive, then under the root and
# Program Files of every other fixed drive (Get-ToolSearchRoots).
function Get-WorkRoot {
  if ($env:AKOUSMA_WORK_ROOT) { return $env:AKOUSMA_WORK_ROOT.Replace('\', '/').TrimEnd('/') }
  return 'C:/Akousma'
}

function Test-ExeInDir {
  param([string]$dir, [string]$name)
  if ([string]::IsNullOrWhiteSpace($dir) -or -not (Test-Path -LiteralPath $dir -PathType Container)) { return $false }
  foreach ($ext in '.exe', '.cmd', '.bat', '.com') {
    if (Test-Path -LiteralPath (Join-Path $dir "$name$ext") -PathType Leaf) { return $true }
  }
  return $false
}

function Get-RegistryString {
  param([string[]]$paths, [string[]]$names)
  foreach ($p in $paths) {
    foreach ($n in $names) {
      try {
        $v = (Get-ItemProperty -Path $p -Name $n -ErrorAction Stop).$n
        if ($v) { return [string]$v }
      } catch { }
    }
  }
  return $null
}

function Get-FixedDriveRoots {
  # Root of every fixed drive that is ready ('C:\', 'E:\', ...); never throws (no drives -> empty list)
  try {
    return @([System.IO.DriveInfo]::GetDrives() | Where-Object {
        try { $_.DriveType -eq 'Fixed' -and $_.IsReady } catch { $false }
      } | ForEach-Object { $_.Name })
  } catch {
    return @()
  }
}

function Get-ToolSearchRoots {
  $work = Get-WorkRoot
  $roots = @(@($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)}, "$env:LOCALAPPDATA/Programs", "$env:SystemDrive/", "$work/") |
    Where-Object { $_ } | ForEach-Object { $_.Replace('\', '/').TrimEnd('/') } | Select-Object -Unique)
  # then the root and Program Files of every other fixed drive (after the folders above, so they win)
  $seen = [System.Collections.Generic.HashSet[string]]::new([string[]]$roots, [System.StringComparer]::OrdinalIgnoreCase)
  $system_drive = "$env:SystemDrive".Replace('\', '/').TrimEnd('/')
  $extra = foreach ($d in (Get-FixedDriveRoots)) {
    $d = "$d".Replace('\', '/').TrimEnd('/')
    if (-not $d) { continue }
    $d
    if ($d -ne $system_drive) { "$d/Program Files"; "$d/Program Files (x86)" }
  }
  foreach ($r in $extra) { if ($seen.Add($r)) { $roots += $r } }
  return $roots
}

function Get-ToolCandidateDirs {
  param([string[]]$subdirs = @(), [string[]]$extra_dirs = @())
  $dirs = New-Object System.Collections.Generic.List[string]
  foreach ($d in $extra_dirs) { if ($d) { $dirs.Add($d) } }
  foreach ($d in ($env:SMB_TOOL_PATHS -split ';')) { if ($d) { $dirs.Add($d) } }
  foreach ($r in (Get-ToolSearchRoots)) { foreach ($s in $subdirs) { $dirs.Add("$r/$s") } }
  return $dirs.ToArray()
}

function Get-GitRoot {
  $git = Get-Command git.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($git) {
    # cmd\git.exe, bin\git.exe or mingw64\bin\git.exe: walk up to the folder that has usr\bin
    $dir = Split-Path -Parent $git.Source
    for ($i = 0; $i -lt 3 -and $dir; $i++) {
      if (Test-Path -LiteralPath (Join-Path $dir 'usr/bin') -PathType Container) { return $dir }
      $dir = Split-Path -Parent $dir
    }
  }
  $reg = Get-RegistryString -paths @('HKLM:\SOFTWARE\GitForWindows', 'HKCU:\SOFTWARE\GitForWindows') -names @('InstallPath')
  if ($reg -and (Test-Path -LiteralPath (Join-Path $reg 'usr/bin') -PathType Container)) { return $reg }
  return $null
}

function Get-PythonDirs {
  # newest first, Python 3.10+ only; registry (PEP 514) first, then Python3xx folders on disk
  $dirs = New-Object System.Collections.Generic.List[string]
  $keys = @('HKLM:\SOFTWARE\Python\PythonCore', 'HKCU:\SOFTWARE\Python\PythonCore', 'HKLM:\SOFTWARE\WOW6432Node\Python\PythonCore')
  $found = foreach ($k in $keys) {
    Get-ChildItem -Path $k -ErrorAction SilentlyContinue | ForEach-Object {
      $ver = try { [version]($_.PSChildName -replace '-.*$', '') } catch { $null }
      if ($ver -and $ver -ge [version]'3.10') {
        $ip = Get-RegistryString -paths @("$($_.PSPath)\InstallPath") -names @('ExecutablePath', '(default)')
        if ($ip) { if ($ip -match '\.exe$') { $ip = Split-Path -Parent $ip }; [pscustomobject]@{ Ver = $ver; Dir = $ip } }
      }
    }
  }
  foreach ($f in ($found | Sort-Object Ver -Descending)) { $dirs.Add($f.Dir) }
  foreach ($r in (Get-ToolSearchRoots)) {
    foreach ($base in $r, "$r/Python") {
      Get-ChildItem -LiteralPath $base -Directory -Filter 'Python3*' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^Python3(\d+)' -and [int]$Matches[1] -ge 10 } |
        Sort-Object { [int]($_.Name -replace '\D', '') } -Descending | ForEach-Object { $dirs.Add($_.FullName) }
    }
  }
  return $dirs.ToArray()
}

function Get-StrawberryPerlRoot {
  # Strawberry Perl layout: <root>\perl\bin\perl.exe, <root>\perl\site\bin, <root>\c\bin (MinGW). Git's own perl has no c\bin, so it is not matched.
  $cands = @(($env:PATH -split ';') | Where-Object { $_ }) + @(Get-ToolCandidateDirs -subdirs @('Strawberry/perl/bin'))
  foreach ($d in $cands) {
    $d = $d.Replace('\', '/').TrimEnd('/')
    if (-not (Test-Path -LiteralPath "$d/perl.exe" -PathType Leaf)) { continue }
    $perl_dir = Split-Path -Parent $d
    if (-not $perl_dir) { continue }
    $root = Split-Path -Parent $perl_dir
    if ($root -and (Split-Path -Leaf $perl_dir) -eq 'perl' -and (Test-Path -LiteralPath (Join-Path $root 'c/bin') -PathType Container)) { return $root }
  }
  return $null
}

function Initialize-Jom {
  # Makes jom.exe available on PATH: -jom_path, PATH, <downloads>/jom (downloaded). Falls back to nmake.
  if ($jom_path) {
    $dir = if (Test-Path -PathType Leaf $jom_path) { Split-Path -Parent $jom_path } else { $jom_path }
    if (Test-Path (Join-Path $dir "jom.exe")) { PrependPathToEnvPath -path $dir; return }
    Write-Warning "jom.exe not found in '$dir' (-jom_path); trying PATH / download"
  }
  if (Get-Command jom.exe -ErrorAction SilentlyContinue) { return }
  $dir = Join-Path $downloads_path "jom"
  if (-not (Test-Path (Join-Path $dir "jom.exe"))) {
    try {
      New-Item -ItemType Directory -Path $dir -Force | Out-Null
      $zip = Join-Path $dir "jom.zip"
      Write-Host "Downloading jom..." -ForegroundColor Yellow
      Invoke-WebRequest -Uri "https://download.qt.io/official_releases/jom/jom.zip" -OutFile $zip -UseBasicParsing
      Expand-Archive -Path $zip -DestinationPath $dir -Force
      Remove-Item $zip -Force -ErrorAction SilentlyContinue
    }
    catch {
      Write-Warning "Could not get jom ($_). OpenSSL will be built serially with nmake."
      return
    }
  }
  if (Test-Path (Join-Path $dir "jom.exe")) { PrependPathToEnvPath -path $dir }
}

function Invoke-NMake {
  # jom /J <jobs> when available, plain nmake otherwise
  [CmdletBinding()]
  param([string[]]$make_args = @())
  if (Get-Command jom.exe -ErrorAction SilentlyContinue) {
    & jom.exe /J $jobs @make_args
  }
  else {
    & nmake @make_args
  }
}

function Clear-VersionChecksums {
  # A checksum in the versions file (<PACKAGE>_SHA256SUM) is for the version that file gives. When a version is changed after
  # the file was read (the CI versions, an override), the checksums that go with it no longer apply: without them the download
  # is not verified (GetPackageChecksum). The names differ where one version is for several packages.
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)][string]$version_variable)
  $name = $version_variable -replace '_version$', ''
  $packages = switch ($name) {
    'qt'         { 'qtbase', 'qttools', 'qtimageformats', 'qtsvg' }
    'gstreamer'  { 'gstreamer', 'gst_plugins_base', 'gst_plugins_good', 'gst_plugins_bad', 'gst_plugins_ugly', 'gst_libav' }
    'dlfcn'      { 'dlfcn_win32' }
    'peparse'    { 'pe_parse' }
    'fftw_mingw' { 'fftw_mingw_x86_64_debug', 'fftw_mingw_x86_64_release' }
    default      { $name }
  }
  foreach ($package in $packages) {
    Remove-Variable -Name "${package}_sha256sum" -Scope Global -ErrorAction SilentlyContinue
  }
}

function Import-CIVersions {
  # Reads "<name>_version: 'x'" lines from strawberry-msvc-dependencies' build.yaml.
  # Only variables that already exist in the versions file are overridden.
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)][string]$file)
  $alias = @{ 'sqlite3' = 'sqlite'; 'gstreamer_plugins_rs' = 'gstreamer_gst_plugins_rs'; 'pe_parse' = 'peparse' }
  $text = if ($file -match '^https?://') { (Invoke-WebRequest -Uri $file -UseBasicParsing).Content } else { Get-Content -Raw -Path $file }
  foreach ($m in [regex]::Matches($text, "(?m)^\s+([a-z0-9_]+)_version:\s*'?([^'\s#]+)'?")) {
    $name = $m.Groups[1].Value.ToLower()
    if ($alias.ContainsKey($name)) { $name = $alias[$name] }
    $var = "${name}_version"
    # Git-pinned deps: CI sets <repo>_version to a 40-char commit hash; pin the clone to it.
    $git_pin = @{ 'glib_networking' = 'glib-networking'; 'libffi' = 'libffi'; 'qtsparkle' = 'qtsparkle'; 'pe_util' = 'pe-util' }
    if ($m.Groups[2].Value -match '^[0-9a-f]{40}$' -and $git_pin.ContainsKey($name) -and -not $git_refs.ContainsKey($git_pin[$name])) {
      $git_refs[$git_pin[$name]] = $m.Groups[2].Value
      Write-Host "  CI git pin: $($git_pin[$name]) @ $($m.Groups[2].Value)" -ForegroundColor DarkCyan
    }
    $old = Get-Variable -Name $var -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $old -and $old -ne $m.Groups[2].Value) {
      Set-Variable -Name $var -Value $m.Groups[2].Value -Scope Global
      Clear-VersionChecksums -version_variable $var
      Write-Host "  CI version: $var $old -> $($m.Groups[2].Value)" -ForegroundColor DarkCyan
    }
  }
}

# Set strict mode
$ErrorActionPreference = "Stop"

Write-Host "========================================" -ForegroundColor Green
Write-Host "Akousma MSVC Build Script" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""

# Load versions

$script_path = Split-Path -Parent $MyInvocation.MyCommand.Path
$version_file = if ($versions_file) { $versions_file } else { Join-Path $script_path "StrawberryPackageVersions.txt" }
$patch_path = Join-Path $script_path "patches"

# patched: the versions are global variables, and this part runs in the session the script was started in. A checksum left
# there by an earlier run must not be used for a version this versions file has no checksum for.
foreach ($v in @(Get-Variable -Name '*_sha256sum' -Scope Global -ErrorAction SilentlyContinue)) {
  Remove-Variable -Name $v.Name -Scope Global -ErrorAction SilentlyContinue
}

if (Test-Path $version_file) {
  Get-Content $version_file | ForEach-Object {
    $line = $_.Trim()
    # Skip empty lines and comments
    if ($line -and -not $line.StartsWith('#')) {
      if ($line -match '^([^=]+)=(.*)$') {
        $name = $matches[1].Trim()
        $value = $matches[2].Trim()
        # Only set variable if value is not empty
        if ($value) {
          # Convert variable name to lowercase
          $name_lower = $name.ToLower()
          # Set as global variable with lowercase name
          Set-Variable -Name $name_lower -Value $value -Scope Global
        }
      }
    }
  }
}
else {
  Write-Error "Package versions file not found: $version_file"
  exit 1
}

if ($ci_versions_file) { Import-CIVersions -file $ci_versions_file }
foreach ($k in $version_overrides.Keys) {
  $name = ([string]$k).ToLower()
  if (-not $name.EndsWith("_version")) { $name = "${name}_version" }
  Write-Host "  Override: $name = $($version_overrides[$k])" -ForegroundColor DarkCyan
  # The versions file has the override already when the preparation part wrote it (with the checksum, if one is known).
  if ([string](Get-Variable -Name $name -Scope Global -ValueOnly -ErrorAction SilentlyContinue) -ne [string]$version_overrides[$k]) {
    Clear-VersionChecksums -version_variable $name
  }
  Set-Variable -Name $name -Value ([string]$version_overrides[$k]) -Scope Global
}
# Versions files from before upstream 2d9ce79 (e.g. -VersionsFile) call the MinGW-W64 FFTW package version FFTW_VERSION.
if (-not $fftw_mingw_version -and $fftw_version) { $fftw_mingw_version = $fftw_version }
# SQLITE_YEAR (the sqlite.org download folder) is new in upstream b1b8e82; older versions files had 2026 in the URL.
if (-not $sqlite_year) { $sqlite_year = "2026" }

$expat_version_underscore = $expat_version.Replace(".", "_")
$libxml2_version_full = [version]$libxml2_version
$libxml2_version_short = "$($libxml2_version_full.Major).$($libxml2_version_full.Minor)"
$glib_version_full = [version]$glib_version
$glib_version_short = "$($glib_version_full.Major).$($glib_version_full.Minor)"
$libsoup_version_full = [version]$libsoup_version
$libsoup_version_short = "$($libsoup_version_full.Major).$($libsoup_version_full.Minor)"
$qt_version_full = [version]$qt_version
$qt_version_short = "$($qt_version_full.Major).$($qt_version_full.Minor)"

# Set build configuration - normalize input to lowercase for internal use
$build_type = $build_type.ToLower()

# Set build system specific configurations
$cmake_build_type = if ($build_type -eq "debug") { "Debug" } else { "Release" }
$meson_build_type = $build_type  # meson uses lowercase
$lib_postfix = if ($build_type -eq "debug") { "d" } else { "" }

# Set arch

$arch_numeric_id = (Get-CimInstance Win32_Processor).Architecture
switch ($arch_numeric_id) {
  0 { $vs_host_arch = "x86" }
  5 { $vs_host_arch = "arm64" }
  9 { $vs_host_arch = "amd64" }
  12 { $vs_host_arch = "arm64" }
  default {
    Write-Error "Unsupported host architecture: $arch_numeric_id"
    exit 1
  }
}

$vs_host_arch = $vs_host_arch.ToLower()
$arch = $arch.ToLower()

# --- patched: x86 (32-bit) again, as upstream had it before 6408bdc "StrawberryMSVCBuild: Remove x86" ---
if ($arch -eq "x86" -or $arch -eq "win32" -or $arch -eq "i686") {
  $arch="x86"
  $vs_arch="x86"
  $openssl_platform="VC-WIN32"
  $msbuild_platform="Win32"
  $arch_short="x86"
  $arch_win="win32"
  $arch_bits="32"
  $libdir="lib"
  $bindir="bin"
  $lib_machine="x86"
  $vs_platform="Win32"
  $libjpeg_turbo_simd="ON"
  $lame_msvcver="X86"
}
elseif ($arch -eq "x64" -or $arch -eq "x86_64" -or $arch -eq "amd64") {
  $arch="x86_64"
  $vs_arch="amd64"
  $openssl_platform="VC-WIN64A"
  $msbuild_platform="x64"
  $arch_short="x64"
  $arch_win="win64"
  $arch_bits="64"
  $libdir="lib64"
  $bindir="bin64"
  $lib_machine="x64"
  $vs_platform="x64"
  $libjpeg_turbo_simd="ON"
  $lame_msvcver="X64"
}
elseif ($arch -eq "arm64") {
  $arch="arm64"
  $vs_arch="arm64"
  $openssl_platform="VC-WIN64-ARM"
  $msbuild_platform="arm64"
  $arch_short="arm64"
  $arch_win="win64"
  $arch_bits="64"
  $libdir="libARM64"
  $bindir="binARM64"
  $lib_machine="ARM64"
  $vs_platform="ARM64"
  $libjpeg_turbo_simd="OFF"
  $lame_msvcver="ARM64"
}
else {
  Write-Error "Unknown arch: $arch"
  exit 1
}
# --- patched: x86 ---
# lame's Makefile.MSVC on 32-bit: it assembles its MMX code with nasmw (NASM's old name, not installed), and unless the CPU
# reports PROCESSOR_LEVEL 6 (AMD Zen reports 23 or 25) it compiles with flags MSVC dropped long ago (/QIfdiv /QI0f /YX).
# Plain C with the P6 flags, like the 64-bit builds (which use no assembly either).
$lame_make_args = if ($arch -eq "x86") { @("ASM=NO", "CPU=P6") } else { @() }
# qtbase 6.11+ has a windows-ioring backend (qioring_win.cpp) that is 64-bit only (static_assert; 32-bit Windows is
# unsupported upstream). Off on x86, where Qt falls back to its threadpool QRandomAccessAsyncFile backend. x64 is unchanged.
$qtbase_arch_args = @(if ($arch -eq "x86") { "-DFEATURE_windows_ioring=OFF" })   # @(): empty on x64, adds nothing

# Set paths
# Use default build path if not specified
$work_root = Get-WorkRoot
if ([string]::IsNullOrEmpty($downloads_path)) {
  $downloads_path = "$work_root/data/projects/akousma/msvc_/downloads"
}

if ([string]::IsNullOrEmpty($build_path)) {
  $build_path = "$work_root/data/projects/akousma/msvc_/build_${arch}_${build_type}"
}

if ([string]::IsNullOrEmpty($prefix_path)) {
  $prefix_path = "$work_root/akousma_msvc_${arch}_${build_type}"
}
$downloads_path = $downloads_path.Replace('\', '/').TrimEnd('/')
if ([string]::IsNullOrEmpty($src_path)) { $src_path = $downloads_path }
$src_path = $src_path.Replace('\', '/').TrimEnd('/')
$build_path = $build_path.Replace('\', '/').TrimEnd('/')
$prefix_path = $prefix_path.Replace('\', '/').TrimEnd('/')

# --- patched: arm64 cross-compile on an x64 PC ---
# x64 Windows can't run arm64 programs, so everything a build runs comes from an x64 build: the x64 prefix
# (-HostPrefixPath; default the prefix of -Arch x64 with the same settings), and for ICU an x64 build in the same ICU tree
# (MSBuildProject). The cross-compile settings are all in CMakeBuild / MesonBuild / MSBuildProject, the helpers next to them
# and Get-CrossPackageArgs, not in the Build-* recipes: the x64 and x86 recipes, and so their change-detection stamps, stay
# as they were. NOTE: written without an x64 -> arm64 test run; see BUILD.txt for what to send back if a package fails.
$cross_build = ($arch -eq "arm64" -and $vs_host_arch -eq "amd64")
$host_prefix_path = ""
if ($cross_build) {
  $host_prefix_path = if ($HostPrefixPath) { $HostPrefixPath } else { "$work_root/akousma_msvc_x86_64_${build_type}" }
  $host_prefix_path = $host_prefix_path.Replace('\', '/').TrimEnd('/')
}
# Cross-compile: no Windows error dialogs. A build tool that starts an arm64 program (x64 Windows: "Machine Type Mismatch"),
# a program that crashes or a missing drive would stop the unattended build at a modal dialog until someone clicks OK. With
# these error-mode flags the failed start or the crash is only an error code for the program that started it. Child processes
# inherit the error mode. It is per process: the preparation part puts this session's previous mode back at the end.
if ($cross_build) {
  try {
    if (-not ('Akousma.ErrorMode' -as [type])) {
      Add-Type -Namespace Akousma -Name ErrorMode -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern uint GetErrorMode();
[DllImport("kernel32.dll")] public static extern uint SetErrorMode(uint uMode);
'@
    }
    # SEM_FAILCRITICALERRORS (0x1) | SEM_NOGPFAULTERRORBOX (0x2) | SEM_NOOPENFILEERRORBOX (0x8000), on top of the current flags
    $previous_error_mode = [Akousma.ErrorMode]::SetErrorMode([uint32]([Akousma.ErrorMode]::GetErrorMode() -bor 0x8003))
    if ($null -eq $global:AkousmaPreviousErrorMode) { $global:AkousmaPreviousErrorMode = $previous_error_mode }
  }
  catch {
    Write-Warning "Could not turn off Windows error dialogs (SetErrorMode): $($_.Exception.Message). A program for the wrong machine type or a crash may stop the build at a dialog."
  }
}
# arm64 (cross-compile or not): OpenSSL's Configure. Build-OpenSSL passes LDLIBS=onecore.lib <zlib> on arm64 (VC-WIN64-ARM sets
# ex_libs to onecore.lib alone, which drops the zlib library the Windows base config adds) and /FS on every architecture.
# Configure refuses a make variable on its command line (VAR=value) together with extra compiler flags such as /FS ("Mixing
# make variables and additional compiler/linker flags as configure command line option is not permitted"), and INSTALL.md
# says it ignores LDLIBS from the environment when such flags are given. /FS (serialised writes to a shared compiler PDB) has
# nothing to do in OpenSSL: it compiles with /Z7, debug information in each .obj and no compiler PDB. So on arm64 this drops
# /FS from Configure's arguments when LDLIBS= is among them; x64 and x86 (no LDLIBS=, and this is not defined) keep it. Here,
# not in Build-OpenSSL: its text is part of OpenSSL's change-detection stamp, so the x64 and x86 builds stay up to date.
if ($arch -eq "arm64") {
  function script:perl {
    $perl_args = @($args)
    if ($perl_args.Count -gt 0 -and $perl_args[0] -eq "Configure" -and @($perl_args | Where-Object { "$_" -like "LDLIBS=*" }).Count -gt 0) {
      $perl_args = @($perl_args | Where-Object { "$_" -ne "/FS" })
    }
    $perl_exe = Get-Command -Name perl -CommandType Application -ErrorAction Stop | Select-Object -First 1
    & $perl_exe.Source @perl_args
  }
}
$qt_dev = "OFF"
$gst_dev = "OFF"

$cmake_loglevel = "DEBUG"
$cmake_generator = "Ninja"

# Display configuration
Write-Host "Build Configuration:" -ForegroundColor Cyan
Write-Host "  Downloads path:      $downloads_path"
Write-Host "  Source path:         $src_path"
Write-Host "  Build path:          $build_path"
Write-Host "  Build type:          $build_type"
Write-Host "  Build Architecture:  $arch"
Write-Host "  CMake build type:    $cmake_build_type"
Write-Host "  Meson build type:    $meson_build_type"
Write-Host "  Prefix path:         $prefix_path"
if ($cross_build) { Write-Host "  Cross-compile:       arm64 on an x64 PC, x64 programs from $host_prefix_path" }
Write-Host "  Jobs per package:    $jobs"
Write-Host "  Parallel packages:   $parallel_packages"
Write-Host ""

# Create directories
Write-Host "Creating directories..." -ForegroundColor Cyan
try {
  @($downloads_path, $src_path, $build_path, $prefix_path, "$prefix_path/include", "$prefix_path/lib", "$prefix_path/lib/pkgconfig", "$prefix_path/lib/cmake", "$prefix_path/bin") | ForEach-Object {
    if (-not (Test-Path $_)) {
      New-Item -ItemType Directory -Path $_ -Force | Out-Null
      Write-Host "  Created: $_" -ForegroundColor Green
    }
  }
}
catch {
  Write-Error "Failed to create directories: $_"
  exit 1
}

# Copy sed.exe if needed
if (-not (Test-Path "$prefix_path/bin/sed.exe")) {
  if (Test-Path "$downloads_path/sed.exe") {
    Copy-Item "$downloads_path/sed.exe" "$prefix_path/bin/" -Force
  }
}

# Setup environment variables
Write-Host "Setting up environment variables..." -ForegroundColor Cyan
# Cross-compile: the x64 pkgconf (the arm64 one doesn't run here), limited to the arm64 prefix's .pc files: its own default
# folder is the x64 prefix's lib/pkgconfig. PKG_CONFIG_ALLOW_CROSS: Rust's pkg-config crate refuses to cross-compile without it.
$pkg_config_exe = if ($cross_build) { "$host_prefix_path/bin/pkgconf.exe" } else { "$prefix_path/bin/pkgconf.exe" }
$env:PKG_CONFIG_EXECUTABLE = $pkg_config_exe
if ($cross_build) {
  $env:PKG_CONFIG_LIBDIR = "$prefix_path/lib/pkgconfig"
  $env:PKG_CONFIG_ALLOW_CROSS = "1"
}
$env:PKG_CONFIG_PATH = "$prefix_path/lib/pkgconfig"
$env:PKG_CONFIG_ALLOW_SYSTEM_CFLAGS = "1"
$env:PKG_CONFIG_ALLOW_SYSTEM_LIBS = "1"
$env:CL = "-MP$jobs"
$env:CMAKE_BUILD_PARALLEL_LEVEL = "$jobs"
$env:CARGO_BUILD_JOBS = "$jobs"
Initialize-Jom
$env:YASMPATH = "$prefix_path/bin"

PrependPathToEnvPath -path "$prefix_path/bin"
if ($cross_build) {
  # The x64 prefix's bin in front of the arm64 one (also when an earlier step put it elsewhere): see the preparation part.
  foreach ($p in "$host_prefix_path/bin", ("$host_prefix_path/bin").Replace('/', '\')) { RemovePathFromEnvPath -path $p }
  $env:PATH = "$host_prefix_path/bin;$env:PATH"
}

# Strawberry Perl folders (derived, not hardcoded); empty when it is not installed
$strawberry_perl_root = Get-StrawberryPerlRoot
$strawberry_perl_bin = $null; $strawberry_perl_site_bin = $null; $strawberry_c_bin = $null
if ($strawberry_perl_root) {
  $strawberry_perl_bin = (Join-Path $strawberry_perl_root 'perl/bin').Replace('/', '\')
  $strawberry_perl_site_bin = (Join-Path $strawberry_perl_root 'perl/site/bin').Replace('/', '\')
  $strawberry_c_bin = (Join-Path $strawberry_perl_root 'c/bin').Replace('/', '\')
}

# Remove Strawberry Perl bin path
if ($strawberry_c_bin) { RemovePathFromEnvPath -path $strawberry_c_bin }

Write-Host "  Setting Visual Studio environment..." -ForegroundColor Cyan
$vs_where_path = "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
if (-not (Test-Path $vs_where_path)) {
  Write-Error "Could not locate VS where $vs_where_path"
  exit 1
}

$vs_install_path = & "${vs_where_path}" -latest -property installationPath 2>$null
if (-not $vs_install_path) {
  Write-Error "Could not locate VS installation path"
  exit 1
}

if (-not (Test-Path $vs_install_path)) {
  Write-Error "VS installation path $vs_install_path does not exist"
  exit 1
}

$vs_dev_shell_path = Join-Path $vs_install_path "Common7/Tools/Launch-VsDevShell.ps1"
if (-not (Test-Path $vs_dev_shell_path)) {
  Write-Error "Could not locate VS dev shell $vs_dev_shell_path"
  exit 1
}

$vs_dev_env_path = Join-Path $vs_install_path "Common7/IDE/devenv.com"
if (-not (Test-Path $vs_dev_env_path)) {
  Write-Error "Could not locate VS dev shell $vs_dev_env_path"
  exit 1
}

# Cross-compile: -Arch arm64 -HostArch amd64 = the x64-hosted compilers that build arm64 code (Hostx64\arm64), from the
# "MSVC ... ARM64/ARM64EC build tools" component.
if ($cross_build -and -not (Get-ChildItem -Path "$vs_install_path/VC/Tools/MSVC/*/bin/Hostx64/arm64/cl.exe" -ErrorAction SilentlyContinue)) {
  Write-Error "-Arch arm64 on an x64 PC needs Visual Studio's ARM64 build tools, which $vs_install_path doesn't have (no VC\Tools\MSVC\*\bin\Hostx64\arm64\cl.exe). Visual Studio Installer > Modify > Individual components: 'MSVC v143 - VS 2022 C++ ARM64/ARM64EC build tools (Latest)' (Microsoft.VisualStudio.Component.VC.Tools.ARM64)."
  exit 1
}
Write-Host "  Initializing Visual Studio $arch environment..." -ForegroundColor Cyan
& $vs_dev_shell_path -Arch $vs_arch -HostArch $vs_host_arch -SkipAutomaticLocation
Write-Host "  Visual Studio $arch environment initialized" -ForegroundColor Green

function Test-Command {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [string]$command
  )

  $null = Get-Command $command -ErrorAction SilentlyContinue
  return $?
}

function Assert-Command {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [string]$command,

    [Parameter(Mandatory=$false)]
    [string]$path,

    [Parameter(Mandatory=$true)]
    [string]$error_message
  )

  if (-not (Test-Command $command)) {
    if ($path -and (Test-Path $path)) {
      $env:PATH = "$path;$env:PATH"
    }

    if (-not (Test-Command $command)) {
      throw $error_message
    }
  }
}

# Check for required tools
Write-Host "Checking requirements..." -ForegroundColor Cyan

$git_root = Get-GitRoot
$git_tool_dirs = @(Get-ToolCandidateDirs -subdirs @('Git/usr/bin') -extra_dirs $(if ($git_root) { @("$git_root/usr/bin") } else { @() }))
$tool_hint = " (or put its folder on PATH / in SMB_TOOL_PATHS)"

$cmd_checks = @(
  @{ Command = "sed"; Paths = $git_tool_dirs; Message = "Missing sed$tool_hint" }
  @{ Command = "patch"; Paths = $git_tool_dirs; Message = "Missing patch$tool_hint" }
  @{ Command = "nasm"; Paths = @(Get-ToolCandidateDirs -subdirs @('NASM', 'nasm', 'NASM/bin')); Message = "Missing nasm. Download from https://www.nasm.us/$tool_hint" }
  @{ Command = "win_flex"; Paths = @(Get-ToolCandidateDirs -subdirs @('win_flex_bison', 'winflexbison')); Message = "Missing win_flex. Download from https://sourceforge.net/projects/winflexbison/$tool_hint" }
  @{ Command = "win_bison"; Paths = @(Get-ToolCandidateDirs -subdirs @('win_flex_bison', 'winflexbison')); Message = "Missing win_bison. Download from https://sourceforge.net/projects/winflexbison/$tool_hint" }
  @{ Command = "perl"; Paths = @(@($strawberry_perl_bin) + @(Get-ToolCandidateDirs -subdirs @('Strawberry/perl/bin')) | Where-Object { $_ }); Message = "Missing perl. Download Strawberry Perl from https://strawberryperl.com/$tool_hint" }
  @{ Command = "python"; Paths = @(Get-PythonDirs); Message = "Missing python. Download from https://www.python.org/$tool_hint" }
  @{ Command = "bzip2"; Paths = $git_tool_dirs; Message = "Missing bzip2$tool_hint" }
  @{ Command = "7z"; Paths = @(@(Get-RegistryString -paths @('HKLM:\SOFTWARE\7-Zip', 'HKCU:\SOFTWARE\7-Zip') -names @('Path64', 'Path')) + @(Get-ToolCandidateDirs -subdirs @('7-Zip')) | Where-Object { $_ }); Message = "Missing 7z. Download 7-Zip from https://www.7-zip.org/download.html$tool_hint" }
  @{ Command = "cmake"; Paths = @(@(Get-RegistryString -paths @('HKLM:\SOFTWARE\Kitware\CMake', 'HKCU:\SOFTWARE\Kitware\CMake') -names @('InstallDir')) | Where-Object { $_ } | ForEach-Object { Join-Path $_ 'bin' }) + @(Get-ToolCandidateDirs -subdirs @('CMake/bin')); Message = "Missing cmake. Download from https://cmake.org/$tool_hint" }
  @{ Command = "meson"; Paths = @(Get-ToolCandidateDirs -subdirs @('Meson')); Message = "Missing meson. Download from https://mesonbuild.com/$tool_hint" }
  @{ Command = "nmake"; Paths = @(); Message = "Missing nmake. Install Visual Studio 2022 or 2026" }
)

foreach ($cmd_check in $cmd_checks) {
  if (-not (Test-Command $cmd_check.Command)) {
    foreach ($path in $cmd_check.Paths) {
      if (Test-ExeInDir $path $cmd_check.Command) {
        $env:PATH = "$env:PATH;$path"
        break
      }
    }
    if (-not (Test-Command $cmd_check.Command)) {
      Write-Error $cmd_check.Message
      exit 1
    }
  }
  Write-Host "  $($cmd_check.Command) found" -ForegroundColor Green
}

# Check for GNU tar
# bsdtar (libarchive) gets stuck when extracting tar.xz archives

$tar_candidates = Get-Command tar -All -ErrorAction SilentlyContinue | Where-Object CommandType -eq Application | Select-Object -ExpandProperty Source -Unique
$tar_results = foreach ($i in $tar_candidates) {
  $out = & $i --version 2>&1 | Out-String
  [pscustomobject]@{
    Path       = $i
    IsGnuTar   = ($out -match '^(?m)tar \(GNU tar\)')
    IsBsdTar   = ($out -match '(?im)\bbsdtar\b')
    VersionRaw = ($out -replace '\r','').Trim()
  }
}
$tar_cmd_path = ($tar_results | Where-Object IsGnuTar | Select-Object -First 1 -ExpandProperty Path)
if (-not $tar_cmd_path) {
  Write-Host "No GNU tar found. Candidates and their banners:"
  $tar_results | ForEach-Object { "{0}`n  {1}`n" -f $_.Path, ($_.VersionRaw -split "`n" | Select-Object -First 1) }
  throw "GNU tar not found on PATH."
}

Write-Host ""
Write-Host "All requirements satisfied!" -ForegroundColor Green
Write-Host ""
Write-Host "Using GNU tar from $tar_cmd_path"
Write-Host ""

function RecursiveCopy {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [string]$source_path,

    [Parameter(Mandatory=$true)]
    [string]$destination_path
  )
  $source_path_backslash = $source_path -replace '/', '\'
  $destination_path_backslash = $destination_path -replace '/', '\'
  xcopy /E /V /I /F /H /R /Y /B $source_path_backslash $destination_path_backslash
}

function DownloadFileWithRetry {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [string]$url,

    [Parameter(Mandatory=$true)]
    [string]$file_path,

    [int]$retries = 10,

    [int]$retry_delay = 10
  )
  for ($attempt = 1; $attempt -le $retries; $attempt++) {
    Write-Host "Downloading $url (attempt $attempt of $retries)" -ForegroundColor Yellow
    try {
      $response = Invoke-WebRequest -Uri $url -OutFile $file_path -PassThru -UseBasicParsing -MaximumRedirection 5 -UserAgent "Wget"
      # Verify file was downloaded and has content
      if (-not (Test-Path $file_path)) {
        throw "Downloaded file not found at $file_path"
      }
      $file_size = (Get-Item $file_path).Length
      if ($file_size -eq 0) {
        throw "Downloaded file is empty (0 bytes)"
      }
      # Keep the original time of the file from the server, instead of the time it was downloaded
      $last_modified = $response.Headers['Last-Modified'] | Select-Object -First 1
      $file_time = [DateTimeOffset]::MinValue
      if ($last_modified -and [DateTimeOffset]::TryParse($last_modified, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$file_time)) {
        (Get-Item $file_path).LastWriteTimeUtc = $file_time.UtcDateTime
      }
      Write-Host "Downloaded $(Split-Path $file_path -Leaf) ($file_size bytes)" -ForegroundColor Green
      return $true
    }
    catch {
      if (Test-Path $file_path) {
        Remove-Item $file_path -Force
      }
      Write-Warning "Failed to download $url : $_"
      # The file doesn't exist on this server, so don't retry, try the next URL instead.
      if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) {
        return $false
      }
      if ($attempt -lt $retries) {
        Write-Host "Retrying in $retry_delay seconds..." -ForegroundColor Yellow
        Start-Sleep -Seconds $retry_delay
      }
    }
  }
  return $false
}

function TestFileChecksum {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [string]$file_path,

    [string]$sha256
  )
  if (-not $sha256) {
    return $true
  }
  $file_sha256 = (Get-FileHash -Path $file_path -Algorithm SHA256).Hash
  if ($file_sha256 -ne $sha256) {
    Write-Warning "SHA256 mismatch for $(Split-Path $file_path -Leaf): expected $($sha256.ToLower()), got $($file_sha256.ToLower())"
    return $false
  }
  Write-Host "SHA256 verified for $(Split-Path $file_path -Leaf)" -ForegroundColor Green
  return $true
}

function DownloadFileIfNotExists {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [string[]]$urls,

    [Parameter(Mandatory=$true)]
    [string]$destination_path,

    [string]$sha256
  )
  # Handle SourceForge URLs that end with /download
  $url = $urls[0]
  $filename = Split-Path $url -Leaf
  if ($filename -eq 'download' -and $url -match '/([^/]+)/download$') {
    $filename = $matches[1]
  }
  $file_path = Join-Path $destination_path $filename
  if (Test-Path $file_path) {
    if (TestFileChecksum -file_path $file_path -sha256 $sha256) {
      Write-Host "Using cached $filename" -ForegroundColor Cyan
      return
    }
    Write-Warning "Removing cached $filename and downloading it again"
    Remove-Item $file_path -Force
  }
  # patched: download to a private .part file and rename it into place once its checksum is verified, so a parallel package
  # (or the prefetch job) never mistakes a half-written archive for a finished download.
  $part_path = "$file_path.$PID.part"
  # Try the URLs in order, the Strawberry packages server is listed last for each package in GetPackageUrls.
  foreach ($download_url in $urls) {
    if (DownloadFileWithRetry -url $download_url -file_path $part_path) {
      if (TestFileChecksum -file_path $part_path -sha256 $sha256) {
        if (Test-Path $file_path) {
          # someone else (prefetch) finished first: that file is kept when it is the right one, else replaced by this one
          if (TestFileChecksum -file_path $file_path -sha256 $sha256) { Remove-Item $part_path -Force }
          else { Move-Item -LiteralPath $part_path -Destination $file_path -Force }
        }
        else {
          try { [System.IO.File]::Move($part_path, $file_path) }   # no overwrite: throws if it appeared meanwhile
          catch {
            if (Test-Path $part_path) { Remove-Item $part_path -Force }
            if (-not (Test-Path $file_path)) { throw }
          }
        }
        return
      }
      Remove-Item $part_path -Force
    }
    Write-Warning "Giving up on $download_url"
  }
  throw "Failed to download $filename from all URLs: $($urls -join ', ')"
}

function Get-GitRefSpec {
  # How a pinned ref is resolved in a clone. A branch name means the remote's branch (origin/<ref>, as of the last fetch), not
  # the clone's local branch of that name: a fetch doesn't move that one, so it would stay at the commit it was first cloned at.
  # Tags and commits (and refs the remote doesn't have as a branch) resolve as they are.
  param([string]$repo_path, [string]$ref)
  if (-not $ref) { return $ref }
  & git -C $repo_path show-ref --verify --quiet "refs/remotes/origin/$ref" 2>$null
  $is_branch = $LASTEXITCODE -eq 0
  $global:LASTEXITCODE = 0
  if ($is_branch) { return "origin/$ref" }
  return $ref
}

function SyncGitRepository {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [string]$url,

    [Parameter(Mandatory=$true)]
    [string]$destination_path,

    [Parameter(Mandatory=$false)]
    [string]$repo_name = "",

    [int]$retries = 10,

    [int]$retry_delay = 10
  )

  if (-not $repo_name) { $repo_name = (Split-Path $url -Leaf) -replace '\.git$', '' }
  $repo_path = Join-Path $destination_path $repo_name
  $pinned_ref = $git_refs[$repo_name]

  if (Test-Path $repo_path) {
    Push-Location $repo_path
    try {
      # patched: a pinned repository is fetched (its ref is checked out below), any other is pulled. No return on success:
      # the checkout of the pinned ref follows.
      $updated = $false
      for ($attempt = 1; $attempt -le $retries; $attempt++) {
        Write-Host "Updating repository $url (attempt $attempt of $retries)" -ForegroundColor Yellow
        if ($pinned_ref) {
          & git fetch --tags --force origin
        }
        else {
          & git pull --rebase
        }
        if ($LASTEXITCODE -eq 0) {
          $updated = $true
          break
        }
        if ($attempt -lt $retries) {
          Write-Host "Retrying in $retry_delay seconds..." -ForegroundColor Yellow
          Start-Sleep -Seconds $retry_delay
        }
      }
      if (-not $updated) {
        if ($pinned_ref) { Write-Warning "Failed to fetch $url" }
        else { Write-Warning "Failed to update repository $url" }
      }
    }
    finally {
      Pop-Location
    }
  }
  else {
    $cloned = $false
    for ($attempt = 1; $attempt -le $retries; $attempt++) {
      Write-Host "Cloning repository $url (attempt $attempt of $retries)" -ForegroundColor Yellow
      & git clone --recurse-submodules $url $repo_path
      if ($LASTEXITCODE -eq 0) {
        $cloned = $true
        break
      }
      # Remove partial clone so the next attempt starts clean
      if (Test-Path $repo_path) {
        Remove-Item $repo_path -Recurse -Force
      }
      if ($attempt -lt $retries) {
        Write-Host "Retrying in $retry_delay seconds..." -ForegroundColor Yellow
        Start-Sleep -Seconds $retry_delay
      }
    }
    if (-not $cloned) {
      throw "Failed to clone repository $url"
    }
  }

  if ($pinned_ref) {
    # patched: the Akousma clone is where you may edit Akousma; its uncommitted changes are never thrown away by the checkout.
    if ($repo_name -eq 'akousma') {
      $dirty = @(& git -C $repo_path status --porcelain=v1 --untracked-files=no 2>$null | Where-Object { $_ })
      $global:LASTEXITCODE = 0
      if ($dirty.Count -gt 0) {
        throw ("$repo_path has uncommitted changes ($($dirty.Count) file(s), e.g. $(($dirty | Select-Object -First 3 | ForEach-Object { $_.Substring(3) }) -join ', ')). " +
               "The build checks out $pinned_ref there and won't discard them: build them with -AkousmaSource $repo_path (incremental), " +
               "or commit / stash them (git -C $repo_path stash).")
      }
    }
    # A branch is checked out as the fetched remote branch (detached), so a new commit on it is built.
    $checkout_ref = Get-GitRefSpec -repo_path $repo_path -ref $pinned_ref
    Write-Host "Checking out $repo_name @ $pinned_ref$(if ($checkout_ref -ne $pinned_ref) { " ($checkout_ref)" })" -ForegroundColor Yellow
    & git -C $repo_path -c advice.detachedHead=false checkout --force $checkout_ref
    if ($LASTEXITCODE -ne 0) { throw "Failed to check out $pinned_ref in $repo_name" }
    & git -C $repo_path submodule update --init --recursive
    if ($LASTEXITCODE -ne 0) { throw "Failed to update submodules of $repo_name" }
  }
}

# Download URLs for each package, tried in order, the file is saved with the filename from the first URL.
# The Strawberry packages server is listed last for all packages, with the filename from the first URL, which is the name update.sh uploads it as.
# The VC redistributables are not listed there, since they don't have a checksum to verify the file.
# Mirrors are based on the ones used by strawberry-msvc-dependencies, only mirrors that have the files are used.
# All URLs for a package must have the same file, since they are checked against the same SHA256 checksum.
function GetPackageUrls {
  [CmdletBinding()]
  param()
  $sourceforge_mirror1 = "downloads.sourceforge.net"
  $sourceforge_mirror2 = "netix.dl.sourceforge.net"
  $qt_mirror1 = "ftp.fau.de/qtproject"
  $qt_mirror2 = "mirrors.ocf.berkeley.edu/qt"
  $packages_server = "https://packages.strawberrymusicplayer.org"
  $package_urls = @{
    'pkgconf' = @(
      "https://github.com/pkgconf/pkgconf/archive/refs/tags/pkgconf-$pkgconf_version.tar.gz",
      "$packages_server/pkgconf-$pkgconf_version.tar.gz"
    )
    'proxy-libintl' = @(
      "https://github.com/frida/proxy-libintl/archive/refs/tags/$proxy_libintl_version/proxy-libintl-$proxy_libintl_version.tar.gz",
      "$packages_server/proxy-libintl-$proxy_libintl_version.tar.gz"
    )
    'getopt-win' = @(
      "https://github.com/ludvikjerabek/getopt-win/archive/refs/tags/v$getopt_win_version/getopt-win-$getopt_win_version.tar.gz",
      "$packages_server/getopt-win-$getopt_win_version.tar.gz"
    )
    'zlib' = @(
      "https://zlib.net/zlib-$zlib_version.tar.gz",
      "https://github.com/madler/zlib/releases/download/v$zlib_version/zlib-$zlib_version.tar.gz",
      "$packages_server/zlib-$zlib_version.tar.gz"
    )
    'openssl' = @(
      "https://github.com/openssl/openssl/releases/download/openssl-$openssl_version/openssl-$openssl_version.tar.gz",
      "https://www.openssl.org/source/openssl-$openssl_version.tar.gz",
      "$packages_server/openssl-$openssl_version.tar.gz"
    )
    'libpng' = @(
      "https://$sourceforge_mirror1/project/libpng/libpng16/$libpng_version/libpng-$libpng_version.tar.gz",
      "https://$sourceforge_mirror2/project/libpng/libpng16/$libpng_version/libpng-$libpng_version.tar.gz",
      "$packages_server/libpng-$libpng_version.tar.gz"
    )
    'libjpeg-turbo' = @(
      "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/$libjpeg_turbo_version/libjpeg-turbo-$libjpeg_turbo_version.tar.gz",
      "$packages_server/libjpeg-turbo-$libjpeg_turbo_version.tar.gz"
    )
    'pcre2' = @(
      "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$pcre2_version/pcre2-$pcre2_version.tar.gz",
      "$packages_server/pcre2-$pcre2_version.tar.gz"
    )
    'bzip2' = @(
      "https://sourceware.org/pub/bzip2/bzip2-$bzip2_version.tar.gz",
      "https://ftp.funet.fi/pub/mirrors/sourceware.org/pub/bzip2/bzip2-$bzip2_version.tar.gz",
      "$packages_server/bzip2-$bzip2_version.tar.gz"
    )
    'xz' = @(
      "https://$sourceforge_mirror1/project/lzmautils/xz-$xz_version.tar.gz",
      "https://github.com/tukaani-project/xz/releases/download/v$xz_version/xz-$xz_version.tar.gz",
      "https://$sourceforge_mirror2/project/lzmautils/xz-$xz_version.tar.gz",
      "$packages_server/xz-$xz_version.tar.gz"
    )
    'brotli' = @(
      "https://github.com/google/brotli/archive/refs/tags/v$brotli_version/brotli-$brotli_version.tar.gz",
      "$packages_server/brotli-$brotli_version.tar.gz"
    )
    'uchardet' = @(
      "https://www.freedesktop.org/software/uchardet/releases/uchardet-$uchardet_version.tar.xz",
      "$packages_server/uchardet-$uchardet_version.tar.xz"
    )
    'icu4c' = @(
      "https://github.com/unicode-org/icu/releases/download/release-$icu4c_version/icu4c-$icu4c_version-sources.tgz",
      "$packages_server/icu4c-$icu4c_version-sources.tgz"
    )
    'pixman' = @(
      "https://www.cairographics.org/releases/pixman-$pixman_version.tar.gz",
      "https://xorg.freedesktop.org/releases/individual/lib/pixman-$pixman_version.tar.gz",
      "$packages_server/pixman-$pixman_version.tar.gz"
    )
    'expat' = @(
      "https://github.com/libexpat/libexpat/releases/download/R_$expat_version_underscore/expat-$expat_version.tar.gz",
      "https://$sourceforge_mirror1/project/expat/expat/$expat_version/expat-$expat_version.tar.gz",
      "https://$sourceforge_mirror2/project/expat/expat/$expat_version/expat-$expat_version.tar.gz",
      "$packages_server/expat-$expat_version.tar.gz"
    )
    'libxml2' = @(
      "https://download.gnome.org/sources/libxml2/$libxml2_version_short/libxml2-$libxml2_version.tar.xz",
      "$packages_server/libxml2-$libxml2_version.tar.xz"
    )
    'nghttp2' = @(
      "https://github.com/nghttp2/nghttp2/releases/download/v$nghttp2_version/nghttp2-$nghttp2_version.tar.gz",
      "$packages_server/nghttp2-$nghttp2_version.tar.gz"
    )
    'dlfcn-win32' = @(
      "https://github.com/dlfcn-win32/dlfcn-win32/archive/refs/tags/v$dlfcn_version/dlfcn-win32-$dlfcn_version.tar.gz",
      "$packages_server/dlfcn-win32-$dlfcn_version.tar.gz"
    )
    'libpsl' = @(
      "https://github.com/rockdaboot/libpsl/releases/download/$libpsl_version/libpsl-$libpsl_version.tar.gz",
      "$packages_server/libpsl-$libpsl_version.tar.gz"
    )
    'orc' = @(
      "https://gstreamer.freedesktop.org/src/orc/orc-$orc_version.tar.xz",
      "$packages_server/orc-$orc_version.tar.xz"
    )
    'sqlite' = @(
      "https://sqlite.org/$sqlite_year/sqlite-autoconf-$sqlite_version.tar.gz",
      "$packages_server/sqlite-autoconf-$sqlite_version.tar.gz"
    )
    'libproxy' = @(
      "https://github.com/libproxy/libproxy/archive/refs/tags/$libproxy_version/libproxy-$libproxy_version.tar.gz",
      "$packages_server/libproxy-$libproxy_version.tar.gz"
    )
    'glib' = @(
      "https://download.gnome.org/sources/glib/$glib_version_short/glib-$glib_version.tar.xz",
      "$packages_server/glib-$glib_version.tar.xz"
    )
    'libsoup' = @(
      "https://download.gnome.org/sources/libsoup/$libsoup_version_short/libsoup-$libsoup_version.tar.xz",
      "$packages_server/libsoup-$libsoup_version.tar.xz"
    )
    'freetype' = @(
      "https://sourceforge.net/projects/freetype/files/freetype2/$freetype_version/freetype-$freetype_version.tar.gz",
      "https://$sourceforge_mirror1/project/freetype/freetype2/$freetype_version/freetype-$freetype_version.tar.gz",
      "https://$sourceforge_mirror2/project/freetype/freetype2/$freetype_version/freetype-$freetype_version.tar.gz",
      "$packages_server/freetype-$freetype_version.tar.gz"
    )
    'cairo' = @(
      "https://cairographics.org/releases/cairo-$cairo_version.tar.xz",
      "$packages_server/cairo-$cairo_version.tar.xz"
    )
    'harfbuzz' = @(
      "https://github.com/harfbuzz/harfbuzz/releases/download/$harfbuzz_version/harfbuzz-$harfbuzz_version.tar.xz",
      "$packages_server/harfbuzz-$harfbuzz_version.tar.xz"
    )
    'jasper' = @(
      "https://github.com/jasper-software/jasper/releases/download/version-$jasper_version/jasper-$jasper_version.tar.gz",
      "$packages_server/jasper-$jasper_version.tar.gz"
    )
    'tiff' = @(
      "https://download.osgeo.org/libtiff/tiff-$tiff_version.tar.gz",
      "$packages_server/tiff-$tiff_version.tar.gz"
    )
    'libwebp' = @(
      "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-$libwebp_version.tar.gz",
      "$packages_server/libwebp-$libwebp_version.tar.gz"
    )
    'libogg' = @(
      "https://downloads.xiph.org/releases/ogg/libogg-$libogg_version.tar.gz",
      "https://github.com/xiph/ogg/releases/download/v$libogg_version/libogg-$libogg_version.tar.gz",
      "$packages_server/libogg-$libogg_version.tar.gz"
    )
    'libvorbis' = @(
      "https://downloads.xiph.org/releases/vorbis/libvorbis-$libvorbis_version.tar.gz",
      "https://github.com/xiph/vorbis/releases/download/v$libvorbis_version/libvorbis-$libvorbis_version.tar.gz",
      "$packages_server/libvorbis-$libvorbis_version.tar.gz"
    )
    'flac' = @(
      "https://ftp.osuosl.org/pub/xiph/releases/flac/flac-$flac_version.tar.xz",
      "https://github.com/xiph/flac/releases/download/$flac_version/flac-$flac_version.tar.xz",
      "https://downloads.xiph.org/releases/flac/flac-$flac_version.tar.xz",
      "$packages_server/flac-$flac_version.tar.xz"
    )
    'wavpack' = @(
      "https://www.wavpack.com/wavpack-$wavpack_version.tar.bz2",
      "$packages_server/wavpack-$wavpack_version.tar.bz2"
    )
    'opus' = @(
      "https://downloads.xiph.org/releases/opus/opus-$opus_version.tar.gz",
      "https://ftp.osuosl.org/pub/xiph/releases/opus/opus-$opus_version.tar.gz",
      "$packages_server/opus-$opus_version.tar.gz"
    )
    'opusfile' = @(
      "https://ftp.osuosl.org/pub/xiph/releases/opus/opusfile-$opusfile_version.tar.gz",
      "https://downloads.xiph.org/releases/opus/opusfile-$opusfile_version.tar.gz",
      "https://github.com/xiph/opusfile/releases/download/v$opusfile_version/opusfile-$opusfile_version.tar.gz",
      "$packages_server/opusfile-$opusfile_version.tar.gz"
    )
    'speex' = @(
      "https://gitlab.xiph.org/xiph/speex/-/archive/Speex-$speex_version/speex-Speex-$speex_version.tar.gz",
      "$packages_server/speex-Speex-$speex_version.tar.gz"
    )
    'mpg123' = @(
      "https://$sourceforge_mirror1/project/mpg123/mpg123/$mpg123_version/mpg123-$mpg123_version.tar.bz2",
      "https://$sourceforge_mirror2/project/mpg123/mpg123/$mpg123_version/mpg123-$mpg123_version.tar.bz2",
      "https://www.mpg123.de/download/mpg123-$mpg123_version.tar.bz2",
      "$packages_server/mpg123-$mpg123_version.tar.bz2"
    )
    'lame' = @(
      "https://$sourceforge_mirror1/project/lame/lame/$lame_version/lame-$lame_version.tar.gz",
      "https://$sourceforge_mirror2/project/lame/lame/$lame_version/lame-$lame_version.tar.gz",
      "$packages_server/lame-$lame_version.tar.gz"
    )
    'fftw-mingw' = @(
      "https://github.com/strawberrymusicplayer/fftw3-mingw-cross/releases/download/${fftw_mingw_version}/fftw-${arch}-w64-mingw32-${build_type}-${fftw_mingw_version}.tar.xz",
      "$packages_server/fftw-${arch}-w64-mingw32-${build_type}-${fftw_mingw_version}.tar.xz"
    )
    'fftw-source' = @(
      "https://www.fftw.org/fftw-$fftw_source_version.tar.gz",
      "$packages_server/fftw-$fftw_source_version.tar.gz"
    )
    'musepack' = @(
      "https://files.musepack.net/source/musepack_src_r$musepack_version.tar.gz",
      "$packages_server/musepack_src_r$musepack_version.tar.gz"
    )
    'libopenmpt' = @(
      "https://lib.openmpt.org/files/libopenmpt/src/libopenmpt-$libopenmpt_version+release.msvc.zip",
      "$packages_server/libopenmpt-$libopenmpt_version+release.msvc.zip"
    )
    'libgme' = @(
      "https://github.com/libgme/game-music-emu/releases/download/$libgme_version/libgme-$libgme_version-src.tar.gz",
      "$packages_server/libgme-$libgme_version-src.tar.gz"
    )
    'fdk-aac' = @(
      "https://$sourceforge_mirror1/project/opencore-amr/fdk-aac/fdk-aac-$fdk_aac_version.tar.gz",
      "https://$sourceforge_mirror2/project/opencore-amr/fdk-aac/fdk-aac-$fdk_aac_version.tar.gz",
      "$packages_server/fdk-aac-$fdk_aac_version.tar.gz"
    )
    'faad2' = @(
      "https://github.com/knik0/faad2/tarball/$faad2_version/faad2-$faad2_version.tar.gz",
      "$packages_server/faad2-$faad2_version.tar.gz"
    )
    'faac' = @(
      "https://github.com/knik0/faac/archive/refs/tags/faac-$faac_version.tar.gz",
      "$packages_server/faac-$faac_version.tar.gz"
    )
    'utfcpp' = @(
      "https://github.com/nemtrif/utfcpp/archive/refs/tags/v$utfcpp_version/utfcpp-$utfcpp_version.tar.gz",
      "$packages_server/utfcpp-$utfcpp_version.tar.gz"
    )
    'taglib' = @(
      "https://taglib.org/releases/taglib-$taglib_version.tar.gz",
      "https://github.com/taglib/taglib/releases/download/v$taglib_version/taglib-$taglib_version.tar.gz",
      "$packages_server/taglib-$taglib_version.tar.gz"
    )
    'libbs2b' = @(
      "https://$sourceforge_mirror1/project/bs2b/libbs2b/$libbs2b_version/libbs2b-$libbs2b_version.tar.bz2",
      "https://$sourceforge_mirror2/project/bs2b/libbs2b/$libbs2b_version/libbs2b-$libbs2b_version.tar.bz2",
      "$packages_server/libbs2b-$libbs2b_version.tar.bz2"
    )
    'libebur128' = @(
      "https://github.com/jiixyj/libebur128/archive/refs/tags/v$libebur128_version/libebur128-$libebur128_version.tar.gz",
      "$packages_server/libebur128-$libebur128_version.tar.gz"
    )
    'libcdio' = @(
      "https://github.com/libcdio/libcdio/releases/download/$libcdio_version/libcdio-$libcdio_version.tar.bz2"
    )
    'chromaprint' = @(
      "https://github.com/acoustid/chromaprint/releases/download/v$chromaprint_version/chromaprint-$chromaprint_version.tar.gz",
      "$packages_server/chromaprint-$chromaprint_version.tar.gz"
    )
    'gstreamer' = @(
      "https://gstreamer.freedesktop.org/src/gstreamer/gstreamer-$gstreamer_version.tar.xz",
      "$packages_server/gstreamer-$gstreamer_version.tar.xz"
    )
    'gst-plugins-base' = @(
      "https://gstreamer.freedesktop.org/src/gst-plugins-base/gst-plugins-base-$gstreamer_version.tar.xz",
      "$packages_server/gst-plugins-base-$gstreamer_version.tar.xz"
    )
    'gst-plugins-good' = @(
      "https://gstreamer.freedesktop.org/src/gst-plugins-good/gst-plugins-good-$gstreamer_version.tar.xz",
      "$packages_server/gst-plugins-good-$gstreamer_version.tar.xz"
    )
    'gst-plugins-bad' = @(
      "https://gstreamer.freedesktop.org/src/gst-plugins-bad/gst-plugins-bad-$gstreamer_version.tar.xz",
      "$packages_server/gst-plugins-bad-$gstreamer_version.tar.xz"
    )
    'gst-plugins-ugly' = @(
      "https://gstreamer.freedesktop.org/src/gst-plugins-ugly/gst-plugins-ugly-$gstreamer_version.tar.xz",
      "$packages_server/gst-plugins-ugly-$gstreamer_version.tar.xz"
    )
    'gst-libav' = @(
      "https://gstreamer.freedesktop.org/src/gst-libav/gst-libav-$gstreamer_version.tar.xz",
      "$packages_server/gst-libav-$gstreamer_version.tar.xz"
    )
    'sparsehash' = @(
      "https://github.com/sparsehash/sparsehash/archive/refs/tags/sparsehash-$sparsehash_version.tar.gz",
      "$packages_server/sparsehash-$sparsehash_version.tar.gz"
    )
    'qtbase' = @(
      "https://download.qt.io/official_releases/qt/$qt_version_short/$qt_version/submodules/qtbase-everywhere-src-$qt_version.tar.xz",
      "https://$qt_mirror1/official_releases/qt/$qt_version_short/$qt_version/submodules/qtbase-everywhere-src-$qt_version.tar.xz",
      "https://$qt_mirror2/official_releases/qt/$qt_version_short/$qt_version/submodules/qtbase-everywhere-src-$qt_version.tar.xz",
      "$packages_server/qtbase-everywhere-src-$qt_version.tar.xz"
    )
    'qttools' = @(
      "https://download.qt.io/official_releases/qt/$qt_version_short/$qt_version/submodules/qttools-everywhere-src-$qt_version.tar.xz",
      "https://$qt_mirror1/official_releases/qt/$qt_version_short/$qt_version/submodules/qttools-everywhere-src-$qt_version.tar.xz",
      "https://$qt_mirror2/official_releases/qt/$qt_version_short/$qt_version/submodules/qttools-everywhere-src-$qt_version.tar.xz",
      "$packages_server/qttools-everywhere-src-$qt_version.tar.xz"
    )
    'qtimageformats' = @(
      "https://download.qt.io/official_releases/qt/$qt_version_short/$qt_version/submodules/qtimageformats-everywhere-src-$qt_version.tar.xz",
      "https://$qt_mirror1/official_releases/qt/$qt_version_short/$qt_version/submodules/qtimageformats-everywhere-src-$qt_version.tar.xz",
      "https://$qt_mirror2/official_releases/qt/$qt_version_short/$qt_version/submodules/qtimageformats-everywhere-src-$qt_version.tar.xz",
      "$packages_server/qtimageformats-everywhere-src-$qt_version.tar.xz"
    )
    'qtsvg' = @(
      "https://download.qt.io/official_releases/qt/$qt_version_short/$qt_version/submodules/qtsvg-everywhere-src-$qt_version.tar.xz",
      "https://$qt_mirror1/official_releases/qt/$qt_version_short/$qt_version/submodules/qtsvg-everywhere-src-$qt_version.tar.xz",
      "https://$qt_mirror2/official_releases/qt/$qt_version_short/$qt_version/submodules/qtsvg-everywhere-src-$qt_version.tar.xz"
    )
    'kdsingleapplication' = @(
      "https://github.com/KDAB/KDSingleApplication/releases/download/v$kdsingleapplication_version/kdsingleapplication-$kdsingleapplication_version.tar.gz",
      "$packages_server/kdsingleapplication-$kdsingleapplication_version.tar.gz"
    )
    'googletest' = @(
      "https://github.com/google/googletest/releases/download/v$googletest_version/googletest-$googletest_version.tar.gz",
      "$packages_server/googletest-$googletest_version.tar.gz"
    )
    'pe-parse' = @(
      "https://github.com/trailofbits/pe-parse/archive/refs/tags/v$peparse_version/pe-parse-$peparse_version.tar.gz",
      "$packages_server/pe-parse-$peparse_version.tar.gz"
    )
    'vc-redist-x86' = @("https://aka.ms/vc14/vc_redist.x86.exe")
    'vc-redist-x64' = @("https://aka.ms/vc14/vc_redist.x64.exe")
    'vc-redist-arm64' = @("https://aka.ms/vc14/vc_redist.arm64.exe")
  }
  return $package_urls
}

# SHA256 checksums are set in StrawberryPackageVersions.txt by scripts/update.sh when a package is updated.
# The variable name is the package name in uppercase with - replaced by _, followed by _SHA256SUM.
function GetPackageChecksum {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [string]$package_name
  )
  # The VC redistributable URLs are not versioned, so they can't have a fixed checksum.
  if ($package_name -like 'vc-redist-*') {
    return $null
  }
  $checksum_name = $package_name
  # The FFTW MinGW binary package is different for each arch and build type.
  if ($package_name -eq 'fftw-mingw') {
    $checksum_name = "$package_name-$arch-$build_type"
  }
  $checksum_variable = "$($checksum_name.ToLower().Replace('-', '_'))_sha256sum"
  $checksum = Get-Variable -Name $checksum_variable -Scope Global -ValueOnly -ErrorAction SilentlyContinue
  if (-not $checksum) {
    # patched: not an error here. The versions file has no checksum for a package upstream doesn't have (libcdio, qtsvg) and
    # for a version that is not the one its checksum was for (-VersionOverrides, the CI versions, a lock from before the
    # checksums): that download is not verified, as before upstream 56af2c1.
    Write-Host "No SHA256 checksum ($($checksum_variable.ToUpper())) for package '$package_name' at this version: the download is not verified" -ForegroundColor DarkYellow
    return $null
  }
  if ($checksum -notmatch '^[0-9a-fA-F]{64}$') {
    throw "Invalid SHA256 checksum $($checksum_variable.ToUpper()) for package '$package_name' in $version_file"
  }
  return $checksum
}

function GetGitRepoUrls {
  $git_repo_urls = @{
    'glib-networking' = "https://gitlab.gnome.org/GNOME/glib-networking"
    'qtbase' = "https://code.qt.io/qt/qtbase"
    'qttools' = "https://code.qt.io/qt/qttools"
    'qtsparkle' = "https://github.com/strawberrymusicplayer/qtsparkle"
    'libffi' = "https://gitlab.freedesktop.org/gstreamer/meson-ports/libffi"
    'ffmpeg' = "https://gitlab.freedesktop.org/gstreamer/meson-ports/ffmpeg"
    'gstreamer' = "https://gitlab.freedesktop.org/gstreamer/gstreamer"
    'gst-plugins-rs' = "https://gitlab.freedesktop.org/gstreamer/gst-plugins-rs"
    'yasm' = "https://github.com/yasm/yasm"
    'pe-util' = "https://github.com/gsauthof/pe-util"
    'akousma' = $akousma_repo
  }
  return $git_repo_urls
}

function GetPackageUrl {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [string]$package_name
  )
  $package_urls = GetPackageUrls
  if (!$package_urls.ContainsKey($package_name)) {
    throw "Package '$package_name' not found in package URLs"
  }
  return $package_urls[$package_name]
}

function GetGitRepoUrl {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [string]$git_repo_name
  )
  $git_repo_urls = GetGitRepoUrls
  if (!$git_repo_urls.ContainsKey($git_repo_name)) {
    throw "Git repo '$git_repo_name' not found in git repo URLs"
  }
  return $git_repo_urls[$git_repo_name]
}

function DownloadPackage {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [string]$package_name
  )
  Write-Host "Checking package: $package_name" -ForegroundColor Cyan
  try {
    if (-not (Test-Path $downloads_path)) {
      New-Item -ItemType Directory -Path $downloads_path -Force | Out-Null
    }
    $package_urls = GetPackageUrls
    if (!$package_urls.ContainsKey($package_name)) {
      throw "Package '$package_name' not found in dependency configuration"
    }
    $package_sha256 = GetPackageChecksum -package_name $package_name
    DownloadFileIfNotExists -urls $package_urls[$package_name] -destination_path $downloads_path -sha256 $package_sha256
    Write-Host "✓ Package $package_name is available" -ForegroundColor Green
  }
  catch {
    Write-Warning "Failed to download package $package_name : $_"
    throw
  }
}

function CloneGitRepo {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [string]$git_repo_name
  )
  Write-Host "Checking git repository: $git_repo_name" -ForegroundColor Cyan
  if (-not (Test-Path $src_path)) {
    New-Item -ItemType Directory -Path $src_path -Force | Out-Null
  }
  try {
    $git_repo_urls = GetGitRepoUrls
    if (!$git_repo_urls.ContainsKey($git_repo_name)) {
      throw "git repository '$git_repo_name' not found in dependency configuration"
    }
    $git_repo_url = $git_repo_urls[$git_repo_name]
    SyncGitRepository -url $git_repo_url -destination_path $src_path -repo_name $git_repo_name
    Write-Host "✓ Repository $git_repo_name is available" -ForegroundColor Green
  }
  catch {
    Write-Warning "Failed to clone git repository $git_repo_name : $_"
    throw
  }
}

function ExtractPackage {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [string]$package_file,

    [Parameter(Mandatory=$false)]
    [string]$package_dir,

    [Parameter(Mandatory=$false)]
    [bool]$ignore_errors = $false
  )
  if (-not $package_dir) {
    $package_dir = [System.IO.Path]::GetFileNameWithoutExtension([System.IO.Path]::GetFileNameWithoutExtension($package_file))
    if (-not $package_dir) {
      throw "Could not get filename from path $package_file"
    }
  }
  Clear-ForCleanBuild $package_dir   # patched: a clean rebuild extracts a fresh tree
  if (Test-Path $package_dir) {
    return
  }
  Write-Host "Extracting $package_file" -ForegroundColor Cyan
  $extension = [System.IO.Path]::GetExtension($package_file)
  if ($extension -eq ".gz" -or $extension -eq ".tgz" -or $extension -eq ".bz2" -or $extension -eq ".xz") {
    & $tar_cmd_path -xf "$downloads_path/$package_file" --force-local
    if ($LASTEXITCODE -ne 0) {
      if (-not $ignore_errors) {
        throw "Failed to extract $package_file"
      }
    }
  }
  else {
    throw "Unknown extension for package $package_file"
  }
}

function CMakeBuild {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$false)]
    [string]$source_path = ".",

    [Parameter(Mandatory=$false)]
    [string]$build_path = "build",

    [Parameter(Mandatory=$false)]
    [string]$cmake_build_type_override = "$cmake_build_type",

    [Parameter(Mandatory=$false)]
    [bool]$build_static_libs = $false,

    [Parameter(Mandatory=$false)]
    [bool]$build_shared_libs = $true,

    [Parameter(Mandatory=$false)]
    [string[]]$additional_args = @()
  )
  $package_name = (Get-Item -Path $PWD).Name
  Write-Host "Building $package_name with CMake" -ForegroundColor Cyan
  Clear-ForCleanBuild $build_path   # patched: clean rebuild = new build folder
  Invoke-LocalPatches -root $source_path   # patched: local patches (-package_patches), after the recipe's own
  if (-not (Test-Path $build_path)) {
    New-Item -ItemType Directory -Path $build_path -Force | Out-Null
  }
  $build_static_libs_toggle = if ($build_static_libs) { "ON" } else { "OFF" }
  $build_shared_libs_toggle = if ($build_shared_libs) { "ON" } else { "OFF" }
  $configure_args = @(
    "--log-level=$cmake_loglevel",
    "-G", "$cmake_generator",
    "-S", "$source_path",
    "-B", "$build_path",
    "-DCMAKE_BUILD_TYPE=$cmake_build_type_override",
    "-DCMAKE_PREFIX_PATH=$prefix_path/lib/cmake",
    "-DCMAKE_INSTALL_PREFIX=$prefix_path",
    "-DBUILD_STATIC_LIBS=$build_static_libs_toggle",
    "-DBUILD_SHARED_LIBS=$build_shared_libs_toggle",
    "-DPKG_CONFIG_EXECUTABLE=$script:pkg_config_exe"
  )
  if ($script:cross_build) {
    $configure_args += Get-CrossCMakeArgs   # before the recipe's own, which win
  }
  if ($additional_args) {
    $configure_args += $additional_args
  }
  if ($strawberry_perl_bin) { RemovePathFromEnvPath -path $strawberry_perl_bin }
  if ($strawberry_perl_site_bin) { RemovePathFromEnvPath -path $strawberry_perl_site_bin }
  # patched: an existing build folder configured with the same arguments is not configured again. The build re-runs CMake
  # by itself when a CMakeLists.txt or another input of the configuration changed (ninja's regeneration rule).
  $configured_file = Join-Path $build_path ".build-akousma-configure-args"
  $configured_text = ($configure_args -join "`n")
  if ((Test-Path -LiteralPath (Join-Path $build_path "CMakeCache.txt")) -and (Test-Path -LiteralPath $configured_file) -and
      ((Get-Content -Raw -LiteralPath $configured_file) -ceq $configured_text)) {
    Write-Host "CMake: $build_path is configured with these arguments already (not run again)" -ForegroundColor DarkCyan
  }
  else {
    Remove-Item -LiteralPath $configured_file -Force -ErrorAction SilentlyContinue
    Write-Host "cmake" @configure_args
    & cmake @configure_args
    if ($LASTEXITCODE -ne 0) {
      throw "CMake configuration failed"
    }
    Set-Content -LiteralPath $configured_file -Value $configured_text -NoNewline -Encoding utf8
  }
  Push-Location $build_path
  try {
    & cmake --build . --parallel $jobs
    if ($LASTEXITCODE -ne 0) {
      throw "CMake build failed"
    }
    & cmake --install .
    if ($LASTEXITCODE -ne 0) {
      throw "CMake install failed"
    }
  }
  finally {
    Pop-Location
  }
}

function MesonBuild {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$false)]
    [string]$source_path = ".",

    [Parameter(Mandatory=$false)]
    [string]$build_path = "build",

    [Parameter(Mandatory=$false)]
    [string]$default_library = "shared",

    [Parameter(Mandatory=$false)]
    [string]$pkg_config_path = "$prefix_path/lib/pkgconfig",

    [Parameter(Mandatory=$false)]
    [string]$wrap_mode = "nodownload",

    [Parameter(Mandatory=$false)]
    [string[]]$additional_args = @()
  )
  $package_name = (Get-Item -Path $PWD).Name
  Write-Host "Building $package_name with Meson" -ForegroundColor Cyan
  Push-Location $source_path
  try {
    Clear-ForCleanBuild $build_path   # patched: clean rebuild = new build folder
    Invoke-LocalPatches -root "."   # patched: local patches (-package_patches), after the recipe's own
    if ($script:cross_build -and $script:smb_component -eq "gst-plugins-rs") {
      # Rust's standard library for arm64 (quick when it is already installed). cargo gets --target from the cross file's rust entry.
      & rustup target add aarch64-pc-windows-msvc
      if ($LASTEXITCODE -ne 0) { throw "rustup target add aarch64-pc-windows-msvc failed (the arm64 cross-compile of gst-plugins-rs needs it)" }
    }
    if (-not (Test-Path "$build_path/build.ninja")) {
      $setup_args = @(
        "--buildtype=$build_type",
        "--default-library=$default_library",
        "--pkg-config-path=$pkg_config_path",
        "--includedir=$prefix_path/include",
        "--libdir=$prefix_path/lib",
        "--prefix=$prefix_path",
        "--wrap-mode=$wrap_mode",
        "-Dc_args=-I$prefix_path/include",
        "-Dcpp_args=-I$prefix_path/include",
        "-Dc_link_args=-L$prefix_path/lib",
        "-Dcpp_link_args=-L$prefix_path/lib"
      )
      if ($script:cross_build) {
        $setup_args += Get-MesonCrossArgs   # before the recipe's own, which win
      }
      if ($additional_args) {
        $setup_args += $additional_args
      }
      $setup_args += $build_path
      Write-Host "meson setup" @setup_args
      if ($strawberry_perl_bin) { RemovePathFromEnvPath -path $strawberry_perl_bin }
      if ($strawberry_perl_site_bin) { RemovePathFromEnvPath -path $strawberry_perl_site_bin }
      & meson setup @setup_args
      if ($LASTEXITCODE -ne 0) {
        throw "Meson setup failed"
      }
    }
    Push-Location $build_path
    try {
      & ninja -j $jobs
      if ($LASTEXITCODE -ne 0) {
        throw "Ninja build failed"
      }
      & ninja install
      if ($LASTEXITCODE -ne 0) {
        throw "Ninja install failed"
      }
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

# --- patched: arm64 cross-compile on an x64 PC (see $cross_build) ---
# These helpers run inside CMakeBuild / MesonBuild, whose parameters have the same names as script variables
# (MesonBuild's -build_path is the package's own "build" folder). PowerShell's dynamic scoping would give a helper the
# caller's value, so they read the script's settings as $script:build_path, $script:prefix_path, ... throughout.
function Get-CrossPackageArgs {
  # Per package, on top of the generic cross-compile settings (the recipe's own arguments come after these and win).
  switch ($script:smb_component) {
    # configure -platform win32-arm64-msvc (Qt picks it from the compiler too; this makes it explicit)
    "qtbase"  { return @("-DQT_QMAKE_TARGET_MKSPEC=win32-arm64-msvc") }
    # Akousma's dist/CMakeLists.txt reads the architecture of a cross-compile from a MinGW compiler name; with cl.exe it
    # would find none and the installer would have no architecture.
    "akousma" { return @("-DTARGET_ARCH=arm64") }
    # orc's test suite runs orcc (guarded upstream for cross builds; off here anyway, nothing uses it)
    "orc"     { return @("-Dtests=disabled", "-Dbenchmarks=disabled", "-Dexamples=disabled") }
    # jasper reads __STDC_VERSION__ by running a test program (try_run), which a cross-compile can't, and then stops unless
    # JAS_STDC_VERSION is given. It compiles with CMAKE_C_STANDARD 11, which CMake turns into -std:c11 for MSVC 19.27 and
    # later, and cl.exe defines __STDC_VERSION__ as 201112L for -std:c11 (what the native x64 / x86 builds get from try_run).
    # Untyped on purpose: jasper sets it with set(... CACHE INTERNAL), which overwrites a typed -D value with "0L".
    "jasper"  { return @("-DJAS_STDC_VERSION=201112L") }
    # chromaprint builds its test suite by default (BUILD_TESTS ON); gtest_discover_tests then runs the new all_tests.exe at
    # build time to list its tests, and the x64 PC can't run an arm64 exe. The tests aren't installed; x64 / x86 keep them.
    "chromaprint" { return @("-DBUILD_TESTS=OFF") }
    # qtimageformats' FindWrapWebP.cmake starts with find_package(WebP), whose config libwebp installs as share/WebP/cmake.
    # CMAKE_PREFIX_PATH (<arm64 prefix>/lib/cmake) doesn't reach it, so CMake next searches the prefixes of the PATH entries,
    # where the x64 prefix's bin comes first: qwebp.dll was linked against the x64 libwebp (LNK4272, unresolved WebP*). jp2
    # and tiff are fine: FindJasper / FindTIFF use find_path / find_library (CMAKE_INCLUDE_PATH / CMAKE_LIBRARY_PATH) and
    # tiff's config is in lib/cmake/tiff.
    "qtimageformats" { return @("-DWebP_DIR=$script:prefix_path/share/WebP/cmake") }
  }
  return @()
}

function Get-CrossCMakeArgs {
  # CMAKE_SYSTEM_NAME makes it a CMake cross-compile (CMAKE_CROSSCOMPILING: try_run / check_*_source_runs are not run;
  # the projects in this build skip them then). CMAKE_SYSTEM_PROCESSOR would otherwise be the x64 PC's AMD64, and projects
  # pick their CPU code from it (libjpeg-turbo: x86 SIMD with NASM instead of Arm Neon). ARM64 is what a native arm64
  # build reports. CMAKE_LIBRARY_PATH / CMAKE_INCLUDE_PATH: find_library / find_path search the arm64 prefix before the
  # folders CMake derives from PATH, where the x64 prefix's bin now comes first (not CMAKE_PREFIX_PATH: find_program would
  # then find the arm64 programs, e.g. Akousma's openssl.exe). QT_HOST_PATH: Qt's tools (moc, rcc, uic, syncqt, lrelease,
  # ...) of the same Qt version, from the x64 prefix (https://doc.qt.io/qt-6/cmake-variable-qt-host-path.html). Other
  # projects ignore the Qt variables (CMake prints "Manually-specified variables were not used").
  return @(
    "-DCMAKE_SYSTEM_NAME=Windows",
    "-DCMAKE_SYSTEM_VERSION=10.0",
    "-DCMAKE_SYSTEM_PROCESSOR=ARM64",
    "-DCMAKE_LIBRARY_PATH=$script:prefix_path/lib",
    "-DCMAKE_INCLUDE_PATH=$script:prefix_path/include",
    "-DQT_HOST_PATH=$script:host_prefix_path",
    "-DQT_HOST_PATH_CMAKE_DIR=$script:host_prefix_path/lib/cmake"
  ) + @(Get-CrossPackageArgs)
}

function Write-TextFileIfChanged([string]$path, [string]$text) {
  # Parallel packages write the same machine files: only when the content differs, and renamed into place.
  # .NET resolves a relative path against the process's working folder, not PowerShell's location: make it absolute first.
  $path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($path)
  [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($path))
  if ([System.IO.File]::Exists($path) -and ([System.IO.File]::ReadAllText($path) -ceq $text)) { return }
  $tmp = "$path.$PID.tmp"
  [System.IO.File]::WriteAllText($tmp, $text, [System.Text.UTF8Encoding]::new($false))
  [System.IO.File]::Move($tmp, $path, $true)
}

function Get-MesonCrossArgs {
  # meson's machine files for the cross-compile (https://mesonbuild.com/Cross-compilation.html), in the build folder:
  #  - cross file = the arm64 machine meson builds for. [binaries]: cl / lib / rc from the arm64 Visual Studio environment,
  #    and the programs meson runs while building, from the x64 prefix: pkg-config, and glib-compile-resources /
  #    glib-compile-schemas / orcc (the GNOME module and GStreamer's find_program look here first). rust: cargo builds for
  #    aarch64-pc-windows-msvc (gst-plugins-rs' cargo_wrapper.py passes the --target on). pkg_config_libdir: only the arm64
  #    .pc files. needs_exe_wrapper: nothing built here is run.
  #  - native file = the x64 PC (meson's build machine): the same programs, and the x64 .pc files for dependency(native: true).
  #    C/C++: meson also looks for compilers of the project's languages for the build machine (not required), and runs the
  #    sanity-check program it builds with them (sanity_check_for_c.exe; the arm64 compiler's check only compiles, because of
  #    needs_exe_wrapper). With no entry here it takes cl from PATH, which makes arm64 code: Windows can't start that and shows
  #    a modal "Machine Type Mismatch" dialog. libpsl (meson.get_compiler('c', native: true).run()) and ffmpeg (libswscale's
  #    ops_asmgen, executable(native: true)) need a working one, so it gets the x64 compiler (Get-BuildMachineMsvc). Without
  #    one: a name that doesn't exist, so meson reports "Compiler for language c for the build machine not found" and runs
  #    nothing (Assert-CrossHostTools stops libpsl and ffmpeg before the build then).
  # In the build folder of the whole build (-build_path), shared by all packages: not MesonBuild's -build_path, the
  # package's own (relative) "build" folder, which a clean rebuild removes.
  $tools = [ordered]@{ 'pkg-config' = "$script:host_prefix_path/bin/pkgconf.exe" }
  foreach ($t in 'glib-compile-resources', 'glib-compile-schemas', 'orcc') {
    if (Test-Path -LiteralPath "$script:host_prefix_path/bin/$t.exe") { $tools[$t] = "$script:host_prefix_path/bin/$t.exe" }
  }
  $binaries = ($tools.Keys | ForEach-Object { "$_ = '$($tools[$_])'" }) -join "`n"
  $cross_file = "$script:build_path/meson-cross-arm64.ini"
  $native_file = "$script:build_path/meson-native-x64.ini"
  Write-TextFileIfChanged $cross_file (@(
    "# Written by Build-Akousma.ps1: arm64 cross-compile on an x64 PC (meson setup --cross-file).",
    "[host_machine]", "system = 'windows'", "cpu_family = 'aarch64'", "cpu = 'aarch64'", "endian = 'little'", "",
    "[binaries]", "c = 'cl'", "cpp = 'cl'", "ar = 'lib'", "windres = 'rc'",
    "rust = ['rustc', '--target', 'aarch64-pc-windows-msvc']", $binaries, "",
    "[properties]", "needs_exe_wrapper = true", "pkg_config_libdir = ['$script:prefix_path/lib/pkgconfig']", ""
  ) -join "`n")
  $msvc = Get-BuildMachineMsvc
  if ($msvc) {
    $build_cc = @("c = '$($msvc.Bin)/cl.exe'", "cpp = '$($msvc.Bin)/cl.exe'", "c_ld = '$($msvc.Bin)/link.exe'",
                  "cpp_ld = '$($msvc.Bin)/link.exe'", "ar = '$($msvc.Bin)/lib.exe'")
    $link_args = "[" + (($msvc.LibPaths | ForEach-Object { "'/LIBPATH:$_'" }) -join ", ") + "]"
    $build_options = @("[built-in options]", "c_link_args = $link_args", "cpp_link_args = $link_args", "")
  }
  else {
    $build_cc = @("c = 'no-x64-build-machine-compiler'", "cpp = 'no-x64-build-machine-compiler'")
    $build_options = @()
  }
  Write-TextFileIfChanged $native_file (@(
    "# Written by Build-Akousma.ps1: the x64 PC of the arm64 cross-compile (meson setup --native-file).",
    "[binaries]") + $build_cc + @($binaries, "",
    "[properties]", "pkg_config_libdir = ['$script:host_prefix_path/lib/pkgconfig']", ""
  ) + $build_options -join "`n")
  return @("--cross-file=$cross_file", "--native-file=$native_file") + @(Get-CrossPackageArgs)
}

function Get-BuildMachineMsvc {
  # The x64 compiler for meson's build machine, from the Visual Studio of this (arm64) environment: Hostx64\x64, next to the
  # Hostx64\arm64 compiler on PATH. Its libraries: this environment's LIB has the arm64 folders (VC, UCRT, Windows SDK), so the
  # same folders with x64, for /LIBPATH, which link searches before LIB. INCLUDE is the same for x64 and arm64. Nothing in the
  # environment changes: the arm64 compiler stays as it is. $null when the x64 tools or libraries are missing.
  if (-not $env:VCToolsInstallDir) { return $null }
  $bin = (Join-Path $env:VCToolsInstallDir "bin/Hostx64/x64").Replace('\', '/')
  foreach ($exe in "cl.exe", "link.exe", "lib.exe") {
    if (-not (Test-Path -LiteralPath "$bin/$exe")) { return $null }
  }
  $lib_paths = @("$env:LIB" -split ';' | ForEach-Object {
      if ($_ -match '^(.+[\\/])arm64[\\/]?$') {
        $x64_dir = ($Matches[1] + "x64").Replace('\', '/')
        if (Test-Path -LiteralPath $x64_dir) { $x64_dir }
      }
    } | Select-Object -Unique)
  # the C runtime (VC), the Universal CRT and the Windows SDK libraries
  foreach ($lib in "msvcrt.lib", "ucrt.lib", "kernel32.lib") {
    if (-not ($lib_paths | Where-Object { Test-Path -LiteralPath "$_/$lib" })) { return $null }
  }
  return @{ Bin = $bin; LibPaths = $lib_paths }
}

function Assert-CrossHostTools([string[]]$queue) {
  # Before anything is built: the x64 programs the queued packages run, in -HostPrefixPath.
  $qt_users = @('qtbase', 'qttools', 'qtimageformats', 'qtsvg', 'kdsingleapplication', 'qtsparkle', 'akousma')
  $gst_orc = @('gstreamer', 'gst-plugins-base', 'gst-plugins-good', 'gst-plugins-bad', 'gst-plugins-ugly')
  $needs = [ordered]@{
    'bin/pkgconf.exe'                                          = @($queue)
    'bin/orcc.exe'                                             = $gst_orc
    'lib/cmake/Qt6/Qt6Config.cmake'                            = $qt_users
    'bin/moc.exe'                                              = $qt_users
    'bin/rcc.exe'                                              = $qt_users
    'bin/uic.exe'                                              = $qt_users
    'lib/cmake/Qt6LinguistTools/Qt6LinguistToolsConfig.cmake'  = @('qtsparkle', 'akousma')
    'bin/lrelease.exe'                                         = @('qtsparkle', 'akousma')
  }
  $missing = foreach ($rel in $needs.Keys) {
    $for = @($needs[$rel] | Where-Object { $queue -contains $_ })
    if ($for.Count -gt 0 -and -not (Test-Path -LiteralPath "$script:host_prefix_path/$rel")) { "  $script:host_prefix_path/$rel   (for $(Format-NameList $for))" }
  }
  # meson packages that compile and run programs for the x64 PC itself (see Get-MesonCrossArgs)
  $build_cc_users = @($queue | Where-Object { $_ -in 'libpsl', 'ffmpeg' })
  if ($build_cc_users.Count -gt 0 -and -not (Get-BuildMachineMsvc)) {
    throw ("The arm64 cross-compile of $(Format-NameList $build_cc_users) also compiles programs for the x64 PC, with Visual Studio's x64 compiler, " +
           "which this environment doesn't have complete (VC\Tools\MSVC\*\bin\Hostx64\x64\cl.exe, and x64 folders next to the arm64 ones in LIB). Visual Studio " +
           "Installer > Modify > Individual components: 'MSVC v143 - VS 2022 C++ x64/x86 build tools (Latest)' (Microsoft.VisualStudio.Component.VC.Tools.x86.x64).")
  }
  if ($missing) {
    throw ("The arm64 cross-compile runs x64 programs from the x64 prefix (-HostPrefixPath), and these are missing:`n" + ($missing -join "`n") +
           "`nBuild x64 first with the same settings (-Arch x64, or -Arch x64,arm64 for both), or pass -HostPrefixPath <x64 prefix>.")
  }
  if (@($qt_users | Where-Object { $queue -contains $_ }).Count -gt 0) {
    # Qt's host tools must be the same Qt version as the Qt being built.
    $host_qt = $null
    foreach ($f in "Qt6ConfigVersionImpl.cmake", "Qt6ConfigVersion.cmake") {
      $path = "$script:host_prefix_path/lib/cmake/Qt6/$f"
      if ((Test-Path -LiteralPath $path) -and ((Get-Content -Raw -LiteralPath $path) -match 'set\(PACKAGE_VERSION "([^"]+)"\)')) { $host_qt = $Matches[1]; break }
    }
    # $qt_version as everywhere else, not $script:qt_version: the versions are global variables (Set-Variable -Scope Global
    # where the versions file, -CiVersionsFile and -VersionOverrides are read), so the script scope has none.
    if ($host_qt -and $host_qt -ne $qt_version) {
      throw "The x64 prefix $script:host_prefix_path has Qt $host_qt, the arm64 build is Qt ${qt_version}: Qt's tools have to be the same version. Rebuild x64 first (-Arch x64) with the same versions."
    }
  }
  Write-Host "Cross-compile: arm64 on an x64 PC, with the x64 programs from $script:host_prefix_path" -ForegroundColor Cyan
}

function UpgradeVSProject {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [string]$project_path
  )
  Write-Host "Upgrading Visual Studio project: $project_path" -ForegroundColor Cyan
  if (-not $vs_dev_env_path) {
    throw "Could not locate devenv.com"
  }
  Start-Process -FilePath "$vs_dev_env_path" -ArgumentList "$project_path /upgrade" -Wait -NoNewWindow
}

function MSBuildProject {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [string]$project_path,

    [Parameter(Mandatory=$false)]
    [string]$configuration = "${build_type}DLL",

    [Parameter(Mandatory=$false)]
    [string]$platform = "$msbuild_platform",

    [Parameter(Mandatory=$false)]
    [string[]]$additional_args = @()
  )
  Write-Host "Building $project_path with MSBuild" -ForegroundColor Cyan
  # -m projects each running cl /MP would multiply to jobs^2 compiler processes; keep the product near $jobs
  $msbuild_cl_mp = [Math]::Max(1, [int][Math]::Ceiling($jobs / [Math]::Max(1, [Math]::Sqrt($jobs))))
  $build_args = @(
    $project_path,
    "-p:Configuration=$configuration",
    "-p:Platform=$platform",
    "-p:UseEnv=true",
    "-m:$jobs",
    "-p:CL_MPCount=$msbuild_cl_mp"
  )
  if ($additional_args) {
    $build_args += $additional_args
  }
  # --- patched: arm64 cross-compile ---
  # ICU's data build (source/data/makedata.mak) runs ICU's own tools. For an ARM64 configuration on an x64 PC it takes the
  # x64 ones from the same tree (tools\*\x64\<configuration>, bin64; "ARM_CROSS_BUILD" in makedata.mak), so the x64
  # configuration is built first: with MSBuild's own x64 settings (UseEnv=false), as the environment is the arm64 one.
  if ($script:cross_build -and $script:smb_component -eq "icu4c" -and $platform -eq $script:msbuild_platform) {
    Write-Host "Building $project_path for x64 first: ICU makes its ARM64 data with its x64 tools" -ForegroundColor Cyan
    & msbuild $project_path "-p:Configuration=$configuration" "-p:Platform=x64" "-p:UseEnv=false" "-m:$jobs" "-p:CL_MPCount=$msbuild_cl_mp" @additional_args
    if ($LASTEXITCODE -ne 0) {
      throw "MSBuild failed (the x64 build of ICU's tools for the arm64 cross-compile)"
    }
  }
  # ICU's allinone\Build.Windows.ProjectConfiguration.props pins WindowsTargetPlatformVersion 10.0.22621.0 for ARM and ARM64
  # (x64 and Win32 get "10.0", the newest SDK installed): without that SDK, MSB8036 stops the ARM64 build at its first project.
  # The ARM64 build compiles and links with this environment's INCLUDE / LIB (UseEnv=true), i.e. the SDK the Visual Studio
  # environment chose ($env:WindowsSDKVersion), so MSBuild gets that version too, whether 10.0.22621.0 is installed or not:
  # one SDK for headers, libraries and MSBuild's own SDK checks. A command-line property overrides the props file.
  # The x64 tools build above keeps ICU's "10.0".
  if ($script:smb_component -eq "icu4c" -and $platform -eq "arm64") {
    $sdk_version = "$env:WindowsSDKVersion".Trim().TrimEnd('\', '/')
    if ($sdk_version -match '^\d+\.\d+\.\d+\.\d+$') {
      Write-Host "ICU ARM64: Windows SDK $sdk_version (this environment's) instead of ICU's 10.0.22621.0" -ForegroundColor Cyan
      $build_args += "-p:WindowsTargetPlatformVersion=$sdk_version"
    }
    else {
      Write-Warning "ICU ARM64: WindowsSDKVersion is not set in this environment ('$env:WindowsSDKVersion'); MSBuild uses ICU's Windows SDK 10.0.22621.0."
    }
  }
  & msbuild @build_args
  if ($LASTEXITCODE -ne 0) {
    throw "MSBuild failed"
  }
}

function CreatePkgConfigFile {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [string]$name,

    [Parameter(Mandatory=$true)]
    [string]$description,

    [Parameter(Mandatory=$false)]
    [string]$url,

    [Parameter(Mandatory=$true)]
    [string]$version,

    [Parameter(Mandatory=$true)]
    [string]$prefix,

    [Parameter(Mandatory=$false)]
    [string]$libs = "",

    [Parameter(Mandatory=$false)]
    [string]$libs_private = "",

    [Parameter(Mandatory=$false)]
    [string]$cflags = "",

    [Parameter(Mandatory=$false)]
    [string]$requires = "",

    [Parameter(Mandatory=$true)]
    [string]$output_file
  )

  $pc_dir = Split-Path -Path $output_file -Parent
  if (-not (Test-Path $pc_dir)) {
    New-Item -ItemType Directory -Path $pc_dir -Force | Out-Null
  }

  $content = @"
prefix=$prefix
exec_prefix=`${prefix}
libdir=`${exec_prefix}/lib
includedir=`${prefix}/include

Name: $name
Description: $description

"@

  if ($url) {
    $content += "Url: ${url}`n"
  }

  $content += "Version: ${version}`n"

  if ($requires) {
    $content += "Requires: ${requires}`n"
  }

  if ($libs) {
    $content += "Libs: ${libs}`n"
  }

  if ($libs_private) {
    $content += "Libs.private: ${libs_private}`n"
  }

  if ($cflags) {
    $content += "Cflags: ${cflags}`n"
  }

  Set-Content -Path $output_file -Value $content -Encoding ASCII
}

function CreateLibFile() {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [string]$name
  )

  $def = "${name}.def"
  $dll = "${name}.dll"

  # Create/overwrite the .def header
  @(
    "LIBRARY $dll"
    "EXPORTS"
  ) | Set-Content -Encoding ASCII $def

  # Append exported symbol names from dumpbin output
  dumpbin /exports $dll |
    Select-Object -Skip 19 |
    ForEach-Object {
      # Split on whitespace; token 4 in cmd for/f == index 3 here
      $parts = ($_ -split '\s+')
      if ($parts.Length -ge 4) { $parts[3] }
    } |
    Where-Object { $_ } |
    Add-Content -Encoding ASCII $def

  # Build the import library from the .def
  & lib /machine:$lib_machine /def:$def

}


#region Build Functions

function Build-PkgConf {
  Write-Host "Building pkgconf" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "pkgconf"
    ExtractPackage "pkgconf-$pkgconf_version.tar.gz"
    Push-Location "pkgconf-pkgconf-$pkgconf_version"
    try {
      MesonBuild
      Copy-Item "$prefix_path/bin/pkgconf.exe" "$prefix_path/bin/pkg-config.exe" -Force
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-Yasm {
  Write-Host "Building yasm" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    CloneGitRepo -git_repo_name "yasm"
    if (-not (Test-Path "yasm")) {
      RecursiveCopy "$src_path/yasm" "$build_path/yasm"
    }
    Push-Location "yasm"
    try {
      CMakeBuild
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-ProxyIntl {
  Write-Host "Building proxy-libintl" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "proxy-libintl"
    ExtractPackage "proxy-libintl-$proxy_libintl_version.tar.gz" -ignore_errors $true
    Push-Location "proxy-libintl-$proxy_libintl_version"
    try {
      MesonBuild
      CreatePkgConfigFile -prefix $prefix_path -name "libintl" -description "libintl" -url "https://github.com/frida/proxy-libintl" -version $proxy_libintl_version -libs "-L`${libdir} -lintl" -cflags "-I`${includedir}" -output_file "$prefix_path/lib/pkgconfig/intl.pc"
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-GetOptWin {
  Write-Host "Building getopt-win" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "getopt-win"
    ExtractPackage "getopt-win-$getopt_win_version.tar.gz"
    Push-Location "getopt-win-$getopt_win_version"
    try {
      CMakeBuild -additional_args @(
          "-DBUILD_SHARED_LIB=ON",
          "-DBUILD_STATIC_LIB=OFF",
          "-DBUILD_TESTING=OFF"
        )
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-ZLib {
  Write-Host "Building zlib" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "zlib"
    ExtractPackage "zlib-$zlib_version.tar.gz"
    Push-Location "zlib-$zlib_version"
    try {
      CMakeBuild
      if ($build_type -eq "debug") {
        & sed -i 's/-lz$/-lzd/g' "$prefix_path/lib/pkgconfig/zlib.pc"
      }
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-OpenSSL {
  Write-Host "Building OpenSSL" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    if ($strawberry_perl_bin) { PrependPathToEnvPath -path $strawberry_perl_bin }
    if ($strawberry_perl_site_bin) { PrependPathToEnvPath -path $strawberry_perl_site_bin }
    DownloadPackage -package_name "openssl"
    ExtractPackage "openssl-$openssl_version.tar.gz"
    Push-Location "openssl-$openssl_version"
    try {
      $is_debug = $build_type -eq "debug"
      $build_flag = if ($is_debug) { "--debug" } else { "--release" }
      # VC-WIN64-ARM replaces the inherited ex_libs with onecore.lib, dropping the zlib library, so add it back with LDLIBS.
      $ldlibs_args = @()
      if ($arch -eq "arm64") { $ldlibs_args += "LDLIBS=onecore.lib $prefix_path/lib/libz${lib_postfix}.lib" }
      & perl Configure $openssl_platform shared zlib no-tests --prefix="$prefix_path" --libdir=lib --openssldir="$prefix_path/ssl" $build_flag --with-zlib-include="$prefix_path/include" --with-zlib-lib="$prefix_path/lib/libz${lib_postfix}.lib" @ldlibs_args /FS
      if ($LASTEXITCODE -ne 0) { throw "OpenSSL configure failed" }
      Invoke-NMake
      if ($LASTEXITCODE -ne 0) { throw "OpenSSL build failed" }
      & nmake install_sw   # serial on purpose: parallel jom races on OpenSSL Makefile [depend] (rename Permission denied)
      if ($LASTEXITCODE -ne 0) { throw "OpenSSL install failed" }
      Copy-Item "$prefix_path/lib/libssl.lib" "$prefix_path/lib/ssl.lib" -Force
      Copy-Item "$prefix_path/lib/libcrypto.lib" "$prefix_path/lib/crypto.lib" -Force
      Copy-Item "exporters/*.pc" "$prefix_path/lib/pkgconfig" -Force
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-LibPNG {
  Write-Host "Building libpng" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "libpng"
    ExtractPackage "libpng-$libpng_version.tar.gz"
    Push-Location "libpng-$libpng_version"
    try {
      & patch -p1 -N -i "$patch_path/libpng-pkgconf.patch" 2>&1 | Out-Null
      CMakeBuild
      Remove-Item "$prefix_path/lib/libpng16_static${lib_postfix}.lib" -Force -ErrorAction SilentlyContinue
      if ($build_type -eq "debug") {
        Copy-Item "$prefix_path/lib/libpng16d.lib" "$prefix_path/lib/png16.lib" -Force
      }
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-LibJPEGTurbo {
  Write-Host "Building libjpeg-turbo" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "libjpeg-turbo"
    ExtractPackage "libjpeg-turbo-$libjpeg_turbo_version.tar.gz"
    Push-Location "libjpeg-turbo-$libjpeg_turbo_version"
    try {
      CMakeBuild -additional_args @(
          "-DENABLE_SHARED=ON",
          "-DENABLE_STATIC=OFF",
          "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"
        )
      Remove-Item "$prefix_path/lib/jpeg-static.lib" -Force -ErrorAction SilentlyContinue
      Remove-Item "$prefix_path/lib/turbojpeg-static.lib" -Force -ErrorAction SilentlyContinue
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-PCRE2 {
  Write-Host "Building pcre2" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "pcre2"
    ExtractPackage "pcre2-$pcre2_version.tar.gz"
    Push-Location "pcre2-$pcre2_version"
    try {
      CMakeBuild -additional_args @(
          "-DPCRE2_BUILD_PCRE2_16=ON",
          "-DPCRE2_BUILD_PCRE2_32=ON",
          "-DPCRE2_BUILD_PCRE2_8=ON",
          "-DPCRE2_BUILD_TESTS=OFF",
          "-DPCRE2_SUPPORT_UNICODE=ON"
        )
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-BZip2 {
  Write-Host "Building bzip2" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "bzip2"
    ExtractPackage "bzip2-$bzip2_version.tar.gz"
    Push-Location "bzip2-$bzip2_version"
    try {
      & patch -p1 -N -i "$patch_path/bzip2-cmake.patch" 2>&1 | Out-Null
      CMakeBuild -build_path "build2" -additional_args @("-DCMAKE_POLICY_VERSION_MINIMUM=3.5")
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-XZ {
  Write-Host "Building xz" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "xz"
    ExtractPackage "xz-$xz_version.tar.gz"
    Push-Location "xz-$xz_version"
    try {
      CMakeBuild -additional_args @(
          "-DBUILD_TESTING=OFF",
          "-DXZ_NLS=OFF"
        )
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-Brotli {
  Write-Host "Building brotli" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "brotli"
    ExtractPackage "brotli-$brotli_version.tar.gz"
    Push-Location "brotli-$brotli_version"
    try {
      CMakeBuild -build_path "build2" -additional_args @("-DBUILD_TESTING=OFF")
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-UChardet {
  Write-Host "Building uchardet" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "uchardet"
    ExtractPackage "uchardet-$uchardet_version.tar.xz"
    Push-Location "uchardet-$uchardet_version"
    try {
      CMakeBuild -additional_args @(
          "-DBUILD_STATIC=OFF",
          "-DBUILD_BINARY=OFF",
          "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"
        )
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-ICU4C {
  Write-Host "Building icu4c" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "icu4c"
    ExtractPackage "icu4c-$icu4c_version-sources.tgz" "icu"
    Push-Location "icu/source/allinone"
    try {
      MSBuildProject -project_path "allinone.sln" -configuration "$build_type" -additional_args @("-p:SkipUWP=true")
    }
    finally {
      Pop-Location
    }
    Push-Location "icu"
    try {
      if (-not (Test-Path "include")) {
        throw "Missing icu4c include dir"
      }
      Copy-Item "include/unicode" "$prefix_path/include/" -Recurse -Force
      Copy-Item "$libdir/*.*" "$prefix_path/lib/" -Force
      Copy-Item "$bindir/*.*" "$prefix_path/bin/" -Force
      CreatePkgConfigFile -prefix $prefix_path -name "icu-uc" -description "International Components for Unicode: Common and Data libraries" -version $icu4c_version -libs "-L`${libdir} -licuuc$lib_postfix -licudt" -libs_private "-lpthread -lm" -output_file "$prefix_path/lib/pkgconfig/icu-uc.pc"
      CreatePkgConfigFile -prefix $prefix_path -name "icu-i18n" -description "International Components for Unicode: Stream and I/O Library" -version $icu4c_version -libs "-licuin$lib_postfix" -requires "icu-uc" -output_file "$prefix_path/lib/pkgconfig/icu-i18n.pc"
      CreatePkgConfigFile -prefix $prefix_path -name "icu-io" -description "International Components for Unicode: Stream and I/O Library" -version $icu4c_version -libs "-licuio$lib_postfix" -requires "icu-i18n" -output_file "$prefix_path/lib/pkgconfig/icu-io.pc"
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-Pixman {
  Write-Host "Building pixman" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "pixman"
    ExtractPackage "pixman-$pixman_version.tar.gz" -ignore_errors $true
    Push-Location "pixman-$pixman_version"
    try {
      $pixman_args = @("-Dgtk=disabled", "-Dlibpng=enabled")
      # pixman enables MMX for any MSVC build, but the MMX intrinsics are x86 only.
      if ($arch -eq "arm64") { $pixman_args += "-Dmmx=disabled" }
      MesonBuild -additional_args $pixman_args
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-Expat {
  Write-Host "Building expat" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "expat"
    ExtractPackage "expat-$expat_version.tar.gz"
    Push-Location "expat-$expat_version"
    try {
      CMakeBuild -additional_args @(
          "-DEXPAT_BUILD_DOCS=OFF",
          "-DEXPAT_BUILD_EXAMPLES=OFF",
          "-DEXPAT_BUILD_FUZZERS=OFF",
          "-DEXPAT_BUILD_TESTS=OFF",
          "-DEXPAT_BUILD_TOOLS=OFF",
          "-DEXPAT_BUILD_PKGCONFIG=ON"
        )
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}


function Build-LibXML2 {
  Write-Host "Building libxml2" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "libxml2"
    ExtractPackage "libxml2-$libxml2_version.tar.xz"
    Push-Location "libxml2-$libxml2_version"
    try {
      CMakeBuild -additional_args @(
          "-DLIBXML2_WITH_PYTHON=OFF",
          "-DLIBXML2_WITH_ZLIB=ON",
          "-DLIBXML2_WITH_LZMA=ON",
          "-DLIBXML2_WITH_ICONV=OFF",
          "-DLIBXML2_WITH_ICU=ON",
          "-DLIBXML2_WITH_REGEXPS=ON",
          "-DLIBXML2_WITH_HTML=ON",
          "-DICU_ROOT=$prefix_path"
        )
      if ($build_type -eq "debug") {
        Copy-Item "$prefix_path/lib/libxml2d.lib" "$prefix_path/lib/libxml2.lib" -Force
      }
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-NgHttp2 {
  Write-Host "Building nghttp2" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "nghttp2"
    ExtractPackage "nghttp2-$nghttp2_version.tar.gz"
    Push-Location "nghttp2-$nghttp2_version"
    try {
      CMakeBuild
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-LibFFI {
  Write-Host "Building libffi" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    CloneGitRepo "libffi"
    if (-not (Test-Path "libffi")) {
      RecursiveCopy "$src_path/libffi" "libffi"
    }
    Push-Location "libffi"
    try {
      MesonBuild
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-DlfcnWin32 {
  Write-Host "Building dlfcn-win32" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "dlfcn-win32"
    ExtractPackage "dlfcn-win32-$dlfcn_version.tar.gz"
    Push-Location "dlfcn-win32-$dlfcn_version"
    try {
      CMakeBuild
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-LibPSL {
  Write-Host "Building libpsl" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "libpsl"
    ExtractPackage "libpsl-$libpsl_version.tar.gz"
    Push-Location "libpsl-$libpsl_version"
    try {
      MesonBuild `
        -additional_args @(
          "-Druntime=libicu"
        )
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-Orc {
  Write-Host "Building orc" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "orc"
    ExtractPackage "orc-$orc_version.tar.xz"
    Push-Location "orc-$orc_version"
    try {
      MesonBuild
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-SQLite {
  Write-Host "Building sqlite" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "sqlite"
    ExtractPackage "sqlite-autoconf-$sqlite_version.tar.gz"
    Push-Location "sqlite-autoconf-$sqlite_version"
    try {
      & cl -DSQLITE_API="__declspec(dllexport)" -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_COLUMN_METADATA sqlite3.c -link -dll -out:sqlite3.dll
      if ($LASTEXITCODE -ne 0) { throw "SQLite DLL build failed" }
      & cl shell.c sqlite3.c -Fe:sqlite3.exe
      if ($LASTEXITCODE -ne 0) { throw "SQLite shell build failed" }
      Copy-Item "*.h" "$prefix_path/include/" -Force
      Copy-Item "*.lib" "$prefix_path/lib/" -Force
      Copy-Item "*.dll" "$prefix_path/bin/" -Force
      Copy-Item "*.exe" "$prefix_path/bin/" -Force
      CreatePkgConfigFile -prefix $prefix_path -name "SQLite" -description "SQL database engine" -url "https://www.sqlite.org/" -version $sqlite_version -libs "-L`${libdir} -lsqlite3" -cflags "-I`${includedir}" -output_file "$prefix_path/lib/pkgconfig/sqlite3.pc"
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-Glib {
  Write-Host "Building glib" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "glib"
    ExtractPackage "glib-$glib_version.tar.xz" -ignore_errors $true
    Push-Location "glib-$glib_version"
    try {
      MesonBuild `
        -additional_args @(
          "-Dtests=false"
        )
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-LibSoup {
  Write-Host "Building libsoup" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "libsoup"
    ExtractPackage "libsoup-$libsoup_version.tar.xz"
    Push-Location "libsoup-$libsoup_version"
    try {
      MesonBuild `
        -additional_args @(
          "-Dtests=false",
          "-Dvapi=disabled",
          "-Dgssapi=disabled",
          "-Dintrospection=disabled",
          "-Dsysprof=disabled",
          "-Dtls_check=false"
        )
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-GlibNetworking {
  Write-Host "Building glib-networking" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    CloneGitRepo -git_repo_name "glib-networking"
    RecursiveCopy "$src_path/glib-networking" "glib-networking"
    Push-Location "glib-networking"
    try {
      & patch -p1 -N --batch -i $patch_path/glib-networking.patch
      if ($LASTEXITCODE -ne 0) { throw "Failed to apply glib-networking.patch (is glib-networking pinned to the commit the patch was written for?)" }
      MesonBuild `
        -additional_args @(
          "-Dgnutls=disabled",
          "-Dopenssl=enabled",
          "-Dgnome_proxy=disabled",
          "-Dlibproxy=disabled",
          "-Dtests=false"
        )
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-Freetype {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [bool]$with_harfbuzz
  )
  $harfbuzz_type = if ($with_harfbuzz) { "with harfbuzz" } else { "without harfbuzz" }
  Write-Host "Building freetype $harfbuzz_type" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "freetype"
    ExtractPackage "freetype-$freetype_version.tar.gz"
    Push-Location "freetype-$freetype_version"
    try {
      $disable_harfbuzz = if ($with_harfbuzz) { "OFF" } else { "ON" }
      CMakeBuild -additional_args @("-DFT_DISABLE_HARFBUZZ=$disable_harfbuzz")
      if ($build_type -eq "debug") {
        Copy-Item "$prefix_path/lib/freetyped.lib" "$prefix_path/lib/freetype.lib" -Force
      }
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-Harfbuzz {
  Write-Host "Building harfbuzz" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "harfbuzz"
    ExtractPackage "harfbuzz-$harfbuzz_version.tar.xz"
    Push-Location "harfbuzz-$harfbuzz_version"
    try {
      MesonBuild `
        -additional_args @(
          "-Dcpp_std=c++17",
          "-Dtests=disabled",
          "-Ddocs=disabled",
          "-Dfreetype=enabled",
          "-Dicu=enabled",
          "-Dcairo=disabled",
          "-Dutilities=disabled"
        )
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
  Build-Freetype -with_harfbuzz $true
}

function Build-Jasper {
  Write-Host "Building jasper" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "jasper"
    ExtractPackage "jasper-$jasper_version.tar.gz" -ignore_errors $true
    & sed -i '/include(InstallRequiredSystemLibraries)/d' "jasper-$jasper_version/CMakeLists.txt"
    CMakeBuild -source_path "jasper-$jasper_version" -build_path "jasper-$jasper_version-build" -additional_args @(
      "-DJAS_ENABLE_JP2_CODEC=ON",
      "-DJAS_ENABLE_JPC_CODEC=ON",
      "-DJAS_ENABLE_JPG_CODEC=ON",
      "-DJAS_ENABLE_LIBJPEG=ON",
      "-DJAS_ENABLE_OPENGL=ON",
      "-DJAS_INCLUDE_BMP_CODEC=ON",
      "-DJAS_INCLUDE_JP2_CODEC=ON",
      "-DJAS_INCLUDE_JPC_CODEC=ON",
      "-DJAS_INCLUDE_JPG_CODEC=ON"
    )
  }
  finally {
    Pop-Location
  }
}

function Build-Tiff {
  Write-Host "Building tiff" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "tiff"
    ExtractPackage "tiff-$tiff_version.tar.gz"
    Push-Location "tiff-$tiff_version"
    try {
      CMakeBuild -additional_args @(
        "-Djpeg=ON",
        "-Dtiff-static=OFF",
        "-Dtiff-docs=OFF",
        "-Dtiff-tests=OFF"
      )
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-LibWebP {
  Write-Host "Building libwebp" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "libwebp"
    ExtractPackage "libwebp-$libwebp_version.tar.gz"
    Push-Location "libwebp-$libwebp_version"
    try {
      CMakeBuild -additional_args @(
        "-DWEBP_LINK_STATIC=OFF",
        "-DWEBP_UNICODE=ON",
        "-DWEBP_USE_THREAD=ON"
      )
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-Ogg {
  Write-Host "Building libogg" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "libogg"
    ExtractPackage "libogg-$libogg_version.tar.gz"
    Push-Location "libogg-$libogg_version"
    try {
      CMakeBuild -additional_args @(
          "-DINSTALL_DOCS=OFF",
          "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"
        )
      Write-Host "libogg built successfully!" -ForegroundColor Green
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-Vorbis {
  Write-Host "Building libvorbis" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "libvorbis"
    ExtractPackage "libvorbis-$libvorbis_version.tar.gz"
    Push-Location "libvorbis-$libvorbis_version"
    try {
      CMakeBuild -additional_args @(
          "-DINSTALL_DOCS=OFF",
          "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"
        )
      Write-Host "libvorbis built successfully!" -ForegroundColor Green
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-Flac {
  Write-Host "Building flac" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "flac"
    ExtractPackage "flac-$flac_version.tar.xz"
    Push-Location "flac-$flac_version"
    try {
      CMakeBuild -build_path "build2" -additional_args @(
          "-DBUILD_DOCS=OFF",
          "-DBUILD_EXAMPLES=OFF",
          "-DINSTALL_MANPAGES=OFF",
          "-DBUILD_TESTING=OFF",
          "-DBUILD_PROGRAMS=OFF"
        )
      Write-Host "flac built successfully!" -ForegroundColor Green
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-WavPack {
  Write-Host "Building wavpack" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "wavpack"
    ExtractPackage "wavpack-$wavpack_version.tar.bz2"
    Push-Location "wavpack-$wavpack_version"
    try {
      CMakeBuild -additional_args @(
            "-DBUILD_TESTING=OFF",
            "-DWAVPACK_BUILD_DOCS=OFF",
            "-DWAVPACK_BUILD_PROGRAMS=OFF",
            "-DWAVPACK_ENABLE_ASM=OFF",
            "-DWAVPACK_ENABLE_LEGACY=OFF",
            "-DWAVPACK_BUILD_WINAMP_PLUGIN=OFF",
            "-DWAVPACK_BUILD_COOLEDIT_PLUGIN=OFF"
          )
      Copy-Item "$prefix_path/lib/wavpackdll.lib" "$prefix_path/lib/wavpack.lib" -Force
      Write-Host "wavpack built successfully!" -ForegroundColor Green
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-Opus {
  Write-Host "Building opus" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "opus"
    ExtractPackage "opus-$opus_version.tar.gz"
    Push-Location "opus-$opus_version"
    try {
      # Remove problematic line from CMakeLists.txt
      & sed -i '/include(opus_buildtype.cmake)/d' CMakeLists.txt
      & patch -p1 -N -i "$patch_path/opus-cmake.patch"
      CMakeBuild
      Write-Host "opus built successfully!" -ForegroundColor Green
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-Opusfile {
  Write-Host "Building opusfile" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "opusfile"
    ExtractPackage "opusfile-$opusfile_version.tar.gz"
    Push-Location "opusfile-$opusfile_version"
    try {
      & patch -p1 -N -i $patch_path/opusfile-cmake.patch
      CMakeBuild -additional_args @("-DCMAKE_POLICY_VERSION_MINIMUM=3.5")
      Write-Host "opusfile built successfully!" -ForegroundColor Green
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-Speex {
  Write-Host "Building speex" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "speex"
    ExtractPackage "speex-Speex-$speex_version.tar.gz"
    Push-Location "speex-Speex-$speex_version"
    try {
      & patch -p1 -N -i "$patch_path/speex-cmake.patch"
      CMakeBuild
      if ($build_type -eq "debug") {
        Copy-Item "$prefix_path/lib/libspeexd.lib" "$prefix_path/lib/libspeex.lib" -Force
        Copy-Item "$prefix_path/bin/libspeexd.dll" "$prefix_path/bin/libspeex.dll" -Force
      }
      Write-Host "speex built successfully!" -ForegroundColor Green
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-MPG123 {
  Write-Host "Building mpg123" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "mpg123"
    ExtractPackage "mpg123-$mpg123_version.tar.bz2"
    Push-Location "mpg123-$mpg123_version"
    try {
      CMakeBuild -source_path "ports/cmake" -build_path "build2" -additional_args @(
          "-DBUILD_PROGRAMS=OFF",
          "-DBUILD_LIBOUT123=OFF",
          "-DYASM_ASSEMBLER=$prefix_path/bin/vsyasm.exe"
        )
      Write-Host "mpg123 built successfully!" -ForegroundColor Green
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }

}

function Build-Lame {
  Write-Host "Building lame" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "lame"
    ExtractPackage "lame-$lame_version.tar.gz"
    Push-Location "lame-$lame_version"
    try {
      & patch -p1 -N -i "$patch_path/lame-msvc.patch"
      & nmake -f Makefile.MSVC MSVCVER=${lame_msvcver} @lame_make_args libmp3lame.dll
      if ($LASTEXITCODE -ne 0) { throw "nmake build failed" }
      New-Item -Path "$prefix_path/include/lame" -ItemType Directory -Force
      Copy-Item "include/lame.h" "$prefix_path/include/lame/" -Force
      Copy-Item "output/libmp3lame.lib" "$prefix_path/lib/" -Force
      Copy-Item "output/libmp3lame.dll" "$prefix_path/bin/" -Force
      Copy-Item "$prefix_path/lib/libmp3lame.lib" "$prefix_path/lib/mp3lame.lib" -Force
      CreatePkgConfigFile -prefix $prefix_path -name "lame" -description "encoder that converts audio to the MP3 file format." -url "https://lame.sourceforge.io/" -version $lame_version -libs "-L`${libdir} -lmp3lame" -cflags "-I`${includedir}" -output_file "$prefix_path/lib/pkgconfig/lame.pc"
      Copy-Item "$prefix_path/lib/pkgconfig/lame.pc" "$prefix_path/lib/pkgconfig/libmp3lame.pc" -Force
      Write-Host "lame built successfully!" -ForegroundColor Green
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-FFTW3 {
  Write-Host "Building fftw3" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    # There is no MinGW-W64 binary package for arm64 or x86 (fftw3-mingw-cross only publishes x86_64), so build it from source
    # with CMake
    if ($arch -eq "arm64" -or $arch -eq "x86") {
      DownloadPackage -package_name "fftw-source"
      ExtractPackage "fftw-$fftw_source_version.tar.gz"
      Push-Location "fftw-$fftw_source_version"
      try {
        & patch -p1 -N -i "$patch_path/fftw-fixes.patch"
        CMakeBuild -additional_args @(
          "-DBUILD_TESTS=OFF",
          "-DENABLE_THREADS=ON",
          "-DWITH_COMBINED_THREADS=ON",
          "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"
        )
      }
      finally {
        Pop-Location
      }
      return
    }
    # It's recommended to build FFTW3 with MinGW-W64 so we use a binary package built on GitHub
    DownloadPackage -package_name "fftw-mingw"
    ExtractPackage "fftw-${arch}-w64-mingw32-${build_type}-${fftw_mingw_version}.tar.xz"
    Push-Location "fftw-${arch}-w64-mingw32-${build_type}-${fftw_mingw_version}/lib"
    try {
      # Generate .lib file from .def
      if ((-not (Test-Path "fftw3.def")) -and (Test-Path "libfftw3-3.def")) {
        Copy-Item "libfftw3-3.def" "fftw3.def" -Force
      }
      & lib /machine:$lib_machine /def:fftw3.def
      if ($LASTEXITCODE -ne 0) { throw "lib.exe failed to create import library" }
    }
    finally {
      Pop-Location
    }
    RecursiveCopy "fftw-${arch}-w64-mingw32-${build_type}-${fftw_mingw_version}" "$prefix_path"
    & sed -i "s,^prefix=.*,prefix=${prefix_path},g" "$prefix_path/lib/pkgconfig/fftw3.pc"
    & sed -i "s,^exec_prefix=.*,exec_prefix=${prefix_path},g" "$prefix_path/lib/pkgconfig/fftw3.pc"
    & sed -i "s,^libdir=.*,libdir=${prefix_path}/lib,g" "$prefix_path/lib/pkgconfig/fftw3.pc"
    & sed -i "s,^includedir=.*,includedir=${prefix_path}/include,g" "$prefix_path/lib/pkgconfig/fftw3.pc"
  }
  finally {
    Pop-Location
  }
}

function Build-Musepack {
  Write-Host "Building musepack" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "musepack"
    ExtractPackage "musepack_src_r$musepack_version.tar.gz"
    Push-Location "musepack_src_r$musepack_version"
    try {
      & patch -p1 -N -i $patch_path/musepack-fixes.patch
      CMakeBuild -additional_args @(
          "-DSHARED=ON",
          "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"
        )
      Copy-Item "build/libmpcdec/*.lib" "$prefix_path/lib/" -Force -ErrorAction SilentlyContinue
      Copy-Item "build/libmpcdec/*.dll" "$prefix_path/bin/" -Force -ErrorAction SilentlyContinue
      CreatePkgConfigFile -prefix $prefix_path -name "MusePack" -description "MusePack" -url "https://www.musepack.net/" -version $musepack_version -libs "-L`${libdir} -lmpcdec" -cflags "-I`${includedir}" -output_file "$prefix_path/lib/pkgconfig/mpcdec.pc"
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-LibOpenMPT {
  Write-Host "Building libopenmpt" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "libopenmpt"
    if (-not (Test-Path "libopenmpt")) {
      $zip_file = "$downloads_path/libopenmpt-$libopenmpt_version+release.msvc.zip"
      Write-Host "Extracting $zip_file" -ForegroundColor Cyan
      New-Item -ItemType Directory -Path "libopenmpt" -Force | Out-Null
      Push-Location "libopenmpt"
      try {
        & 7z x $zip_file
        if ($LASTEXITCODE -ne 0) { throw "Failed to extract libopenmpt archive" }
      }
      finally {
        Pop-Location
      }
    }
    Push-Location "libopenmpt"
    try {
      & patch -p1 -N -i $patch_path/libopenmpt-cmake.patch
      CMakeBuild -build_path "build2"
      Write-Host "libopenmpt built successfully!" -ForegroundColor Green
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-LibGME {
  Write-Host "Building libgme" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "libgme"
    ExtractPackage "libgme-$libgme_version-src.tar.gz"
    Push-Location "libgme-$libgme_version"
    try {
      & patch -p1 -N -i $patch_path/libgme-pkgconf.patch
      CMakeBuild
      Remove-Item "$prefix_path/lib/gme-static.lib" -Force -ErrorAction SilentlyContinue
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-FdkAac {
  Write-Host "Building fdk-aac" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "fdk-aac"
    ExtractPackage "fdk-aac-$fdk_aac_version.tar.gz"
    Push-Location "fdk-aac-$fdk_aac_version"
    try {
      CMakeBuild
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-Faad2 {
  Write-Host "Building faad2" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "faad2"
    Get-ChildItem -Directory -Filter "knik0-faad2-*" | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    ExtractPackage "faad2-$faad2_version.tar.gz"
    $package_dir = (Get-ChildItem -Directory -Filter "knik0-faad2-*" | Select-Object -First 1).Name
    Push-Location $package_dir
    try {
      CMakeBuild
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-Faac {
  Write-Host "Building faac" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "faac"
    ExtractPackage "faac-$faac_version.tar.gz" -package_dir "faac-faac-$faac_version"
    Push-Location "faac-faac-$faac_version"
    try {
      MesonBuild -additional_args @("-Dfrontend=false")
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-UtfCpp {
  Write-Host "Building utfcpp (header-only)" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "utfcpp"
    ExtractPackage "utfcpp-$utfcpp_version.tar.gz"
    Push-Location "utfcpp-$utfcpp_version"
    try {
      CMakeBuild
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-TagLib {
  Write-Host "Building TagLib" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "taglib"
    ExtractPackage "taglib-$taglib_version.tar.gz"
    Push-Location "taglib-$taglib_version"
    try {
      CMakeBuild
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-LibBS2B {
  Write-Host "Building libbs2b" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "libbs2b"
    ExtractPackage "libbs2b-$libbs2b_version.tar.bz2"
    Push-Location "libbs2b-$libbs2b_version"
    try {
      & patch -p1 -N -i $patch_path/libbs2b-msvc.patch
      CMakeBuild
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-LibEBUR128 {
  Write-Host "Building libebur128" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "libebur128"
    ExtractPackage "libebur128-$libebur128_version.tar.gz"
    Push-Location "libebur128-$libebur128_version"
    try {
      # On arm64 the SSE2 check falls through to a #warning, which MSVC only supports with /std:clatest.
      if ($arch -eq "arm64") {
        & sed -i "s/^#warning .*//g" ebur128/ebur128.c
      }
      CMakeBuild -additional_args @(
          "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"
        )
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

# libcdio (Audio CD): lib/driver only (drives, audio CDs, CD-Text, the Windows driver through DeviceIoControl), as a DLL.
# Upstream builds with autotools; patches/libcdio-cmake.patch adds a CMakeLists.txt that builds what upstream's own Visual
# Studio project (.vs/libcdio.vcxproj) builds, with its .vs/config.h, and installs libcdio.pc. Used by GStreamer's cdio
# plugin (gst-plugins-ugly) and by Akousma.
function Build-LibCdio {
  Write-Host "Building libcdio" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "libcdio"
    ExtractPackage "libcdio-$libcdio_version.tar.bz2"
    Push-Location "libcdio-$libcdio_version"
    try {
      & patch -p1 -N -i $patch_path/libcdio-cmake.patch
      CMakeBuild
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-FFMpeg {
  Write-Host "Building ffmpeg" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    CloneGitRepo -git_repo_name "ffmpeg"
    if (-not (Test-Path "ffmpeg")) {
      RecursiveCopy "$src_path/ffmpeg" "ffmpeg"
      Push-Location "ffmpeg"
      try {
        & git checkout "meson-$ffmpeg_version"
        & git checkout .
        & git pull --rebase
      }
      finally {
        Pop-Location
      }
    }
    Push-Location "ffmpeg"
    try {
      MesonBuild `
        -additional_args @(
          "-Dtests=disabled",
          "-Dgpl=enabled",
          "-Diconv=disabled",
          "-Dcheckasm=disabled"
        )
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-Chromaprint {
  Write-Host "Building chromaprint" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "chromaprint"
    ExtractPackage "chromaprint-$chromaprint_version.tar.gz" -ignore_errors $true
    Push-Location "chromaprint-$chromaprint_version"
    try {
      CMakeBuild -additional_args @(
          "-DFFMPEG_ROOT=$prefix_path",
          "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"
        )
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-GStreamer {
  Write-Host "Building GStreamer" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    if ($gst_dev -eq "ON") {
      CloneGitRepo -git_repo_name "gstreamer"
      if (-not (Test-Path "gstreamer")) {
        RecursiveCopy "$src_path/gstreamer/subprojects/gstreamer" "gstreamer"
      }
      Push-Location "gstreamer"
    }
    else {
      DownloadPackage -package_name "gstreamer"
      ExtractPackage "gstreamer-$gstreamer_version.tar.xz"
      Push-Location "gstreamer-$gstreamer_version"
    }
    try {
      MesonBuild `
        -additional_args @(
          "-Dexamples=disabled",
          "-Dtests=disabled",
          "-Dbenchmarks=disabled",
          "-Dtools=enabled",
          "-Dintrospection=disabled",
          "-Dnls=disabled",
          "-Ddoc=disabled",
          "-Dgst_debug=true",
          "-Dgst_parse=true",
          "-Dregistry=true"
        )
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-GstPluginsBase {
  Write-Host "Building gst-plugins-base" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    if ($gst_dev -eq "ON") {
      CloneGitRepo -git_repo_name "gst-plugins-base"
      if (-not (Test-Path "gst-plugins-base")) {
        RecursiveCopy "$src_path/gstreamer/subprojects/gst-plugins-base" "gst-plugins-base"
      }
      Push-Location "gst-plugins-base"
    }
    else {
      DownloadPackage -package_name "gst-plugins-base"
      ExtractPackage "gst-plugins-base-$gstreamer_version.tar.xz"
      Push-Location "gst-plugins-base-$gstreamer_version"
    }
    try {
      MesonBuild `
        -additional_args @(
          "-Dexamples=disabled",
          "-Dtests=disabled",
          "-Dtools=enabled",
          "-Dintrospection=disabled",
          "-Dnls=disabled",
          "-Dorc=enabled",
          "-Ddoc=disabled",
          "-Dadder=enabled",
          "-Dapp=enabled",
          "-Daudioconvert=enabled",
          "-Daudiomixer=enabled",
          "-Daudiorate=enabled",
          "-Daudioresample=enabled",
          "-Daudiotestsrc=enabled",
          "-Ddsd=enabled",
          "-Dencoding=enabled",
          "-Dpbtypes=enabled",
          "-Dplayback=enabled",
          "-Dtypefind=enabled",
          "-Dvolume=enabled",
          "-Dogg=enabled",
          "-Dopus=enabled",
          "-Dvorbis=enabled"
        )
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-GstPluginsGood {
  Write-Host "Building gst-plugins-good" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    if ($gst_dev -eq "ON") {
      if (-not (Test-Path "gst-plugins-good")) {
        RecursiveCopy "$src_path/gstreamer/subprojects/gst-plugins-good" "gst-plugins-good"
      }
      Push-Location "gst-plugins-good"
    }
    else {
      DownloadPackage -package_name "gst-plugins-good"
      ExtractPackage "gst-plugins-good-$gstreamer_version.tar.xz"
      Push-Location "gst-plugins-good-$gstreamer_version"
    }
    try {
      # Local patches (wrapper: patches\gstreamer-*.patch / -GstGoodPatch) are applied by MesonBuild (Invoke-LocalPatches).
      MesonBuild `
        -additional_args @(
          "--auto-features=disabled",
          "-Dexamples=disabled",
          "-Dtests=disabled",
          "-Dnls=disabled",
          "-Dorc=enabled",
          "-Dasm=enabled",
          "-Ddoc=disabled",
          "-Dapetag=enabled",
          "-Daudiofx=enabled",
          "-Daudioparsers=enabled",
          "-Dautodetect=enabled",
          "-Dequalizer=enabled",
          "-Dicydemux=enabled",
          "-Did3demux=enabled",
          "-Disomp4=enabled",
          "-Dreplaygain=enabled",
          "-Drtp=enabled",
          "-Drtpmanager=enabled",
          "-Drtsp=enabled",
          "-Dspectrum=enabled",
          "-Dudp=enabled",
          "-Dwavenc=enabled",
          "-Dwavparse=enabled",
          "-Dxingmux=enabled",
          "-Dadaptivedemux2=enabled",
          "-Ddirectsound=enabled",
          "-Dflac=enabled",
          "-Dlame=enabled",
          "-Dmpg123=enabled",
          "-Dspeex=enabled",
          "-Dtaglib=enabled",
          "-Dwaveform=enabled",
          "-Dwavpack=enabled",
          "-Dsoup=enabled",
          "-Dmatroska=enabled",
          "-Dhls-crypto=openssl"
        )
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-GstPluginsBad {
  Write-Host "Building gst-plugins-bad" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    if ($gst_dev -eq "ON") {
      if (-not (Test-Path "gst-plugins-bad")) {
        RecursiveCopy "$src_path/gstreamer/subprojects/gst-plugins-bad" "gst-plugins-bad"
      }
      Push-Location "gst-plugins-bad"
    }
    else {
      DownloadPackage -package_name "gst-plugins-bad"
      ExtractPackage "gst-plugins-bad-$gstreamer_version.tar.xz"
      Push-Location "gst-plugins-bad-$gstreamer_version"
    }
    & patch -p1 -N -i "$patch_path/gstreamer-asio.patch"
    try {
      MesonBuild `
        -additional_args @(
          "--auto-features=disabled",
          "-Dexamples=disabled",
          "-Dtools=enabled",
          "-Dtests=disabled",
          "-Dintrospection=disabled",
          "-Dnls=disabled",
          "-Dorc=enabled",
          "-Dgpl=enabled",
          "-Daiff=enabled",
          "-Dasfmux=enabled",
          "-Dmpegtsdemux=enabled",
          "-Dasio=enabled",
          "-Dbs2b=enabled",
          "-Ddash=enabled",
          "-Ddirectsound=enabled",
          "-Dfaac=enabled",
          "-Dfaad=enabled",
          "-Dfdkaac=enabled",
          "-Dgme=enabled",
          "-Dmusepack=enabled",
          "-Dopenmpt=enabled",
          "-Dopus=enabled",
          "-Dwasapi=enabled",
          "-Dwasapi2=enabled",
          "-Dhls=enabled"
        )
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-GstPluginsUgly {
  Write-Host "Building gst-plugins-ugly" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    if ($gst_dev -eq "ON") {
      if (-not (Test-Path "gst-plugins-ugly")) {
        RecursiveCopy "$src_path/gstreamer/subprojects/gst-plugins-ugly" "gst-plugins-ugly"
      }
      Push-Location "gst-plugins-ugly"
    }
    else {
      DownloadPackage -package_name "gst-plugins-ugly"
      ExtractPackage "gst-plugins-ugly-$gstreamer_version.tar.xz"
      Push-Location "gst-plugins-ugly-$gstreamer_version"
    }
    try {
      MesonBuild `
        -additional_args @(
          "--auto-features=disabled",
          "-Dnls=disabled",
          "-Dorc=enabled",
          "-Dtests=disabled",
          "-Ddoc=disabled",
          "-Dgpl=enabled",
          "-Dasfdemux=enabled",
          "-Dcdio=enabled"
        )
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-GstLibav {
  Write-Host "Building gst-libav" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    if ($gst_dev -eq "ON") {
      if (-not (Test-Path "gst-libav")) {
        RecursiveCopy "$src_path/gstreamer/subprojects/gst-libav" "gst-libav"
      }
      Push-Location "gst-libav"
    }
    else {
      DownloadPackage -package_name "gst-libav"
      ExtractPackage "gst-libav-$gstreamer_version.tar.xz"
      Push-Location "gst-libav-$gstreamer_version"
    }
    try {
      MesonBuild `
        -additional_args @(
          "-Dtests=disabled",
          "-Ddoc=disabled"
        )
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-GstPluginsRs {
  Write-Host "Building gst-plugins-rs (Rust GStreamer plugins)" -ForegroundColor Yellow
  # Git for Windows ships a GNU coreutils link.exe (Git\usr\bin) that can come before MSVC's link.exe on PATH; rustc then
  # calls it as the linker and fails with "/usr/bin/link: extra operand". Put the real MSVC linker's folder first.
  $msvc_link = Get-Command link.exe -All -ErrorAction SilentlyContinue | Where-Object { $_.Source -match '\\VC\\Tools\\MSVC\\' } | Select-Object -First 1
  if (-not $msvc_link) { throw "MSVC link.exe not found on PATH (Visual Studio environment not initialised?)" }
  $env:PATH = "$(Split-Path $msvc_link.Source);$env:PATH"
  Write-Host "  Using MSVC linker: $($msvc_link.Source)" -ForegroundColor Cyan
  Push-Location $build_path
  try {
    CloneGitRepo -git_repo_name "gst-plugins-rs"
    if (-not (Test-Path "gst-plugins-rs")) {
      RecursiveCopy "$src_path/gst-plugins-rs" "gst-plugins-rs"
    }
    Push-Location "gst-plugins-rs"
    try {
      MesonBuild `
        -pkg_config_path "" `
        -additional_args @(
          "--auto-features=disabled",
          "-Dexamples=disabled",
          "-Dtests=disabled",
          "-Dspotify=enabled"
        )
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-SparseHash {
  Write-Host "Copying sparsehash" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "sparsehash"
    ExtractPackage "sparsehash-$sparsehash_version.tar.gz"
    Push-Location "sparsehash-sparsehash-$sparsehash_version"
    try {
      & patch -p1 -N -i "$patch_path/sparsehash-msvc.patch"
      Copy-Item "src/google" "$prefix_path/include/" -Recurse -Force
      Copy-Item "src/sparsehash" "$prefix_path/include/" -Recurse -Force
      Copy-Item "src/windows/sparsehash/internal/sparseconfig.h" "$prefix_path/include/sparsehash/internal/" -Force
      Copy-Item "src/windows/google/sparsehash/sparseconfig.h" "$prefix_path/include/google/sparsehash/" -Force
      CreatePkgConfigFile -prefix $prefix_path -name "sparsehash" -description "C++ associative containers" -url "https://github.com/sparsehash/sparsehash" -version $sparsehash_version -cflags "-I`${includedir}" -output_file "$prefix_path/lib/pkgconfig/libsparsehash.pc"
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-QtBase {
  Write-Host "Building qtbase" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    if ($qt_dev -eq "ON") {
      if (-not (Test-Path "qtbase")) {
        RecursiveCopy "$src_path/qtbase" "qtbase"
      }
      Push-Location "qtbase"
    }
    else {
      DownloadPackage -package_name "qtbase"
      ExtractPackage "qtbase-everywhere-src-$qt_version.tar.xz"
      Push-Location "qtbase-everywhere-src-$qt_version"
      & patch -p1 -N -i "$patch_path/qtbase-qcryptographichash.patch"
    }
    try {
      CMakeBuild -additional_args (@(
          "-DQT_BUILD_EXAMPLES=OFF",
          "-DQT_BUILD_TESTS=OFF",
          "-DFEATURE_openssl=ON",
          "-DFEATURE_openssl_linked=ON",
          "-DFEATURE_system_zlib=ON",
          "-DFEATURE_system_png=ON",
          "-DFEATURE_system_jpeg=ON",
          "-DFEATURE_system_pcre2=ON",
          "-DFEATURE_system_freetype=ON",
          "-DFEATURE_system_harfbuzz=ON",
          "-DFEATURE_system_sqlite=ON",
          "-DICU_ROOT=$prefix_path"
        ) + $qtbase_arch_args)
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-QtTools {
  Write-Host "Building qttools" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    if ($qt_dev -eq "ON") {
      if (-not (Test-Path "qttools")) {
        RecursiveCopy "$src_path/qttools" "qttools"
      }
      Push-Location "qttools"
    }
    else {
      DownloadPackage -package_name "qttools"
      ExtractPackage "qttools-everywhere-src-$qt_version.tar.xz"
      Push-Location "qttools-everywhere-src-$qt_version"
    }
    try {
      CMakeBuild `
        -additional_args @(
          "-DQT_BUILD_EXAMPLES=OFF",
          "-DQT_BUILD_EXAMPLES_BY_DEFAULT=OFF",
          "-DQT_BUILD_TOOLS_WHEN_CROSSCOMPILING=ON",
          "-DFEATURE_assistant=OFF",
          "-DFEATURE_designer=OFF",
          "-DFEATURE_distancefieldgenerator=OFF",
          "-DFEATURE_kmap2qmap=OFF",
          "-DFEATURE_pixeltool=OFF",
          "-DFEATURE_qdbus=OFF",
          "-DFEATURE_qev=OFF",
          "-DFEATURE_qtattributionsscanner=OFF",
          "-DFEATURE_qtdiag=OFF",
          "-DFEATURE_qtplugininfo=OFF",
          "-DFEATURE_linguist=ON"
        )
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-QtImageFormats {
  Write-Host "Building qtimageformats" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    if ($qt_dev -eq "ON") {
      if (-not (Test-Path "qtimageformats")) {
        RecursiveCopy "$src_path/qtimageformats" "qtimageformats"
      }
      Push-Location "qtimageformats"
    }
    else {
      DownloadPackage -package_name "qtimageformats"
      ExtractPackage "qtimageformats-everywhere-src-$qt_version.tar.xz"
      Push-Location "qtimageformats-everywhere-src-$qt_version"
    }
    try {
      CMakeBuild -additional_args @(
        "-DFEATURE_jasper=ON",
        "-DFEATURE_tiff=ON",
        "-DFEATURE_webp=ON",
        "-DFEATURE_system_tiff=ON",
        "-DFEATURE_system_webp=ON"
      )
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

# Qt SVG: the SVG image format and icon engine plugins, for the icon sets with SVG icons (Settings > Appearance > Icon set).
function Build-QtSvg {
  Write-Host "Building qtsvg" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    if ($qt_dev -eq "ON") {
      if (-not (Test-Path "qtsvg")) {
        RecursiveCopy "$src_path/qtsvg" "qtsvg"
      }
      Push-Location "qtsvg"
    }
    else {
      DownloadPackage -package_name "qtsvg"
      ExtractPackage "qtsvg-everywhere-src-$qt_version.tar.xz"
      Push-Location "qtsvg-everywhere-src-$qt_version"
    }
    try {
      CMakeBuild
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-QtSparkle {
  Write-Host "Building qtsparkle" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    CloneGitRepo -git_repo_name "qtsparkle"
    if (-not (Test-Path "qtsparkle")) {
      RecursiveCopy "$src_path/qtsparkle" "qtsparkle"
    }
    Push-Location "qtsparkle"
    try {
      CMakeBuild -additional_args @(
        "-DBUILD_WITH_QT6=ON"
      )
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-KDSingleApplication {
  Write-Host "Building KDSingleApplication" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "kdsingleapplication"
    ExtractPackage "kdsingleapplication-$kdsingleapplication_version.tar.gz"
    Push-Location "kdsingleapplication-$kdsingleapplication_version"
    try {
      CMakeBuild -additional_args @("-DKDSingleApplication_QT6=ON")
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-GoogleTest {
  Write-Host "Building GoogleTest" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "googletest"
    ExtractPackage "googletest-$googletest_version.tar.gz"
    Push-Location "googletest-$googletest_version"
    try {
      # Build static libraries with the shared CRT, like the rest of the dependencies.
      CMakeBuild -build_static_libs $true -build_shared_libs $false -additional_args @("-Dgtest_force_shared_crt=ON")
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-PeParse {
  Write-Host "Building pe-parse" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "pe-parse"
    ExtractPackage "pe-parse-$peparse_version.tar.gz"
    Push-Location "pe-parse-$peparse_version"
    try {
      CMakeBuild -additional_args @("-DBUILD_COMMAND_LINE_TOOLS=OFF")
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-PeUtil {
  Write-Host "Building pe-util" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    CloneGitRepo -git_repo_name "pe-util"
    if (-not (Test-Path "pe-util")) {
      RecursiveCopy "$src_path/pe-util" "pe-util"
    }
    Push-Location "pe-util"
    try {
      CMakeBuild -additional_args @("-DBUILD_COMMAND_LINE_TOOLS=OFF")
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Get-AkousmaSourceId {
  # The source id of a local Akousma checkout (-AkousmaSource), for change detection: its commit, plus a hash of the uncommitted
  # changes (tracked changes and untracked files that are not ignored), so editing a file rebuilds Akousma.
  $sha = & git -C $akousma_source rev-parse -q --verify "HEAD^{commit}" 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $sha) { $global:LASTEXITCODE = 0; return "local $akousma_source (not a git checkout)" }
  $sha = ([string]@($sha)[0]).Trim()
  $diff = (& git -C $akousma_source diff --binary HEAD 2>$null) -join "`n"
  $untracked = @(& git -C $akousma_source ls-files --others --exclude-standard 2>$null)
  $global:LASTEXITCODE = 0
  if (-not $diff -and $untracked.Count -eq 0) { return $sha }
  $state = [System.Text.StringBuilder]::new($diff)
  foreach ($f in ($untracked | Sort-Object)) {
    $path = Join-Path $akousma_source $f
    if (Test-Path -LiteralPath $path -PathType Leaf) { [void]$state.Append("`n$f $((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash)") }
  }
  return "$sha+local-$((Get-TextSha256 $state.ToString()).Substring(0, 12))"
}

function Get-AkousmaCMakeArgs {
  $enable_win32_console = if ($build_type -eq "debug") { "ON" } else { "OFF" }
  # QtSparkle's only feed is upstream Strawberry's, which offers Strawberry releases: off unless -EnableQtSparkle.
  $qtsparkle = if ($enable_qtsparkle) { "ON" } else { "OFF" }
  # Release builds show the plain Akousma version; -IncludeGitCommit adds Akousma's short git commit.
  $git_commit = if ($include_git_commit) { "ON" } else { "OFF" }
  # Audio CD needs libcdio (and GStreamer's cdio plugin, built with gst-plugins-ugly once libcdio is there).
  $audiocd = if (Test-Path "$prefix_path/lib/pkgconfig/libcdio.pc") { "ON" } else { "OFF" }
  # x86: the installer's architecture is set explicitly (CMake reports the 64-bit host as the processor of a native 32-bit
  # build), and warnings are not errors: Akousma is developed and tested as x64 only, and 32-bit MSVC warns about conversions
  # (64-bit file offsets and sizes to 32-bit size_t / qsizetype) that x64 doesn't have. x64 is unchanged.
  $werror = if ($arch -eq "x86") { "OFF" } else { "ON" }
  $arch_args = if ($arch -eq "x86") { @("-DTARGET_ARCH=i686") } else { @() }
  # -IncrementalLink (Release): incremental linking instead of CMake's /INCREMENTAL:NO. /INCREMENTAL can't be combined with
  # /OPT:REF or /OPT:ICF (the linker's default without /DEBUG; it would turn incremental linking off again), hence NOREF/NOICF.
  # Akousma uses no /LTCG (/GL), which would also rule it out. Debug builds link incrementally already (CMake's default).
  if ($incremental_link -and $build_type -ne "debug") { $arch_args += @("-DCMAKE_EXE_LINKER_FLAGS_RELEASE=/INCREMENTAL /OPT:NOREF /OPT:NOICF") }
  return @(
    "-DARCH=$arch"
  ) + $arch_args + @(
    "-DENABLE_TRANSLATIONS=ON",
    "-DBUILD_WERROR=$werror",
    "-DENABLE_WIN32_CONSOLE=$enable_win32_console",
    "-DICU_ROOT=$prefix_path",
    "-DENABLE_AUDIOCD=$audiocd",
    "-DENABLE_MTP=OFF",
    "-DENABLE_GPOD=OFF",
    "-DENABLE_QTSPARKLE=$qtsparkle",
    "-DAKOUSMA_INCLUDE_GIT_COMMIT=$git_commit"
  )
}

function Get-AkousmaSourceDir {
  # Where the Akousma sources are built from: the local checkout, or the build copy of the clone.
  if ($akousma_source) { return $akousma_source }
  return "$build_path/akousma"
}

function Build-Akousma {
  Write-Host "Building akousma" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    if ($akousma_source) {
      # A local checkout (-AkousmaSource): built as it is, uncommitted changes included, out of tree in <build_path>/akousma/build.
      # The checkout itself is not changed. The existing build folder is reused, so only what changed is recompiled.
      Write-Host "Akousma source: $akousma_source ($(Get-AkousmaSourceId))" -ForegroundColor Cyan
      New-Item -ItemType Directory -Path "akousma" -Force | Out-Null
      Push-Location "akousma"
      try {
        CMakeBuild -source_path $akousma_source -additional_args (Get-AkousmaCMakeArgs)
      }
      finally {
        Pop-Location
      }
    }
    else {
      # The git repository (-AkousmaRepo, cloned to <src_path>/akousma) at -AkousmaRef, built in a copy of the clone.
      CloneGitRepo -git_repo_name "akousma"
      if (-not (Test-Path "akousma")) {
        RecursiveCopy "$src_path/akousma" "akousma"
      }
      Push-Location "akousma"
      try {
        # Source = exactly the commit: files that were changed in the build copy (by hand or by an earlier version of these build
        # tools, which patched strawberry here) are reset first. Files that end up identical keep their old timestamps, so the
        # incremental CMake build below (the existing build folder is reused) only recompiles what really changed.
        $akousma_saved = Sync-GitBuildCopy -src_repo "$src_path/akousma" -name "akousma"
        Restore-UnchangedTimestamps $akousma_saved "akousma"
        CMakeBuild -additional_args (Get-AkousmaCMakeArgs)
      }
      finally {
        Pop-Location
      }
    }
    Write-Host "Akousma built successfully!" -ForegroundColor Green
  }
  finally {
    Pop-Location
  }
}

function Build-AkousmaSetup {
  Write-Host "Creating AkousmaSetup" -ForegroundColor Yellow
  $akousma_src_dir = Get-AkousmaSourceDir
  Push-Location $build_path
  try {
    New-Item -Path "AkousmaSetup" -ItemType Directory -Force | Out-Null
    Push-Location "AkousmaSetup"
    try {
      # akousma.nsi installs every DLL staged here, so start from no DLLs: none left over from an earlier run (an older
      # FFmpeg or ICU version, a dependency no longer needed). Icon sets too (a removed set's .rcc).
      Get-ChildItem -Path "." -Include "*.dll", "*.rcc" -File -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force
      New-Item -Path @('platforms', 'styles', 'imageformats', 'iconengines', 'tls', 'sqldrivers', 'gio-modules', 'gstreamer-plugins', 'iconsets') -ItemType Directory -Force
      Copy-Item -Path "$build_path/akousma/build/akousma.exe", `
                      "$build_path/akousma/build/akousma.nsi", `
                      "$akousma_src_dir/COPYING", `
                      "$akousma_src_dir/dist/windows/*.ico", `
                      "$akousma_src_dir/dist/windows/*.nsh" `
                      "." -Force
      Copy-Item "$build_path/akousma/build/iconsets/*.rcc" "./iconsets/" -Force
      Copy-Item "$prefix_path/plugins/platforms/*.dll" "./platforms/" -Force
      Copy-Item "$prefix_path/plugins/styles/*.dll" "./styles/" -Force
      Copy-Item "$prefix_path/plugins/imageformats/*.dll" "./imageformats/" -Force
      # Qt SVG's icon engine (and imageformats/qsvg) only when qtsvg is in the prefix; akousma.nsi lists them only then.
      if (Test-Path "$prefix_path/plugins/iconengines") { Copy-Item "$prefix_path/plugins/iconengines/*.dll" "./iconengines/" -Force }
      Copy-Item "$prefix_path/plugins/tls/*.dll" "./tls/" -Force
      Copy-Item "$prefix_path/plugins/sqldrivers/*.dll" "./sqldrivers/" -Force
      Copy-Item "$prefix_path/lib/gio/modules/*.dll" "./gio-modules/" -Force
      Copy-Item "$prefix_path/lib/gstreamer-1.0/*.dll" "./gstreamer-plugins/" -Force
      # Audio CD: akousma.nsi lists GStreamer's cdio plugin when Akousma was built with Audio CD support (libcdio in the
      # prefix, see Get-AkousmaCMakeArgs); CopyDLLDependencies stages libcdio's cdio.dll for it and akousma.exe.
      $audiocd_built = (Test-Path "$build_path/akousma/build/CMakeCache.txt") -and (Select-String -Path "$build_path/akousma/build/CMakeCache.txt" -Pattern '^ENABLE_AUDIOCD:[A-Z]*=ON$' -Quiet)
      if ($audiocd_built -and -not (Test-Path "./gstreamer-plugins/gstcdio.dll")) {
        throw "Akousma was built with Audio CD support, but GStreamer's cdio plugin is missing ($prefix_path/lib/gstreamer-1.0/gstcdio.dll): rebuild gst-plugins-ugly (-ForceRebuild gst-plugins-ugly)."
      }
      Write-Host "Audio CD: $(if ($audiocd_built) { 'yes, gstcdio.dll and libcdio staged' } else { 'no (Akousma built without libcdio)' })" -ForegroundColor Cyan
      # Only the GStreamer tools the installer ships, so the DLLs only the others need are not staged.
      Copy-Item -Path "$prefix_path/bin/sqlite3.exe", "$prefix_path/bin/gst-launch-1.0.exe", "$prefix_path/bin/gst-play-1.0.exe", "$prefix_path/bin/gst-discoverer-1.0.exe" -Destination "." -Force
      & "$PSScriptRoot/CopyDLLDependencies.ps1" -Copy -DestDir "./" -InDir "./" -InDir "./platforms" -InDir "./styles" -InDir "./imageformats" -InDir "./iconengines" -InDir "./tls" -InDir "./sqldrivers" -InDir "./gio-modules" -InDir "./gstreamer-plugins" -RecursiveSrcDir "$prefix_path/bin"
      # The uninstaller deletes exactly the DLLs staged here (akousma.nsi includes this file).
      Get-ChildItem -Path "." -Filter "*.dll" -File | Sort-Object Name | ForEach-Object { "  Delete `"`$INSTDIR\$($_.Name)`"" } | Set-Content -Path "akousma-uninstall-dlls.nsh" -Encoding ascii
      DownloadPackage -package_name "vc-redist-${arch_short}"
      Copy-Item "$downloads_path/vc_redist.${arch_short}.exe" "." -Force
      & makensis akousma.nsi
      if ($LASTEXITCODE -ne 0) { throw "makensis akousma.nsi failed" }
      Write-Host "AkousmaSetup built successfully: $((Get-ChildItem -Filter 'AkousmaSetup*.exe' | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName)" -ForegroundColor Green
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

#endregion


function Get-PackageDependencies {
  # Conservative build-order constraints. Anything not listed here has no
  # constraints beyond pkgconf. akousma / akousma-setup wait for everything.
  $codecs = @("zlib", "bzip2", "xz", "libpng", "libjpeg-turbo", "ogg", "vorbis", "opus", "speex", "flac", "wavpack", "mpg123", "lame", "fdk-aac", "faad2", "faac", "libopenmpt", "libgme", "libbs2b", "libwebp", "openssl")
  $qt = @("zlib", "openssl", "libpng", "libjpeg-turbo", "pcre2", "icu4c", "sqlite", "freetype", "harfbuzz", "bzip2", "brotli", "xz")
  return @{
    "pkgconf"             = @()
    "yasm"                = @()
    "proxy-libintl"       = @("pkgconf")
    "getopt-win"          = @("pkgconf")
    "zlib"                = @("pkgconf")
    "openssl"             = @("pkgconf", "zlib")
    "libpng"              = @("pkgconf", "zlib")
    "libjpeg-turbo"       = @("pkgconf")
    "pcre2"               = @("pkgconf", "zlib", "bzip2")
    "bzip2"               = @("pkgconf")
    "xz"                  = @("pkgconf")
    "brotli"              = @("pkgconf")
    "uchardet"            = @("pkgconf")
    "icu4c"               = @("pkgconf")
    "pixman"              = @("pkgconf", "libpng")
    "expat"               = @("pkgconf")
    "boost"               = @("pkgconf")
    "libxml2"             = @("pkgconf", "zlib", "xz", "icu4c")
    "nghttp2"             = @("pkgconf", "zlib", "openssl")
    "libffi"              = @("pkgconf")
    "dlfcn-win32"         = @("pkgconf")
    "libpsl"              = @("pkgconf", "icu4c", "proxy-libintl")
    "orc"                 = @("pkgconf")
    "sqlite"              = @("pkgconf")
    "glib"                = @("pkgconf", "zlib", "pcre2", "libffi", "proxy-libintl", "dlfcn-win32", "getopt-win", "bzip2", "xz")
    "libsoup"             = @("pkgconf", "glib", "nghttp2", "libpsl", "sqlite", "libxml2", "brotli", "zlib", "openssl")
    "glib-networking"     = @("pkgconf", "glib", "openssl", "zlib", "libsoup")
    "freetype"            = @("pkgconf", "zlib", "libpng", "bzip2", "brotli")
    "harfbuzz"            = @("pkgconf", "freetype", "glib", "icu4c")
    "jasper"              = @("pkgconf", "libjpeg-turbo")
    "tiff"                = @("pkgconf", "zlib", "libjpeg-turbo", "xz")
    "libwebp"             = @("pkgconf", "libpng", "libjpeg-turbo", "tiff")
    "ogg"                 = @("pkgconf")
    "vorbis"              = @("pkgconf", "ogg")
    "flac"                = @("pkgconf", "ogg")
    "wavpack"             = @("pkgconf")
    "opus"                = @("pkgconf")
    "opusfile"            = @("pkgconf", "opus", "ogg", "openssl", "zlib")
    "speex"               = @("pkgconf", "ogg")
    "mpg123"              = @("pkgconf", "yasm")
    "lame"                = @("pkgconf")
    "fftw3"               = @("pkgconf")
    "musepack"            = @("pkgconf")
    "libopenmpt"          = @("pkgconf", "zlib", "mpg123", "ogg", "vorbis")
    "libgme"              = @("pkgconf", "zlib")
    "fdk-aac"             = @("pkgconf")
    "faad2"               = @("pkgconf")
    "faac"                = @("pkgconf")
    "utfcpp"              = @("pkgconf")
    "taglib"              = @("pkgconf", "zlib", "utfcpp")
    "libbs2b"             = @("pkgconf")
    "libebur128"          = @("pkgconf")
    "libcdio"             = @("pkgconf")
    "ffmpeg"              = @("pkgconf", "yasm", "libxml2", "libwebp", "opusfile", "fftw3", "libebur128", "taglib") + $codecs
    "chromaprint"         = @("pkgconf", "ffmpeg", "fftw3")
    "gstreamer"           = @("pkgconf", "glib", "libffi", "zlib", "orc")
    "gst-plugins-base"    = @("pkgconf", "gstreamer", "orc", "harfbuzz", "freetype", "pixman", "libpng", "libjpeg-turbo", "opusfile") + $codecs
    "gst-plugins-good"    = @("pkgconf", "gst-plugins-base", "libsoup", "taglib", "pixman", "libxml2", "nghttp2") + $codecs
    "gst-plugins-bad"     = @("pkgconf", "gst-plugins-base", "libsoup", "libxml2", "nghttp2", "chromaprint", "opusfile", "musepack", "fftw3", "pixman") + $codecs
    "gst-plugins-ugly"    = @("pkgconf", "gst-plugins-base", "libcdio")
    "gst-libav"           = @("pkgconf", "gst-plugins-base", "ffmpeg")
    "gst-plugins-rs"      = @("pkgconf", "gst-plugins-base", "gst-plugins-bad", "glib", "openssl", "zlib")
    "qtbase"              = @("pkgconf") + $qt
    "qttools"             = @("qtbase")
    "qtimageformats"      = @("qtbase", "jasper", "tiff", "libwebp")
    "qtsvg"               = @("qtbase")
    "kdsingleapplication" = @("qtbase")
    "qtsparkle"           = @("qtbase", "qttools")
    "sparsehash"          = @("pkgconf")
    "googletest"          = @("pkgconf")
    "pe-parse"            = @("pkgconf")
    "pe-util"             = @("pkgconf", "pe-parse", "boost")
  }
}

function Get-PackageWeight {
  # Rough relative build cost, used only to order the queue (critical path) and to split cores.
  # Unlisted packages count as 1. These are estimates; adjust to what your machine shows in the logs.
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)][string]$name)
  $w = @{
    'qtbase' = 14; 'ffmpeg' = 9; 'gst-plugins-rs' = 7; 'akousma' = 7; 'gst-plugins-bad' = 6
    'icu4c' = 5; 'qttools' = 4; 'boost' = 4; 'glib' = 4; 'openssl' = 4
    'gst-plugins-good' = 3; 'gst-plugins-base' = 3; 'gstreamer' = 3; 'gst-libav' = 3
    'harfbuzz' = 2; 'libxml2' = 2; 'libopenmpt' = 2; 'qtimageformats' = 2; 'taglib' = 2
    'freetype' = 2; 'pcre2' = 2; 'akousma-setup' = 2
  }
  if ($w.ContainsKey($name)) { return [int]$w[$name] }
  return 1
}

function Start-DownloadPrefetch {
  # Downloads the source archives of all queued packages in the background, several at a time, while
  # the scheduler is already building the first packages. Best effort: anything missed or failed is
  # simply downloaded by the package's own process as before. Files are renamed into place atomically.
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)][string[]]$queue)

  if (-not (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)) { return $null }
  $table = GetPackageUrls
  $urls = @()
  # The first URL of each package: the file's name comes from it. The package's own process verifies the checksum of what is
  # here, and downloads the file again (then with the mirrors) when it is not the right one.
  foreach ($c in $queue) { if ($table.ContainsKey($c)) { $urls += [string]@($table[$c])[0] } }
  if ($urls.Count -eq 0) { return $null }
  Write-Host "Prefetching $($urls.Count) source archives in the background..." -ForegroundColor Cyan

  return Start-ThreadJob -ArgumentList $urls, $downloads_path -ScriptBlock {
    param($urls, $dest)
    $ProgressPreference = 'SilentlyContinue'
    $urls | ForEach-Object -ThrottleLimit 6 -Parallel {
      $url = $_
      $dest = $using:dest
      $name = Split-Path $url -Leaf
      if ($name -eq 'download' -and $url -match '/([^/]+)/download$') { $name = $matches[1] }
      $file = Join-Path $dest $name
      if (Test-Path $file) { return }
      $part = "$file.prefetch-$([guid]::NewGuid().ToString('N').Substring(0, 8)).part"
      try {
        Invoke-WebRequest -Uri $url -OutFile $part -UseBasicParsing -MaximumRedirection 5 -UserAgent "Wget"
        if ((Test-Path $part) -and (Get-Item $part).Length -gt 0) { [System.IO.File]::Move($part, $file) }
      }
      catch { }
      finally { if (Test-Path $part) { Remove-Item $part -Force -ErrorAction SilentlyContinue } }
    }
  }
}

function Invoke-ParallelQueue {
  # Runs each queued component in its own pwsh process, respecting Get-PackageDependencies.
  #  - Ready packages are started longest-remaining-chain first (critical path), so the Qt /
  #    GStreamer / ffmpeg chains start as early as their dependencies allow.
  #  - Cores are handed out from a shared budget (-jobs) when a package starts, weighted by package
  #    cost: a package that starts while others run gets the free share, one that starts alone
  #    (the serial tail: qtbase -> qttools -> akousma ...) gets every core.
  #  - Never fewer than jobs/4 cores are offered to a new package, so a package that is busy in a
  #    serial phase (configure, extract, link) cannot keep the next ready one waiting.
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)][string[]]$queue)

  $pwsh = (Get-Process -Id $PID).Path
  $logs = if ($log_dir) { $log_dir } else { Join-Path $build_path "logs" }
  New-Item -ItemType Directory -Path $logs -Force | Out-Null

  # Hashtables cannot be passed through -File, so children read them from the environment.
  $env:SMB_GIT_REFS_JSON = ($git_refs | ConvertTo-Json -Compress)
  $env:SMB_VERSION_OVERRIDES_JSON = ($version_overrides | ConvertTo-Json -Compress)
  $env:SMB_PACKAGE_PATCHES_JSON = ($smb_package_patches | ConvertTo-Json -Compress -Depth 4)

  $graph = Get-PackageDependencies
  $deps = @{}
  foreach ($c in $queue) {
    if ($c -eq "akousma") { $deps[$c] = @($queue | Where-Object { $_ -ne "akousma" -and $_ -ne "akousma-setup" }) }
    elseif ($c -eq "akousma-setup") { $deps[$c] = @($queue | Where-Object { $_ -ne "akousma-setup" }) }
    elseif ($graph.ContainsKey($c)) { $deps[$c] = @($graph[$c] | Where-Object { $queue -contains $_ }) }
    else {
      Write-Warning "No dependency info for '$c'; it will run after everything queued before it."
      $idx = [Array]::IndexOf($queue, $c)
      $deps[$c] = if ($idx -gt 0) { @($queue[0..($idx - 1)]) } else { @() }
    }
  }

  # Critical-path priority: own weight + the heaviest chain of packages that (transitively) wait on it.
  $weight = @{}; $order = @{}; $dependents = @{}; $prio = @{}
  for ($i = 0; $i -lt $queue.Count; $i++) {
    $c = $queue[$i]
    $weight[$c] = Get-PackageWeight -name $c
    $order[$c] = $i
    $dependents[$c] = [System.Collections.Generic.List[string]]::new()
    $prio[$c] = $weight[$c]
  }
  foreach ($c in $queue) { foreach ($d in $deps[$c]) { $dependents[$d].Add($c) } }
  for ($pass = 0; $pass -lt $queue.Count; $pass++) {
    $changed = $false
    foreach ($c in $queue) {
      $best = 0
      foreach ($n in $dependents[$c]) { if ($prio[$n] -gt $best) { $best = $prio[$n] } }
      if (($weight[$c] + $best) -ne $prio[$c]) { $prio[$c] = $weight[$c] + $best; $changed = $true }
    }
    if (-not $changed) { break }
  }

  Write-Host "Parallel build: up to $parallel_packages packages at once, $jobs cores shared between them. Logs: $logs" -ForegroundColor Cyan
  $prefetch = Start-DownloadPrefetch -queue $queue

  $remaining = [System.Collections.Generic.List[string]]::new()
  foreach ($c in $queue) { $remaining.Add($c) }
  $running = @{}
  $done = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $failed = [System.Collections.Generic.List[string]]::new()
  $clock = [Diagnostics.Stopwatch]::StartNew()

  while ($remaining.Count -gt 0 -or $running.Count -gt 0) {
    if ($failed.Count -eq 0 -and $running.Count -lt $parallel_packages -and $remaining.Count -gt 0) {
      $ready = @($remaining | Where-Object {
          $cand = $_
          @($deps[$cand] | Where-Object { -not $done.Contains($_) }).Count -eq 0
        } | Sort-Object @{ Expression = { $prio[$_] }; Descending = $true }, @{ Expression = { $order[$_] } })
      $batch = @($ready | Select-Object -First ($parallel_packages - $running.Count))

      $allocated = 0
      foreach ($k in $running.Keys) { $allocated += $running[$k].Jobs }
      $sum_w = 0
      foreach ($c in $batch) { $sum_w += $weight[$c] }

      foreach ($c in $batch) {
        $avail = [Math]::Max($jobs - $allocated, [int][Math]::Ceiling($jobs / 4))
        # Heavy packages (weight >= 5: qtbase, ffmpeg, gst-plugins-rs/bad, icu4c, akousma) keep their core
        # count until they exit, so they never start with less than half the machine. Light packages spend most
        # of their time in serial phases, so a little oversubscription costs nothing and keeps cores busy.
        $floor = if ($weight[$c] -ge 5) { [int][Math]::Ceiling($jobs / 2) } else { 2 }
        $child_jobs = [Math]::Min($jobs, [Math]::Max($floor, [Math]::Max(2, [int][Math]::Ceiling($avail * $weight[$c] / $sum_w))))
        $sum_w -= $weight[$c]
        $allocated += $child_jobs

        $child_args = @(
          "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $PSCommandPath,
          "-build_type", $build_type, "-arch", $arch,
          "-downloads_path", $downloads_path, "-src_path", $src_path, "-build_path", $build_path, "-prefix_path", $prefix_path,
          "-jobs", $child_jobs, "-parallel_packages", 1, "-only", $c, "-child_build"
        )
        if ($versions_file) { $child_args += @("-versions_file", $versions_file) }
        if ($ci_versions_file) { $child_args += @("-ci_versions_file", $ci_versions_file) }
        if ($jom_path) { $child_args += @("-jom_path", $jom_path) }
        if ($script:host_prefix_path) { $child_args += @("-host_prefix_path", $script:host_prefix_path) }
        $child_args += @("-akousma_repo", $akousma_repo)
        if ($akousma_source) { $child_args += @("-akousma_source", $akousma_source) }
        if ($enable_qtsparkle) { $child_args += @("-enable_qtsparkle") }
        if ($include_git_commit) { $child_args += @("-include_git_commit") }
        if ($incremental_link) { $child_args += @("-incremental_link") }
        $log = Join-Path $logs "$c.log"
        $p = Start-Process -FilePath $pwsh -ArgumentList $child_args -NoNewWindow -PassThru `
               -RedirectStandardOutput $log -RedirectStandardError "$log.err"
        $null = $p.Handle   # keep the handle so ExitCode is readable after exit
        $running[$c] = @{ Process = $p; Log = $log; Started = $clock.Elapsed; Jobs = $child_jobs }
        [void]$remaining.Remove($c)
        Write-Host ("[{0:mm\:ss}] started  {1} with {2} jobs  (running: {3}; cores allocated: {4}/{5})" -f $clock.Elapsed, $c, $child_jobs, (($running.Keys | Sort-Object) -join ", "), $allocated, $jobs) -ForegroundColor Cyan
      }
    }

    # Stall check right after a scheduling pass: if nothing is running and nothing could be started,
    # the remaining packages can never become ready. (Checking after a package finishes, before the
    # next pass, wrongly flagged a stall when the last running package was the one they waited on.)
    if ($failed.Count -eq 0 -and $running.Count -eq 0 -and $remaining.Count -gt 0) {
      throw "Scheduler stalled; unresolved: $($remaining -join ', ')"
    }
    Start-Sleep -Milliseconds 700

    foreach ($c in @($running.Keys)) {
      $r = $running[$c]
      if (-not $r.Process.HasExited) { continue }
      $r.Process.WaitForExit()
      $elapsed = $clock.Elapsed - $r.Started
      if ($r.Process.ExitCode -eq 0) {
        [void]$done.Add($c)
        Write-Host ("[{0:mm\:ss}] finished {1} ({2:mm\:ss})" -f $clock.Elapsed, $c, $elapsed) -ForegroundColor Green
      }
      else {
        $failed.Add($c)
        Write-Host ("[{0:mm\:ss}] FAILED   {1} (exit {2}) - last log lines:" -f $clock.Elapsed, $c, $r.Process.ExitCode) -ForegroundColor Red
        foreach ($f in @($r.Log, "$($r.Log).err")) { if (Test-Path $f) { Get-Content $f -Tail 25 | ForEach-Object { Write-Host "    $_" } } }
      }
      $running.Remove($c)
    }

    if ($failed.Count -gt 0 -and $running.Count -eq 0) { break }
  }

  if ($prefetch) { Remove-Job $prefetch -Force -ErrorAction SilentlyContinue }
  if ($failed.Count -gt 0) {
    throw "Failed: $($failed -join ', '). Not started: $($remaining -join ', '). Logs in $logs"
  }
  Write-Host ("Parallel build finished in {0:hh\:mm\:ss}" -f $clock.Elapsed) -ForegroundColor Green
}

#region Change detection
# --- patched: per-package change detection ---
# Every package gets a stamp, <build_path>/.stamps/<package>.json, written when it built (or, the first time, when its existing
# output was adopted). The stamp holds a fingerprint of everything that decides what the package's output looks like:
#   - build type / arch
#   - its sources: the download URL (it carries the version) or the git commit of each repository the recipe clones
#   - sha256 of the build tools' own patches its recipe applies ($patch_path/*.patch)
#   - sha256 and order of the local patches for it (-package_patches; the preparation part fills it from local-patches\, -GstGoodPatch)
#   - the text of its build recipe (its line in the build switch + its Build-* function), so a new build tools ref rebuilds what it changed
# A package is skipped when its output marker exists and its stamp matches. Otherwise it is rebuilt: dependencies in a clean copy
# (fresh extract / copy, new build folder), akousma incrementally (source reset to the commit, or a local checkout as it is, then the
# existing CMake build folder is reused, so only what really changed is recompiled). See Get-BuildPlan for the rules.

$smb_script_file = $PSCommandPath
$smb_stamp_dir = "$build_path/.stamps"
# Header-only packages: their dependents compile them in, so a rebuild of one of these rebuilds its direct dependents.
# (Everything else is a shared library; use -rebuild_dependents to rebuild direct dependents of those too.)
$smb_embedded_packages = @('utfcpp', 'sparsehash', 'boost')
# Build tools: never a reason to rebuild dependents.
$smb_tool_packages = @('pkgconf', 'yasm')
# Extra folders (in build_path) a clean rebuild removes, besides <build_path>/<package> and the folders the recipe extracts/configures.
$smb_extra_build_dirs = @{ 'akousma-setup' = @('AkousmaSetup') }
$script:smb_component = ""
$script:smb_clean_packages = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
if ($env:SMB_CLEAN_PACKAGES) { foreach ($p in $env:SMB_CLEAN_PACKAGES -split ';') { if ($p) { [void]$script:smb_clean_packages.Add($p) } } }
$script:smb_cleaned_dirs = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$script:smb_patched_components = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$script:smb_recipes = $null

function Get-PackageMarkers {
  # The file each package installs; it is (re)built when this is missing. Same checks as upstream's queue, in queue order.
  return [ordered]@{
    "pkgconf"             = "$prefix_path/bin/pkgconf.exe"
    "yasm"                = "$prefix_path/bin/yasm.exe"
    "proxy-libintl"       = "$prefix_path/lib/pkgconfig/intl.pc"
    "getopt-win"          = "$prefix_path/lib/getopt.lib"
    "zlib"                = "$prefix_path/lib/pkgconfig/zlib.pc"
    "openssl"             = "$prefix_path/lib/pkgconfig/openssl.pc"
    "libpng"              = "$prefix_path/lib/pkgconfig/libpng.pc"
    "libjpeg-turbo"       = "$prefix_path/lib/pkgconfig/libjpeg.pc"
    "pcre2"               = "$prefix_path/lib/pkgconfig/libpcre2-16.pc"
    "bzip2"               = "$prefix_path/lib/pkgconfig/bzip2.pc"
    "xz"                  = "$prefix_path/lib/pkgconfig/liblzma.pc"
    "brotli"              = "$prefix_path/lib/pkgconfig/libbrotlicommon.pc"
    "uchardet"            = "$prefix_path/lib/pkgconfig/uchardet.pc"
    "icu4c"               = "$prefix_path/lib/pkgconfig/icu-uc.pc"
    "pixman"              = "$prefix_path/lib/pkgconfig/pixman-1.pc"
    "expat"               = "$prefix_path/lib/pkgconfig/expat.pc"
    "libxml2"             = "$prefix_path/lib/pkgconfig/libxml-2.0.pc"
    "nghttp2"             = "$prefix_path/lib/pkgconfig/libnghttp2.pc"
    "libffi"              = "$prefix_path/lib/pkgconfig/libffi.pc"
    "dlfcn-win32"         = "$prefix_path/include/dlfcn.h"
    "libpsl"              = "$prefix_path/lib/pkgconfig/libpsl.pc"
    "orc"                 = "$prefix_path/lib/pkgconfig/orc-0.4.pc"
    "sqlite"              = "$prefix_path/lib/pkgconfig/sqlite3.pc"
    "glib"                = "$prefix_path/lib/pkgconfig/glib-2.0.pc"
    "libsoup"             = "$prefix_path/lib/pkgconfig/libsoup-3.0.pc"
    "glib-networking"     = "$prefix_path/lib/gio/modules/gioopenssl.lib"
    "freetype"            = "$prefix_path/lib/pkgconfig/freetype2.pc"
    "harfbuzz"            = "$prefix_path/lib/pkgconfig/harfbuzz.pc"
    "jasper"              = "$prefix_path/lib/pkgconfig/jasper.pc"
    "tiff"                = "$prefix_path/lib/pkgconfig/libtiff-4.pc"
    "libwebp"             = "$prefix_path/lib/pkgconfig/libwebp.pc"
    "ogg"                 = "$prefix_path/lib/pkgconfig/ogg.pc"
    "vorbis"              = "$prefix_path/lib/pkgconfig/vorbis.pc"
    "flac"                = "$prefix_path/lib/pkgconfig/flac.pc"
    "wavpack"             = "$prefix_path/lib/pkgconfig/wavpack.pc"
    "opus"                = "$prefix_path/lib/pkgconfig/opus.pc"
    "opusfile"            = "$prefix_path/bin/opusfile.dll"
    "speex"               = "$prefix_path/lib/pkgconfig/speex.pc"
    "mpg123"              = "$prefix_path/lib/pkgconfig/libmpg123.pc"
    "lame"                = "$prefix_path/lib/mp3lame.lib"
    "fftw3"               = "$prefix_path/lib/pkgconfig/fftw3.pc"
    "musepack"            = "$prefix_path/lib/pkgconfig/mpcdec.pc"
    "libopenmpt"          = "$prefix_path/lib/pkgconfig/libopenmpt.pc"
    "libgme"              = "$prefix_path/lib/pkgconfig/libgme.pc"
    "fdk-aac"             = "$prefix_path/lib/pkgconfig/fdk-aac.pc"
    "faad2"               = "$prefix_path/lib/pkgconfig/faad2.pc"
    "faac"                = "$prefix_path/lib/faac.lib"
    "utfcpp"              = "$prefix_path/include/utf8cpp/utf8.h"
    "taglib"              = "$prefix_path/lib/pkgconfig/taglib.pc"
    "libbs2b"             = "$prefix_path/lib/libbs2b.lib"
    "libebur128"          = "$prefix_path/lib/pkgconfig/libebur128.pc"
    "libcdio"             = "$prefix_path/lib/pkgconfig/libcdio.pc"
    "ffmpeg"              = "$prefix_path/lib/avutil.lib"
    "chromaprint"         = "$prefix_path/lib/pkgconfig/libchromaprint.pc"
    "gstreamer"           = "$prefix_path/lib/pkgconfig/gstreamer-1.0.pc"
    "gst-plugins-base"    = "$prefix_path/lib/pkgconfig/gstreamer-plugins-base-1.0.pc"
    "gst-plugins-good"    = "$prefix_path/lib/gstreamer-1.0/gstflac.dll"
    "gst-plugins-bad"     = "$prefix_path/lib/pkgconfig/gstreamer-plugins-bad-1.0.pc"
    "gst-plugins-ugly"    = "$prefix_path/lib/gstreamer-1.0/gstasf.dll"
    "gst-libav"           = "$prefix_path/lib/gstreamer-1.0/gstlibav.dll"
    "gst-plugins-rs"      = "$prefix_path/lib/gstreamer-1.0/gstspotify.dll"
    "qtbase"              = "$prefix_path/bin/qt-configure-module.bat"
    "qttools"             = "$prefix_path/bin/lconvert.exe"
    "qtimageformats"      = "$prefix_path/plugins/imageformats/qwebp${lib_postfix}.dll"
    "qtsvg"               = "$prefix_path/plugins/iconengines/qsvgicon${lib_postfix}.dll"
    "kdsingleapplication" = "$prefix_path/lib/cmake/KDSingleApplication-qt6/KDSingleApplication-qt6Config.cmake"
    "qtsparkle"           = "$prefix_path/lib/cmake/qtsparkle-qt6/qtsparkle-qt6Config.cmake"
    "sparsehash"          = "$prefix_path/lib/pkgconfig/libsparsehash.pc"
    "googletest"          = "$prefix_path/lib/cmake/GTest/GTestConfig.cmake"
    "pe-parse"            = "$prefix_path/lib/cmake/pe-parse/pe-parse-config.cmake"
    "pe-util"             = "$prefix_path/bin/peldd.exe"
    "akousma"             = "$build_path/akousma/build/akousma.exe"
    "akousma-setup"       = "$build_path/AkousmaSetup/AkousmaSetup*.exe"
  }
}

function Get-TextSha256([string]$text) {
  $bytes = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($text))
  return ([System.BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
}

function Get-NormalizedFileSha256([string]$path) {
  # Line endings don't count: a patch checked out with CRLF hashes the same as with LF.
  if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return "missing" }
  return Get-TextSha256 ([System.IO.File]::ReadAllText($path).Replace("`r`n", "`n"))
}

function Get-LocalPatches([string]$name) {
  if ($name -and $smb_package_patches.ContainsKey($name)) { return @($smb_package_patches[$name]) }
  return @()
}

function Get-CommandArgumentValue {
  param($cmd, [string]$parameter)
  $elements = $cmd.CommandElements
  $value_ast = $null
  for ($i = 1; $i -lt $elements.Count; $i++) {
    $e = $elements[$i]
    if ($e -is [System.Management.Automation.Language.CommandParameterAst]) {
      if ($e.ParameterName -eq $parameter) { $value_ast = if ($e.Argument) { $e.Argument } elseif ($i + 1 -lt $elements.Count) { $elements[$i + 1] } else { $null }; break }
      if (-not $e.Argument) { $i++ }   # skip that parameter's value
      continue
    }
    if (-not $value_ast) { $value_ast = $e }   # first positional argument, unless the named one follows
  }
  if ($value_ast -is [System.Management.Automation.Language.StringConstantExpressionAst]) { return $value_ast.Value }
  if ($value_ast -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) { return $ExecutionContext.InvokeCommand.ExpandString($value_ast.Value) }
  if ($value_ast) { return $value_ast.Extent.Text }
  return $null
}

function Test-InDisabledDevBranch($node) {
  # True for code inside 'if ($gst_dev -eq "ON") { ... }' (or $qt_dev) while that switch is off: those git clones aren't used.
  $child = $node
  $parent = $node.Parent
  while ($parent) {
    if ($parent -is [System.Management.Automation.Language.IfStatementAst]) {
      foreach ($clause in $parent.Clauses) {
        if ([object]::ReferenceEquals($clause.Item2, $child) -and $clause.Item1.Extent.Text -match '^\$(\w+_dev)\s+-eq\s+"ON"$') {
          if ((Get-Variable -Name $Matches[1] -ValueOnly -ErrorAction SilentlyContinue) -ne "ON") { return $true }
        }
      }
    }
    $child = $parent
    $parent = $parent.Parent
  }
  return $false
}

function Get-SmbRecipes {
  # Reads this script's own build switch and Build-* functions once: per package the recipe text, the downloads and git
  # repositories it uses, the build tools' patches it applies, and whether it builds with CMakeBuild / MesonBuild.
  if ($script:smb_recipes) { return $script:smb_recipes }
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($smb_script_file, [ref]$null, [ref]$null)
  $functions = @{}
  foreach ($f in $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $functions[$f.Name] = $f }
  $switch = $ast.Find({ param($a) $a -is [System.Management.Automation.Language.SwitchStatementAst] -and $a.Condition.Extent.Text -eq '$component' }, $true)
  if (-not $switch) { throw "Change detection: the build switch was not found in $smb_script_file" }
  $recipes = @{}
  foreach ($clause in $switch.Clauses) {
    if ($clause.Item1 -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { continue }
    $name = $clause.Item1.Value
    $call = $clause.Item2.Find({ param($a) $a -is [System.Management.Automation.Language.CommandAst] }, $true)
    $fn = if ($call -and $functions.ContainsKey($call.GetCommandName())) { $functions[$call.GetCommandName()] } else { $null }
    $text = $clause.Item2.Extent.Text
    if ($fn) { $text += "`n" + $fn.Extent.Text }
    $text = $text.Replace("`r", "")
    $downloads = [System.Collections.Generic.List[string]]::new()
    $repos = [System.Collections.Generic.List[string]]::new()
    $uses_cmake_or_meson = $false
    if ($fn) {
      foreach ($cmd in $fn.FindAll({ param($a) $a -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $cmd_name = $cmd.GetCommandName()
        if ($cmd_name -in 'CMakeBuild', 'MesonBuild') { $uses_cmake_or_meson = $true }
        if ($cmd_name -notin 'DownloadPackage', 'CloneGitRepo') { continue }
        if (Test-InDisabledDevBranch $cmd) { continue }
        $value = Get-CommandArgumentValue $cmd $(if ($cmd_name -eq 'DownloadPackage') { 'package_name' } else { 'git_repo_name' })
        if (-not $value) { continue }
        if ($cmd_name -eq 'DownloadPackage') { if (-not $downloads.Contains($value)) { $downloads.Add($value) } }
        elseif (-not $repos.Contains($value)) { $repos.Add($value) }
      }
    }
    $tool_patches = @([regex]::Matches($text, '\$patch_path[/\\]([\w.+-]+\.patch)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    # A git-sourced recipe that uses a version (ffmpeg: git checkout meson-$ffmpeg_version) builds what that version says, not
    # the clone's commit: the version is a source of its own. (A download's version is in its URL already.)
    $version_vars = if ($repos.Count) { @([regex]::Matches($text, '\$([a-z0-9_]+_version)\b') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique) } else { @() }
    $recipes[$name] = @{ Text = $text; Downloads = @($downloads); GitRepos = @($repos); VersionVars = $version_vars; ToolPatches = $tool_patches; UsesCMakeOrMeson = $uses_cmake_or_meson }
  }
  $script:smb_recipes = $recipes
  return $recipes
}

function Resolve-GitSourceId {
  # The commit a git-sourced package builds: the pinned ref (git_refs) resolved in the local clone, else the clone's HEAD.
  # A pinned branch (e.g. -AkousmaRef master) resolves to origin/<branch>, and with -sync the clone is fetched first, so a new
  # commit on the branch is seen as a change. Otherwise no network unless -sync and a pinned ref is not in the clone yet (then
  # the clone is fetched, like the build would). Unpinned clones are not pulled here; the build pulls them as before, and the
  # stamp records the commit it built.
  param([string]$repo, [switch]$sync)
  if ($repo -eq 'akousma' -and $akousma_source) { return (Get-AkousmaSourceId) }
  $path = "$($script:src_path)/$repo"
  $ref = $git_refs[$repo]
  $fetched = $false
  for ($attempt = 0; $attempt -lt 2; $attempt++) {
    if (Test-Path -LiteralPath "$path/.git") {
      $spec = if ($ref) { Get-GitRefSpec -repo_path $path -ref $ref } else { "HEAD" }
      if ($sync -and $ref -and -not $fetched -and $spec -ne $ref) {
        $fetched = $true
        & git -C $path fetch --tags --force origin 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Warning "Could not fetch $repo; using $spec as of its last fetch." }
      }
      $sha = & git -C $path rev-parse -q --verify "$spec^{commit}" 2>$null
      if ($LASTEXITCODE -eq 0 -and $sha) { return ([string]@($sha)[0]).Trim() }
    }
    if (-not $sync -or $attempt -gt 0 -or -not $ref -or -not (Test-Path -LiteralPath "$path/.git")) { break }
    try { CloneGitRepo -git_repo_name $repo | Out-Host }
    catch { Write-Warning "Could not update $repo to resolve '$ref': $_"; break }
  }
  $global:LASTEXITCODE = 0
  if (Test-Path -LiteralPath "$path/.git") { return "unresolved $ref" }
  return "not cloned"
}

function Get-PackageFingerprint {
  param([string]$name, [switch]$sync)
  $recipe = (Get-SmbRecipes)[$name]
  $package_urls = GetPackageUrls
  $sources = [ordered]@{}
  $tool_patches = [ordered]@{}
  if ($recipe) {
    # The first URL of a download: the one the file is named after, and what the stamps held before the mirrors were added
    # (upstream 56af2c1), so they stay valid. The mirrors serve the same file (one checksum), so they don't count.
    foreach ($d in $recipe.Downloads) { $sources[$d] = if ($package_urls.ContainsKey($d)) { [string]@($package_urls[$d])[0] } else { "unknown" } }
    foreach ($r in $recipe.GitRepos) { $sources["git:$r"] = Resolve-GitSourceId -repo $r -sync:$sync }
    foreach ($v in $recipe.VersionVars) { $sources["version:$v"] = [string](Get-Variable -Name $v -ValueOnly -ErrorAction SilentlyContinue) }
    foreach ($p in $recipe.ToolPatches) { $tool_patches[$p] = Get-NormalizedFileSha256 (Join-Path $patch_path $p) }
  }
  $local_patches = @(foreach ($p in @(Get-LocalPatches $name)) { [ordered]@{ name = (Split-Path $p -Leaf); sha256 = (Get-NormalizedFileSha256 $p) } })
  $parts = [ordered]@{
    config        = "$($build_type.ToLowerInvariant())/$arch" + $(if ($script:cross_build) { " cross-compiled on x64" } else { "" }) + $(if ($name -eq 'akousma') { " " + ((Get-AkousmaCMakeArgs) -join ' ') } else { "" })
    sources       = $sources
    tool_patches  = $tool_patches
    local_patches = $local_patches
    recipe        = if ($recipe) { Get-TextSha256 $recipe.Text } else { "none" }
  }
  return @{ Hash = (Get-TextSha256 ($parts | ConvertTo-Json -Compress -Depth 6)); Parts = $parts }
}

function Get-StampPath([string]$name) { return "$smb_stamp_dir/$name.json" }

function Read-PackageStamp([string]$name) {
  $path = Get-StampPath $name
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  try { return (Get-Content -Raw -LiteralPath $path | ConvertFrom-Json -AsHashtable) }
  catch { Write-Warning "Unreadable stamp $path; treating $name as changed."; return @{ fingerprint = "unreadable" } }
}

function Write-PackageStamp([string]$name, [System.Collections.IDictionary]$data) {
  New-Item -ItemType Directory -Force -Path $smb_stamp_dir | Out-Null
  $path = Get-StampPath $name
  $tmp = "$path.$PID.tmp"
  Set-Content -LiteralPath $tmp -Value ($data | ConvertTo-Json -Depth 8) -Encoding utf8
  Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Complete-PackageStamp([string]$name, [string]$state = "built") {
  # After a successful build (or when adopting existing output). Computed again here, so a git package records the commit the
  # build actually used (an unpinned clone may have been pulled).
  $fp = Get-PackageFingerprint -name $name
  Write-PackageStamp $name ([ordered]@{ package = $name; fingerprint = $fp.Hash; state = $state; time = (Get-Date).ToString("s"); toolchain = [string]$env:VCToolsVersion; parts = $fp.Parts })
}

function Set-PackageStampPending([string]$name, [string]$reason) {
  # Marks a package as needing a build before it starts (or when a rebuild it needs is left out by -only / -skip): if the build
  # fails or is interrupted, the next run rebuilds it instead of trusting a half-updated prefix. The old details are kept for the reasons.
  $old = Read-PackageStamp $name
  $parts = if ($old -and $old.parts) { $old.parts } else { $null }
  $toolchain = if ($old -and $old.toolchain) { [string]$old.toolchain } else { "" }
  Write-PackageStamp $name ([ordered]@{ package = $name; fingerprint = "pending"; state = "pending"; reason = $reason; time = (Get-Date).ToString("s"); toolchain = $toolchain; parts = $parts })
}

function Get-ShortSourceId([string]$key, [string]$value) {
  if (-not $value) { return "(none)" }
  if ($key.StartsWith("git:")) { if ($value -match '^[0-9a-f]{40}$') { return $value.Substring(0, 7) } else { return $value } }
  if ($value -match '/([^/]+)/download$') { return $Matches[1] }
  return ($value -split '/')[-1]
}

function Get-FingerprintChanges($stamp, $fp) {
  $reasons = [System.Collections.Generic.List[string]]::new()
  if ($stamp.fingerprint -eq "pending") {
    $reasons.Add($(if ($stamp.reason) { [string]$stamp.reason } else { "previous build did not finish" }))
  }
  $old = $stamp.parts
  $new = $fp.Parts
  if (-not $old) {
    if ($reasons.Count -eq 0) { $reasons.Add("stamp has no details") }
    return $reasons
  }
  if ($old['config'] -ne $new['config']) { $reasons.Add("build config $($old['config']) -> $($new['config'])") }
  $old_sources = if ($old['sources']) { $old['sources'] } else { @{} }
  $new_sources = $new['sources']
  foreach ($k in $new_sources.Keys) {
    $label = $k -replace '^(git|version):', ''
    if (-not $old_sources.Contains($k)) { $reasons.Add("new source $label") }
    elseif ([string]$old_sources[$k] -ne [string]$new_sources[$k]) {
      $what = if ($k.StartsWith("git:")) { "commit" } else { "version" }
      $reasons.Add("$label $what changed $(Get-ShortSourceId $k $old_sources[$k]) -> $(Get-ShortSourceId $k $new_sources[$k])")
    }
  }
  foreach ($k in $old_sources.Keys) { if (-not $new_sources.Contains($k)) { $reasons.Add("source $($k -replace '^(git|version):', '') no longer used") } }
  $old_tools = if ($old['tool_patches']) { $old['tool_patches'] } else { @{} }
  $new_tools = $new['tool_patches']
  foreach ($k in $new_tools.Keys) {
    if (-not $old_tools.Contains($k)) { $reasons.Add("build tools patch added: $k") }
    elseif ($old_tools[$k] -ne $new_tools[$k]) { $reasons.Add("build tools patch changed: $k") }
  }
  foreach ($k in $old_tools.Keys) { if (-not $new_tools.Contains($k)) { $reasons.Add("build tools patch removed: $k") } }
  $old_local = @($old['local_patches'] | Where-Object { $_ })
  $new_local = @($new['local_patches'] | Where-Object { $_ })
  $old_by_name = @{}; foreach ($p in $old_local) { $old_by_name[[string]$p['name']] = [string]$p['sha256'] }
  $new_by_name = @{}; foreach ($p in $new_local) { $new_by_name[[string]$p['name']] = [string]$p['sha256'] }
  $local_reasons = [System.Collections.Generic.List[string]]::new()
  foreach ($p in $new_local) {
    $n = [string]$p['name']
    if (-not $old_by_name.ContainsKey($n)) { $local_reasons.Add("patch added: $n") }
    elseif ($old_by_name[$n] -ne [string]$p['sha256']) { $local_reasons.Add("patch changed: $n") }
  }
  foreach ($p in $old_local) { if (-not $new_by_name.ContainsKey([string]$p['name'])) { $local_reasons.Add("patch removed: $($p['name'])") } }
  if ($local_reasons.Count -eq 0 -and ((@($old_local | ForEach-Object { $_['name'] }) -join '|') -ne (@($new_local | ForEach-Object { $_['name'] }) -join '|'))) {
    $local_reasons.Add("patch order changed")
  }
  foreach ($r in $local_reasons) { $reasons.Add($r) }
  if ($old['recipe'] -ne $new['recipe']) { $reasons.Add("build recipe changed (build tools ref / build script)") }
  if ($reasons.Count -eq 0) { $reasons.Add("fingerprint changed") }
  return $reasons
}

function Test-LegacyPatchStamp([string]$name) {
  # Earlier versions of this script left .gst-good-patch-<sha256[0..11]> in the prefix after building gst-plugins-good with
  # -GstGoodPatch: with that file, the existing gst-plugins-good is known to contain the patch and can be adopted.
  if ($name -ne 'gst-plugins-good') { return $false }
  $patches = @(Get-LocalPatches $name)
  if ($patches.Count -ne 1 -or -not (Test-Path -LiteralPath $patches[0] -PathType Leaf)) { return $false }
  $hash = (Get-FileHash -LiteralPath $patches[0] -Algorithm SHA256).Hash.Substring(0, 12)
  return (Test-Path -LiteralPath "$prefix_path/lib/gstreamer-1.0/.gst-good-patch-$hash")
}

function Test-AkousmaRefMismatch {
  # -no_change_detection only: the old check (a pinned akousma ref that the build tree is not at). Not for a local checkout.
  if ($akousma_source -or -not $git_refs.ContainsKey('akousma') -or -not (Test-Path "$build_path/akousma/.git")) { return $false }
  $have = & git -C "$build_path/akousma" rev-parse HEAD 2>$null
  $want = & git -C "$build_path/akousma" rev-parse --verify "$($git_refs['akousma'])^{commit}" 2>$null
  $global:LASTEXITCODE = 0
  return -not ($have -and $want -and $have -eq $want)
}

function Format-NameList([string[]]$names, [int]$max = 6) {
  if ($names.Count -le $max) { return ($names -join ', ') }
  return (($names | Select-Object -First $max) -join ', ') + " and $($names.Count - $max) more"
}

function Assert-LocalPatches([System.Collections.IDictionary]$markers) {
  foreach ($name in @($smb_package_patches.Keys)) {
    if (-not $markers.Contains($name)) { throw "Local patches were given for '$name', which this build script does not build. Known packages: $($markers.Keys -join ', ')" }
    $recipe = (Get-SmbRecipes)[$name]
    if ($name -in 'akousma', 'akousma-setup') {
      throw "Local patches for '$name' are not applied: Akousma's changes are commits in the Akousma repository (-AkousmaRepo / -AkousmaSource)."
    }
    if (-not ($recipe -and $recipe.UsesCMakeOrMeson)) {
      throw "Local patches for '$name' can't be applied automatically: its recipe doesn't build through CMakeBuild / MesonBuild (where local patches are applied). Patches: $(@(Get-LocalPatches $name) -join ', ')"
    }
    foreach ($p in @(Get-LocalPatches $name)) { if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "Patch for $name not found: $p" } }
  }
}

function Get-BuildPlan {
  # Decides, per package: skip (up to date), adopt (existing output, no stamp yet: stamp it, don't rebuild), build (no output),
  # rebuild (stamp differs / forced / a dependency needs it), or excluded (-only / -skip).
  #  - Rebuilt dependencies get a clean copy; akousma is rebuilt incrementally (clean only with -force_rebuild).
  #  - First run with stamps: existing output is adopted, except akousma (always re-synced to its commit, which is cheap
  #    because files that end up unchanged keep their timestamps) and a package with local patches that can't be verified.
  #  - A rebuild of a header-only package rebuilds its direct dependents (all direct dependents with -rebuild_dependents);
  #    any rebuild relinks akousma (incremental) and re-creates AkousmaSetup.
  #  - Dependents a rebuild needs but that -only / -skip leave out get a pending stamp, so the next run rebuilds them.
  param(
    [System.Collections.IDictionary]$markers,
    [hashtable]$graph,
    [string[]]$only = @(),
    [string[]]$skip = @(),
    [string[]]$force = @(),
    [switch]$no_change_detection,
    [switch]$rebuild_dependents
  )
  # 'a,b' in one argument (pwsh -File, or a quoted list) counts as two names.
  $split = { param($names) @($names | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
  $only = & $split $only; $skip = & $split $skip; $force = & $split $force
  $plan = [ordered]@{}
  $force_all = $force -contains 'all'
  foreach ($n in @(@($force) + @($only) + @($skip) | Where-Object { $_ -and $_ -ne 'all' } | Select-Object -Unique)) {
    if (-not $markers.Contains($n)) { Write-Warning "Unknown package '$n' in -only / -skip / -force_rebuild (known: $($markers.Keys -join ', '))" }
  }
  foreach ($name in $markers.Keys) {
    $e = @{ Name = $name; Action = 'skip'; Reasons = [System.Collections.Generic.List[string]]::new(); Clean = $false; Fp = $null; Pending = $null; Own = $false }
    $plan[$name] = $e
    if ($skip -contains $name) { $e.Action = 'excluded'; $e.Reasons.Add('-skip'); continue }
    if ($only.Count -gt 0 -and $only -notcontains $name) { $e.Action = 'excluded'; $e.Reasons.Add('not in -only'); continue }
    $has_output = Test-Path $markers[$name]
    $forced = $force_all -or ($force -contains $name)
    if ($no_change_detection) {
      if ($forced) { $e.Action = 'rebuild'; $e.Clean = $true; $e.Reasons.Add('forced (-ForceRebuild)') }
      elseif (-not $has_output) { $e.Action = 'build'; $e.Reasons.Add('no output') }
      elseif ($name -eq 'akousma' -and (Test-AkousmaRefMismatch)) { $e.Action = 'rebuild'; $e.Reasons.Add("build tree is not at $($git_refs['akousma'])") }
      else { $e.Reasons.Add('output exists (change detection off)') }
      $e.Own = $e.Action -in 'build', 'rebuild'
      continue
    }
    $fp = Get-PackageFingerprint -name $name -sync
    $e.Fp = $fp
    $stamp = Read-PackageStamp $name
    if ($forced) {
      $e.Action = 'rebuild'; $e.Clean = $true; $e.Reasons.Add('forced (-ForceRebuild)')
    }
    elseif (-not $has_output) {
      $e.Action = 'build'; $e.Reasons.Add('no output')
      if ($stamp -and $stamp.fingerprint -ne $fp.Hash -and $name -ne 'akousma') { $e.Clean = $true }
    }
    elseif (-not $stamp) {
      if ($name -eq 'akousma') {
        $e.Action = 'rebuild'; $e.Reasons.Add('no stamp yet: source reset to the commit')
      }
      elseif (@(Get-LocalPatches $name).Count -gt 0 -and -not (Test-LegacyPatchStamp $name)) {
        $e.Action = 'rebuild'; $e.Clean = $true; $e.Reasons.Add("no stamp yet, and its local patches can't be verified as applied")
      }
      else {
        $e.Action = 'adopt'; $e.Reasons.Add('existing output, no stamp yet')
      }
    }
    elseif ($stamp.fingerprint -ne $fp.Hash) {
      $e.Action = 'rebuild'; $e.Clean = ($name -ne 'akousma')
      foreach ($r in (Get-FingerprintChanges $stamp $fp)) { $e.Reasons.Add($r) }
    }
    else { $e.Reasons.Add('up to date') }
    # Akousma is built incrementally, so its build folder must come from the same compiler: a new MSVC toolset (a Visual
    # Studio update) starts it again. The dependencies keep their builds (MSVC 14.x stays binary compatible).
    if ($name -eq 'akousma' -and -not $forced -and $stamp -and $stamp.toolchain -and $env:VCToolsVersion -and
        $stamp.toolchain -ne $env:VCToolsVersion) {
      if ($e.Action -notin 'build', 'rebuild') { $e.Reasons.Clear() }
      $e.Action = 'rebuild'; $e.Clean = $true
      $e.Reasons.Add("MSVC toolset changed $($stamp.toolchain) -> $($env:VCToolsVersion) (clean rebuild)")
    }
    $e.Own = $e.Action -in 'build', 'rebuild'
  }
  if ($no_change_detection) { return $plan }

  # Dependents of rebuilt packages.
  do {
    $changed = $false
    foreach ($p in @($plan.Keys | Where-Object { $plan[$_].Action -in 'build', 'rebuild' })) {
      $embed = $smb_embedded_packages -contains $p
      $relink = $rebuild_dependents -and $plan[$p].Own -and ($smb_tool_packages -notcontains $p)
      if (-not $embed -and -not $relink) { continue }
      foreach ($d in @($plan.Keys)) {
        if ($d -in 'akousma', 'akousma-setup') { continue }   # below
        if (-not $graph.ContainsKey($d) -or @($graph[$d]) -notcontains $p) { continue }
        $de = $plan[$d]
        if ($de.Action -in 'build', 'rebuild') { continue }
        $why = if ($embed) { "uses $p (header-only), which is rebuilt" } else { "links $p, which is rebuilt (-RebuildDependents)" }
        if ($de.Action -eq 'excluded') { if (-not $de.Pending) { $de.Pending = $why }; continue }
        $de.Action = 'rebuild'; $de.Clean = $true; $de.Reasons.Clear(); $de.Reasons.Add($why)
        $changed = $true
      }
    }
  } while ($changed)

  $rebuilt = @($plan.Keys | Where-Object { $plan[$_].Action -in 'build', 'rebuild' -and $_ -notin 'akousma', 'akousma-setup' })
  if ($rebuilt.Count -gt 0 -and $plan.Contains('akousma')) {
    $se = $plan['akousma']
    $why = "dependencies rebuilt: $(Format-NameList $rebuilt) (relink)"
    if ($se.Action -in 'skip', 'adopt') { $se.Action = 'rebuild'; $se.Reasons.Clear(); $se.Reasons.Add($why) }
    elseif ($se.Action -eq 'excluded' -and -not $se.Pending) { $se.Pending = $why }
  }
  if ($plan.Contains('akousma-setup')) {
    $all_rebuilt = @($plan.Keys | Where-Object { $plan[$_].Action -in 'build', 'rebuild' -and $_ -ne 'akousma-setup' })
    $ue = $plan['akousma-setup']
    if ($all_rebuilt.Count -gt 0) {
      $why = "packages rebuilt: $(Format-NameList $all_rebuilt)"
      if ($ue.Action -in 'skip', 'adopt') { $ue.Action = 'rebuild'; $ue.Reasons.Clear(); $ue.Reasons.Add($why) }
      elseif ($ue.Action -eq 'excluded' -and -not $ue.Pending) { $ue.Pending = $why }
    }
    if ($ue.Action -in 'build', 'rebuild') { $ue.Clean = $true }   # a fresh AkousmaSetup folder: no DLLs left over from older builds
  }
  return $plan
}

function Write-BuildPlan($plan, [switch]$no_change_detection) {
  $mode = if ($no_change_detection) { "off (-NoChangeDetection: output markers only)" } else { "stamps in $smb_stamp_dir" }
  Write-Host "Change detection: $mode" -ForegroundColor Cyan
  $colors = @{ skip = 'DarkGray'; adopt = 'DarkCyan'; build = 'Yellow'; rebuild = 'Yellow'; excluded = 'DarkGray' }
  foreach ($name in $plan.Keys) {
    $e = $plan[$name]
    $how = ""
    if ($e.Action -eq 'rebuild') { $how = if ($e.Clean) { " [clean]" } else { " [incremental]" } }
    $text = ($e.Reasons -join '; ')
    if ($e.Pending) { $text += "; needs a rebuild ($($e.Pending)): marked for the next run" }
    Write-Host ("  {0,-8} {1,-20} {2}{3}" -f $e.Action, $name, $text, $how) -ForegroundColor $colors[$e.Action]
  }
  $count = { param($a) @($plan.Values | Where-Object { $_.Action -eq $a }).Count }
  Write-Host ("  => {0} to build, {1} to rebuild, {2} adopted, {3} up to date, {4} excluded" -f (& $count 'build'), (& $count 'rebuild'), (& $count 'adopt'), (& $count 'skip'), (& $count 'excluded')) -ForegroundColor Cyan
  Write-Host ""
}

function Save-PlanStamps($plan) {
  foreach ($name in $plan.Keys) {
    $e = $plan[$name]
    if ($e.Action -eq 'adopt') { Complete-PackageStamp -name $name -state "adopted" }
    elseif ($e.Action -in 'build', 'rebuild') {
      # A rebuild that only follows from other packages has no change of its own to show next time: keep the reason.
      $why = if ($e.Fp -and $e.Reasons.Count -gt 0 -and ($e.Reasons[0] -like 'dependencies rebuilt:*' -or $e.Reasons[0] -like 'packages rebuilt:*' -or $e.Reasons[0] -like 'uses *' -or $e.Reasons[0] -like 'links *')) { " ($($e.Reasons[0]))" } else { "" }
      Set-PackageStampPending $name "previous build did not finish$why"
    }
    elseif ($e.Action -eq 'excluded' -and $e.Pending) { Set-PackageStampPending $name $e.Pending }
  }
}

function Clear-ForCleanBuild([string]$path) {
  # Clean rebuild of the current package: remove a folder of it (source copy, extracted tree, build folder) the first time the
  # build touches it in this process, so nothing from the previous build lingers. Never outside build_path.
  if (-not $path -or -not $script:smb_component -or -not $script:smb_clean_packages.Contains($script:smb_component)) { return }
  $full = [System.IO.Path]::GetFullPath($path, (Get-Location).Path).TrimEnd('\', '/')
  $root = [System.IO.Path]::GetFullPath($script:build_path).TrimEnd('\', '/')
  $sep = [System.IO.Path]::DirectorySeparatorChar
  if (-not $full.StartsWith($root + $sep, [StringComparison]::OrdinalIgnoreCase)) { return }
  # Once per folder, and never inside a folder already cleaned in this process: never remove what this build just made.
  # Such a folder is the fresh tree ExtractPackage just unpacked (or a fresh source copy), so a folder in it came from the
  # tarball: tiff's own build\ (its CMakeLists.txt does add_subdirectory(build)) is also CMakeBuild's default build folder.
  foreach ($cleaned in $script:smb_cleaned_dirs) {
    if ($full.StartsWith($cleaned + $sep, [StringComparison]::OrdinalIgnoreCase)) { return }
  }
  if (-not $script:smb_cleaned_dirs.Add($full)) { return }
  if (Test-Path -LiteralPath $full) {
    Write-Host "Clean rebuild of $($script:smb_component): removing $full" -ForegroundColor DarkYellow
    Remove-Item -LiteralPath $full -Recurse -Force
  }
}

function Clear-ComponentBuildDirs([string]$component) {
  foreach ($dir in @($component) + @($smb_extra_build_dirs[$component] | Where-Object { $_ })) {
    Clear-ForCleanBuild "$($script:build_path)/$dir"
  }
}

function Invoke-LocalPatches {
  # Applies the local patches of the current package (-package_patches), in order, -p1 from $root. Called by CMakeBuild /
  # MesonBuild (so after the build tools' own patches); once per package and process.
  # A patch that is already applied is skipped. Git binary diffs (e.g. new icons) are applied with git apply, the rest with
  # GNU patch, with the line endings of the tree (tarballs and Windows checkouts can have either).
  param([string]$root = ".", [string]$component = $script:smb_component)
  if (-not $component -or -not $script:smb_patched_components.Add($component)) { return }
  $patches = @(Get-LocalPatches $component)
  if ($patches.Count -eq 0) { return }
  # One line per patch (applied / already applied / failed), so the log shows exactly what went into this build.
  $count = $patches.Count
  $applied = 0; $already = 0
  Write-Host "$component local patches ($count, in this order): $((@($patches) | ForEach-Object { Split-Path $_ -Leaf }) -join ', ')" -ForegroundColor Cyan
  Push-Location $root
  try {
    $number = 0
    foreach ($patch_path_item in $patches) {
      $number++
      if (-not (Test-Path -LiteralPath $patch_path_item)) { throw "$component patch [$number/$count] not found: $patch_path_item" }
      $patch_file = (Resolve-Path -LiteralPath $patch_path_item).Path
      $patch_name = Split-Path $patch_file -Leaf
      $was_applied = $false; $was_already = $false
      $text_sections = [System.Text.StringBuilder]::new()
      $binary_sections = [System.Text.StringBuilder]::new()
      foreach ($section in [regex]::Split([System.IO.File]::ReadAllText($patch_file).Replace("`r`n", "`n"), '(?m)^(?=diff --git )')) {
        if ($section.Contains("`nGIT binary patch`n")) { [void]$binary_sections.Append($section) } else { [void]$text_sections.Append($section) }
      }
      $patch_text = $text_sections.ToString()
      $has_text = $patch_text.Contains("`n+++ ") -or $patch_text.StartsWith("+++ ")
      if (-not $has_text -and $binary_sections.Length -eq 0) {
        throw "$component patch [$number/$count] $patch_name FAILED: it contains no diff (no '+++ ' file header, no GIT binary patch): $patch_file"
      }
      if ($has_text) {
        # Line endings: those of the first file the patch changes that exists here.
        $tree_has_crlf = $false
        foreach ($m in [regex]::Matches($patch_text, '(?m)^\+\+\+ [^/\t\n]*/([^\t\n]+)')) {
          $target = $m.Groups[1].Value.Trim()
          if (Test-Path -LiteralPath $target -PathType Leaf) { $tree_has_crlf = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $target).Path).Contains("`r`n"); break }
        }
        if ($tree_has_crlf) { $patch_text = $patch_text.Replace("`n", "`r`n") }
        $patch_local = Join-Path $script:build_path "$component-local-$number.patch"
        [System.IO.File]::WriteAllText($patch_local, $patch_text, [System.Text.UTF8Encoding]::new($false))
        # Already applied? -f: never ask (an "Unreversed patch detected! Ignore -R?" prompt would wait for input or be answered).
        & patch -p1 --binary --dry-run -R -f -s -i $patch_local *> $null
        if ($LASTEXITCODE -eq 0) {
          $was_already = $true
        }
        else {
          Write-Host "Applying $component patch [$number/$count]: $patch_name" -ForegroundColor Cyan
          & patch -p1 --binary -N --batch -i $patch_local
          if ($LASTEXITCODE -ne 0) {
            throw "$component patch [$number/$count] $patch_name FAILED to apply (patch exit code $LASTEXITCODE; the rejected hunks are listed above). " +
                  "The build stops here: fix or remove $patch_file and run again."
          }
          $was_applied = $true
        }
      }
      if ($binary_sections.Length -gt 0) {
        $patch_local = Join-Path $script:build_path "$component-local-$number-binary.patch"
        [System.IO.File]::WriteAllText($patch_local, $binary_sections.ToString(), [System.Text.UTF8Encoding]::new($false))
        # Paths in the patch are relative to this folder: don't let git use a repository above it, where git apply would skip paths outside the current folder.
        $old_ceiling_directories = $env:GIT_CEILING_DIRECTORIES
        $env:GIT_CEILING_DIRECTORIES = Split-Path (Get-Location).Path -Parent
        try {
          & git apply -R --check $patch_local *> $null
          if ($LASTEXITCODE -eq 0) {
            if (-not $was_applied) { $was_already = $true }
          }
          else {
            Write-Host "Applying $component patch [$number/$count] binary files: $patch_name" -ForegroundColor Cyan
            & git apply $patch_local
            if ($LASTEXITCODE -ne 0) {
              throw "$component patch [$number/$count] $patch_name FAILED: its binary files could not be applied (git apply exit code $LASTEXITCODE). " +
                    "The build stops here: fix or remove $patch_file and run again."
            }
            $was_applied = $true; $was_already = $false
          }
        }
        finally {
          $env:GIT_CEILING_DIRECTORIES = $old_ceiling_directories
        }
      }
      if ($was_applied) {
        $applied++
        Write-Host "$component patch [$number/$count] applied: $patch_name" -ForegroundColor Green
      }
      elseif ($was_already) {
        $already++
        # a git build copy was just reset to the commit, so this only happens for a patch whose changes an earlier patch in
        # the list already made (a duplicate); other packages: a tree that was patched before.
        Write-Host "$component patch [$number/$count] skipped, already applied: $patch_name (its changes are already in the source)" -ForegroundColor Yellow
      }
    }
    Write-Host "$component local patches: $applied applied, $already already applied, 0 failed (of $count)" -ForegroundColor Green
  }
  finally {
    Pop-Location
  }
}

function Sync-GitBuildCopy {
  # Run in a build copy of a git clone (e.g. <build_path>/akousma, a copy of <src_path>/akousma with its .git).
  # Puts it at the source clone's HEAD with no local changes, keeping the 'build' folder (CMake's) and ignored files.
  # Returns the content hash + timestamp of every file that differed from the commit before (an earlier run's patches),
  # for Restore-UnchangedTimestamps. A copy of those changes is kept in <build_path>/<name>-before-sync.diff.
  param([string]$src_repo, [string]$name)
  $target = & git -C $src_repo rev-parse HEAD
  if ($LASTEXITCODE -ne 0 -or -not $target) { throw "Could not read the $name commit in $src_repo" }
  $target = ([string]@($target)[0]).Trim()
  if (-not (Test-Path -LiteralPath ".git")) { Write-Warning "$((Get-Location).Path) is not a git checkout; patches are applied on top of it as they are."; return $null }
  $saved = @{}
  $status = (& git status --porcelain=v1 -z --untracked-files=all -- . ':(exclude)build') -join "`n"
  $entries = $status -split "`0"
  for ($i = 0; $i -lt $entries.Count; $i++) {
    $entry = $entries[$i].TrimStart("`n")
    if ($entry.Length -lt 4) { continue }
    if ($entry[0] -in 'R', 'C') { $i++ }   # a rename/copy is followed by the old name
    $path = $entry.Substring(3)
    if (Test-Path -LiteralPath $path -PathType Leaf) {
      $saved[$path] = @{ Hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash; Time = (Get-Item -LiteralPath $path).LastWriteTimeUtc }
    }
  }
  $head = & git rev-parse HEAD 2>$null
  if ($saved.Count -gt 0) {
    $backup = "$($script:build_path)/$name-before-sync.diff"
    & git diff --binary "--output=$backup" HEAD 2>$null
    Write-Host "$name build copy: $($saved.Count) file(s) differ from $(([string]@($head)[0]).Substring(0, [Math]::Min(7, ([string]@($head)[0]).Length))) (earlier patches); a copy of the tracked changes is in $backup" -ForegroundColor DarkCyan
  }
  & git cat-file -e "$target^{commit}" 2>$null
  if ($LASTEXITCODE -ne 0) {
    & git fetch --force --tags $src_repo HEAD
    & git cat-file -e "$target^{commit}" 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Commit $target is not in $((Get-Location).Path) and could not be fetched from $src_repo" }
  }
  Write-Host "$name build copy: resetting to $($target.Substring(0, 7)) (keeping the build folder)" -ForegroundColor Cyan
  & git checkout --force --detach $target
  if ($LASTEXITCODE -ne 0) { throw "git checkout $target failed in $((Get-Location).Path)" }
  & git clean -fdq -- . ':(exclude)build'
  if ($LASTEXITCODE -ne 0) { throw "git clean failed in $((Get-Location).Path)" }
  if (Test-Path -LiteralPath ".gitmodules") {
    & git submodule update --init --recursive
    if ($LASTEXITCODE -ne 0) { throw "Failed to update submodules in $((Get-Location).Path)" }
  }
  return $saved
}

function Restore-UnchangedTimestamps($saved, [string]$name) {
  # Files the reset + re-patch left exactly as they were get their old timestamps back, so the build doesn't recompile them.
  if (-not $saved -or $saved.Count -eq 0) { return }
  $kept = 0
  foreach ($path in $saved.Keys) {
    if ((Test-Path -LiteralPath $path -PathType Leaf) -and (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -eq $saved[$path].Hash) {
      (Get-Item -LiteralPath $path).LastWriteTimeUtc = $saved[$path].Time
      $kept++
    }
  }
  Write-Host "$name build copy: $kept of $($saved.Count) earlier-patched file(s) are unchanged and keep their timestamps; $($saved.Count - $kept) changed or removed" -ForegroundColor DarkCyan
}

#endregion

#region Main Build Logic

Write-Host "Starting build process..." -ForegroundColor Cyan
Write-Host ""

try {
  $package_markers = Get-PackageMarkers

  if ($child_build) {
    # A child process of the parallel build: the parent already decided to build this package.
    $build_queue = @($only)
  }
  else {
    Assert-LocalPatches $package_markers
    # --- patched: x86 ---
    # gst-plugins-rs (the Spotify plugin) is built for x86_64 only, like upstream's CI did when it still built x86, and the
    # x86 AkousmaSetup doesn't list it. It would also need Rust's i686-pc-windows-msvc target.
    if ($arch -eq "x86" -and @($skip | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() }) -notcontains 'gst-plugins-rs') {
      Write-Host "x86: gst-plugins-rs (Spotify) is not built for x86 (skipped like -Skip gst-plugins-rs)." -ForegroundColor Cyan
      $skip = @($skip) + @('gst-plugins-rs')
    }
    # --- patched: arm64 cross-compile on an x64 PC ---
    # yasm (an x86 assembler) builds its generators (genperf, re2c, ...) and runs them, and no arm64 package uses it.
    # gst-plugins-rs (Spotify): the arm64 AkousmaSetup doesn't contain it (akousma.nsi lists gstspotify.dll for x64 only).
    # -Only <name> builds either anyway.
    if ($cross_build) {
      $only_names = @($only | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() })
      $skip_names = @($skip | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() })
      foreach ($n in 'yasm', 'gst-plugins-rs') {
        if ($only_names -notcontains $n -and $skip_names -notcontains $n) {
          Write-Host "arm64 cross-compile: $n is not built (skipped like -Skip $n)." -ForegroundColor Cyan
          $skip = @($skip) + @($n)
        }
      }
    }
    $plan = Get-BuildPlan -markers $package_markers -graph (Get-PackageDependencies) -only $only -skip $skip -force $force_rebuild `
                          -no_change_detection:$no_change_detection -rebuild_dependents:$rebuild_dependents
    Write-BuildPlan $plan -no_change_detection:$no_change_detection
    $build_queue = @($plan.Keys | Where-Object { $plan[$_].Action -in 'build', 'rebuild' })
    $clean_queue = @($build_queue | Where-Object { $plan[$_].Clean })
    if ($list) {
      Write-Host "Build queue: $(if ($build_queue.Count) { $build_queue -join ', ' } else { '(nothing)' })" -ForegroundColor Cyan
      exit 0
    }
    if ($cross_build -and $build_queue.Count -gt 0) { Assert-CrossHostTools $build_queue }
    Save-PlanStamps $plan
    $script:smb_clean_packages.Clear()
    foreach ($c in $clean_queue) { [void]$script:smb_clean_packages.Add($c) }
    $env:SMB_CLEAN_PACKAGES = $clean_queue -join ';'   # for the parallel build's child processes
  }

  if ($build_queue.Count -eq 0) {
    Write-Host "Nothing to build: every package is up to date." -ForegroundColor Green
    exit 0
  }

  Write-Host "Build queue: $($build_queue -join ', ')" -ForegroundColor Cyan
  Write-Host ""

  if ($parallel_packages -gt 1 -and $build_queue.Count -gt 1) {
    Invoke-ParallelQueue -queue $build_queue
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "Build completed successfully!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    exit 0
  }

  # Build each component
  foreach ($component in $build_queue) {
    Write-Host "========================================" -ForegroundColor Magenta
    Write-Host "Building: $component" -ForegroundColor Magenta
    Write-Host "========================================" -ForegroundColor Magenta

    $script:smb_component = $component
    Clear-ComponentBuildDirs $component

    switch ($component) {
      "pkgconf" { Build-PkgConf }
      "yasm" { Build-Yasm }
      "proxy-libintl" { Build-ProxyIntl }
      "getopt-win" { Build-GetOptWin }
      "zlib" { Build-Zlib }
      "openssl" { Build-OpenSSL }
      "libpng" { Build-LibPNG }
      "libjpeg-turbo" { Build-LibJPEGTurbo }
      "pcre2" { Build-PCRE2 }
      "bzip2" { Build-BZip2 }
      "xz" { Build-XZ }
      "brotli" { Build-Brotli }
      "uchardet" { Build-UChardet }
      "icu4c" { Build-ICU4C }
      "pixman" { Build-Pixman }
      "expat" { Build-Expat }
      "libxml2" { Build-LibXML2 }
      "nghttp2" { Build-NgHttp2 }
      "libffi" { Build-LibFFI }
      "dlfcn-win32" { Build-DlfcnWin32 }
      "libpsl" { Build-LibPSL }
      "orc" { Build-Orc }
      "sqlite" { Build-SQLite }
      "glib" { Build-Glib }
      "libsoup" { Build-LibSoup }
      "glib-networking" { Build-GlibNetworking }
      "freetype" { Build-Freetype -with_harfbuzz $false }
      "harfbuzz" { Build-Harfbuzz }
      "jasper" { Build-Jasper }
      "tiff" { Build-Tiff }
      "libwebp" { Build-LibWebP }
      "ogg" { Build-Ogg }
      "vorbis" { Build-Vorbis }
      "flac" { Build-Flac }
      "wavpack" { Build-WavPack }
      "opus" { Build-Opus }
      "opusfile" { Build-Opusfile }
      "speex" { Build-Speex }
      "mpg123" { Build-MPG123 }
      "lame" { Build-Lame }
      "fftw3" { Build-FFTW3 }
      "musepack" { Build-Musepack }
      "libopenmpt" { Build-LibOpenMPT }
      "libgme" { Build-LibGME }
      "fdk-aac" { Build-FdkAac }
      "faad2" { Build-Faad2 }
      "faac" { Build-Faac }
      "utfcpp" { Build-UtfCpp }
      "taglib" { Build-TagLib }
      "libbs2b" { Build-LibBS2B }
      "libebur128" { Build-LibEBUR128 }
      "libcdio" { Build-LibCdio }
      "ffmpeg" { Build-FFMpeg }
      "chromaprint" { Build-Chromaprint }
      "gstreamer" { Build-GStreamer }
      "gst-plugins-base" { Build-GstPluginsBase }
      "gst-plugins-good" { Build-GstPluginsGood }
      "gst-plugins-bad" { Build-GstPluginsBad }
      "gst-plugins-ugly" { Build-GstPluginsUgly }
      "gst-libav" { Build-GstLibAv }
      "gst-plugins-rs" { Build-GstPluginsRs }
      "qtbase" { Build-QtBase }
      "qttools" { Build-QtTools }
      "qtimageformats" { Build-QtImageFormats }
      "qtsvg" { Build-QtSvg }
      "kdsingleapplication" { Build-KDSingleApplication }
      "qtsparkle" { Build-QtSparkle }
      "sparsehash" { Build-SparseHash }
      "googletest" { Build-GoogleTest }
      "pe-parse" { Build-PeParse }
      "pe-util" { Build-PeUtil }
      "akousma" { Build-Akousma }
      "akousma-setup" { Build-AkousmaSetup }
      default {
        Write-Warning "Unknown component: $component (skipping)"
      }
    }

    Complete-PackageStamp -name $component   # patched: change detection stamp
    $script:smb_component = ""
    Write-Host "Completed: $component" -ForegroundColor Green
    Write-Host ""
  }

  Write-Host "========================================" -ForegroundColor Green
  Write-Host "Build completed successfully!" -ForegroundColor Green
  Write-Host "========================================" -ForegroundColor Green
  exit 0

}
catch {
  Write-Host ""
  Write-Host "========================================" -ForegroundColor Red
  Write-Host "Build failed!" -ForegroundColor Red
  Write-Host "Error: $_" -ForegroundColor Red
  Write-Host "========================================" -ForegroundColor Red
  exit 1
}

#endregion
