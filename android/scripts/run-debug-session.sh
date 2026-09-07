#!/usr/bin/env bash
# Part 3 reproducer: a REAL debugging session on the phone -- breakpoints bind and hit,
# backtrace with file:line, locals and expressions, stepping, func-eval -- driven through
# the netcoredbg CLI over a FIFO in the app sandbox. Prints every debugger reply and a
# verdict at the end.
#
# Prereqs: the Debug app is installed (Part 1), adb sees the device, and the prebuilt
# pieces exist under ../*/prebuilt/ (or run the build-*.sh scripts first). Nothing here
# needs the .NET 11 SDK.
#
# Usage: run-debug-session.sh [-s <serial>] [-p <package>] [-P <plan-file>]
#   -P  a plan file to run instead of the built-in one (see PLAN FORMAT below).
#
# PLAN FORMAT (one action per line; '#' comments):
#   send <wait-seconds> <cli command...>   write one netcoredbg CLI command, wait, show replies
#   tap <x> <y> <wait-seconds>             tap the screen (device pixels), wait, show replies
#   wait <seconds>                         wait and show replies
#   screen                                 print the sample app's counter/status text
#   echo <text>                            print a marker
#
# The built-in plan targets samples/SimpleDebugApp_API_37 from CodeBrix.Android and the
# Pixel 4 XL layout (the Count button is at 720,818 on a 1440x3040 screen). For another
# device get the bounds with `adb shell uiautomator dump` and pass your own plan.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SERIAL=""; PKG="com.codebrix.simpledebugapp"; ACT_SUFFIX=".MainActivity"; PLAN=""
while getopts "s:p:P:" o; do case $o in s) SERIAL="-s $OPTARG";; p) PKG="$OPTARG";; P) PLAN="$OPTARG";; esac; done

NCDBG="$ROOT/netcoredbg/prebuilt/netcoredbg"
MANAGED="$ROOT/netcoredbg/prebuilt/managed"
SHIM="$ROOT/dbgshim/prebuilt/libdbgshim.so"
TRACE="$ROOT/harness/prebuilt/libtrace.so"
for f in "$NCDBG" "$SHIM" "$TRACE" "$MANAGED/ManagedPart.dll"; do [ -f "$f" ] || { echo "MISSING: $f (run the build-*.sh scripts)"; exit 1; }; done

A(){ adb $SERIAL "$@" </dev/null; }
RA(){ A shell "run-as $PKG sh -c '$*'"; }
ts(){ date +"[%H:%M:%S]"; }
D="/data/data/$PKG/ncdbg"
OVR="/data/data/$PKG/files/.__override__/arm64-v8a"
OUT="$(mktemp -d /tmp/ncdbg-session.XXXXXX)"
LASTLINES=0
show(){ RA "cat $D/ncdbg.out" | tr -d '\r' > "$OUT/ncdbg.out"; local n; n=$(wc -l < "$OUT/ncdbg.out"); if [ "$n" -gt "$LASTLINES" ]; then sed -n "$((LASTLINES+1)),${n}p" "$OUT/ncdbg.out" | grep -v '^$' | cut -c1-400 | sed 's/^/    | /'; fi; LASTLINES=$n; }
send(){ local w=$1; shift; echo; echo "$(ts) >>> $*"; timeout 10 adb $SERIAL shell "run-as $PKG sh -c 'set -f; echo $* > $D/cmd.fifo'" </dev/null; sleep "$w"; show; }
screen(){ A shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1; echo "$(ts) screen: $(A shell cat /sdcard/ui.xml | tr '>' '\n' | grep -oE 'text="[^"]*" resource-id="'"$PKG"':id/(status|counter)_text"' | sed -E 's/ resource-id="[^"]*"//' | tr '\n' ' ')"; }

if [ -z "$PLAN" ]; then
  PLAN="$OUT/plan.txt"
  cat > "$PLAN" <<'EOF'
send 3 break MainActivity.cs:47
send 3 break Calculator.cs:56
send 3 info break
send 3 continue
echo tap the Count button: breakpoint 1 must hit on the UI thread
tap 720 818 4
send 4 bt
send 4 print _count
send 6 print this
send 4 step
send 4 next
send 4 print count
send 4 print parity
send 4 print count % 2
send 4 continue
wait 2
send 4 print isSquare
send 4 finish
send 4 next
send 4 print description
send 4 continue
screen
send 3 detach
send 3 quit
EOF
fi

echo "== device:"; A get-state
A shell pm list packages | grep -q "$PKG" || { echo "app $PKG not installed -- do Part 1 first"; exit 1; }

echo "== place debugger + managed helper in the app sandbox (via run-as, as the app uid)"
A shell mkdir -p /data/local/tmp/ncdbg
A push "$NCDBG"  /data/local/tmp/ncdbg/netcoredbg   >/dev/null
A push "$SHIM"   /data/local/tmp/ncdbg/libdbgshim.so >/dev/null
A push "$TRACE"  /data/local/tmp/ncdbg/libtrace.so   >/dev/null
for f in "$MANAGED"/*.dll; do A push "$f" /data/local/tmp/ncdbg/ >/dev/null; done
A shell chmod 644 /data/local/tmp/ncdbg/*
A shell "run-as $PKG sh -c 'mkdir -p $D && cp /data/local/tmp/ncdbg/* $D/ && chmod 755 $D/netcoredbg'"

echo "== mark the app as the debug app (ActivityManager then skips ANRs while it sits at a breakpoint; undo: am clear-debug-app)"
A shell am set-debug-app --persistent "$PKG"

echo "== restart the app FRESH (a stale/interrupted session makes the runtime reply SessionResync instead of SessionAccept)"
A shell am force-stop "$PKG"; A shell sleep 1
A shell am start -n "$PKG/$ACT_SUFFIX" >/dev/null 2>&1; A shell sleep 4
PID="$(A shell pidof "$PKG" | tr -d '\r')"
LIBDIR="$(RA cat /proc/$PID/maps | grep -o '/data/app/[^ ]*/lib/arm64' | head -1)"
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
echo "==================== Part 3 VERDICT ===================="
T="$OUT/ncdbg.out"
chk(){ if grep -q "$2" "$T"; then echo "$1: YES"; else echo "$1: NO"; fi; }
chk "attach completed (symbols loaded + stopped)      " "symbols loaded"
chk "line breakpoint bound                            " "Breakpoint 1 at"
chk "breakpoint hit                                   " "reason: breakpoint 1 hit"
chk "backtrace with file:line                         " "^#0: .* at .*\.cs:[0-9]"
chk "variable / expression printed                    " "^_count = "
chk "stepping (end stepping range)                    " "reason: end stepping range"
chk "func-eval (print this expanded the object)       " "^this = {"
if grep -q "terminating due to uncaught\|Fatal signal" "$T"; then echo ">>> the debugger CRASHED during the session -- see $OUT/ncdbg.out"; fi
echo "   full transcript: $OUT/ncdbg.out   (app left running; debugger stopped)"
