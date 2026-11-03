# :hammer_and_wrench: Akousma MSVC Build Tools

Build tools for [Akousma](https://github.com/Genki-jp0/Akousma) on Windows with Visual Studio 2022 or 2026.
`Build-Akousma.ps1` builds every dependency, Akousma itself and the `AkousmaSetup-*.exe` installer in one run, for x64,
x86 and arm64 (arm64 is cross-compiled on an x64 PC).

Based on [strawberry-msvc-build-tools](https://github.com/strawberrymusicplayer/strawberry-msvc-build-tools)
(at d7e0c51) by Jonas Kvinge; Akousma is based on
[Strawberry Music Player](https://github.com/strawberrymusicplayer/strawberry).
Licensed under the GPL version 3 (see `COPYING`).

* `Build-Akousma.ps1`: the build script. `Get-Help .\Build-Akousma.ps1 -Detailed` lists every parameter.
* `BUILD.txt`: the full guide (tool search, build settings, architectures, parameters, folders, local patches, change
  detection, Audio CD).
* `local-patches/`: your patches for dependencies (`qtbase-*.patch` -> qtbase, `gstreamer-*.patch` -> gst-plugins-good,
  ...), applied automatically. Akousma's own changes are commits in the Akousma repository, not patches.
* `patches/`: the dependency patches from upstream (plus `libcdio-cmake.patch`), applied by the script.
* `StrawberryPackageVersions.txt`: the dependency versions (upstream's file, name kept). `CopyDLLDependencies.ps1`:
  collects the DLLs for the installer.

## Requirements

* [PowerShell 7](https://learn.microsoft.com/en-us/powershell/scripting/install/install-powershell-on-windows)
* [Visual Studio 2022 or 2026](https://visualstudio.microsoft.com/vs/) with `Desktop development with C++` (nmake, and
  ninja from `C++ CMake tools for Windows`). arm64 needs two more components, see BUILD.txt.
* [Git for Windows](https://gitforwindows.org/): also provides `sed`, `patch`, `bzip2` and GNU `tar` (`Git\usr\bin`)
* [Strawberry Perl](https://strawberryperl.com/)
* [Python](https://www.python.org/downloads/windows/) 3.10 or newer
* [CMake](https://cmake.org/), [Meson](https://mesonbuild.com/), [NASM](https://www.nasm.us/),
  [7-Zip](https://www.7-zip.org/download.html)
* [Win Flex/Bison](https://sourceforge.net/projects/winflexbison/): a zip, unpack it to e.g. `C:\win_flex_bison`
* [Rust](https://www.rust-lang.org) (MSVC toolchain) with cargo-c (`cargo install cargo-c`), for gst-plugins-rs
  (Spotify; not built for x86 or for an arm64 cross-compile)
* [NSIS](https://nsis.sourceforge.io/) with the [LockedList plugin](https://nsis.sourceforge.io/LockedList_plug-in), for
  the installer: copy `LockedList\Plugins\LockedList64.dll` to `C:\Program Files (x86)\NSIS\Plugins\` and
  `LockedList\Plugins\x86-unicode\LockedList.dll` to `C:\Program Files (x86)\NSIS\Plugins\x86-unicode\`

Put each tool's folder on PATH (recommended). A tool that isn't on PATH is searched for (registry, usual folders,
`$env:SMB_TOOL_PATHS`, Program Files and the drive roots; see BUILD.txt), except `makensis`: add
`C:\Program Files (x86)\NSIS` to PATH yourself (ninja comes from the Visual Studio environment). Before it builds
anything the script checks sed, patch, nasm, win_flex, win_bison, perl, python, bzip2, 7z, cmake, meson, nmake and GNU
tar, and stops at the first one that is missing. Keep other GCC / MinGW installations off PATH (Strawberry Perl's own
`c\bin` is taken off PATH by the script).

The script downloads everything else itself: jom, the dependency sources and git clones, and the Akousma source.

## Building

In PowerShell 7 (pwsh), from anywhere:

```powershell
.\Build-Akousma.ps1                                 # Akousma master, the architectures in build-settings.json
.\Build-Akousma.ps1 -Arch x64                       # x64 only, this run (-SaveSettings: from now on)
.\Build-Akousma.ps1 -AkousmaRef v1.0.0              # a branch, tag or commit
.\Build-Akousma.ps1 -AkousmaSource E:\src\Akousma   # a local checkout, uncommitted changes included
.\Build-Akousma.ps1 -BuildType debug                # debug build
.\Build-Akousma.ps1 -List                           # what would be rebuilt and why; builds nothing
.\Build-Akousma.ps1 -WorkRoot E:\ -DryRun           # the resolved folders, source and patches; builds nothing
```

The first build of an architecture builds every dependency (several hours). Later runs rebuild only what changed
(printing the reason), then relink Akousma and re-create the installer.

Output, for x64 release with the default folders:

* `C:\Atelier\data\projects\akousma\msvc_\build_x86_64_release\akousma\build\akousma.exe`
* `C:\Atelier\data\projects\akousma\msvc_\build_x86_64_release\AkousmaSetup\AkousmaSetup-<version>-msvc-x64.exe`
  (x86: `build_x86_release\...-msvc-x86.exe`, arm64: `build_arm64_release\...-msvc-arm64.exe`)
* the log: `C:\Atelier\data\projects\akousma\build.log` (x86: `build_x86.log`), per package: `<build tree>\logs`

## Settings and folders

`build-settings.json`, next to the script, keeps your settings: the architectures (every one, x64, x86 and arm64, until
you change it), the build type, the Akousma source and the folders. The first run creates it with the defaults;
`.gitignore` keeps it out of git. A parameter on the command line wins for that run; add `-SaveSettings` to write it
into the file.

Everything goes under `C:\Atelier` by default (`-WorkRoot E:\` moves it all):

* `C:\Atelier\data\projects\akousma\...`: downloads, sources, build trees, `build.log`, jom
* `C:\Atelier\akousma_msvc_<arch>_<build type>`: the dependency prefix
* `C:\Atelier\temp`, `C:\Atelier\cache\pip`, `C:\Atelier\cargo`, `C:\Atelier\rustup`

Coming from the older `C:\` or `strawberry` folders, or using upstream's prebuilt dependency packages: see "Folders" in
BUILD.txt.
