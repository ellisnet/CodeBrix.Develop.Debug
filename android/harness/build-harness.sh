#!/usr/bin/env bash
# Build libtrace.so, the LD_PRELOAD helper used by the attach runs. It answers
# Android's SELinux-blocked kill(pid,0) liveness check (so the attach is not
# aborted early), redirects the debugger's assembly/framework opens to the
# on-device layout, and traces syscalls so the scripts can read the
# clr-debug-pipe handshake. env switches are documented in ../README.md.
#
# Usage: build-harness.sh [<abi>]      abi = arm64-v8a (default) | x86_64
# Output: prebuilt/<abi>/libtrace.so
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ABI="${1:-arm64-v8a}"
case "$ABI" in
  arm64-v8a) TRIPLE=aarch64-linux-android33 ;;
  x86_64)    TRIPLE=x86_64-linux-android33 ;;
  *) echo "ERROR: unsupported ABI '$ABI' (use arm64-v8a or x86_64)"; exit 1 ;;
esac
NDK="${ANDROID_NDK_ROOT:-$HOME/Android/Sdk/ndk/29.0.14206865}"
CC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/${TRIPLE}-clang"
[ -x "$CC" ] || { echo "ERROR: NDK clang not found at $CC. Set ANDROID_NDK_ROOT."; exit 1; }
OUT="$HERE/prebuilt/$ABI"
mkdir -p "$OUT"
"$CC" -O1 -shared -fPIC -o "$OUT/libtrace.so" "$HERE/trace.c" -ldl
echo "=== built + refreshed: $OUT/libtrace.so ($ABI)"; ls -la "$OUT/libtrace.so"
