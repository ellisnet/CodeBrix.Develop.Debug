# Android arm64 debugging bundle

Everything needed to reproduce, on a second LMDE machine, the two results we
proved on a Pixel 4 XL:

- **Part 1** — build a Debug `.NET 11` Android app, deploy it, run it.
- **Part 2** — place an on-device debugger and show it attaches to the running
  app and forms the live debug session ("dbgshim did its job").

This folder is **self-contained**: the source for every binary is vendored and
pinned, so nothing here depends on a network clone or a moving branch. The one
thing it does **not** include (by design) is the app being debugged and the
.NET 11 SDK — see Prerequisites.

The first half of this document is the practical runbook for Parts 1 and 2. The
second half — **[Part 3 — The full research record](#part-3--the-full-research-record)** —
is the exhaustive write-up of how CoreCLR debugging works on Android, every
blocker found, the wall we hit (an in-process-CoreCLR hosting deadlock), and the
route through it. Read it to understand *why*, not just *how*.

---

## What's in here

```
android/
  README.md                     this file
  NOTICE.txt                    vendored third-party sources + pinned commits + licenses
  dbgshim/
    CMakeLists.txt              wrapper that builds libdbgshim.so from the vendored source
    diagnostics-src/            pinned dotnet/diagnostics subset (dbgshim source)
    build-dbgshim-android.sh    -> build-arm64/dbgshim/libdbgshim.so
    prebuilt/libdbgshim.so      prebuilt arm64 binary (ready to use)
  netcoredbg/
    coreclr-deps/               pinned CoreCLR header/IDL subset (coreclr/ + native/)
    build-netcoredbg-android.sh builds netcoredbg from THIS repo against coreclr-deps
    prebuilt/netcoredbg         prebuilt arm64 binary (ready to use)
  harness/
    trace.c                     LD_PRELOAD helper (see "Why the helper")
    build-harness.sh            -> libtrace.so
    prebuilt/libtrace.so        prebuilt arm64 binary (ready to use)
  scripts/
    run-attach.sh               Part 2 in one command: place, attach, report the verdict
```

The three `prebuilt/` binaries are the exact ones we ran. You can use them as-is,
or rebuild any of them with the matching `build-*.sh` (each was verified to build
from the vendored source alone).

---

## Prerequisites (install on the machine; NOT vendored)

Exact versions we used are given so a second machine can match them; newer point
releases will usually work, but the notes below call out where a version matters.

### Hardware / device
- A **physical arm64 Android phone**, USB-connected, USB debugging (Developer
  Options) on. We used a **Pixel 4 XL, Android 13 (API 33)**. `adb devices` must
  list it. The device serial is passed to every script with `-s <serial>`.

### For Part 2 (building/running the debugger pieces)
- **Android platform-tools** (`adb`) on PATH.
- **Android NDK 29.0.14206865** at `~/Android/Sdk/ndk/29.0.14206865`, or set
  `ANDROID_NDK_ROOT`. Clang 21; deliberately the stable NDK, not an rc. Only the
  debugger pieces need the NDK — the app (Part 1) does not.
- **cmake 3.31.x** — **NOT cmake 4.x** (this source tree sets
  `cmake_minimum_required` below 4 and 4.x refuses it).
- A **`dotnet` on PATH for the netcoredbg build only** — its build runs a tiny
  code-gen tool (`generrmsg`) with `dotnet build`. The **system .NET 10 SDK
  (10.0.400) is fine**; the .NET 11 preview is **not** needed to build the
  debugger. (Do not confuse this with Part 1, which does need .NET 11.)

### For Part 1 (building the sample app) — the .NET 11 SDK

The sample app targets `net11.0-android37.0`, which the shipping .NET 10 workload
cannot build (it tops out at `net10.0-android36.1`). You need the **.NET 11
preview SDK plus its `android` workload**, installed **isolated** so it does not
become the default SDK for everything else on the machine.

Exact versions we used:

| Component            | Version                                   |
|---------------------|--------------------------------------------|
| .NET SDK            | `11.0.100-preview.7.26381.103`             |
| workload set        | `11.0.100-preview.7.26410.2`               |
| `android` workload  | `37.0.0-preview.7.2131`                    |

Install it (this is the whole setup — no apt packages, no PATH changes):

```bash
# 1) SDK into an isolated dir (NEVER /usr/share/dotnet, NEVER on PATH)
curl -sSL https://dot.net/v1/dotnet-install.sh | bash /dev/stdin \
    --channel 11.0 --quality preview --install-dir ~/dotnet11

# 2) the Android workload, into that same isolated SDK
DOTNET_ROOT=$HOME/dotnet11 ~/dotnet11/dotnet workload install android
```

**Isolation rules (do not skip — this is the safety mechanism):**
- Install to `~/dotnet11`, not `/usr/share/dotnet` (that tree is dpkg-owned).
- **Never put `~/dotnet11` on `PATH`.** Outside Visual Studio the SDK resolver
  considers prerelease versions, so a preview on PATH silently becomes the
  default SDK for every repo that doesn't pin one.
- Always invoke it by absolute path with `DOTNET_ROOT` set:
  `DOTNET_ROOT=$HOME/dotnet11 ~/dotnet11/dotnet <args>`.
- Complete uninstall is `rm -rf ~/dotnet11` — nothing else to unwind.

Verify the isolation held (safe, read-only):

```bash
~/dotnet11/dotnet --list-sdks   # expect 11.0.x under /home/jeremy/dotnet11/sdk
dotnet --list-sdks              # expect ONLY your system SDK (e.g. 10.0.400)
```

If the second command lists an `11.x`, the isolation leaked — fix that first.

### Also needed for the Part 1 app build (standard .NET Android toolchain)
- **Android SDK** at `~/Android/Sdk` (auto-detected; no `ANDROID_HOME` needed),
  with **platform `android-37.0`** and **build-tools `37.0.0`** installed. We had
  platforms `android-36`…`android-37.2` and build-tools `36.x`/`37.0.0` present.
- A **JDK** for the Android build (we used the system OpenJDK 25; OpenJDK 17+
  works). It is auto-detected from the system.

---

## Part 1 — build + deploy + run the Debug app

The app is a separate project, **not** copied into this folder. Get it from:

> **https://github.com/ellisnet/CodeBrix.Android/tree/main/samples/SimpleDebugApp_API_37**

```bash
git clone https://github.com/ellisnet/CodeBrix.Android
cd CodeBrix.Android/samples/SimpleDebugApp_API_37
```

It must be a **Debug** build (`-c Debug`) so the runtime is debuggable and
symbols/assemblies are deployed as files. Build with the **isolated .NET 11 SDK**
and install straight to the device in one step (`-t:Install`):

```bash
DOTNET_ROOT=$HOME/dotnet11 $HOME/dotnet11/dotnet \
  build -c Debug -t:Install -p:AdbTarget="-s <serial>" ./SimpleDebugApp.csproj
adb -s <serial> shell am start -n com.codebrix.simpledebugapp/.MainActivity
```

Notes:
- The project pins `net11.0-android37.0` and `SupportedOSPlatformVersion=33`, so
  the API 33 (Android 13) floor is intact. Its Debug config sets
  `EmbedAssembliesIntoApk=false` and portable PDBs — that is what makes the app
  debuggable and puts loose assemblies + the PDB on the device.
- `-t:Install` uses fast deployment: assemblies land under the app's data dir,
  not inside the APK.

Verify it really is a Debug build **on the device** (all three should hold):

- `adb -s <serial> shell dumpsys package com.codebrix.simpledebugapp | grep flags`
  shows `DEBUGGABLE`.
- `adb -s <serial> shell run-as com.codebrix.simpledebugapp ls files/.__override__/arm64-v8a/`
  contains loose `.dll` files **and** `SimpleDebugApp.pdb` (Debug deploys
  assemblies as files, not embedded in the APK).
- The running process maps `libcoreclr.so` (CoreCLR), not `libmonosgen` (Mono):
  `adb -s <serial> shell run-as com.codebrix.simpledebugapp cat /proc/$(adb -s <serial> shell pidof com.codebrix.simpledebugapp)/maps | grep -o 'lib\(coreclr\|monosgen\)[^ ]*'`.

---

## Part 2 — attach on the phone and prove dbgshim works

One command (uses the prebuilt binaries):

```bash
android/scripts/run-attach.sh -s <serial>
```

It places `netcoredbg` + `libdbgshim.so` + `libtrace.so` into the app's own
directory (via `run-as`, so they run as the app uid), restarts the app fresh,
attaches, and prints a verdict. Success looks like:

```
SessionAccept (type 1) received : YES
GetDCB (type 8) exchange        : YES
MT_WriteMemory (type 7) rounds  : 18
>>> dbgshim DID ITS JOB: it loaded, resolved mscordbi, and formed the live debug session.
```

That is the whole Part-2 claim: netcoredbg loaded `libdbgshim.so`, dbgshim found
and loaded the app's `mscordbi`, built the ICorDebug interface, and
`DebugActiveProcess` drove the `clr-debug-pipe` handshake to a formed session.

### What the pieces do at attach time

1. **netcoredbg** (on the phone, launched as the app uid via `run-as`) loads
2. **libdbgshim.so** (the piece built here), which locates and loads the app's
3. **libmscordbi.so** (ships in the APK) — the ICorDebug engine that actually
   attaches over the runtime's `clr-debug-pipe` FIFOs.

### Why the helper (`libtrace.so`)

Two Android facts make a raw attach fail, so the helper is `LD_PRELOAD`ed:

- **`TRACE_MASK_KILL0=1`** — Android SELinux denies `kill(pid,0)` between the
  `run-as` debugger domain and the app domain (a `signull` denial), even at the
  same uid. The PAL uses that call to check the target is alive, so it aborts
  early. The helper answers it from `/proc/<pid>` instead. This is a proof-time
  workaround; the real fix is a PAL change to tolerate `EPERM` there.
- It also writes a syscall trace (`TRACE_OUT`) so the script can read the pipe
  handshake and print the verdict.

Also required, and handled by the script: **attach to a freshly launched app
process.** A process that had an earlier interrupted debug session makes the
runtime reply `SessionResync` instead of `SessionAccept`, and the attach times
out.

---

## Known wall (a LATER part, not dbgshim)

After dbgshim forms the session and the first debug event flows, the run hangs.
The cause is **not** dbgshim: netcoredbg hosts its own in-process CoreCLR to run
its managed symbol reader (`ManagedPart.dll`), and that in-process runtime
**deadlocks** on Android during managed-delegate creation, inside the ICorDebug
callback, before the attach is reported complete. A 60-second timeout confirmed
it is a deadlock, not slowness. Solving it (e.g. initialize that runtime off the
callback thread, or run the symbol reader out of process) is the next part of
the work. Full evidence trail:
`~/ClaudeHome/SUMMARY_android_debug_story_2026-09-06.txt` (top block + ADDENDUM 3).

---

## Rebuilding from source (each verified self-contained)

```bash
android/dbgshim/build-dbgshim-android.sh        # -> libdbgshim.so
android/netcoredbg/build-netcoredbg-android.sh  # -> netcoredbg (needs system dotnet)
android/harness/build-harness.sh                # -> libtrace.so
```

Pinned upstream commits and licenses are in `NOTICE.txt`.

---
---

# Part 3 — The full research record

*"How .NET 11 CoreCLR debugging works on Android, and where it gets stuck."*

Everything below is the accumulated research behind Parts 1 and 2 and the Part 3
investigation. It is deliberately exhaustive. If you only want to reproduce the
working pieces, the runbook above is enough; read on to understand *why* each
piece exists, what the wall is, and the route through it.

All findings here were verified on a real device (Pixel 4 XL, Android 13 / API
33) against `com.codebrix.simpledebugapp` (`net11.0-android37.0`), not inferred.

## Contents
1. The cast — every piece and where it runs
2. How CoreCLR debugging works (the model)
3. The attach pipeline, exactly as proven on hardware
4. The wire protocol we decoded (`clr-debug-pipe`)
5. The five Android blockers
6. The wall, in depth — the in-process-CoreCLR hosting deadlock
7. ManagedPart internals + dependency archaeology
8. Licensing findings (Roslyn)
9. The architectural pivot — ClrDebug and a managed debugger
10. The verification harness (`libtrace.so`)
11. Open questions and next steps
12. Sources

---

## 1. The cast — every piece and where it runs

Debugging a managed Android app pulls in a surprising number of moving parts.
Here is every one, what it is, and — critically — whether it runs ON THE PHONE
or on the HOST laptop.

| Piece | What it is | Runs on | Origin |
|---|---|---|---|
| The app (`SimpleDebugApp`) | the debuggee; a `net11.0-android37.0` CoreCLR app | phone | CodeBrix.Android |
| `libcoreclr.so` | the app's .NET 11 runtime | phone | ships in the APK |
| `libmscordbi.so` | ICorDebug engine (the "right side" / RS) | phone | ships in the APK |
| `libmscordaccore.so` | the DAC — reads runtime data structures out of the debuggee | phone | ships in the APK |
| `netcoredbg` | the debugger executable (C++), an ICorDebug/dbgshim client | phone | this repo (built for android-arm64) |
| `libdbgshim.so` | bootstrap shim: finds the runtime, loads mscordbi, hands back ICorDebug | phone | vendored + built here |
| `ManagedPart.dll` + Roslyn | netcoredbg's MANAGED brain: PDB symbol reading + C# expression eval | phone | this repo (managed build) |
| `libtrace.so` | our LD_PRELOAD proof harness (kill-mask + trace) | phone | `harness/` (proof only) |
| The IDE / DAP client | CodeBrix.Develop, connects over an adb-forwarded port | **host** | CodeBrix.Develop |

The important, non-obvious fact: **the debugger runs on the phone, not the
laptop.** ICorDebug "does not support being called remotely, either cross-machine
or cross-process," so the ICorDebug client (mscordbi, driven by netcoredbg) must
live in the same place as the debuggee. The laptop only ever talks to netcoredbg
over a forwarded TCP port via the Debug Adapter Protocol.

## 2. How CoreCLR debugging works (the model)

The chain, from "a process id" to "a stopped, inspectable managed program":

1. **dbgshim bootstraps.** Given the debuggee pid, dbgshim's `EnumerateCLRs`
   finds `libcoreclr.so` inside it, `CreateVersionStringFromModule` builds a
   runtime-version string, and `CreateDebuggingInterfaceFromVersionEx` loads the
   matching `libmscordbi.so` and returns an `ICorDebug` object. dbgshim exports
   exactly 18 functions; netcoredbg dlsym's a subset. dbgshim is the ONLY piece
   we had to port/build ourselves — mscordbi and the DAC ship in the APK.

2. **mscordbi is the ICorDebug engine ("right side", RS).** It is the code that
   actually attaches (`ICorDebug::DebugActiveProcess`) and services every
   inspection request (threads, stacks, modules, values, breakpoints, stepping).

3. **The RS talks to the runtime's "left side" (LS) over a transport.** On
   Windows the RS/LS use shared memory plus named events. On Unix there is no
   such model, so CoreCLR uses `DbgTransportSession` over a pair of named FIFOs
   the runtime creates at `/data/data/<pkg>/cache/clr-debug-pipe-<pid>-<disamb>-{in,out}`.
   Everything — session setup, memory read/write, debug events — is framed
   messages over those two pipes. (See section 4 for the wire format we decoded.)

4. **The DAC (`libmscordaccore.so`) reads debuggee data structures.** ICorDebug
   uses it to walk the runtime's internal state (module lists, method descriptors,
   GC heap) out of the target's memory.

5. **netcoredbg's ManagedPart provides the "managed brain."** ICorDebug gives you
   IL offsets and metadata tokens; turning those into `file:line`, local-variable
   names, and evaluated expressions needs a portable-PDB reader and a C#
   evaluator. netcoredbg keeps that logic in a managed assembly, `ManagedPart.dll`,
   and — because netcoredbg is a C++ program that cannot itself run managed code —
   it **hosts a second CoreCLR instance inside its own process** to run it. This
   last step is the one that breaks on Android (section 6).

## 3. The attach pipeline, exactly as proven on hardware

Traced call-by-call in `netcoredbg` (`src/debugger/manageddebugger.cpp`,
`src/managed/interop.cpp`) and confirmed against the on-device syscall trace:

```
ManagedDebugger::AttachToProcess(pid)
  -> GetCLRPath(pid)                     find the app's libcoreclr.so           [OK]
  -> CreateVersionStringFromModule(...)  dbgshim builds the version string      [OK]
  -> CreateDebuggingInterfaceFromVersionEx(CorDebugVersion_4_0, ...)
        dbgshim -> loads libmscordbi.so -> returns ICorDebug                    [OK]
  -> Startup(pCordb):
        ICorDebug::Initialize()                                                 [OK]
        SetManagedHandler(ManagedCallback)                                      [OK]
        ICorDebug::DebugActiveProcess(pid, FALSE)
              mscordbi opens the clr-debug-pipe FIFOs and runs the transport
              handshake: SessionRequest -> SessionAccept, GetDCB, WriteMemory   [OK]
  -> wait up to 5s for ProcessAttachedState::Attached ...
        Attached is set by NotifyProcessCreated(), called at the END of
        ManagedCallback::CreateProcess(), which FIRST calls:
            Interop::Init(clrPath)
              coreclr_initialize(debuggee libcoreclr.so, TPA, APP_PATHS)        [OK]
              coreclr_create_delegate("ManagedPart", "SymbolReader", ...)       [HANGS]
  -> 5s elapses with no Attached -> AttachToProcess returns E_FAIL             [FAIL]
```

Everything up to and including `DebugActiveProcess` works on Android. The failure
is the very last managed-bootstrap step, inside the ICorDebug callback.

## 4. The wire protocol we decoded (`clr-debug-pipe`)

The RS/LS transport (`DbgTransportSession`, defined in the runtime at
`debug/inc/dbgtransportsession.h`) frames every exchange with a 48-byte header:

```
struct MessageHeader {          // 48 bytes total, little-endian
  MessageType m_eType;          // off 0   4  message type (enum below)
  DWORD m_cbDataBlock;          // off 4   4  size of the data block that follows
  DWORD m_dwId;                 // off 8   4  sender's message id
  DWORD m_dwReplyId;            // off 12  4  id this is a reply to
  DWORD m_dwLastSeenId;         // off 16  4  highest id the sender has seen
  DWORD m_dwReserved;           // off 20  4  zero
  union {                       // off 24 16  type-specific
     { DWORD major, minor; }               VersionInfo;    // Session{Request,Accept}
     { RejectReason r; DWORD major,minor;} SessionReject;
     { PBYTE addr; DWORD cb; HRESULT hr; } MemoryAccess;   // Read/WriteMemory
     { IPCEventType t; DWORD evt; }        Event;
  } TypeSpecificData;
  BYTE m_sMustBeZero[8];        // off 40  8
};
// protocol version: kCurrentMajorVersion = 2, kCurrentMinorVersion = 0
```

Message types (enum order == on-wire value):

```
0 MT_SessionRequest   RS->LS  request a session (+ 16-byte GUID data block)
1 MT_SessionAccept    LS->RS  session accepted
2 MT_SessionReject    LS->RS  rejected (+ reason, versions)
3 MT_SessionResync    both    resync a broken session (carries last-seen id)
4 MT_SessionClose     RS->LS
5 MT_Event            both    a debug event is in the data block
6 MT_ReadMemory       both
7 MT_WriteMemory      both
8 MT_GetDCB           both    read the debuggee's Debugger Control Block
9 MT_SetDCB           both
```

The exact bytes we captured on a healthy FRESH-process attach (from the trace
harness; `[NN` = first bytes of the 48-byte header):

```
write pipe: [00 00 00 00 10 00 00 00 ...]   MT_SessionRequest, data block 0x10=16
write pipe: [<16-byte session GUID>]        the SessionRequestData
read  pipe: [01 00 00 00 00 00 00 00 ...]   MT_SessionAccept                <-- session formed
read  pipe: [08 00 00 00 68 00 00 00 ...]   MT_GetDCB, data block 0x68=104
write pipe: [08 00 00 00 ...]  + read 104   the DCB comes back
... then 18x MT_WriteMemory (type 07) round-trips, ids climbing, all acked
```

The **failure signature** on a STALE process (one that had an earlier
interrupted debug session) is the runtime replying with `MT_SessionResync`
(type 3) carrying a non-zero `m_dwLastSeenId` instead of `MT_SessionAccept`.
The RS treats that as critical, the session never opens, and
`WaitForSessionToOpen(10000)` returns `CORDBG_E_TIMEOUT` (0x80131c08). This is
why Part 2 MUST attach to a freshly launched process.

## 5. The five Android blockers

Each was isolated on hardware. Four are worked around by the proof harness; the
fifth is the wall.

**Blocker 1 — SELinux denies the liveness check `kill(pid, 0)`.**
The PAL checks the debuggee is alive with `kill(pid, 0)`. Even though netcoredbg
(launched via `run-as`) and the app share the same uid, the kernel denies it:
`avc: denied { signull } scontext=runas_app tcontext=untrusted_app tclass=process`.
The `runas_app` SELinux domain may not signal the `untrusted_app` domain. The
PAL reads the `EPERM` as "process gone" and aborts the attach early.
- Harness workaround: interpose `kill()`; for `sig==0` with `EPERM`/`EACCES`,
  answer from `/proc/<pid>` existence.
- Real fix: PAL change to tolerate `EPERM` on the signal-0 probe on Android, or
  run the debugger in a domain permitted to signal the app.

**Blocker 2 — stale transport session state.**
See section 4. Attach to a FRESH process; the runtime otherwise replies
`MT_SessionResync` and the attach times out. Not a code fix — an orchestration
rule.

**Blocker 3 — `sem_open` returns ENOSYS.**
Android bionic declares `sem_open` but named POSIX semaphores don't work
(`Function not implemented`). The PAL uses them for the runtime-startup
notification (`/clr%s%08x%016llx`). BENIGN on the attach path: it is an
open-existing that already `goto exit`s on failure; an in-process emulation in
the harness changed nothing. Flagged because any path needing a working
cross-process named event would hit it.

**Blocker 4 — the managed assemblies are not where the debugger looks.**
After the session forms, the first debug event (`MT_Event`, type 5) fires and
mscordbi/DAC tries to open the module file (e.g. `System.Private.CoreLib.dll`)
NEXT TO `libcoreclr.so` — i.e. in the read-only APK `lib/arm64` dir, which holds
only `.so` files. On Android the managed assemblies live elsewhere and ARE
readable by the (app-uid) debugger:
- `/data/local/tmp/fastdeploy2/<pkg>/0/arm64-v8a/*.dll` (where the runtime loaded them)
- `/data/data/<pkg>/files/.__override__/arm64-v8a/*.dll` (a full set INCLUDING the app PDB)
- Harness workaround: interpose `open()`/`openat()`; when a `*.dll`/`*.pdb` open
  fails, retry from the `.__override__` dir. `opendir()` on the runtime dir is
  also redirected so the hosted runtime's assembly (TPA) scan finds the framework.
- Real fix: teach the debugger's module/symbol path resolution the Android layout.

**Blocker 5 — THE WALL: hosting a second in-process CoreCLR deadlocks.**
See section 6.

Verified positive corollary: a `.NET DebugPipe` thread in the app sits in
`fifo_open`, i.e. the runtime's ICorDebug transport IS listening. CoreCLR on
Android is debuggable at the transport level. (An earlier note that "nothing
listens" was about the Mono soft-debugger TCP port — a different, Mono-only
mechanism — not this FIFO transport.)

## 6. The wall, in depth — the in-process-CoreCLR hosting deadlock

**What happens.** `ManagedCallback::CreateProcess()` (the ICorDebug callback that
fires when the runtime is ready) calls `Interop::Init()` BEFORE
`NotifyProcessCreated()`. `Interop::Init` (`src/managed/interop.cpp`) hosts a
second CoreCLR inside the netcoredbg process:
`coreclr_initialize` on the debuggee's `libcoreclr.so`, then
`coreclr_create_delegate("ManagedPart", ...)` to bind ManagedPart's entry points.
On Android, `coreclr_initialize` SUCCEEDS (CoreLib loads via the blocker-4
redirect), but `coreclr_create_delegate("ManagedPart", ...)` **HANGS**. We
raised `startupWaitTimeout` from 5s to 60s and it hung the full 60 seconds with
only CoreLib + `ManagedPart.dll` opened and no further progress — so it is a
DEADLOCK, not slowness.

**Why (strong hypothesis).** dotnet/runtime issue #100953 documents a
stop-the-world GC deadlock when .NET is embedded in a native app: a native
thread calls `*_create_delegate`, which registers that thread with the runtime's
thread list; the thread returns to native code and never re-enters managed; a
later GC's stop-the-world phase then waits forever for that thread to reach a
safepoint. That is exactly our shape — we call `create_delegate` from the
ICorDebug callback thread, which then sits in native callback code while the
debuggee is suspended. Caveats: #100953 is tagged **Mono**, not CoreCLR, and has
no fix (parked in "Future"); but it is the same class of embedding/GC-suspension
hazard, and CoreCLR-on-Android is officially **experimental** with active bugs
(e.g. dotnet/android #10588 ANR, #10472 crash). So the wall is best understood as
an architectural property of "a C++ process hosting a second CoreCLR and calling
`create_delegate` from a thread that then blocks," not as a missing feature or a
stale dependency.

**What this rules out.** Bumping ManagedPart's dependencies (section 7) does NOT
fix the deadlock — the hang is before any ManagedPart code runs meaningfully, in
the runtime's own thread/GC machinery.

## 7. ManagedPart internals + dependency archaeology

**ManagedPart** (`src/managed/`, four files) is netcoredbg's managed helper:
- `SymbolReader.cs` — reads portable PDBs via `System.Reflection.Metadata`
  (`MetadataReader`): sequence points (IL offset <-> `file:line:col`), local
  variable names and scopes. This is the heaviest user (58 `SequencePoint`,
  29 `MetadataReader` references).
- `Evaluation.cs` / `StackMachine.cs` — C# expression evaluation using Roslyn
  scripting (`Microsoft.CodeAnalysis.CSharp`).
- `Utils.cs` — COM string / memory helpers.

It targets **`netstandard2.0`** on purpose: netcoredbg hosts it in whatever
runtime version it happens to be debugging (net6 through net11), and
netstandard2.0 loads on all of them. That is the reason the dependency set is so
conservative — and so old.

Dependencies as pinned (`ManagedPart.csproj`), and the assessment:

| Package | Pinned | Released | Assessment |
|---|---|---|---|
| `System.IO.FileSystem` | 4.3.0 | 2016 | Redundant: implicit in netstandard2.0, in-box on .NET 11. Remove. |
| `System.Runtime.InteropServices` | 4.3.0 | 2016 | Same. Remove. |
| `Microsoft.CSharp` | [4.4,) | legacy | In-box on modern .NET; keep only if `dynamic` needs it. Low priority. |
| `System.Reflection.Metadata` | 1.4.2 | 2016 | The actual PDB reader, pinned 10 years old. Bump. Latest stable 10.0.11; an 11.0.0-preview.7 exists that matches the SDK. Modern versions still ship a netstandard2.0 target, so no retarget needed. |
| `Microsoft.CodeAnalysis.CSharp.Scripting` | [2.3,) → resolves to 2.3.0 | 2017 | Bump to 4.14 or 5.9 (both MIT). But modern Roslyn scripting likely dropped netstandard2.0, so this needs a TFM bump + minor code changes + testing. |

Roslyn version facts (from the NuGet flat-container index): the scripting package
has a `5.9.0` latest stable and a `4.14.0` prior line; `System.Reflection.Metadata`
latest stable is `10.0.11` with an `11.0.0-preview.7.26381.103` matching our SDK.

Design tension to decide: keeping `netstandard2.0` preserves netcoredbg's
host-any-runtime behavior but forces old-compatible dependencies; retargeting
ManagedPart to net-current suits the Android/net11 goal and makes
`System.Reflection.Metadata`, `System.Collections.Immutable`, and `Microsoft.CSharp`
all in-box, but would stop it hosting in older runtimes. In the pivot architecture
(section 9) this tension disappears, because the managed helper simply targets the
runtime it runs in.

## 8. Licensing findings (Roslyn)

Roslyn is inherited from upstream Samsung netcoredbg (the `ManagedPart.csproj`
reference and `StackMachine.cs`/`Evaluation.cs` predate the CodeBrix fork), not
added here. The shipped version is **2.3.0** (confirmed in `ManagedPart.deps.json`).

The 2.3.0 NuGet packages declare their OWN license as the **Microsoft .NET
Library License**, not Apache-2.0:
- nuspec `<licenseUrl>http://go.microsoft.com/fwlink/?LinkId=529443</licenseUrl>`
  which 302-redirects to `https://www.microsoft.com/net/dotnet_library_license.htm`,
  plus `<requireLicenseAcceptance>true</requireLicenseAcceptance>` (a hallmark of
  that EULA; open-source packages set it false and carry a `<license>` expression).
- The distinction that trips people up: the Roslyn SOURCE repo
  (github.com/dotnet/roslyn) is Apache-2.0, but the redistributed 2.3.0 BINARY
  packages are under the .NET Library License — the package license governs the
  DLLs. Modern Roslyn (3.x/4.x/5.x) relicensed to MIT: the 4.0.1 and 4.8.0
  nuspecs declare `<license type="expression">MIT</license>`.

The repo's root `THIRD-PARTY-NOTICES.txt` (item 3) has been corrected to name the
.NET Library License; `MAINTAINER-README.txt` records the full provenance. None of
this concerns the `android/` folder, which carries no Roslyn. Bumping to a modern
Roslyn would, as a bonus, make the whole thing cleanly MIT.

## 9. The architectural pivot — ClrDebug and a managed debugger

The deadlock (section 6) and a study of **ClrDebug** (github.com/lordmilko/ClrDebug,
MIT) converge on the same conclusion: **stop hosting a second CoreCLR.**

**Why we host one at all:** only because netcoredbg is C++ and C++ cannot run
managed code, so ManagedPart must be brought to life via
`coreclr_initialize`/`coreclr_create_delegate` — and THAT bootstrap is what
deadlocks. If the debug helper runs in a runtime that is ALREADY managed, that
step does not exist, and this specific deadlock is structurally impossible.

**What ClrDebug is:** a pure-managed (no native code), MIT, auto-generated binding
layer over the entire CLR debugging surface — ICorDebug, dbgshim, IMetaDataImport,
the DAC (ISOSDacInterface), CorSym, plus Windows-only DbgEng/DIA. On its `net8.0`
build path every COM interface is `[GeneratedComInterface]` and callbacks are
`[GeneratedComClass]` — source-generated `ComWrappers`, which is what makes
driving ICorDebug from managed code portable to Linux/Android CoreCLR (the
`netstandard2.0` fallback is Windows-only classic COM).

**The shape it points to:** a managed .NET app, running on the phone as a normal
`net11.0-android-arm64` process, that:
- `NativeLibrary.Load("libdbgshim.so")` and drives the proven attach flow
  (`EnumerateCLRs` -> `CreateVersionStringFromModule` ->
  `CreateDebuggingInterfaceFromVersionEx` -> `Initialize` ->
  `SetManagedHandler(managed callback)` -> `DebugActiveProcess`) — see ClrDebug's
  `Samples/NetCore/*`, which is a complete working in-process managed attach;
- reads portable PDBs itself with `System.Reflection.Metadata.MetadataReader`
  (ClrDebug's own symbol path is the Windows-only ISym/diasymreader COM route and
  is NOT usable on Android — but this is exactly what ManagedPart already does);
- keeps Roslyn scripting for expression eval (ClrDebug has no evaluator, only
  `CorDebugEval`, the runtime's func-eval primitive).

All of that is ordinary managed work IN the host runtime, so nothing re-introduces
the `create_delegate` bootstrap. Two ways to adopt it: rewrite netcoredbg's engine
as a managed process, or (smaller) move only ManagedPart's *functionality* into a
managed process that co-hosts ICorDebug via ClrDebug, so the C++ side never calls
`coreclr_initialize`.

**The one genuine unknown to de-risk first:** whether source-generated
`ComWrappers` ICorDebug callbacks actually work on **android-arm64 CoreCLR** —
ClrDebug has no Android/arm64 validation. The cheap spike: a managed app that
attaches, `SetManagedHandler`, and catches a single `LoadModule` callback firing.
That one result decides whether the whole pivot is viable, and it is far cheaper
than either porting more C++ or bumping dependencies.

## 10. The verification harness (`libtrace.so`)

`harness/trace.c` -> `libtrace.so`, `LD_PRELOAD`ed into netcoredbg. It is PROOF
tooling, not a shipped component. Env switches:

```
TRACE_OUT=<file>       write the syscall trace here
TRACE_MASK_KILL0=1     answer kill(pid,0) from /proc            (blocker 1)
TRACE_EMU_SEM=1        in-process named-semaphore emulation     (blocker 3; benign)
TRACE_REDIR_DIR=<dir>  redirect failing *.dll/*.pdb opens here  (blocker 4)
TRACE_TPA_DIR + TRACE_CLR_DIR   redirect opendir(clrDir) so the hosted
                                runtime's TPA scan finds the framework (blocker 4/5)
```

It also dumps `clr-debug-pipe` FIFO traffic (decoded in section 4) and the
`process_vm_readv`/`ptrace`/`sem_open`/`open` calls. `scripts/run-attach.sh` wires
it all together and prints the Part-2 verdict. Only `TRACE_MASK_KILL0` is needed
to reach "dbgshim did its job"; the redirect switches are for pushing further into
the ManagedPart hosting attempt.

## 11. Open questions and next steps

1. **The ComWrappers spike (highest value).** Prove or disprove that
   source-generated `ComWrappers` ICorDebug callbacks fire on android-arm64
   CoreCLR. This gates the entire section-9 pivot.
2. **Can two CoreCLR instances coexist in one process on Android at all?** A bare
   `coreclr_initialize` from a second module in one process, no debugger involved,
   would isolate whether the deadlock is "two runtimes" or "create_delegate from a
   suspended-callback thread." Informs whether patching netcoredbg's threading
   (initialize Interop off the callback thread) is even worth trying as a
   stop-gap before the pivot.
3. **Productionize the four workarounds.** kill(pid,0) EPERM tolerance and the
   module/TPA path resolution need to become real PAL / debugger-side code, not an
   LD_PRELOAD shim.
4. **Dependency modernization** (section 7): low-risk part (drop facade packages,
   bump `System.Reflection.Metadata`) can happen anytime; the Roslyn bump rides
   along with the pivot.
5. Only once the helper stands up does breakpoint verification (Part 3 step 3)
   become testable; the LaunchCapability net11 arm in CodeBrix.Develop stays
   refused until then.

## 12. Sources

### Key external links (the ones the research leaned on)

- **The embedding stop-the-world GC deadlock (our wall's likely mechanism)** —
  dotnet/runtime issue #100953:
  https://github.com/dotnet/runtime/issues/100953
- **CoreCLR-on-Android experimental support** — dotnet/runtime PR #112034:
  https://github.com/dotnet/runtime/pull/112034
  (and its tracking issue #111955: https://github.com/dotnet/runtime/issues/111955)
- **CoreCLR ANR on Android (evidence CoreCLR-on-Android is still rough)** —
  dotnet/android issue #10588: https://github.com/dotnet/android/issues/10588
  (related crash, #10472: https://github.com/dotnet/android/issues/10472)
- **ClrDebug** — managed ICorDebug/dbgshim/metadata/DAC interop (MIT), the basis
  for the section-9 pivot: https://github.com/lordmilko/ClrDebug
  (working attach recipe in `Samples/NetCore/*`; dbgshim wrappers in
  `Extensions/Extensions.DbgShim.cs`)
- **NuGet flat-container index — Microsoft.CodeAnalysis.CSharp.Scripting** (Roslyn
  scripting versions; latest stable 5.9.0, prior line 4.14.0):
  https://api.nuget.org/v3-flatcontainer/microsoft.codeanalysis.csharp.scripting/index.json
- **NuGet flat-container index — System.Reflection.Metadata** (PDB reader
  versions; latest stable 10.0.11, plus 11.0.0-preview.7 matching the SDK):
  https://api.nuget.org/v3-flatcontainer/system.reflection.metadata/index.json

### Supporting references

- ICorDebug cannot be remoted; the debugger runs in-process — Microsoft
  unmanaged-API docs (ICorDebug interface / `DebugActiveProcess`).
- Transport / message format — CoreCLR `debug/inc/dbgtransportsession.h`
  (vendored here under `netcoredbg/coreclr-deps/`).
- Roslyn 2.3.0 license — the packages' own nuspecs, `<licenseUrl>` fwlink
  `LinkId=529443` which redirects to
  https://www.microsoft.com/net/dotnet_library_license.htm (Microsoft .NET
  Library License), with `<requireLicenseAcceptance>true`.
- The evidence trail that predates this file —
  `~/ClaudeHome/SUMMARY_android_debug_story_2026-09-06.txt`.

---
---

# Roadmap — Parts 4, 5, and beyond

Where this goes after Part 3. The end goal: **in CodeBrix.Develop, open a
solution with a .NET 11 CoreCLR Android app, hit Debug once, and get full
line-by-line debugging on the phone — breakpoints set in the editor bind and get
hit, call stack and locals populate, stepping and watches work.**

The encouraging part: once the on-device debugger can read symbols and bind
breakpoints (Part 3), most of what remains is **wiring existing pieces
together**, not inventing new ones. CodeBrix.Develop already has a DAP client,
breakpoint store, call-stack pad, gutter breakpoints, F5/F9/F10/F11, the paused
hover popover, and the Android device plumbing (adb bridge, device monitor,
device selection). So Parts 4-5 are mostly integration; Parts 6+ are hardening
and breadth.

Two framing notes:
- **Architecture-agnostic.** Part 3 settles the on-device debugger's *internals*
  (either C++ netcoredbg + ManagedPart with the hosting deadlock solved, or the
  managed ClrDebug-based helper from section 9's pivot). Parts 4+ treat it as a
  black box that "exposes a DAP server on the phone," so this roadmap holds
  either way.
- **Workarounds ride along.** Parts 4-5 inherit the four Android workarounds from
  Part 2/3. They can stay the `LD_PRELOAD` stopgap until Part 6 makes them real,
  so they do not block progress.

## Part 4 — Remote debugging over the wire (device <-> off-device DAP, no IDE yet)

**Definition of done:** From the laptop, using a *plain* DAP client (a test
harness or stock VS Code), connect to the debugger running on the phone and do a
full session: set a breakpoint before the code runs, see it bind and get hit,
view the call stack with `file:line`, inspect locals, add a watch, and step
(in/over/out).

**The work:**
- Launch the on-device debugger in server mode
  (`netcoredbg --server=<port> --interpreter=vscode`) attached to the fresh app
  process.
- `adb forward tcp:<hostPort> tcp:<devicePort>` and connect the DAP client to the
  forwarded port.
- Verify each DAP capability end-to-end over the wire: `setBreakpoints`
  (including deferred / bind-on-module-load), `stackTrace`, `scopes`/`variables`,
  `evaluate` (watch), and the `stepIn/Out/Next` + `continue` loop.

**Reuse / risk:** This is the Tizen model netcoredbg already supports, so server
mode exists. The risk is confirming deferred breakpoints and func-eval (watch)
work over the remote transport on Android, and that the callback/stop model
behaves. This part deliberately excludes the IDE so any problem is a
transport-or-debugger problem, not an IDE-wiring problem.

## Part 5 — CodeBrix.Develop drives it: the one-click Debug pipeline (the goal)

**Definition of done — the stated target:** In CodeBrix.Develop, open a solution
containing a .NET 11 CoreCLR Android app, pick the device, hit Debug once, and
get line-by-line debugging: breakpoints set in the editor bind and get hit, call
stack and locals populate, stepping and watches work.

**The work — a "debug launch pipeline" the IDE runs on F5:**
1. Build the app in Debug for the selected device (SDK selection + build path
   already exist).
2. Install it, then push the debugger payload into the app sandbox via `run-as`
   (the bundle from `android/`: the on-device debugger + `libdbgshim.so` +
   ManagedPart + its deps).
3. Launch the app **fresh** with debugging enabled and capture its pid.
4. Start the on-device debugger in server mode against that pid; `adb forward`
   the port.
5. Connect the IDE's **existing** DAP client to the forwarded port.
6. Flip `LaunchCapability`'s net11-Android arm from "not implemented" to offered
   — the one line the earlier work set up for exactly this moment.

**Reuse / risk:** Most IDE-side pieces exist (DAP client, breakpoint store,
call-stack pad, hover, device selection, per-solution SDK). The genuinely new
code is the launch pipeline sequencing build -> install -> push -> launch-fresh
-> server -> forward -> connect, plus surfacing its progress and errors. Main
risk is lifecycle correctness: device disconnect, app exit, detach/stop, cleanup.

## Part 6 — Productionize: real workarounds, packaging, robustness

**Definition of done:** Reliable enough to hand to another developer — not a demo
held together by an `LD_PRELOAD` shim.

**The work:**
- Replace the four proof-time workarounds with real solutions: a proper answer to
  the SELinux `kill(pid,0)` denial (a PAL/liveness fix or a sanctioned launch
  wrapper, not a preload hack) and Android-aware module/symbol path resolution
  inside the debugger. The fresh-process rule becomes a property of the launch
  pipeline; `sem_open` stays a non-issue.
- Package the debugger payload as a **versioned bundle** the IDE ships and pushes
  (device and IDE stay in lockstep), with a "push only if changed" check.
- Session robustness: timeouts, reconnection, clear error surfacing, on-device
  file cleanup, and handling multiple connected devices.

## Part 7 and beyond — breadth

- **Launch, not just attach** — start the app *under* the debugger so you can
  break in `OnCreate`/startup, not only attach to a running app.
- **The version and RID matrix** — other .NET versions, and arm64 emulators / x64
  devices, not just the one Pixel.
- **Richer breakpoints** — conditional and hit-count breakpoints, exception
  breakpoints (first-chance / uncaught), and "just my code".
- **Nice-to-haves** — Hot Reload, edit-and-continue where feasible, and CI that
  rebuilds and smoke-tests the payload.

## The critical path

**Parts 4 -> 5 reach the end-of-day goal.** Part 4 proves the debugger works
remotely with a throwaway client; Part 5 is CodeBrix.Develop doing it for real on
one button. Part 6 turns "it worked once in a demo" into "a developer can rely on
it"; Part 7+ is scope.
