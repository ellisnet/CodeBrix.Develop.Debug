#!/usr/bin/env bash
# Part 3 reproducer: a REAL debugging session on the device -- breakpoints bind and hit,
# backtrace with file:line, locals and expressions, stepping, func-eval, exceptions --
# driven through the netcoredbg CLI over a FIFO in the app sandbox. Prints every debugger
# reply and a verdict at the end. Works on both arm64-v8a and x86_64 devices (the ABI is
# detected from the device and the matching prebuilt binaries are used).
#
# Prereqs: the Debug app is installed (Part 1), adb sees the device, and the prebuilt
# pieces exist under ../*/prebuilt/<abi>/ + ../netcoredbg/prebuilt/managed/ (or run the
# build-*.sh scripts first). Nothing here needs the .NET 11 SDK.
#
# Usage: run-debug-session.sh [-s <serial>] [-p <package>] [-P <plan-file>]
#   -P  a plan file to run instead of the built-in one (see PLAN FORMAT below).
#
# PLAN FORMAT (one action per line; '#' comments):
#   send <wait-seconds> <cli command...>   write one netcoredbg CLI command, wait, show replies
#   tapid <resource-id> <wait-seconds>     tap the app view with this resource-id (by its
#                                          on-screen bounds -- resolution-independent)
#   tap <x> <y> <wait-seconds>             tap absolute device pixels, wait, show replies
#   wait <seconds>                         wait and show replies
#   screen                                 print the sample app's counter/status text
#   echo <text>                            print a marker
#
# The built-in plan targets samples/SimpleDebugApp_API_37 from CodeBrix.Android and uses
# tapid, so it works unchanged on any screen size / orientation (Pixel or emulator).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SERIAL=""; PKG="com.codebrix.simpledebugapp"; ACT_SUFFIX=".MainActivity"; PLAN=""
while getopts "s:p:P:" o; do case $o in s) SERIAL="-s $OPTARG";; p) PKG="$OPTARG";; P) PLAN="$OPTARG";; esac; done

A(){ adb $SERIAL "$@" </dev/null; }
RA(){ A shell "run-as $PKG sh -c '$*'"; }
ts(){ date +"[%H:%M:%S]"; }
D="/data/data/$PKG/ncdbg"
OUT="$(mktemp -d /tmp/ncdbg-session.XXXXXX)"

echo "== device:"; A get-state
A shell pm list packages | grep -q "$PKG" || { echo "app $PKG not installed -- do Part 1 first"; exit 1; }

# Pick the prebuilt binaries for the device's primary ABI; the on-device assembly
# dir (.__override__) is named by that same ABI.
ABI="$(A shell getprop ro.product.cpu.abi | tr -d '\r')"
case "$ABI" in arm64-v8a|x86_64) ;; *) echo "unsupported device ABI '$ABI' (need arm64-v8a or x86_64)"; exit 1;; esac
NCDBG="$ROOT/netcoredbg/prebuilt/$ABI/netcoredbg"
MANAGED="$ROOT/netcoredbg/prebuilt/managed"
SHIM="$ROOT/dbgshim/prebuilt/$ABI/libdbgshim.so"
TRACE="$ROOT/harness/prebuilt/$ABI/libtrace.so"
for f in "$NCDBG" "$SHIM" "$TRACE" "$MANAGED/ManagedPart.dll"; do [ -f "$f" ] || { echo "MISSING: $f (run build-*.sh $ABI first)"; exit 1; }; done
OVR="/data/data/$PKG/files/.__override__/$ABI"
echo "== device ABI: $ABI"

LASTLINES=0
show(){ RA "cat $D/ncdbg.out" | tr -d '\r' > "$OUT/ncdbg.out"; local n; n=$(wc -l < "$OUT/ncdbg.out"); if [ "$n" -gt "$LASTLINES" ]; then sed -n "$((LASTLINES+1)),${n}p" "$OUT/ncdbg.out" | grep -v '^$' | cut -c1-400 | sed 's/^/    | /'; fi; LASTLINES=$n; }
send(){ local w=$1; shift; echo; echo "$(ts) >>> $*"; timeout 10 adb $SERIAL shell "run-as $PKG sh -c 'set -f; echo $* > $D/cmd.fifo'" </dev/null; sleep "$w"; show; }
screen(){ A shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1; echo "$(ts) screen: $(A shell cat /sdcard/ui.xml | tr '>' '\n' | grep -oE 'text="[^"]*" resource-id="'"$PKG"':id/(status|counter)_text"' | sed -E 's/ resource-id="[^"]*"//' | tr '\n' ' ')"; }
tapid(){ # tap a view by resource-id, computed from its bounds (resolution-independent)
  local id="$1" w="$2"
  A shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1
  local nums; nums=$(A shell cat /sdcard/ui.xml | tr '>' '\n' | grep "resource-id=\"$PKG:id/$id\"" | grep -oE 'bounds="\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]"' | head -1 | grep -oE '[0-9]+')
  set -- $nums
  if [ $# -ne 4 ]; then echo "$(ts) tapid $id -> NOT FOUND on screen"; return; fi
  local cx=$(( ($1+$3)/2 )) cy=$(( ($2+$4)/2 ))
  echo "$(ts) tapid $id -> ($cx,$cy)"; A shell input tap $cx $cy; sleep "$w"; show
}

if [ -z "$PLAN" ]; then
  PLAN="$OUT/plan.txt"
  cat > "$PLAN" <<'EOF'
send 3 break MainActivity.cs:47
send 3 break Calculator.cs:56
send 3 info break
send 3 continue
echo tap the Count button: breakpoint 1 must hit on the UI thread
tapid count_button 4
send 4 bt
send 4 print _count
send 6 print this
send 4 step
send 4 next
send 4 print count
send 4 print count % 2
send 4 continue
wait 2
send 4 print isSquare
send 4 finish
send 4 next
send 4 print description
send 4 continue
screen
echo first-chance exception stop
send 3 catch throw *
tapid throw_button 5
send 4 bt
send 4 continue
wait 2
screen
send 3 detach
send 3 quit
EOF
fi

echo "== place debugger + managed helper in the app sandbox (via run-as, as the app uid)"
A shell mkdir -p /data/local/tmp/ncdbg
A push "$NCDBG"  /data/local/tmp/ncdbg/netcoredbg   >/dev/null
A push "$SHIM"   /data/local/tmp/ncdbg/libdbgshim.so >/dev/null
A push "$TRACE"  /data/local/tmp/ncdbg/libtrace.so   >/dev/null
for f in "$MANAGED"/*.dll; do A push "$f" /data/local/tmp/ncdbg/ >/dev/null; done
A shell chmod 644 /data/local/tmp/ncdbg/*
A shell "run-as $PKG sh -c 'mkdir -p $D && cp /data/local/tmp/ncdbg/* $D/ && chmod 755 $D/netcoredbg'"

# set-debug-app MUST come before the fresh launch: applied to an already-running app it
# restarts the process, orphaning the pid we attach to. (ActivityManager then also skips
# ANRs while the app sits at a breakpoint; undo with `am clear-debug-app`.)
echo "== mark the app as the debug app, then restart it FRESH (a stale process makes the runtime reply SessionResync instead of SessionAccept)"
A shell am set-debug-app --persistent "$PKG"
A shell am force-stop "$PKG"; A shell sleep 1
A shell am start -n "$PKG/$ACT_SUFFIX" >/dev/null 2>&1; A shell sleep 4
PID="$(A shell pidof "$PKG" | tr -d '\r')"
# The app's native-lib dir under /data/app (holds libcoreclr.so). ABI-agnostic.
LIBDIR="$(RA cat /proc/$PID/maps | grep -oE '/data/app/[^ ]*/lib/[a-z0-9_]+' | sort -u | head -1)"
echo "   fresh pid=$PID  apk-lib=$LIBDIR"
RA "pkill -9 netcoredbg; rm -f $D/trace.txt $D/file $D/ncdbg.out $D/cmd.fifo; mkfifo $D/cmd.fifo" >/dev/null 2>&1

echo "== attach (CLI reads commands from a FIFO; the harness masks the SELinux-blocked liveness check and redirects the hosted runtime's framework lookups)"
A shell "run-as $PKG sh -c 'cd $D && (sleep 1200 > $D/cmd.fifo 2>/dev/null </dev/null &) && (LD_PRELOAD=$D/libtrace.so TRACE_OUT=$D/trace.txt TRACE_MASK_KILL0=1 TRACE_REDIR_DIR=$OVR TRACE_TPA_DIR=$OVR TRACE_CLR_DIR=$LIBDIR LD_LIBRARY_PATH=$LIBDIR TMPDIR=/data/data/$PKG/cache $D/netcoredbg --interpreter=cli --attach $PID --log=file < $D/cmd.fifo > $D/ncdbg.out 2>&1 &) ; sleep 2; pidof netcoredbg'" | tr -d '\r' | tail -1 > "$OUT/ncdbg.pid"
echo "   debugger pid=$(cat "$OUT/ncdbg.pid"); waiting 10 s for the attach"
sleep 10; show

set -f   # no glob expansion while splitting plan lines (`catch throw *` must keep its `*`)
while IFS= read -r -u 3 line; do
  [ -z "$line" ] && continue; case "$line" in \#*) continue;; esac
  set -- $line
  case "$1" in
    send) shift; w=$1; shift; send "$w" "$@";;
    tapid) tapid "$2" "$3";;
    tap) echo "$(ts) tap $2,$3"; A shell input tap "$2" "$3"; sleep "$4"; show;;
    wait) sleep "$2"; show;;
    screen) screen;;
    echo) shift; echo "$(ts) ## $*";;
  esac
done 3< "$PLAN"
set +f

sleep 2
RA "pkill -9 netcoredbg" >/dev/null 2>&1
echo
echo "==================== Part 3 VERDICT ($ABI) ===================="
T="$OUT/ncdbg.out"
chk(){ if grep -q "$2" "$T"; then echo "$1: YES"; else echo "$1: NO"; fi; }
chk "attach completed (symbols loaded + stopped)      " "symbols loaded"
chk "line breakpoint bound                            " "Breakpoint 1 at"
chk "breakpoint hit                                   " "reason: breakpoint 1 hit"
chk "backtrace with file:line                         " "^#0: .* at .*\.cs:[0-9]"
chk "variable / expression printed                    " "^_count = "
chk "stepping (end stepping range)                    " "reason: end stepping range"
chk "func-eval (print this expanded the object)       " "^this = {"
chk "first-chance exception stop                      " "reason: exception received"
if grep -q "terminating due to uncaught\|Fatal signal" "$T"; then echo ">>> the debugger CRASHED during the session -- see $OUT/ncdbg.out"; fi
echo "   full transcript: $OUT/ncdbg.out   (app left running; debugger stopped)"
