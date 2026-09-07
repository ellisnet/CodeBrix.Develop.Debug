#!/usr/bin/env bash
# Build libtrace.so, the LD_PRELOAD helper used by the Part-2 attach run.
# It answers Android's SELinux-blocked kill(pid,0) liveness check (so the
# attach is not aborted early) and traces the debugger's syscalls so we can
# read the clr-debug-pipe handshake. env switches are documented in ../README.md.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NDK="${ANDROID_NDK_ROOT:-$HOME/Android/Sdk/ndk/29.0.14206865}"
CC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android33-clang"
[ -x "$CC" ] || { echo "ERROR: NDK clang not found at $CC. Set ANDROID_NDK_ROOT."; exit 1; }
"$CC" -O1 -shared -fPIC -o "$HERE/libtrace.so" "$HERE/trace.c" -ldl
echo "=== built: $HERE/libtrace.so"; ls -la "$HERE/libtrace.so"
