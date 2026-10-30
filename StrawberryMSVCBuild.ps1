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
  Build script for Strawberry MSVC dependencies
.DESCRIPTION
  Builds all dependencies required for Strawberry Music Player on Windows using MSVC
.PARAMETER build_type
  Build type: debug or release (default: debug)
.PARAMETER arch
  Architecture: x86, x64, x86_64, amd64, or arm64
.PARAMETER src_path
  Where git sources (strawberry, qt*, gstreamer, ffmpeg, ...) are cloned. Empty = same as downloads_path.
.PARAMETER downloads_path
  Path to downloads directory (default: <root>/data/projects/strawberry/msvc_/downloads)
.PARAMETER build_path
  Path to build directory (default: <root>/data/projects/strawberry/msvc_/build_<arch>_<build_type>, where <arch> and <build_type> are substituted with the actual parameter values)
.PARAMETER prefix_path
  Install prefix (default: <root>/strawberry_msvc_<arch>_<build_type>)
.NOTES
  <root> is $env:STRAWBERRY_ROOT if set (Build-Strawberry.ps1 sets it to its -WorkRoot), otherwise C: (upstream's default).
  Tools (git usr/bin tools, nasm, win_flex/win_bison, perl, python, 7z, cmake, meson) are taken from PATH first, then
  registry / usual install folders; add extra folders (';'-separated) with $env:SMB_TOOL_PATHS.
.PARAMETER jobs
  Parallel jobs used inside every package (jom, ninja, b2, msbuild, cargo, cl /MP). Default: logical processors.
.PARAMETER parallel_packages
  Build this many independent packages at the same time (default 1 = sequential, like upstream).
  Uses a dependency graph and one child pwsh process per package; logs go to -log_dir.
.PARAMETER versions_file
  Use another StrawberryPackageVersions.txt instead of the one next to this script.
.PARAMETER ci_versions_file
  Path/URL of a strawberry-msvc-dependencies .github/workflows/build.yaml; its *_version values override the versions file.
.PARAMETER version_overrides
  Hashtable, e.g. @{ qt_version = '6.11.2'; boost_version = '1.92.0' }. Applied last.
.PARAMETER strawberry_ref
  Tag/branch/commit of the strawberry source to build (e.g. 1.2.30). Upstream builds master otherwise.
.PARAMETER git_refs
  Hashtable pinning any git-sourced component, e.g. @{ 'gst-plugins-rs' = '0.15.3'; ffmpeg = '<sha>' }.
.PARAMETER only
  Build only these components (still skipped if already built).
.PARAMETER skip
  Never build these components.
.PARAMETER list
  Print the build queue and exit.
.PARAMETER jom_path
  Folder containing jom.exe (otherwise PATH, otherwise downloaded to <downloads_path>/jom, otherwise nmake fallback).
.PARAMETER log_dir
  Per-package logs when -parallel_packages > 1 (default <build_path>/logs).
.PARAMETER package_patches
  Local patches per package, e.g. @{ strawberry = @('a.patch', 'b.patch'); 'gst-plugins-good' = @('c.patch') }: -p1, applied in
  order after the build tools' own patches (strawberry: after its source is reset to the commit). Only for packages built with
  CMakeBuild / MesonBuild, and strawberry. SMB_STRAWBERRY_PATCH (';'-separated) and SMB_GST_GOOD_PATCH are still read when
  this has no entry for those two.
.PARAMETER force_rebuild
  Rebuild these packages even if they are up to date ('all' = every package). Dependencies are rebuilt from a clean copy,
  strawberry from a fresh copy of its source and an empty build folder.
.PARAMETER no_change_detection
  Decide like upstream: build what has no output, skip everything else (stamps are still written after builds).
.PARAMETER rebuild_dependents
  When a package is rebuilt for a change of its own, also rebuild its direct dependents (shared libraries included).
  Without it only dependents of header-only packages are rebuilt (plus strawberry's relink and StrawberrySetup, always).
.PARAMETER child_build
  Internal: a child process of the parallel build, building -only <package> without deciding again.
.EXAMPLE
  ./StrawberryMSVCBuild.ps1 -build_type release -arch x86_64
.EXAMPLE
  ./StrawberryMSVCBuild.ps1 -build_type debug -arch x86_64 -downloads_path "D:/strawberry/downloads" -build_path "D:/strawberry/build"
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)]
  [ValidateSet("debug", "release", "Debug", "Release")]
  [string]$build_type,

  [Parameter(Mandatory=$true)]
  [ValidateSet("x86", "x64", "x86_64", "amd64", "arm64")]
  [string]$arch,

  [Parameter(Mandatory=$false)]
  [string]$downloads_path = "",

  [Parameter(Mandatory=$false)]
  [string]$src_path = "",

  [Parameter(Mandatory=$false)]
  [string]$build_path = "",

  [Parameter(Mandatory=$false)]
  [string]$prefix_path = "",

  [Parameter(Mandatory=$false)]
  [ValidateRange(0, 512)]
  [int]$jobs = 0,

  [Parameter(Mandatory=$false)]
  [ValidateRange(0, 64)]
  [int]$parallel_packages = 1,

  [Parameter(Mandatory=$false)]
  [string]$versions_file = "",

  [Parameter(Mandatory=$false)]
  [string]$ci_versions_file = "",

  [Parameter(Mandatory=$false)]
  [hashtable]$version_overrides = @{},

  [Parameter(Mandatory=$false)]
  [string]$strawberry_ref = "",

  [Parameter(Mandatory=$false)]
  [hashtable]$git_refs = @{},

  [Parameter(Mandatory=$false)]
  [string[]]$only = @(),

  [Parameter(Mandatory=$false)]
  [string[]]$skip = @(),

  [Parameter(Mandatory=$false)]
  [switch]$list,

  [Parameter(Mandatory=$false)]
  [string]$jom_path = "",

  [Parameter(Mandatory=$false)]
  [string]$log_dir = "",

  [Parameter(Mandatory=$false)]
  [hashtable]$package_patches = @{},

  [Parameter(Mandatory=$false)]
  [string[]]$force_rebuild = @(),

  [Parameter(Mandatory=$false)]
  [switch]$no_change_detection,

  [Parameter(Mandatory=$false)]
  [switch]$rebuild_dependents,

  [Parameter(Mandatory=$false)]
  [switch]$child_build
)

# --- patched: jobs default, hashtables handed down by the parallel scheduler ---
if ($jobs -le 0) { $jobs = [Environment]::ProcessorCount }
if ($parallel_packages -le 0) { $parallel_packages = [Math]::Max(2, [int][Math]::Ceiling($jobs / 2)) }   # 0 = auto
if ($version_overrides.Count -eq 0 -and $env:SMB_VERSION_OVERRIDES_JSON) {
  $version_overrides = $env:SMB_VERSION_OVERRIDES_JSON | ConvertFrom-Json -AsHashtable
}
if ($git_refs.Count -eq 0 -and $env:SMB_GIT_REFS_JSON) {
  $git_refs = $env:SMB_GIT_REFS_JSON | ConvertFrom-Json -AsHashtable
}
if ($strawberry_ref) { $git_refs['strawberry'] = $strawberry_ref }
# --- patched: local patches per package (wrapper: patches\ folder, -StrawberryPatch, -GstGoodPatch) ---
if ($child_build -and $package_patches.Count -eq 0 -and $env:SMB_PACKAGE_PATCHES_JSON) {
  $package_patches = $env:SMB_PACKAGE_PATCHES_JSON | ConvertFrom-Json -AsHashtable
}
$smb_package_patches = @{}
foreach ($k in @($package_patches.Keys)) {
  $patch_list = @($package_patches[$k] | Where-Object { $_ } | ForEach-Object { [string]$_ })
  if ($patch_list.Count -gt 0) { $smb_package_patches[[string]$k] = $patch_list }
}
if (-not $child_build) {
  # Older wrappers passed these two environment variables instead.
  if (-not $smb_package_patches.ContainsKey('strawberry') -and $env:SMB_STRAWBERRY_PATCH) { $smb_package_patches['strawberry'] = @($env:SMB_STRAWBERRY_PATCH -split ';' | Where-Object { $_ }) }
  if (-not $smb_package_patches.ContainsKey('gst-plugins-good') -and $env:SMB_GST_GOOD_PATCH) { $smb_package_patches['gst-plugins-good'] = @($env:SMB_GST_GOOD_PATCH) }
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
# Defaults hang off STRAWBERRY_ROOT, else C: (upstream's default, whatever drive this script is on). Tools are found
# on PATH first, then via registry (Git, Python, 7-Zip, CMake), then in the usual install
# folders under Program Files / LOCALAPPDATA\Programs / the system drive / the work drive,
# then in any folders listed in SMB_TOOL_PATHS (';'-separated).
function Get-StrawberryWorkRoot {
  if ($env:STRAWBERRY_ROOT) { return $env:STRAWBERRY_ROOT.Replace('\', '/').TrimEnd('/') }
  return 'C:'
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

function Get-ToolSearchRoots {
  $work = Get-StrawberryWorkRoot
  return @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)}, "$env:LOCALAPPDATA/Programs", "$env:SystemDrive/", "$work/") |
    Where-Object { $_ } | ForEach-Object { $_.Replace('\', '/').TrimEnd('/') } | Select-Object -Unique
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

function Import-CIVersions {
  # Reads "<name>_version: 'x'" lines from strawberry-msvc-dependencies' build.yaml.
  # Only variables that already exist in the versions file are overridden.
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)][string]$file)
  $alias = @{ 'sqlite3' = 'sqlite'; 'fftw_mingw' = 'fftw'; 'gstreamer_plugins_rs' = 'gstreamer_gst_plugins_rs'; 'pe_parse' = 'peparse' }
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
      Write-Host "  CI version: $var $old -> $($m.Groups[2].Value)" -ForegroundColor DarkCyan
    }
  }
}

# Set strict mode
$ErrorActionPreference = "Stop"

Write-Host "========================================" -ForegroundColor Green
Write-Host "Strawberry MSVC Dependencies Build Script" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""

# Load versions

$script_path = Split-Path -Parent $MyInvocation.MyCommand.Path
$version_file = if ($versions_file) { $versions_file } else { Join-Path $script_path "StrawberryPackageVersions.txt" }
$patch_path = Join-Path $script_path "patches"

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
  Set-Variable -Name $name -Value ([string]$version_overrides[$k]) -Scope Global
}

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
  default {
    Write-Error "Unsupported host architecture: $arch_numeric_id"
    exit 1
  }
}

$vs_host_arch = $vs_host_arch.ToLower()
$arch = $arch.ToLower()

if ($arch -eq "x64" -or $arch -eq "x86_64" -or $arch -eq "amd64") {
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

# Set paths
# Use default build path if not specified
$work_root = Get-StrawberryWorkRoot
if ([string]::IsNullOrEmpty($downloads_path)) {
  $downloads_path = "$work_root/data/projects/strawberry/msvc_/downloads"
}

if ([string]::IsNullOrEmpty($build_path)) {
  $build_path = "$work_root/data/projects/strawberry/msvc_/build_${arch}_${build_type}"
}

if ([string]::IsNullOrEmpty($prefix_path)) {
  $prefix_path = "$work_root/strawberry_msvc_${arch}_${build_type}"
}
$downloads_path = $downloads_path.Replace('\', '/').TrimEnd('/')
if ([string]::IsNullOrEmpty($src_path)) { $src_path = $downloads_path }
$src_path = $src_path.Replace('\', '/').TrimEnd('/')
$build_path = $build_path.Replace('\', '/').TrimEnd('/')
$prefix_path = $prefix_path.Replace('\', '/').TrimEnd('/')
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
$env:PKG_CONFIG_EXECUTABLE = "$prefix_path/bin/pkgconf.exe"
$env:PKG_CONFIG_PATH = "$prefix_path/lib/pkgconfig"
$env:PKG_CONFIG_ALLOW_SYSTEM_CFLAGS = "1"
$env:PKG_CONFIG_ALLOW_SYSTEM_LIBS = "1"
$env:CL = "-MP$jobs"
$env:CMAKE_BUILD_PARALLEL_LEVEL = "$jobs"
$env:CARGO_BUILD_JOBS = "$jobs"
Initialize-Jom
$env:YASMPATH = "$prefix_path/bin"

PrependPathToEnvPath -path "$prefix_path/bin"

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

function DownloadFileIfNotExists {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [string]$url,

    [Parameter(Mandatory=$true)]
    [string]$destination_path
  )
  # Handle SourceForge URLs that end with /download
  $filename = Split-Path $url -Leaf
  if ($filename -eq 'download' -and $url -match '/([^/]+)/download$') {
    $filename = $matches[1]
  }
  $file_path = Join-Path $destination_path $filename
  if (-not (Test-Path $file_path)) {
    Write-Host "Downloading $url" -ForegroundColor Yellow
    # patched: download to a private .part file and rename it into place, so a parallel package
    # (or the prefetch job) never mistakes a half-written archive for a finished download.
    $part_path = "$file_path.$PID.part"
    try {
      Invoke-WebRequest -Uri $url -OutFile $part_path -UseBasicParsing -MaximumRedirection 5 -UserAgent "Wget"
      # Verify file was downloaded and has content
      if (-not (Test-Path $part_path)) {
        throw "Downloaded file not found at $part_path"
      }
      $file_size = (Get-Item $part_path).Length
      if ($file_size -eq 0) {
        throw "Downloaded file is empty (0 bytes)"
      }
      if (Test-Path $file_path) {
        Remove-Item $part_path -Force   # someone else (prefetch) finished first
      }
      else {
        try { [System.IO.File]::Move($part_path, $file_path) }   # no overwrite: throws if it appeared meanwhile
        catch {
          if (Test-Path $part_path) { Remove-Item $part_path -Force }
          if (-not (Test-Path $file_path)) { throw }
        }
      }
      Write-Host "Downloaded $filename ($file_size bytes)" -ForegroundColor Green
    }
    catch {
      if (Test-Path $part_path) {
        Remove-Item $part_path -Force
      }
      Write-Error "Failed to download $url : $_"
      throw
    }
  }
  else {
    Write-Host "Using cached $filename" -ForegroundColor Cyan
  }
}

function SyncGitRepository {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [string]$url,

    [Parameter(Mandatory=$true)]
    [string]$destination_path
  )

  $repo_name = Split-Path $url -Leaf
  $repo_path = Join-Path $destination_path $repo_name
  $pinned_ref = $git_refs[$repo_name]

  if (Test-Path $repo_path) {
    Write-Host "Updating repository $url" -ForegroundColor Yellow
    Push-Location $repo_path
    try {
      if ($pinned_ref) {
        & git fetch --tags --force origin
        if ($LASTEXITCODE -ne 0) { Write-Warning "Failed to fetch $url" }
      }
      else {
        & git pull --rebase
        if ($LASTEXITCODE -ne 0) {
          Write-Warning "Failed to update repository $url"
        }
      }
    }
    finally {
      Pop-Location
    }
  }
  else {
    Write-Host "Cloning repository $url" -ForegroundColor Yellow
    & git clone --recurse-submodules $url $repo_path
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to clone repository $url"
    }
  }

  if ($pinned_ref) {
    Write-Host "Checking out $repo_name @ $pinned_ref" -ForegroundColor Yellow
    & git -C $repo_path checkout --force $pinned_ref
    if ($LASTEXITCODE -ne 0) { throw "Failed to check out $pinned_ref in $repo_name" }
    & git -C $repo_path submodule update --init --recursive
    if ($LASTEXITCODE -ne 0) { throw "Failed to update submodules of $repo_name" }
  }
}

function GetPackageUrls {
  [CmdletBinding()]
  param()
  $package_urls = @{
    'pkgconf' = "https://github.com/pkgconf/pkgconf/archive/refs/tags/pkgconf-$pkgconf_version.tar.gz"
    'proxy-libintl' = "https://github.com/frida/proxy-libintl/archive/refs/tags/$proxy_libintl_version/proxy-libintl-$proxy_libintl_version.tar.gz"
    'getopt-win' = "https://github.com/ludvikjerabek/getopt-win/archive/refs/tags/v$getopt_win_version/getopt-win-$getopt_win_version.tar.gz"
    'zlib' = "https://zlib.net/zlib-$zlib_version.tar.gz"
    'openssl' = "https://github.com/openssl/openssl/releases/download/openssl-$openssl_version/openssl-$openssl_version.tar.gz"
    'libpng' = "https://downloads.sourceforge.net/project/libpng/libpng16/$libpng_version/libpng-$libpng_version.tar.gz"
    'libjpeg-turbo' = "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/$libjpeg_turbo_version/libjpeg-turbo-$libjpeg_turbo_version.tar.gz"
    'pcre2' = "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$pcre2_version/pcre2-$pcre2_version.tar.gz"
    'bzip2' = "https://sourceware.org/pub/bzip2/bzip2-$bzip2_version.tar.gz"
    'xz' = "https://downloads.sourceforge.net/project/lzmautils/xz-$xz_version.tar.gz"
    'brotli' = "https://github.com/google/brotli/archive/refs/tags/v$brotli_version/brotli-$brotli_version.tar.gz"
    'uchardet' = "https://www.freedesktop.org/software/uchardet/releases/uchardet-$uchardet_version.tar.xz"
    'icu4c' = "https://github.com/unicode-org/icu/releases/download/release-$icu4c_version/icu4c-$icu4c_version-sources.tgz"
    'pixman' = "https://www.cairographics.org/releases/pixman-$pixman_version.tar.gz"
    'expat' = "https://github.com/libexpat/libexpat/releases/download/R_$expat_version_underscore/expat-$expat_version.tar.gz"
    'libxml2' = "https://download.gnome.org/sources/libxml2/$libxml2_version_short/libxml2-$libxml2_version.tar.xz"
    'nghttp2' = "https://github.com/nghttp2/nghttp2/releases/download/v$nghttp2_version/nghttp2-$nghttp2_version.tar.gz"
    'dlfcn-win32' = "https://github.com/dlfcn-win32/dlfcn-win32/archive/refs/tags/v$dlfcn_version/dlfcn-win32-$dlfcn_version.tar.gz"
    'libpsl' = "https://github.com/rockdaboot/libpsl/releases/download/$libpsl_version/libpsl-$libpsl_version.tar.gz"
    'orc' = "https://gstreamer.freedesktop.org/src/orc/orc-$orc_version.tar.xz"
    'sqlite' = "https://sqlite.org/2026/sqlite-autoconf-$sqlite_version.tar.gz"
    'libproxy' = "https://github.com/libproxy/libproxy/archive/refs/tags/$libproxy_version/libproxy-$libproxy_version.tar.gz"
    'glib' = "https://download.gnome.org/sources/glib/$glib_version_short/glib-$glib_version.tar.xz"
    'libsoup' = "https://download.gnome.org/sources/libsoup/$libsoup_version_short/libsoup-$libsoup_version.tar.xz"
    'freetype' = "https://sourceforge.net/projects/freetype/files/freetype2/$freetype_version/freetype-$freetype_version.tar.gz"
    'cairo' = "https://cairographics.org/releases/cairo-$cairo_version.tar.xz"
    'harfbuzz' = "https://github.com/harfbuzz/harfbuzz/releases/download/$harfbuzz_version/harfbuzz-$harfbuzz_version.tar.xz"
    'jasper' = "https://github.com/jasper-software/jasper/releases/download/version-$jasper_version/jasper-$jasper_version.tar.gz"
    'tiff' = "https://download.osgeo.org/libtiff/tiff-$tiff_version.tar.gz"
    'libwebp' = "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-$libwebp_version.tar.gz"
    'libogg' = "https://downloads.xiph.org/releases/ogg/libogg-$libogg_version.tar.gz"
    'libvorbis' = "https://downloads.xiph.org/releases/vorbis/libvorbis-$libvorbis_version.tar.gz"
    'flac' = "https://ftp.osuosl.org/pub/xiph/releases/flac/flac-$flac_version.tar.xz"
    'wavpack' = "https://www.wavpack.com/wavpack-$wavpack_version.tar.bz2"
    'opus' = "https://downloads.xiph.org/releases/opus/opus-$opus_version.tar.gz"
    'opusfile' = "https://ftp.osuosl.org/pub/xiph/releases/opus/opusfile-$opusfile_version.tar.gz"
    'speex' = "https://gitlab.xiph.org/xiph/speex/-/archive/Speex-$speex_version/speex-Speex-$speex_version.tar.gz"
    'mpg123' = "https://downloads.sourceforge.net/project/mpg123/mpg123/$mpg123_version/mpg123-$mpg123_version.tar.bz2"
    'lame' = "https://downloads.sourceforge.net/project/lame/lame/$lame_version/lame-$lame_version.tar.gz"
    'fftw' = "https://github.com/strawberrymusicplayer/fftw3-mingw-cross/releases/download/${fftw_version}/fftw-${arch}-w64-mingw32-${build_type}-${fftw_version}.tar.xz"
    'musepack' = "https://files.musepack.net/source/musepack_src_r$musepack_version.tar.gz"
    'libopenmpt' = "https://lib.openmpt.org/files/libopenmpt/src/libopenmpt-$libopenmpt_version+release.msvc.zip"
    'libgme' = "https://github.com/libgme/game-music-emu/releases/download/$libgme_version/libgme-$libgme_version-src.tar.gz"
    'fdk-aac' = "https://downloads.sourceforge.net/project/opencore-amr/fdk-aac/fdk-aac-$fdk_aac_version.tar.gz"
    'faad2' = "https://github.com/knik0/faad2/tarball/$faad2_version/faad2-$faad2_version.tar.gz"
    'faac' = "https://github.com/knik0/faac/archive/refs/tags/faac-$faac_version.tar.gz"
    'utfcpp' = "https://github.com/nemtrif/utfcpp/archive/refs/tags/v$utfcpp_version/utfcpp-$utfcpp_version.tar.gz"
    'taglib' = "https://taglib.org/releases/taglib-$taglib_version.tar.gz"
    'libbs2b' = "https://downloads.sourceforge.net/project/bs2b/libbs2b/$libbs2b_version/libbs2b-$libbs2b_version.tar.bz2"
    'libebur128' = "https://github.com/jiixyj/libebur128/archive/refs/tags/v$libebur128_version/libebur128-$libebur128_version.tar.gz"
    'chromaprint' = "https://github.com/acoustid/chromaprint/releases/download/v$chromaprint_version/chromaprint-$chromaprint_version.tar.gz"
    'gstreamer' = "https://gstreamer.freedesktop.org/src/gstreamer/gstreamer-$gstreamer_version.tar.xz"
    'gst-plugins-base' = "https://gstreamer.freedesktop.org/src/gst-plugins-base/gst-plugins-base-$gstreamer_version.tar.xz"
    'gst-plugins-good' = "https://gstreamer.freedesktop.org/src/gst-plugins-good/gst-plugins-good-$gstreamer_version.tar.xz"
    'gst-plugins-bad' = "https://gstreamer.freedesktop.org/src/gst-plugins-bad/gst-plugins-bad-$gstreamer_version.tar.xz"
    'gst-plugins-ugly' = "https://gstreamer.freedesktop.org/src/gst-plugins-ugly/gst-plugins-ugly-$gstreamer_version.tar.xz"
    'gst-libav' = "https://gstreamer.freedesktop.org/src/gst-libav/gst-libav-$gstreamer_version.tar.xz"
    'sparsehash' = "https://github.com/sparsehash/sparsehash/archive/refs/tags/sparsehash-$sparsehash_version.tar.gz"
    'abseil-cpp' = "https://github.com/abseil/abseil-cpp/archive/refs/tags/$abseil_version/abseil-cpp-$abseil_version.tar.gz"
    'protobuf' = "https://github.com/protocolbuffers/protobuf/releases/download/v$protobuf_version/protobuf-$protobuf_version.tar.gz"
    'qtbase' = "https://download.qt.io/official_releases/qt/$qt_version_short/$qt_version/submodules/qtbase-everywhere-src-$qt_version.tar.xz"
    'qttools' = "https://download.qt.io/official_releases/qt/$qt_version_short/$qt_version/submodules/qttools-everywhere-src-$qt_version.tar.xz"
    'qtimageformats' = "https://download.qt.io/official_releases/qt/$qt_version_short/$qt_version/submodules/qtimageformats-everywhere-src-$qt_version.tar.xz"
    'qtgrpc' = "https://download.qt.io/official_releases/qt/$qt_version_short/$qt_version/submodules/qtgrpc-everywhere-src-$qt_version.tar.xz"
    'kdsingleapplication' = "https://github.com/KDAB/KDSingleApplication/releases/download/v$kdsingleapplication_version/kdsingleapplication-$kdsingleapplication_version.tar.gz"
    'glew' = "https://downloads.sourceforge.net/project/glew/glew/$glew_version/glew-$glew_version.tgz"
    'libprojectm' = "https://github.com/projectM-visualizer/projectm/releases/download/v$libprojectm_version/libprojectm-$libprojectm_version.tar.gz"
    'pe-parse' = "https://github.com/trailofbits/pe-parse/archive/refs/tags/v$peparse_version/pe-parse-$peparse_version.tar.gz"
    'vc-redist-x86' = "https://aka.ms/vc14/vc_redist.x86.exe"
    'vc-redist-x64' = "https://aka.ms/vc14/vc_redist.x64.exe"
    "vc-redist-arm64" = "https://aka.ms/vc14/vc_redist.arm64.exe"
  }
  return $package_urls
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
    'tinysvcmdns' = "https://github.com/Pro/tinysvcmdns"
    'yasm' = "https://github.com/yasm/yasm"
    'pe-util' = "https://github.com/gsauthof/pe-util"
    'strawberry' = "https://github.com/strawberrymusicplayer/strawberry"
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
    $package_url = $package_urls[$package_name]
    DownloadFileIfNotExists -url $package_url -destination_path $downloads_path
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
    SyncGitRepository -url $git_repo_url -destination_path $src_path
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
    "-DPKG_CONFIG_EXECUTABLE=$prefix_path/bin/pkgconf.exe"
  )
  if ($additional_args) {
    $configure_args += $additional_args
  }
  Write-Host "cmake" @configure_args
  if ($strawberry_perl_bin) { RemovePathFromEnvPath -path $strawberry_perl_bin }
  if ($strawberry_perl_site_bin) { RemovePathFromEnvPath -path $strawberry_perl_site_bin }
  & cmake @configure_args
  if ($LASTEXITCODE -ne 0) {
    throw "CMake configuration failed"
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
        Copy-Item "$prefix_path/lib/zd.lib" "$prefix_path/lib/z.lib" -Force
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
      & perl Configure $openssl_platform shared zlib no-capieng no-tests --prefix="$prefix_path" --libdir=lib --openssldir="$prefix_path/ssl" $build_flag --with-zlib-include="$prefix_path/include" --with-zlib-lib="$prefix_path/lib/z${lib_postfix}.lib" /FS
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
      MesonBuild -additional_args @("-Dgtk=disabled", "-Dlibpng=enabled")
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
    #DownloadPackage -package_name "glib-networking"
    #ExtractPackage "glib-networking-$glib_networking_version.tar.xz"
    #Set-Location "glib-networking-$glib_networking_version"
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
      & nmake -f Makefile.MSVC MSVCVER=${lame_msvcver} libmp3lame.dll
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
    # It's recommended to build FFTW3 with MinGW-W64 so we use a binary package built on GitHub
    DownloadPackage -package_name "fftw"
    ExtractPackage "fftw-${arch}-w64-mingw32-${build_type}-${fftw_version}.tar.xz"
    Push-Location "fftw-${arch}-w64-mingw32-${build_type}-${fftw_version}/lib"
    try {
      # Generate .lib file from .def
      if ((-not (Test-Path "fftw3.def")) && Test-Path "libfftw3-3.def") {
        Copy-Item "libfftw3-3.def" "fftw3.def" -Force
      }
      & lib /machine:$lib_machine /def:fftw3.def
      if ($LASTEXITCODE -ne 0) { throw "lib.exe failed to create import library" }
    }
    finally {
      Pop-Location
    }
    RecursiveCopy "fftw-${arch}-w64-mingw32-${build_type}-${fftw_version}" "$prefix_path"
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
    & patch -p3 -N -i "$patch_path/gstreamer-faac2.patch"
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
          "-Dasfdemux=enabled"
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

function Build-AbseilCpp {
  Write-Host "Building abseil-cpp" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "abseil-cpp"
    ExtractPackage "abseil-cpp-$abseil_version.tar.gz"
    Push-Location "abseil-cpp-$abseil_version"
    try {
      CMakeBuild -additional_args @(
          "-DCMAKE_CXX_STANDARD=17",
          "-DCMAKE_CXX_STANDARD_REQUIRED=ON",
          "-DABSL_INTERNAL_AT_LEAST_CXX17=ON",
          "-DABSL_BUILD_TESTING=OFF",
          "-DABSL_USE_EXTERNAL_GOOGLETEST=OFF"
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

function Build-Protobuf {
  Write-Host "Building protobuf" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "protobuf"
    ExtractPackage "protobuf-$protobuf_version.tar.gz"
    Push-Location "protobuf-$protobuf_version"
    try {
      CMakeBuild -additional_args @(
          "-Dprotobuf_BUILD_TESTS=OFF",
          "-Dprotobuf_ABSL_PROVIDER=package"
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
    }
    try {
      CMakeBuild -additional_args @(
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

function Build-QtGrpc {
  Write-Host "Building qtgrpc" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    if ($qt_dev -eq "ON") {
      if (-not (Test-Path "qtgrpc")) {
        RecursiveCopy "$src_path/qtgrpc" "qtgrpc"
      }
      Push-Location "qtgrpc"
    }
    else {
      DownloadPackage -package_name "qtgrpc"
      ExtractPackage "qtgrpc-everywhere-src-$qt_version.tar.xz"
      Push-Location "qtgrpc-everywhere-src-$qt_version"
    }
    try {
      CMakeBuild -additional_args @(
          "-DQT_BUILD_EXAMPLES=OFF",
          "-DQT_BUILD_TESTS=OFF"
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

function Build-Glew {
  Write-Host "Building glew" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "glew"
    ExtractPackage "glew-$glew_version.tgz"
    Push-Location "glew-$glew_version"
    try {
      CMakeBuild -source_path "build/cmake" -additional_args @("-DCMAKE_POLICY_VERSION_MINIMUM=3.5")
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-LibProjectm {
  Write-Host "Building libprojectm" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    DownloadPackage -package_name "libprojectm"
    ExtractPackage "libprojectm-$libprojectm_version.tar.gz"
    Push-Location "libprojectm-$libprojectm_version"
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

function Build-TinySvcmdns {
  Write-Host "Building tinysvcmdns" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    CloneGitRepo -git_repo_name "tinysvcmdns"
    if (-not (Test-Path "tinysvcmdns")) {
      RecursiveCopy "$src_path/tinysvcmdns" "tinysvcmdns"
    }
    Push-Location "tinysvcmdns"
    try {
      CMakeBuild -additional_args @("-DCMAKE_POLICY_VERSION_MINIMUM=3.5")
      Copy-Item "*.lib" "$prefix_path/lib/" -Force
      Copy-Item "*.dll" "$prefix_path/bin/" -Force
      Copy-Item "*.exe" "$prefix_path/bin/" -Force
      Copy-Item "*.h" "$prefix_path/include/" -Force
      Copy-Item "../*.h" "$prefix_path/include/" -Force
      CreatePkgConfigFile -prefix $prefix_path -name "tinysvcmdns" -description "tinysvcmdns" -version "0.1" -cflags "-I`${includedir}" -libs "-L`${libdir} -ltinysvcmdns" -output_file "$prefix_path/lib/pkgconfig/tinysvcmdns.pc"
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

function Build-Strawberry {
  Write-Host "Building strawberry" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    CloneGitRepo -git_repo_name "strawberry"
    if (-not (Test-Path "strawberry")) {
      RecursiveCopy "$src_path/strawberry" "strawberry"
    }
    Push-Location "strawberry"
    try {
      # Source = exactly <commit> + the local patches, in order (wrapper: patches\strawberry-*.patch / -StrawberryPatch): files
      # an earlier run patched (or that were edited by hand) are reset first, so a removed or edited patch is undone too.
      # Files that end up identical keep their old timestamps, so the incremental CMake build below (the existing build
      # folder is reused) only recompiles what really changed.
      $strawberry_saved = Sync-GitBuildCopy -src_repo "$src_path/strawberry" -name "strawberry"
      Invoke-LocalPatches -root "." -component "strawberry"
      Restore-UnchangedTimestamps $strawberry_saved "strawberry"
      $enable_win32_console = if ($build_type -eq "debug") { "ON" } else { "OFF" }
      CMakeBuild -additional_args @(
          "-DARCH=$arch",
          "-DENABLE_TRANSLATIONS=ON",
          "-DBUILD_WERROR=ON",
          "-DENABLE_WIN32_CONSOLE=$enable_win32_console",
          "-DICU_ROOT=$prefix_path",
          "-DENABLE_AUDIOCD=OFF",
          "-DENABLE_MTP=OFF",
          "-DENABLE_GPOD=OFF"
        )
      Write-Host "Strawberry built successfully!" -ForegroundColor Green
    }
    finally {
      Pop-Location
    }
  }
  finally {
    Pop-Location
  }
}

function Build-StrawberrySetup {
  Write-Host "Creating StrawberrySetup" -ForegroundColor Yellow
  Push-Location $build_path
  try {
    New-Item -Path "StrawberrySetup" -ItemType Directory -Force | Out-Null
    Push-Location "StrawberrySetup"
    try {
      New-Item -Path @('platforms', 'styles', 'imageformats', 'tls', 'sqldrivers', 'gio-modules', 'gstreamer-plugins') -ItemType Directory -Force
      Copy-Item -Path "$build_path/strawberry/build/strawberry.exe", `
                      "$build_path/strawberry/build/strawberry.nsi", `
                      "$build_path/strawberry/COPYING", `
                      "$build_path/strawberry/dist/windows/*.ico", `
                      "$build_path/strawberry/dist/windows/*.nsh" `
                      "." -Force
      Copy-Item "$prefix_path/plugins/platforms/*.dll" "./platforms/" -Force
      Copy-Item "$prefix_path/plugins/styles/*.dll" "./styles/" -Force
      Copy-Item "$prefix_path/plugins/imageformats/*.dll" "./imageformats/" -Force
      Copy-Item "$prefix_path/plugins/tls/*.dll" "./tls/" -Force
      Copy-Item "$prefix_path/plugins/sqldrivers/*.dll" "./sqldrivers/" -Force
      Copy-Item "$prefix_path/lib/gio/modules/*.dll" "./gio-modules/" -Force
      Copy-Item "$prefix_path/lib/gstreamer-1.0/*.dll" "./gstreamer-plugins/" -Force
      Copy-Item -Path "$prefix_path/bin/sqlite3.exe", "$prefix_path/bin/gst-*.exe" -Destination "." -Force
      & "$PSScriptRoot/CopyDLLDependencies.ps1" -Copy -DestDir "./" -InDir "./" -InDir "./platforms" -InDir "./styles" -InDir "./imageformats" -InDir "./tls" -InDir "./sqldrivers" -InDir "./gio-modules" -InDir "./gstreamer-plugins" -RecursiveSrcDir "$prefix_path/bin"
      DownloadPackage -package_name "vc-redist-${arch_short}"
      Copy-Item "$downloads_path/vc_redist.${arch_short}.exe" "." -Force
      & makensis strawberry.nsi
      Write-Host "Strawberry setup built successfully!" -ForegroundColor Green
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
  # constraints beyond pkgconf. strawberry / strawberry-setup wait for everything.
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
    "ffmpeg"              = @("pkgconf", "yasm", "libxml2", "libwebp", "opusfile", "fftw3", "libebur128", "taglib") + $codecs
    "chromaprint"         = @("pkgconf", "ffmpeg", "fftw3")
    "gstreamer"           = @("pkgconf", "glib", "libffi", "zlib", "orc")
    "gst-plugins-base"    = @("pkgconf", "gstreamer", "orc", "harfbuzz", "freetype", "pixman", "libpng", "libjpeg-turbo", "opusfile") + $codecs
    "gst-plugins-good"    = @("pkgconf", "gst-plugins-base", "libsoup", "taglib", "pixman", "libxml2", "nghttp2") + $codecs
    "gst-plugins-bad"     = @("pkgconf", "gst-plugins-base", "libsoup", "libxml2", "nghttp2", "chromaprint", "opusfile", "musepack", "fftw3", "pixman") + $codecs
    "gst-plugins-ugly"    = @("pkgconf", "gst-plugins-base")
    "gst-libav"           = @("pkgconf", "gst-plugins-base", "ffmpeg")
    "gst-plugins-rs"      = @("pkgconf", "gst-plugins-base", "gst-plugins-bad", "glib", "openssl", "zlib")
    "abseil-cpp"          = @("pkgconf")
    "protobuf"            = @("pkgconf", "abseil-cpp", "zlib")
    "qtbase"              = @("pkgconf") + $qt
    "qttools"             = @("qtbase")
    "qtimageformats"      = @("qtbase", "jasper", "tiff", "libwebp")
    "qtgrpc"              = @("qtbase", "protobuf", "abseil-cpp")
    "kdsingleapplication" = @("qtbase")
    "qtsparkle"           = @("qtbase", "qttools")
    "sparsehash"          = @("pkgconf")
    "glew"                = @("pkgconf")
    "libprojectm"         = @("pkgconf", "glew")
    "tinysvcmdns"         = @("pkgconf")
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
    'qtbase' = 14; 'ffmpeg' = 9; 'gst-plugins-rs' = 7; 'strawberry' = 7; 'gst-plugins-bad' = 6
    'icu4c' = 5; 'qttools' = 4; 'boost' = 4; 'glib' = 4; 'openssl' = 4
    'qtgrpc' = 3; 'gst-plugins-good' = 3; 'gst-plugins-base' = 3; 'gstreamer' = 3; 'gst-libav' = 3
    'protobuf' = 3; 'abseil-cpp' = 3; 'libprojectm' = 3
    'harfbuzz' = 2; 'libxml2' = 2; 'libopenmpt' = 2; 'qtimageformats' = 2; 'taglib' = 2
    'freetype' = 2; 'pcre2' = 2; 'strawberry-setup' = 2
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
  foreach ($c in $queue) { if ($table.ContainsKey($c)) { $urls += [string]$table[$c] } }
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
  #    (the serial tail: qtbase -> qttools -> strawberry ...) gets every core.
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
    if ($c -eq "strawberry") { $deps[$c] = @($queue | Where-Object { $_ -ne "strawberry" -and $_ -ne "strawberry-setup" }) }
    elseif ($c -eq "strawberry-setup") { $deps[$c] = @($queue | Where-Object { $_ -ne "strawberry-setup" }) }
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
        # Heavy packages (weight >= 5: qtbase, ffmpeg, gst-plugins-rs/bad, icu4c, strawberry) keep their core
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
#   - sha256 and order of the local patches for it (-package_patches; the wrapper fills it from patches\, -StrawberryPatch, -GstGoodPatch)
#   - the text of its build recipe (its line in the build switch + its Build-* function), so a new build tools ref rebuilds what it changed
# A package is skipped when its output marker exists and its stamp matches. Otherwise it is rebuilt: dependencies in a clean copy
# (fresh extract / copy, new build folder), strawberry incrementally (source reset to the commit + patches re-applied, then the
# existing CMake build folder is reused, so only what really changed is recompiled). See Get-BuildPlan for the rules.

$smb_script_file = $PSCommandPath
$smb_stamp_dir = "$build_path/.stamps"
# Header-only packages: their dependents compile them in, so a rebuild of one of these rebuilds its direct dependents.
# (Everything else is a shared library; use -rebuild_dependents to rebuild direct dependents of those too.)
$smb_embedded_packages = @('utfcpp', 'sparsehash', 'boost')
# Build tools: never a reason to rebuild dependents.
$smb_tool_packages = @('pkgconf', 'yasm')
# Extra folders (in build_path) a clean rebuild removes, besides <build_path>/<package> and the folders the recipe extracts/configures.
$smb_extra_build_dirs = @{ 'strawberry-setup' = @('StrawberrySetup') }
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
    "ffmpeg"              = "$prefix_path/lib/avutil.lib"
    "chromaprint"         = "$prefix_path/lib/pkgconfig/libchromaprint.pc"
    "gstreamer"           = "$prefix_path/lib/pkgconfig/gstreamer-1.0.pc"
    "gst-plugins-base"    = "$prefix_path/lib/pkgconfig/gstreamer-plugins-base-1.0.pc"
    "gst-plugins-good"    = "$prefix_path/lib/gstreamer-1.0/gstflac.dll"
    "gst-plugins-bad"     = "$prefix_path/lib/pkgconfig/gstreamer-plugins-bad-1.0.pc"
    "gst-plugins-ugly"    = "$prefix_path/lib/gstreamer-1.0/gstasf.dll"
    "gst-libav"           = "$prefix_path/lib/gstreamer-1.0/gstlibav.dll"
    "gst-plugins-rs"      = "$prefix_path/lib/gstreamer-1.0/gstspotify.dll"
    "abseil-cpp"          = "$prefix_path/lib/pkgconfig/absl_any.pc"
    "protobuf"            = "$prefix_path/lib/pkgconfig/protobuf.pc"
    "qtbase"              = "$prefix_path/bin/qt-configure-module.bat"
    "qttools"             = "$prefix_path/bin/lconvert.exe"
    "qtimageformats"      = "$prefix_path/plugins/imageformats/qwebp${lib_postfix}.dll"
    "qtgrpc"              = "$prefix_path/lib/cmake/Qt6Protobuf/Qt6ProtobufConfig.cmake"
    "kdsingleapplication" = "$prefix_path/lib/cmake/KDSingleApplication-qt6/KDSingleApplication-qt6Config.cmake"
    "qtsparkle"           = "$prefix_path/lib/cmake/qtsparkle-qt6/qtsparkle-qt6Config.cmake"
    "sparsehash"          = "$prefix_path/lib/pkgconfig/libsparsehash.pc"
    "glew"                = "$prefix_path/lib/cmake/glew/glew-config.cmake"
    "libprojectm"         = "$prefix_path/lib/cmake/projectM4/projectM4Config.cmake"
    "tinysvcmdns"         = "$prefix_path/lib/pkgconfig/tinysvcmdns.pc"
    "pe-parse"            = "$prefix_path/lib/cmake/pe-parse/pe-parse-config.cmake"
    "pe-util"             = "$prefix_path/bin/peldd.exe"
    "strawberry"          = "$build_path/strawberry/build/strawberry.exe"
    "strawberry-setup"    = "$build_path/StrawberrySetup/StrawberrySetup*.exe"
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
    $recipes[$name] = @{ Text = $text; Downloads = @($downloads); GitRepos = @($repos); ToolPatches = $tool_patches; UsesCMakeOrMeson = $uses_cmake_or_meson }
  }
  $script:smb_recipes = $recipes
  return $recipes
}

function Resolve-GitSourceId {
  # The commit a git-sourced package builds: the pinned ref (git_refs) resolved in the local clone, else the clone's HEAD.
  # No network unless -sync and a pinned ref is not in the clone yet (then the clone is fetched, like the build would).
  # Unpinned clones are not pulled here; the build pulls them as before, and the stamp records the commit it built.
  param([string]$repo, [switch]$sync)
  $path = "$($script:src_path)/$repo"
  $ref = $git_refs[$repo]
  for ($attempt = 0; $attempt -lt 2; $attempt++) {
    if (Test-Path -LiteralPath "$path/.git") {
      $spec = if ($ref) { "$ref^{commit}" } else { "HEAD" }
      $sha = & git -C $path rev-parse -q --verify $spec 2>$null
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
    foreach ($d in $recipe.Downloads) { $sources[$d] = if ($package_urls.ContainsKey($d)) { [string]$package_urls[$d] } else { "unknown" } }
    foreach ($r in $recipe.GitRepos) { $sources["git:$r"] = Resolve-GitSourceId -repo $r -sync:$sync }
    foreach ($p in $recipe.ToolPatches) { $tool_patches[$p] = Get-NormalizedFileSha256 (Join-Path $patch_path $p) }
  }
  $local_patches = @(foreach ($p in @(Get-LocalPatches $name)) { [ordered]@{ name = (Split-Path $p -Leaf); sha256 = (Get-NormalizedFileSha256 $p) } })
  $parts = [ordered]@{
    config        = "$($build_type.ToLowerInvariant())/$arch"
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
  Write-PackageStamp $name ([ordered]@{ package = $name; fingerprint = $fp.Hash; state = $state; time = (Get-Date).ToString("s"); parts = $fp.Parts })
}

function Set-PackageStampPending([string]$name, [string]$reason) {
  # Marks a package as needing a build before it starts (or when a rebuild it needs is left out by -only / -skip): if the build
  # fails or is interrupted, the next run rebuilds it instead of trusting a half-updated prefix. The old details are kept for the reasons.
  $old = Read-PackageStamp $name
  $parts = if ($old -and $old.parts) { $old.parts } else { $null }
  Write-PackageStamp $name ([ordered]@{ package = $name; fingerprint = "pending"; state = "pending"; reason = $reason; time = (Get-Date).ToString("s"); parts = $parts })
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
    $label = $k -replace '^git:', ''
    if (-not $old_sources.Contains($k)) { $reasons.Add("new source $label") }
    elseif ([string]$old_sources[$k] -ne [string]$new_sources[$k]) {
      $what = if ($k.StartsWith("git:")) { "commit" } else { "version" }
      $reasons.Add("$label $what changed $(Get-ShortSourceId $k $old_sources[$k]) -> $(Get-ShortSourceId $k $new_sources[$k])")
    }
  }
  foreach ($k in $old_sources.Keys) { if (-not $new_sources.Contains($k)) { $reasons.Add("source $($k -replace '^git:', '') no longer used") } }
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

function Test-StrawberryRefMismatch {
  # -no_change_detection only: the old check (a pinned strawberry ref that the build tree is not at).
  if (-not $git_refs.ContainsKey('strawberry') -or -not (Test-Path "$build_path/strawberry/.git")) { return $false }
  $have = & git -C "$build_path/strawberry" rev-parse HEAD 2>$null
  $want = & git -C "$build_path/strawberry" rev-parse --verify "$($git_refs['strawberry'])^{commit}" 2>$null
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
    if ($name -ne 'strawberry' -and -not ($recipe -and $recipe.UsesCMakeOrMeson)) {
      throw "Local patches for '$name' can't be applied automatically: its recipe doesn't build through CMakeBuild / MesonBuild (where local patches are applied). Patches: $(@(Get-LocalPatches $name) -join ', ')"
    }
    foreach ($p in @(Get-LocalPatches $name)) { if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "Patch for $name not found: $p" } }
  }
}

function Get-BuildPlan {
  # Decides, per package: skip (up to date), adopt (existing output, no stamp yet: stamp it, don't rebuild), build (no output),
  # rebuild (stamp differs / forced / a dependency needs it), or excluded (-only / -skip).
  #  - Rebuilt dependencies get a clean copy; strawberry is rebuilt incrementally (clean only with -force_rebuild).
  #  - First run with stamps: existing output is adopted, except strawberry (always re-synced to commit + patches, which is cheap
  #    because files that end up unchanged keep their timestamps) and a package with local patches that can't be verified.
  #  - A rebuild of a header-only package rebuilds its direct dependents (all direct dependents with -rebuild_dependents);
  #    any rebuild relinks strawberry (incremental) and re-creates StrawberrySetup.
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
      elseif ($name -eq 'strawberry' -and (Test-StrawberryRefMismatch)) { $e.Action = 'rebuild'; $e.Reasons.Add("build tree is not at $($git_refs['strawberry'])") }
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
      if ($stamp -and $stamp.fingerprint -ne $fp.Hash -and $name -ne 'strawberry') { $e.Clean = $true }
    }
    elseif (-not $stamp) {
      if ($name -eq 'strawberry') {
        $e.Action = 'rebuild'; $e.Reasons.Add('no stamp yet: source reset to the commit + patches re-applied')
      }
      elseif (@(Get-LocalPatches $name).Count -gt 0 -and -not (Test-LegacyPatchStamp $name)) {
        $e.Action = 'rebuild'; $e.Clean = $true; $e.Reasons.Add("no stamp yet, and its local patches can't be verified as applied")
      }
      else {
        $e.Action = 'adopt'; $e.Reasons.Add('existing output, no stamp yet')
      }
    }
    elseif ($stamp.fingerprint -ne $fp.Hash) {
      $e.Action = 'rebuild'; $e.Clean = ($name -ne 'strawberry')
      foreach ($r in (Get-FingerprintChanges $stamp $fp)) { $e.Reasons.Add($r) }
    }
    else { $e.Reasons.Add('up to date') }
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
        if ($d -in 'strawberry', 'strawberry-setup') { continue }   # below
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

  $rebuilt = @($plan.Keys | Where-Object { $plan[$_].Action -in 'build', 'rebuild' -and $_ -notin 'strawberry', 'strawberry-setup' })
  if ($rebuilt.Count -gt 0 -and $plan.Contains('strawberry')) {
    $se = $plan['strawberry']
    $why = "dependencies rebuilt: $(Format-NameList $rebuilt) (relink)"
    if ($se.Action -in 'skip', 'adopt') { $se.Action = 'rebuild'; $se.Reasons.Clear(); $se.Reasons.Add($why) }
    elseif ($se.Action -eq 'excluded' -and -not $se.Pending) { $se.Pending = $why }
  }
  if ($plan.Contains('strawberry-setup')) {
    $all_rebuilt = @($plan.Keys | Where-Object { $plan[$_].Action -in 'build', 'rebuild' -and $_ -ne 'strawberry-setup' })
    $ue = $plan['strawberry-setup']
    if ($all_rebuilt.Count -gt 0) {
      $why = "packages rebuilt: $(Format-NameList $all_rebuilt)"
      if ($ue.Action -in 'skip', 'adopt') { $ue.Action = 'rebuild'; $ue.Reasons.Clear(); $ue.Reasons.Add($why) }
      elseif ($ue.Action -eq 'excluded' -and -not $ue.Pending) { $ue.Pending = $why }
    }
    if ($ue.Action -in 'build', 'rebuild') { $ue.Clean = $true }   # a fresh StrawberrySetup folder: no DLLs left over from older builds
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
  if (-not $script:smb_cleaned_dirs.Add($full)) { return }   # once per folder: never remove what this build just made
  $root = [System.IO.Path]::GetFullPath($script:build_path).TrimEnd('\', '/')
  if (-not $full.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { return }
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
  # MesonBuild (so after the build tools' own patches) and by Build-Strawberry; once per package and process.
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
        # strawberry's source was just reset to the commit, so this only happens for a patch whose changes an earlier patch in
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
  # Run in a build copy of a git clone (e.g. <build_path>/strawberry, a copy of <src_path>/strawberry with its .git).
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
    $plan = Get-BuildPlan -markers $package_markers -graph (Get-PackageDependencies) -only $only -skip $skip -force $force_rebuild `
                          -no_change_detection:$no_change_detection -rebuild_dependents:$rebuild_dependents
    Write-BuildPlan $plan -no_change_detection:$no_change_detection
    $build_queue = @($plan.Keys | Where-Object { $plan[$_].Action -in 'build', 'rebuild' })
    $clean_queue = @($build_queue | Where-Object { $plan[$_].Clean })
    if ($list) {
      Write-Host "Build queue: $(if ($build_queue.Count) { $build_queue -join ', ' } else { '(nothing)' })" -ForegroundColor Cyan
      exit 0
    }
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
      "ffmpeg" { Build-FFMpeg }
      "chromaprint" { Build-Chromaprint }
      "gstreamer" { Build-GStreamer }
      "gst-plugins-base" { Build-GstPluginsBase }
      "gst-plugins-good" { Build-GstPluginsGood }
      "gst-plugins-bad" { Build-GstPluginsBad }
      "gst-plugins-ugly" { Build-GstPluginsUgly }
      "gst-libav" { Build-GstLibAv }
      "gst-plugins-rs" { Build-GstPluginsRs }
      "abseil-cpp" { Build-AbseilCpp }
      "protobuf" { Build-Protobuf }
      "qtbase" { Build-QtBase }
      "qttools" { Build-QtTools }
      "qtimageformats" { Build-QtImageFormats }
      "qtgrpc" { Build-QtGrpc }
      "kdsingleapplication" { Build-KDSingleApplication }
      "qtsparkle" { Build-QtSparkle }
      "sparsehash" { Build-SparseHash }
      "glew" { Build-Glew }
      "libprojectm" { Build-LibProjectm }
      "tinysvcmdns" { Build-TinySvcmdns }
      "pe-parse" { Build-PeParse }
      "pe-util" { Build-PeUtil }
      "strawberry" { Build-Strawberry }
      "strawberry-setup" { Build-StrawberrySetup }
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
