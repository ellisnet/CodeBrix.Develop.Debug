#!/usr/bin/env bash
# Build the netcoredbg debugger binary for android-arm64 from THIS repo
# (CodeBrix.Develop.Debug -- the parent of the android/ folder). The only
# Android-specific source change (bionic has no libpthread) is already committed
# in ../../src/CMakeLists.txt.
#
# DBGSHIM_DIR is deliberately left EMPTY: that makes netcoredbg load
# "libdbgshim.so" from its OWN directory at runtime, so on the phone the .so
# only needs to sit next to the netcoredbg binary.
#
# CoreCLR headers/IDL are VENDORED next to this script (./coreclr-src, pinned to
# dotnet/runtime cc77fc9 -- see NOTICE.txt) and passed via -DCORECLR_DIR, so the
# build needs NO network and does NOT clone the 1.2 GB dotnet/runtime.
# Requirements: NDK 29.0.14206865, cmake 3.31.x (NOT 4.x), and a system `dotnet`
# on PATH (the tiny generrmsg tool is built with it; the SYSTEM .NET 10 SDK is
# fine -- the .NET 11 preview is NOT needed for this). Output: build-arm64/src/netcoredbg
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
NDK="${ANDROID_NDK_ROOT:-$HOME/Android/Sdk/ndk/29.0.14206865}"
BUILD="$REPO/build/android-arm64"
[ -d "$NDK" ] || { echo "ERROR: NDK not found at $NDK. Set ANDROID_NDK_ROOT."; exit 1; }

mkdir -p "$BUILD"
# detectplatform.cmake keys on CMAKE_SYSTEM_NAME==Linux, but the NDK sets it to
# Android, so pre-seed what that block would have set for arm64.
cmake -S "$REPO" -B "$BUILD" \
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-33 \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_MANAGED=OFF -DDBGSHIM_DIR= \
  -DCORECLR_DIR="$HERE/coreclr-deps/coreclr" \
  -DCLR_CMAKE_PLATFORM_UNIX=1 -DCLR_CMAKE_PLATFORM_UNIX_ARM64=1 \
  -DCLR_CMAKE_HOST_ARCH=arm64 -DCLR_CMAKE_TARGET_ARCH=arm64
cmake --build "$BUILD" --target netcoredbg -j"$(nproc)"
echo "=== built: $BUILD/src/netcoredbg"; ls -la "$BUILD/src/netcoredbg"

# ManagedPart.dll + Roslyn (netcoredbg's managed symbol reader) come from a
# normal host build of netcoredbg; they are NOT needed to prove the Part-2
# dbgshim attach, only for later parts. See ../README.md.
