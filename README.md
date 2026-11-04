# :hammer_and_wrench: Akousma Build Tools

Build tools for [Akousma](https://github.com/Genki-jp0/Akousma) on Windows and Linux:

* Windows: `Build-Akousma.ps1` builds every dependency with Visual Studio 2022 or 2026 (MSVC), Akousma itself and the
  `AkousmaSetup-*.exe` installer in one run, for x64, x86 and arm64 (arm64 is cross-compiled on an x64 PC).
* Linux: `build-akousma.sh` builds Akousma with the libraries of your distribution and makes an install folder, an
  AppImage and, on request, a `.deb` or `.rpm`, for amd64, i386 and arm64 (the machine's own architecture natively,
  the others in containers).

Based on [strawberry-msvc-build-tools](https://github.com/strawberrymusicplayer/strawberry-msvc-build-tools)
(at d7e0c51) by Jonas Kvinge; Akousma is based on
[Strawberry Music Player](https://github.com/strawberrymusicplayer/strawberry).
Licensed under the GPL version 3 (see `COPYING`).

The two scripts are independent: each has its own settings file (`build-settings.json` for Windows,
`build-settings.linux.conf` for Linux, both next to the scripts and kept out of git) and its own release records
(`versions/` for Windows, `versions/linux/` for Linux).

## Windows (MSVC)

* `Build-Akousma.ps1`: the build script. `Get-Help .\Build-Akousma.ps1 -Detailed` lists every parameter.
* `BUILD.txt`: the full guide (tool search, build settings, architectures, parameters, folders, local patches, change
  detection, Audio CD).
* `local-patches/`: your patches for dependencies (`qtbase-*.patch` -> qtbase, `gstreamer-*.patch` -> gst-plugins-good,
  ...), applied automatically. Akousma's own changes are commits in the Akousma repository, not patches.
* `patches/`: the dependency patches from upstream (plus `libcdio-cmake.patch`), applied by the script.
* `StrawberryPackageVersions.txt`: the pinned dependency versions (upstream's file, name kept). `versions/`: the
  dependency versions of each Akousma release (`-FreezeDeps`). `CopyDLLDependencies.ps1`: collects the DLLs for the
  installer.

### Requirements

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

### Building

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

Dependency versions (`-Deps`, see "Dependency versions" in BUILD.txt): a build of a release tag uses that release's
lock, `versions/<release>.txt`; any other build (master, a branch, a local checkout) uses the latest versions
upstream's CI has built (strawberry-msvc-build-tools master), falling back to the pinned `StrawberryPackageVersions.txt`
per package when a patch would not fit, or entirely without network. Each run prints what differs from the pinned
versions.

```powershell
.\Build-Akousma.ps1 -AkousmaRef v1.0.0 -FreezeDeps 1.0.0   # release: build, keep its versions (commit versions/1.0.0.txt)
.\Build-Akousma.ps1 -AkousmaRef v1.0.0                     # later: the same versions again
.\Build-Akousma.ps1 -Deps pinned                           # the versions in StrawberryPackageVersions.txt
```

The first build of an architecture builds every dependency (several hours). Later runs rebuild only what changed
(printing the reason), then relink Akousma and re-create the installer.

Output, for x64 release with the default folders:

* `C:\Atelier\data\projects\akousma\msvc_\build_x86_64_release\akousma\build\akousma.exe`
* `C:\Atelier\data\projects\akousma\msvc_\build_x86_64_release\AkousmaSetup\AkousmaSetup-<version>-msvc-x64.exe`
  (x86: `build_x86_release\...-msvc-x86.exe`, arm64: `build_arm64_release\...-msvc-arm64.exe`)
* the log: `C:\Atelier\data\projects\akousma\build.log` (x86: `build_x86.log`), per package: `<build tree>\logs`

### Settings and folders

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

## Linux

`build-akousma.sh` builds only Akousma itself. The libraries (Qt 6, GStreamer, TagLib, ...) are the distribution's
packages; the script checks them and, with `--install-deps`, installs the missing ones. One exception: where the
distribution's KDSingleApplication is older than Akousma needs (1.1.0; Ubuntu 24.04 has 1.0.0), the script builds
KDSingleApplication (v1.2.1, static) from source first, as upstream Strawberry's CI does. Outputs, in one run:

* an install folder (`bin/akousma`, `share/...`), runnable as it is
* an AppImage (linuxdeploy with its Qt and GStreamer plugins, downloaded by the script)
* a native package on request: `.deb` with Akousma's `debian/` (dpkg-buildpackage), `.rpm` with Akousma's spec
  (rpmbuild)

for each architecture in `ARCHS`: amd64, i386 and arm64 by default, like the Windows script's x64, x86 and arm64.
The machine's own architecture is built natively, as above. Each other one is built by the same script inside a
container (podman, or docker) of a distribution that has the packages for that architecture: the same distribution
release as the machine when it has an image for it (Ubuntu 24.04 arm64 on Ubuntu 24.04, Fedora 43 aarch64 on Fedora
43), else Debian 13, the one distribution that still builds Qt 6 for i386. i386 runs on an amd64 machine as it is;
arm64 runs under qemu-user (binfmt_misc), which is slow (hours for a first build). Each architecture has its own
folders (`build_x86_64_release`, `build_i686_release`, `build_aarch64_release`, ...); a `.deb` or `.rpm` that an
architecture's distribution can't make (an i386 `.rpm`: there is no i686 Fedora) is left out with a warning.

Supported: Debian / Ubuntu (apt), Fedora (dnf), Arch Linux (pacman), openSUSE (zypper); see "Status".

* `build-akousma.sh`: the script. `./build-akousma.sh --help` lists every option.
* `linux/BUILD.txt`: the full guide (options, settings, folders, packages, change detection, outputs, release locks).
* `versions/linux/`: the package versions each Akousma release was built with (`--freeze-deps`).

### Requirements

bash 4.4+, git and sudo. Everything else comes from the distribution's packages:

```sh
./build-akousma.sh --check-deps        # what is installed, what is missing (and the command to install it)
./build-akousma.sh --install-deps      # install the missing packages (sudo; the command is shown first)
```

For the other architectures: podman (or a working docker) and, for arm64 on an amd64 machine, qemu-user-static.
`--install-deps` installs both (podman only when no engine works) and registers qemu in binfmt_misc. The build image
of each architecture (`localhost/akousma-build:<arch>-<base image>`, its packages installed) is made by the first build
that needs it; `--update-images` makes it again with the newest packages. When something is missing, the script
builds the architectures it can, then stops with an error naming the others and the fix; `--arch amd64` builds only
the machine's own architecture.

### Building

```sh
./build-akousma.sh                                  # Akousma master for amd64, i386, arm64: install folder + AppImage
./build-akousma.sh --arch amd64                     # only amd64, this run (--save-settings: from now on)
./build-akousma.sh --arch amd64,i386                # amd64 and i386
./build-akousma.sh --deb                            # ... and a .deb (Debian / Ubuntu)
./build-akousma.sh --rpm                            # ... and an .rpm (Fedora / openSUSE)
./build-akousma.sh --outputs install                # only the install folder
./build-akousma.sh --ref v1.0.0                     # a branch, tag or commit
./build-akousma.sh --source ~/src/Akousma           # a local checkout, uncommitted changes included
./build-akousma.sh --build-type debug               # debug build (its own folders)
./build-akousma.sh --list                           # what would be built and why; builds nothing
./build-akousma.sh --dry-run                        # settings, folders, source, packages, steps of each
                                                    # architecture; changes nothing
```

A branch is built at `origin/<branch>` right after a fetch, never at a stale local branch. A second run with nothing
changed (same Akousma commit, settings and package versions) skips the build and the outputs; otherwise CMake rebuilds
only what changed. `--force` builds anyway, `--clean` starts the CMake build folder again.

Output, release build with the default folders (`~/Atelier`):

* `~/Atelier/akousma_linux_x86_64_release/bin/akousma`: the install folder (i386: `akousma_linux_i686_release`, arm64:
  `akousma_linux_aarch64_release`)
* `~/Atelier/data/projects/akousma/linux_/build_x86_64_release/packages/`: `Akousma-<version>-x86_64.AppImage`,
  `akousma_<version>-<codename>_amd64.deb`, `akousma-<version>-1.<dist>.x86_64.rpm` (i386: `build_i686_release`,
  `-i686.AppImage`, `_i386.deb`; arm64: `build_aarch64_release`, `-aarch64.AppImage`, `_arm64.deb`, `.aarch64.rpm`)
* the log: `~/Atelier/data/projects/akousma/build_linux.log`, per step: `<build folder>/logs`

### Settings and folders

`build-settings.linux.conf`, next to the script, keeps your settings (architectures, folders, Akousma source, build
type, outputs, container engine and images, ...). The first run creates it with the defaults; `.gitignore` keeps it
out of git. It is a plain `KEY=value` file that the script reads (it is never run). An option on the command line
wins for that run; add `--save-settings` to write it into the file:

```sh
./build-akousma.sh --src-path /mnt/data/akousma/src --save-settings --dry-run   # save without building
```

Everything goes under `~/Atelier` by default (`--work-root` moves it all). The git clones (`--src-path`) and the
downloads (`--downloads-path`) can be put elsewhere, e.g. on another drive.

### Dependency versions and releases

The dependencies are the distribution's packages, so they can't be pinned the way `Build-Akousma.ps1` pins its
dependencies: `apt`/`dnf`/`pacman`/`zypper` install what the distribution currently ships, and old versions are
usually not available any more. What the script can do is record and compare:

```sh
./build-akousma.sh --ref v1.0.0 --freeze-deps 1.0.0   # build 1.0.0, write versions/linux/1.0.0.txt; commit it
./build-akousma.sh --ref v1.0.0                       # later: builds the recorded commit, warns about each package
./build-akousma.sh --release 1.0.0                    #   whose version differs from the record
```

`versions/linux/<release>.txt` records the Akousma commit and, for each architecture, the distribution and its
version (and the container base image), and the installed version of each dependency package (and the
KDSingleApplication tag when it is built from source: that one is pinned). It is written only when every architecture
was built.
For a build that really matches a release, use the same distribution release and keep its packages (e.g. a container
or VM); for a binary that runs on many distributions, ship the AppImage.

### Status

Tested with Akousma master on Ubuntu 24.04 (install folder, AppImage, .deb) and Fedora 43 (install folder, .rpm),
and the container builds of i386 and arm64 on an Ubuntu 24.04 amd64 machine with docker: see "Tested" in
linux/BUILD.txt. Arch Linux and openSUSE: the package names are checked against those distributions'
package databases, but the script has not been run there yet. Please report a package name that doesn't resolve.
