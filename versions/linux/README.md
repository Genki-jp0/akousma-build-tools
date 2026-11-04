# Release records (Linux)

The records of `build-akousma.sh` (the Windows locks of `Build-Akousma.ps1` are one folder up, in `versions/`).

One file per Akousma release, `<release>.txt` (e.g. `1.0.0.txt`), written by
`./build-akousma.sh --ref v1.0.0 --freeze-deps 1.0.0`; commit it. It is a `KEY=value` file:

* `akousma_commit`: the Akousma commit the release was built from (the script builds this commit again)
* `build_tools_commit`, `frozen`, `distro`, `distro_version`, `distro_name`, `package_manager`, `arch`, `build_type`,
  `cmake_args`
* `kdsingleapplication_ref` / `kdsingleapplication_commit`: when KDSingleApplication was built from source (pinned)
* `tool.<name>.sha256`: the AppImage tools that were used
* `pkg.<package>=<version>`: every dependency package that was installed, at its installed version

A build of that release (`--release 1.0.0`, `--ref 1.0.0`, `--ref v1.0.0`, or a build of `akousma_commit`) builds
the recorded commit and warns about each package whose installed version differs from the record, and when the
distribution differs.

**Distribution packages are not pinned by this.** The package manager installs what the distribution ships now; old
versions are usually gone. The record tells you what changed since the release, it can't bring the old versions
back. For an exact rebuild, keep a container or VM of the distribution release the record names.
