#!/usr/bin/env bash
# Build libdbgshim.so for an Android ABI from the VENDORED, pinned dbgshim source
# (./diagnostics-src, dotnet/diagnostics @ 49690774 -- see NOTICE.txt).
#
# Usage: build-dbgshim-android.sh [<abi>]   abi = arm64-v8a (default) | x86_64
# Output: build-<arch>/dbgshim/libdbgshim.so  AND refreshed prebuilt/<abi>/libdbgshim.so
#
# Requirements on the machine (NOT vendored -- install them; see ../README.md):
#   * Android NDK 29.0.14206865  (ANDROID_NDK_ROOT, or the default path below)
#   * cmake 3.31.x               (NOT cmake 4.x -- this tree requires < 4)
#   * a C/C++ toolchain (the NDK brings clang)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ABI="${1:-arm64-v8a}"
case "$ABI" in
  arm64-v8a) ARCH=arm64 ;;
  x86_64)    ARCH=x64 ;;
  *) echo "ERROR: unsupported ABI '$ABI' (use arm64-v8a or x86_64)"; exit 1 ;;
esac
NDK="${ANDROID_NDK_ROOT:-$HOME/Android/Sdk/ndk/29.0.14206865}"
BUILD="$HERE/build-$ARCH"

[ -d "$NDK" ] || { echo "ERROR: NDK not found at $NDK. Set ANDROID_NDK_ROOT."; exit 1; }
command -v cmake >/dev/null || { echo "ERROR: cmake not on PATH."; exit 1; }

# tryrun.cmake (loaded via -C, BEFORE the toolchain file) reads the target arch
# from the environment, so it must be exported here.
export TARGET_BUILD_ARCH="$ARCH"

rm -rf "$BUILD"
cmake -S "$HERE" -B "$BUILD" \
  -C "$HERE/diagnostics-src/eng/native/tryrun.cmake" \
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI="$ABI" -DANDROID_PLATFORM=android-33 \
  -DCMAKE_BUILD_TYPE=Release \
  -DHAVE_LTTNG_TRACEPOINT_H=1
cmake --build "$BUILD" -j"$(nproc)"

SO="$BUILD/dbgshim/libdbgshim.so"
echo "=== built: $SO"
ls -la "$SO"
OUT="$HERE/prebuilt/$ABI"
mkdir -p "$OUT"
cp "$SO" "$OUT/libdbgshim.so"
echo "=== refreshed $OUT/libdbgshim.so ($ABI)"
echo "=== exported symbols (expect 18):"
"$NDK"/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-nm -D --defined-only "$SO" 2>/dev/null | grep ' T ' | wc -l || true
