#!/usr/bin/env bash
# Part 2 reproducer: place the on-device debugger, attach to a FRESH instance of
# the debuggable app, and report whether dbgshim formed the debug session.
# Works on both arm64-v8a and x86_64 devices (the ABI is detected from the device).
#
# Prereqs: the app is already built (Debug) and installed on the device (Part 1),
# adb sees the device, and the prebuilt binaries exist under ../*/prebuilt/<abi>/
# (or run the build-*.sh scripts first). Nothing here needs the .NET 11 SDK.
#
# Usage: run-attach.sh [-s <serial>] [-p <package>]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SERIAL=""; PKG="com.codebrix.simpledebugapp_net11"; ACT_SUFFIX=".MainActivity"
while getopts "s:p:" o; do case $o in s) SERIAL="-s $OPTARG";; p) PKG="$OPTARG";; esac; done

A(){ adb $SERIAL "$@" </dev/null; }
D="/data/data/$PKG/ncdbg"
echo "== device:"; A get-state
A shell pm list packages | grep -q "$PKG" || { echo "app $PKG not installed -- do Part 1 first"; exit 1; }

# Pick the prebuilt binaries for the device's primary ABI.
ABI="$(A shell getprop ro.product.cpu.abi | tr -d '\r')"
case "$ABI" in arm64-v8a|x86_64) ;; *) echo "unsupported device ABI '$ABI' (need arm64-v8a or x86_64)"; exit 1;; esac
NCDBG="$ROOT/netcoredbg/prebuilt/$ABI/netcoredbg"
SHIM="$ROOT/dbgshim/prebuilt/$ABI/libdbgshim.so"
TRACE="$ROOT/harness/prebuilt/$ABI/libtrace.so"
for f in "$NCDBG" "$SHIM" "$TRACE"; do [ -f "$f" ] || { echo "MISSING: $f (run build-*.sh $ABI first)"; exit 1; }; done
echo "== device ABI: $ABI"

echo "== place debugger in the app sandbox (via run-as, as the app uid)"
A shell mkdir -p /data/local/tmp/ncdbg
A push "$NCDBG"  /data/local/tmp/ncdbg/netcoredbg   >/dev/null
A push "$SHIM"   /data/local/tmp/ncdbg/libdbgshim.so >/dev/null
A push "$TRACE"  /data/local/tmp/ncdbg/libtrace.so   >/dev/null
A shell chmod 644 /data/local/tmp/ncdbg/*
A shell "run-as $PKG sh -c 'mkdir -p $D && cp /data/local/tmp/ncdbg/netcoredbg /data/local/tmp/ncdbg/libdbgshim.so /data/local/tmp/ncdbg/libtrace.so $D/ && chmod 755 $D/netcoredbg'"

echo "== restart the app FRESH (a stale/interrupted session makes the runtime reply SessionResync instead of SessionAccept)"
A shell am force-stop "$PKG"; A shell sleep 1
A shell am start -n "$PKG/$ACT_SUFFIX" >/dev/null 2>&1; A shell sleep 4
PID="$(A shell pidof "$PKG" | tr -d '\r')"
# The app's native-lib dir under /data/app (holds libcoreclr.so). ABI-agnostic.
LIBDIR="$(A shell "run-as $PKG cat /proc/$PID/maps" | grep -oE '/data/app/[^ ]*/lib/[a-z0-9_]+' | sort -u | head -1)"
echo "   fresh pid=$PID  apk-lib=$LIBDIR"
A shell "run-as $PKG sh -c 'rm -f $D/trace.txt $D/file'"

echo "== attach (TRACE_MASK_KILL0 answers the SELinux-blocked liveness check; 20s cap -- dbgshim finishes in ~1s)"
printf 'detach\nquit\n' | timeout 20 adb $SERIAL shell \
  "run-as $PKG sh -c 'cd $D && LD_PRELOAD=$D/libtrace.so TRACE_OUT=$D/trace.txt TRACE_MASK_KILL0=1 LD_LIBRARY_PATH=$LIBDIR TMPDIR=/data/data/$PKG/cache $D/netcoredbg --interpreter=cli --attach $PID --log=file'" \
  >/dev/null 2>&1 || true

echo
echo "==================== dbgshim VERDICT ($ABI) ===================="
T="$(A shell "run-as $PKG cat $D/trace.txt" 2>/dev/null)"
# The read pipe fd number varies by device/run, so match it loosely.
accept=$(printf '%s' "$T" | grep -cE 'read\(pipe fd [0-9]+, 48\) = 48  \[01' || true)
getdcb=$(printf '%s' "$T" | grep -cE 'read\(pipe fd [0-9]+, 48\) = 48  \[08' || true)
writes=$(printf '%s' "$T" | grep -cE 'read\(pipe fd [0-9]+, 48\) = 48  \[07' || true)
echo "SessionAccept (type 1) received : $([ "$accept" -gt 0 ] && echo YES || echo NO)"
echo "GetDCB (type 8) exchange        : $([ "$getdcb" -gt 0 ] && echo YES || echo NO)"
echo "MT_WriteMemory (type 7) rounds  : $writes"
if [ "$accept" -gt 0 ] && [ "$writes" -gt 0 ]; then
  echo ">>> dbgshim DID ITS JOB: it loaded, resolved mscordbi, and formed the live debug session."
else
  echo ">>> dbgshim did NOT form the session -- inspect $D/trace.txt and $D/file on the device."
fi
echo "   (Part 2 proves the transport only; the full debug session is Part 3 -- see run-debug-session.sh.)"
echo "== app still running:"; A shell pidof "$PKG" | tr -d '\r'; echo
