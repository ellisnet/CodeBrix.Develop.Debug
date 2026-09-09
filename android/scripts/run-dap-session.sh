#!/usr/bin/env bash
# Part 4 reproducer: the on-device debugger in Debug Adapter Protocol SERVER mode, driven from
# this machine by a PLAIN DAP client (android/dap-probe, no IDE code) over an adb-forwarded TCP
# port. Places the debugger + managed helper in the app sandbox, marks the debug app, launches the
# app fresh, starts `netcoredbg --interpreter=vscode --server=<port>` under run-as, forwards the
# port, and runs the probe, which attaches, sets breakpoints, taps buttons, inspects, steps, stops
# on a first-chance exception, detaches, and prints a VERDICT. Works on arm64-v8a and x86_64.
#
# Prereqs: the Debug app is installed (Part 1), adb sees the device, the prebuilt pieces exist
# under ../*/prebuilt/<abi>/ + ../netcoredbg/prebuilt/managed/, and a system `dotnet` (10.x) is
# on PATH to build/run the probe. Nothing here needs the .NET 11 SDK.
#
# Usage: run-dap-session.sh [-s <serial>] [-p <package>] [-d <source dir>] [-H <host port>] [-D <device port>] [-t]
#   -d  the folder holding MainActivity.cs / Calculator.cs (the paths the app's PDB records);
#       default: ~/GitHome/CodeBrix.Android/samples/SimpleDebugApp_API_37
#   -H  host port for `adb forward` (default 4711); -D device port the server listens on (default 4711)
#   -t  "tracing harness" mode: LD_PRELOAD libtrace.so (the investigation-era shim, which also
#       dumps the syscall trace) instead of relying on the Android compatibility layer built into
#       netcoredbg. Default: the built-in layer (NETCOREDBG_ANDROID_* variables) - what the NuGet
#       packages and CodeBrix.Develop use. (-n, the old name for the default, is still accepted.)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SERIAL=""; PKG="com.codebrix.simpledebugapp_net11"; ACT_SUFFIX=".MainActivity"
SRCDIR="$HOME/GitHome/CodeBrix.Android/samples/SimpleDebugApp_API_37"
HOSTPORT=4711; DEVPORT=4711; NATIVE=1
while getopts "s:p:d:H:D:nt" o; do case $o in s) SERIAL="-s $OPTARG";; p) PKG="$OPTARG";; d) SRCDIR="$OPTARG";; H) HOSTPORT="$OPTARG";; D) DEVPORT="$OPTARG";; n) NATIVE=1;; t) NATIVE=0;; esac; done
SERIAL_ONLY="${SERIAL#-s }"

A(){ adb $SERIAL "$@" </dev/null; }
RA(){ A shell "run-as $PKG sh -c '$*'"; }
ts(){ date +"[%H:%M:%S]"; }
D="/data/data/$PKG/ncdbg"
OUT="$(mktemp -d /tmp/ncdbg-dap.XXXXXX)"

echo "== device:"; A get-state
A shell pm list packages | grep -q "$PKG" || { echo "app $PKG not installed -- do Part 1 first"; exit 1; }
ABI="$(A shell getprop ro.product.cpu.abi | tr -d '\r')"
case "$ABI" in arm64-v8a|x86_64) ;; *) echo "unsupported device ABI '$ABI' (need arm64-v8a or x86_64)"; exit 1;; esac
NCDBG="$ROOT/netcoredbg/prebuilt/$ABI/netcoredbg"
MANAGED="$ROOT/netcoredbg/prebuilt/managed"
SHIM="$ROOT/dbgshim/prebuilt/$ABI/libdbgshim.so"
TRACE="$ROOT/harness/prebuilt/$ABI/libtrace.so"
for f in "$NCDBG" "$SHIM" "$MANAGED/ManagedPart.dll"; do [ -f "$f" ] || { echo "MISSING: $f (run build-*.sh $ABI first)"; exit 1; }; done
[ "$NATIVE" = 1 ] || [ -f "$TRACE" ] || { echo "MISSING: $TRACE (run harness/build-harness.sh $ABI, or drop -t)"; exit 1; }
OVR="/data/data/$PKG/files/.__override__/$ABI"
echo "== device ABI: $ABI   mode: $([ "$NATIVE" = 1 ] && echo 'built-in compat layer (no LD_PRELOAD)' || echo 'LD_PRELOAD tracing harness')"

echo "== build the probe"
dotnet build -c Release "$ROOT/dap-probe/DapProbe.csproj" -nologo -v:quiet || { echo "probe build failed"; exit 1; }
PROBE="$ROOT/dap-probe/bin/Release/net10.0/DapProbe.dll"

echo "== place debugger + managed helper in the app sandbox (via run-as, as the app uid)"
A shell mkdir -p /data/local/tmp/ncdbg
A push "$NCDBG"  /data/local/tmp/ncdbg/netcoredbg   >/dev/null
A push "$SHIM"   /data/local/tmp/ncdbg/libdbgshim.so >/dev/null
[ "$NATIVE" = 1 ] || A push "$TRACE"  /data/local/tmp/ncdbg/libtrace.so   >/dev/null
for f in "$MANAGED"/*.dll; do A push "$f" /data/local/tmp/ncdbg/ >/dev/null; done
A shell chmod 644 /data/local/tmp/ncdbg/*
A shell "run-as $PKG sh -c 'mkdir -p $D && cp /data/local/tmp/ncdbg/* $D/ && chmod 755 $D/netcoredbg'"

echo "== mark the app as the debug app, then restart it FRESH"
A shell am set-debug-app --persistent "$PKG"
A shell am force-stop "$PKG"; A shell sleep 1
A shell am start -n "$PKG/$ACT_SUFFIX" >/dev/null 2>&1; A shell sleep 4
PID="$(A shell pidof "$PKG" | tr -d '\r' | awk '{print $1}')"
[ -n "$PID" ] || { echo "app did not start"; exit 1; }
LIBDIR="$(RA cat /proc/$PID/maps | grep -oE '/data/app/[^ ]*/lib/[a-z0-9_]+' | sort -u | head -1)"
echo "   fresh pid=$PID  apk-lib=$LIBDIR"
RA "pkill -9 netcoredbg; rm -f $D/trace.txt $D/ncdbg.out; rm -f /data/data/$PKG/cache/netcoredbg.*.log" >/dev/null 2>&1

echo "== start the debugger in DAP server mode on port $DEVPORT (device), forwarded from host port $HOSTPORT"
if [ "$NATIVE" = 1 ]; then
  ENV="NETCOREDBG_ANDROID_ASSEMBLY_DIR=$OVR NETCOREDBG_ANDROID_CLR_DIR=$LIBDIR NETCOREDBG_ANDROID_TRACE=$D/trace.txt NETCOREDBG_COMMAND_TIMEOUT_MS=60000"
else
  ENV="LD_PRELOAD=$D/libtrace.so TRACE_OUT=$D/trace.txt TRACE_MASK_KILL0=1 TRACE_REDIR_DIR=$OVR TRACE_TPA_DIR=$OVR TRACE_CLR_DIR=$LIBDIR"
fi
A shell "run-as $PKG sh -c 'cd $D && ($ENV LD_LIBRARY_PATH=$LIBDIR TMPDIR=/data/data/$PKG/cache $D/netcoredbg --interpreter=vscode --server=$DEVPORT --log > $D/ncdbg.out 2>&1 &) ; sleep 1; pidof netcoredbg'" | tr -d '\r' | tail -1 > "$OUT/ncdbg.pid"
echo "   debugger pid=$(cat "$OUT/ncdbg.pid")"
A forward --remove tcp:$HOSTPORT >/dev/null 2>&1
A forward tcp:$HOSTPORT tcp:$DEVPORT || { echo "adb forward failed"; exit 1; }

echo "== run the plain DAP client"
dotnet "$PROBE" --port "$HOSTPORT" --pid "$PID" --serial "$SERIAL_ONLY" --package "$PKG" --source-dir "$SRCDIR" --transcript "$OUT/dap-transcript.txt"
RESULT=$?

sleep 1
A forward --remove tcp:$HOSTPORT >/dev/null 2>&1
RA "cat $D/ncdbg.out" | tr -d '\r' > "$OUT/ncdbg.out"
RA "cat /data/data/$PKG/cache/netcoredbg.*.log" 2>/dev/null | tr -d '\r' > "$OUT/netcoredbg.log"
RA "pkill -9 netcoredbg" >/dev/null 2>&1
if grep -q "terminating due to uncaught\|Fatal signal" "$OUT/ncdbg.out"; then echo ">>> the debugger CRASHED during the session -- see $OUT/ncdbg.out"; fi
echo "   transcript: $OUT/dap-transcript.txt   debugger stdout/stderr: $OUT/ncdbg.out   debugger log: $OUT/netcoredbg.log"
echo "   (app left running; debugger stopped; debug-app flag left set -- undo with: adb $SERIAL shell am clear-debug-app)"
exit $RESULT
