#!/usr/bin/env bash
# Build the netcoredbg debugger binary for an Android ABI from THIS repo
# (CodeBrix.Develop.Debug -- the parent of the android/ folder). The only
# Android-specific source change (bionic has no libpthread) is already committed
# in ../../src/CMakeLists.txt.
#
# Usage: build-netcoredbg-android.sh [<abi>]   abi = arm64-v8a (default) | x86_64
# Output: build/android-<arch>/src/netcoredbg AND refreshed prebuilt/<abi>/netcoredbg
#
# DBGSHIM_DIR is deliberately left EMPTY: that makes netcoredbg load
# "libdbgshim.so" from its OWN directory at runtime, so on the phone the .so
# only needs to sit next to the netcoredbg binary.
#
# CoreCLR headers/IDL are VENDORED next to this script (./coreclr-deps, pinned to
# dotnet/runtime cc77fc9 -- see NOTICE.txt) and passed via -DCORECLR_DIR, so the
# build needs NO network and does NOT clone the 1.2 GB dotnet/runtime.
# Requirements: NDK 29.0.14206865, cmake 3.31.x (NOT 4.x), and a system `dotnet`
# on PATH (the tiny generrmsg tool is built with it; the SYSTEM .NET 10 SDK is
# fine -- the .NET 11 preview is NOT needed for this).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
ABI="${1:-arm64-v8a}"
case "$ABI" in
  arm64-v8a) ARCH=arm64; UNIXDEF=CLR_CMAKE_PLATFORM_UNIX_ARM64 ;;
  x86_64)    ARCH=x64;   UNIXDEF=CLR_CMAKE_PLATFORM_UNIX_AMD64 ;;
  *) echo "ERROR: unsupported ABI '$ABI' (use arm64-v8a or x86_64)"; exit 1 ;;
esac
NDK="${ANDROID_NDK_ROOT:-$HOME/Android/Sdk/ndk/29.0.14206865}"
BUILD="$REPO/build/android-$ARCH"
[ -d "$NDK" ] || { echo "ERROR: NDK not found at $NDK. Set ANDROID_NDK_ROOT."; exit 1; }

rm -rf "$BUILD"; mkdir -p "$BUILD"
# detectplatform.cmake keys on CMAKE_SYSTEM_NAME==Linux, but the NDK sets it to
# Android, so pre-seed what that block would have set for this arch.
cmake -S "$REPO" -B "$BUILD" \
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI="$ABI" -DANDROID_PLATFORM=android-33 \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_MANAGED=OFF -DDBGSHIM_DIR= \
  -DCORECLR_DIR="$HERE/coreclr-deps/coreclr" \
  -DCLR_CMAKE_PLATFORM_UNIX=1 -D${UNIXDEF}=1 \
  -DCLR_CMAKE_HOST_ARCH=$ARCH -DCLR_CMAKE_TARGET_ARCH=$ARCH
cmake --build "$BUILD" --target netcoredbg -j"$(nproc)"
echo "=== built: $BUILD/src/netcoredbg"; ls -la "$BUILD/src/netcoredbg"
OUT="$HERE/prebuilt/$ABI"
mkdir -p "$OUT"
cp "$BUILD/src/netcoredbg" "$OUT/netcoredbg"
echo "=== refreshed $OUT/netcoredbg ($ABI)"

# This build is the NATIVE debugger only (-DBUILD_MANAGED=OFF). The managed helper
# (ManagedPart.dll + Roslyn) is architecture-independent, built separately by
# ./build-managed-helper.sh into ./prebuilt/managed/. Part 2 (the dbgshim attach
# proof) does not need it; Part 3 (a real debug session) does. See ../README.md.
