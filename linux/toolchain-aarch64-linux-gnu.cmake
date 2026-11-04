# CMake toolchain file: arm64 (aarch64) programs built on an amd64 Debian with dpkg multiarch.
#
# build-akousma.sh uses it for arm64 on an amd64 machine (ARM64_MODE=cross, the default), in its Debian 13 build
# container: "dpkg --add-architecture arm64", crossbuild-essential-arm64, the arm64 -dev packages (name:arm64) and the
# amd64 Qt tools. No sysroot: the arm64 libraries are in /usr/lib/aarch64-linux-gnu, the headers in /usr/include (and
# /usr/include/aarch64-linux-gnu), where CMake looks for them because of CMAKE_LIBRARY_ARCHITECTURE.
#
# Qt: Debian builds Qt 6 natively for every architecture, so its CMake packages don't ask for QT_HOST_PATH, and the
# Qt6*Tools packages of every architecture name the same /usr/lib/qt6/libexec/{moc,rcc,uic} and
# /usr/lib/qt6/bin/lrelease. Those come from qt6-base-dev-tools, qt6-tools-dev-tools and qt6-l10n-tools, which are
# Multi-Arch: foreign: the amd64 ones are installed, so moc, uic, rcc and lrelease run natively.
#
# By hand, in such a container:  cmake -S <Akousma> -B build -G Ninja \
#                                  -DCMAKE_TOOLCHAIN_FILE=<this file> -DCMAKE_BUILD_TYPE=Release

set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(CMAKE_LIBRARY_ARCHITECTURE aarch64-linux-gnu)

set(CMAKE_C_COMPILER aarch64-linux-gnu-gcc)
set(CMAKE_CXX_COMPILER aarch64-linux-gnu-g++)

# The pkg-config of the arm64 packages (pkgconf:arm64): .pc files of /usr/lib/aarch64-linux-gnu/pkgconfig.
set(PKG_CONFIG_EXECUTABLE aarch64-linux-gnu-pkg-config CACHE FILEPATH "pkg-config for aarch64-linux-gnu")

# arm64 programs that CMake or ctest run (try_run, the tests) go through qemu-user.
find_program(AKOUSMA_QEMU_AARCH64 NAMES qemu-aarch64-static qemu-aarch64)
if(AKOUSMA_QEMU_AARCH64)
  set(CMAKE_CROSSCOMPILING_EMULATOR "${AKOUSMA_QEMU_AARCH64}")
endif()
