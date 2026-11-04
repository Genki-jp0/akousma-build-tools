# Release locks

One file per Akousma release, `<release>.txt` (e.g. `1.0.0.txt`): the dependency versions that release was built with,
in the format of `StrawberryPackageVersions.txt`, plus `# name: value` lines (the Akousma and build tools commits, the
git-sourced dependencies' commits, the patch hashes).

`Build-Akousma.ps1 -AkousmaRef v1.0.0 -FreezeDeps 1.0.0` writes `1.0.0.txt`; commit it. From then on a build of tag
`1.0.0` / `v1.0.0` (or of the commit recorded in the file) uses these versions (`-Deps auto`, the default), and
`-Deps 1.0.0` uses them for any build. Every other build uses the latest versions. See "Dependency versions" in
BUILD.txt.

`linux/` holds the release records of the Linux script, `build-akousma.sh` (see `linux/README.md` there);
Build-Akousma.ps1 doesn't read them.
