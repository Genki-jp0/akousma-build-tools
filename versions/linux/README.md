# Release records (Linux)

The records of `build-akousma.sh` (the Windows locks of `Build-Akousma.ps1` are one folder up, in `versions/`).

One file per Akousma release, `<release>.txt` (e.g. `1.0.0.txt`), written by
`./build-akousma.sh --ref v1.0.0 --freeze-deps 1.0.0`; commit it. It is a `KEY=value` file:

* `akousma_commit`: the Akousma commit the release was built from (the script builds this commit again)
* `akousma_source`, `build_tools_commit`, `frozen`, `archs` (the architectures it covers, e.g. `amd64,i386,arm64`)
* one section per architecture, every key prefixed with the architecture (`amd64.`, `i386.`, `arm64.`):
  * `distro`, `distro_version`, `distro_name`, `package_manager`, `arch`, `build_type`, `cmake_args`: what it was built
    on (for i386 and arm64 on an amd64 machine: the container), plus `container_image` / `container_image_digest`
    (the base image) for an architecture built in a container
  * `kdsingleapplication_ref` / `kdsingleapplication_commit`: when KDSingleApplication was built from source (pinned)
  * `tool.<name>.sha256`: the AppImage tools that were used
  * `pkg.<package>=<version>`: every dependency package that was installed, at its installed version

The file is written only when every architecture was built (`--arch` chooses which ones a release has).

A build of that release (`--release 1.0.0`, `--ref 1.0.0`, `--ref v1.0.0`, or a build of `akousma_commit`) builds
the recorded commit and, for each architecture, warns about each package whose installed version differs from its
section, and when the distribution differs (or the record has no section for that architecture).

**Distribution packages are not pinned by this.** The package manager installs what the distribution ships now; old
versions are usually gone. The record tells you what changed since the release, it can't bring the old versions
back. For an exact rebuild, keep a container or VM of the distribution release the record names.
