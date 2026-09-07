# Android debugging bundle (arm64 + x64)

Everything needed to reproduce, on a fresh clone on another machine, the three
results — proved on **both** an arm64 device (Pixel 4 XL) and an **x86_64**
device (a Google-API emulator):

- **Part 1** — build a Debug `.NET 11` Android app, deploy it, run it.
- **Part 2** — place an on-device debugger and show it attaches and forms the
  live debug session ("dbgshim did its job").
- **Part 3** — a **full interactive debug session on the device**: breakpoints
  bind and hit, backtrace with `file:line`, locals and object inspection,
  stepping, and first-chance exception stops.

**On-device .NET 11 CoreCLR debugging works end to end, on both arm64-v8a and
x86_64.** This folder is self-contained: the source for every binary is vendored
and pinned, and each binary is committed prebuilt for **both** ABIs, so a fresh
clone can either run the prebuilt pieces directly or rebuild them with no network
and no moving dependency. The scripts detect the device's ABI and pick the
matching binaries automatically. The two things this folder does **not** include
(by design) are the app being debugged and the .NET 11 SDK — see Prerequisites.

The first half of this document is the runbook for Parts 1, 2 and 3. The second
half is a compact **[Reference](#reference--how-it-works-and-the-android-specifics)**
(how the pieces fit, the Android-specific facts the harness works around, the
device fact sheet) and the **[Roadmap](#roadmap--parts-4-5-and-beyond)** for the
rest of the project.

---

## What's in here

```
android/
  README.md                     this file
  NOTICE.txt                    provenance + licenses of everything in this folder
  dbgshim/
    CMakeLists.txt              wrapper that builds libdbgshim.so from the vendored source
    diagnostics-src/            pinned dotnet/diagnostics subset (dbgshim source)
    build-dbgshim-android.sh    build [<abi>]; refreshes prebuilt/<abi>/libdbgshim.so
    prebuilt/arm64-v8a/libdbgshim.so   prebuilt arm64 binary (ready to use)
    prebuilt/x86_64/libdbgshim.so      prebuilt x64 binary  (ready to use)
  netcoredbg/
    coreclr-deps/               pinned CoreCLR header/IDL subset (coreclr/ + native/)
    build-netcoredbg-android.sh build [<abi>] from THIS repo's src/ against coreclr-deps
    build-managed-helper.sh     builds + refreshes prebuilt/managed/ from THIS repo's src/managed/
    prebuilt/arm64-v8a/netcoredbg      prebuilt arm64 binary (built WITH the CoreLib-name fix)
    prebuilt/x86_64/netcoredbg         prebuilt x64 binary  (built WITH the CoreLib-name fix)
    prebuilt/managed/           the managed helper pushed to the device: ManagedPart.dll +
                                the four Microsoft.CodeAnalysis*.dll (Roslyn) — the symbol
                                reader + C# evaluator that run in netcoredbg's hosted runtime.
                                ARCHITECTURE-INDEPENDENT (netstandard2.0): one copy serves both ABIs
  harness/
    trace.c                     LD_PRELOAD helper (see the Reference)
    build-harness.sh            build [<abi>]; refreshes prebuilt/<abi>/libtrace.so
    prebuilt/arm64-v8a/libtrace.so     prebuilt arm64 binary (ready to use)
    prebuilt/x86_64/libtrace.so        prebuilt x64 binary  (ready to use)
  scripts/
    run-attach.sh               Part 2 in one command: place, attach, report the verdict
    run-debug-session.sh        Part 3 in one command: place debugger + managed helper,
                                mark the debug app, launch fresh, attach, drive a scripted
                                breakpoint/stepping/locals/exception session, print a verdict
```

Both run scripts detect the device's primary ABI (`ro.product.cpu.abi`) and use
the matching `prebuilt/<abi>/` binaries; `<abi>` is `arm64-v8a` or `x86_64`. The
prebuilt binaries are the exact ones we ran; use them as-is, or rebuild any with
the matching `build-*.sh [<abi>]` (default `arm64-v8a`; each rebuild refreshes its
`prebuilt/<abi>/` file in place, and each was verified to build from the vendored
source alone). The managed helper is the same for both ABIs.
The netcoredbg source is not vendored under `android/` — it is this repository's
own `src/`, which the clone already has.

---

## Prerequisites (install on the machine; NOT vendored)

Exact versions we used are given so a second machine can match them; newer point
releases will usually work, but the notes below call out where a version matters.

### Hardware / device
- An **arm64-v8a** or **x86_64** Android device that `adb devices` lists, with
  USB debugging on (a physical phone) or a running emulator. The device serial is
  passed to every script with `-s <serial>`. We verified on two:
  a **Pixel 4 XL, Android 13 (API 33)** (arm64-v8a), and a **Google-API x86_64
  emulator, API 37** (`sdk_gphone64_x86_64`). Use a **Google APIs** system image,
  not a Play image — `run-as` (which the scripts rely on) only works on
  debuggable/Google-API images. The `arm64` and `x86_64` builds are independent,
  so an x86_64 emulator exercises the real x64 path, not arm64-via-translation.

### For Parts 2 and 3 (building/running the debugger pieces)
- **Android platform-tools** (`adb`) on PATH.
- **Android NDK 29.0.14206865** at `~/Android/Sdk/ndk/29.0.14206865`, or set
  `ANDROID_NDK_ROOT`. Clang 21; deliberately the stable NDK, not an rc. Only the
  debugger pieces need the NDK — the app (Part 1) does not.
- **cmake 3.31.x** — **NOT cmake 4.x** (this source tree sets
  `cmake_minimum_required` below 4 and 4.x refuses it).
- A **`dotnet` on PATH** for the netcoredbg build (a tiny code-gen tool,
  `generrmsg`, is built with `dotnet build`) and for the managed helper
  (`build-managed-helper.sh` runs `dotnet publish`). The **system .NET 10 SDK
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
~/dotnet11/dotnet --list-sdks   # expect 11.0.x under /home/<you>/dotnet11/sdk
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
- The **same command works for an x86_64 device/emulator** — `-t:Install`
  detects the target's ABI and deploys the matching assemblies. On x64 the
  runtime and loose assemblies land under the `x86_64` ABI dir instead of
  `arm64-v8a`; the verify commands below adjust accordingly.

Verify it really is a Debug build **on the device** (all three should hold; swap
`arm64-v8a`→`x86_64` and `arm64`→`x86_64` on an x64 device):

- `adb -s <serial> shell dumpsys package com.codebrix.simpledebugapp | grep flags`
  shows `DEBUGGABLE`.
- `adb -s <serial> shell run-as com.codebrix.simpledebugapp ls files/.__override__/arm64-v8a/`
  contains loose `.dll` files **and** `SimpleDebugApp.pdb` (Debug deploys
  assemblies as files, not embedded in the APK).
- The running process maps `libcoreclr.so` (CoreCLR), not `libmonosgen` (Mono):
  `adb -s <serial> shell run-as com.codebrix.simpledebugapp cat /proc/$(adb -s <serial> shell pidof com.codebrix.simpledebugapp)/maps | grep -o 'lib\(coreclr\|monosgen\)[^ ]*'`.

`.NET 10` Android apps run on MonoVM, which this debugger cannot attach to; only
`.NET 11` (CoreCLR) is debuggable here. Keep the app at `net11.0-android37.0`.

---

## Part 2 — attach on the device and prove dbgshim works

One command (detects the device ABI, uses the matching prebuilt binaries):

```bash
android/scripts/run-attach.sh -s <serial>
```

It places `netcoredbg` + `libdbgshim.so` + `libtrace.so` into the app's own
directory (via `run-as`, so they run as the app uid), restarts the app fresh,
attaches, and prints a verdict. Success looks like (the `(x86_64)` tag is the
detected ABI):

```
==================== dbgshim VERDICT (arm64-v8a) ====================
SessionAccept (type 1) received : YES
GetDCB (type 8) exchange        : YES
MT_WriteMemory (type 7) rounds  : 18
>>> dbgshim DID ITS JOB: it loaded, resolved mscordbi, and formed the live debug session.
```

That is the whole Part-2 claim: netcoredbg loaded `libdbgshim.so`, dbgshim found
and loaded the app's `mscordbi`, built the ICorDebug interface, and
`DebugActiveProcess` drove the `clr-debug-pipe` handshake to a formed session.
Part 2 needs only one of the harness switches (`TRACE_MASK_KILL0`, below) and
does not need the managed helper. It must attach to a **freshly launched** app
process (see the Reference for why).

---

## Part 3 — full on-device debugging works

One command reproduces the whole session (detects the ABI; uses the matching
prebuilt binaries + the managed helper):

```bash
android/scripts/run-debug-session.sh -s <serial>
```

It places `netcoredbg` + `libdbgshim.so` + `libtrace.so` **and the managed
helper** (`ManagedPart.dll` + the four Roslyn assemblies) into the app sandbox,
marks the app as the debug app, launches it fresh, attaches, and drives a
scripted breakpoint / stepping / locals / expression / exception session over a
FIFO. Success looks like:

```
==================== Part 3 VERDICT (arm64-v8a) ====================
attach completed (symbols loaded + stopped)      : YES
line breakpoint bound                            : YES
breakpoint hit                                   : YES
backtrace with file:line                         : YES
variable / expression printed                    : YES
stepping (end stepping range)                    : YES
func-eval (print this expanded the object)       : YES
first-chance exception stop                      : YES
```

The identical verdict (all YES) is produced on both the arm64-v8a Pixel and the
x86_64 emulator by this same command. Pass `-P <plan-file>` to drive your own
command plan (the plan format is documented at the top of `run-debug-session.sh`).
The built-in plan taps the sample app's buttons by their resource-id
(`tapid count_button`), computed from their on-screen bounds, so it works
unchanged on any screen size or orientation.

### What works (all confirmed on the device, on both ABIs)

- **attach completes** on a FRESH app process (symbols load, process stops).
- **line breakpoints bind** (`info break` shows `Rslvd=y`) and **hit** — on the
  UI thread, on a thread-pool worker, inside a loop, and in an async continuation
  (state-machine `MoveNext`); re-hit works (`times= 2` on a second tap);
  delete / disable / `info break` / `info threads` all work.
- **backtrace with `file:line`** across app + framework frames (Mono.Android /
  Java.Interop frames show without `file:line`, as expected; app frames show it).
- **locals / fields / arrays / `List<T>` / full object expansion** — `print this`
  expands `MainActivity` with all fields and base-class properties.
- **arithmetic expression eval** — e.g. `count % 2` -> `1` — routed through
  ManagedPart's Roslyn `CalculationDelegate`.
- **stepping** — `step` (into), `next` (over), `finish` (out).
- **first-chance exception catchpoints** — `catch throw *` stops at the throw
  site BEFORE the app's `catch` runs, reason `exception received, name:
  System.InvalidOperationException, ... stage: throw`, with a correct backtrace;
  `continue` then lets the app's own catch run.
- **detach + quit** leave the app running.

### The one bug that was fixed

`print this` (any expression whose expansion triggers a func-eval) used to abort
the whole debugger with `libc++abi: terminating due to uncaught exception of type
HRException*`. Root cause: netcoredbg detected `System.Private.CoreLib` by the
exact string `"System.Private.CoreLib.dll"`, but CoreCLR on Android reports that
module by simple name with no path and no `.dll`, so the cross-thread-dependency
notification class was never set up and the first func-eval passed NULL into
mscordbi, which threw an `HRException*` (by pointer) that nothing caught. Fixed in
this repo's C++ source and rebuilt into `netcoredbg/prebuilt/<abi>/netcoredbg` for both ABIs:

- `IsSameModuleName()` (`src/metadata/modules.{h,cpp}`) compares module names
  treating a missing `.dll` as equal; used in the CoreLib check
  (`src/debugger/managedcallback.cpp`), `IsModuleHaveSameName`, and
  `Modules::GetModuleWithName`.
- `EvalWaiter::SetEnableCustomNotification` (`src/debugger/evalwaiter.cpp`)
  returns `E_FAIL` on a NULL notification class instead of calling mscordbi;
  func-evals still run without it.
- catch-all guards around CLI command dispatch (`src/protocols/cliprotocol.cpp`)
  and the DAP request `future.get()` (`src/protocols/vscodeprotocol.cpp`), so an
  escaping mscordbi throw becomes a failed command, never an abort. (mscordbi
  throws by pointer, so only `catch (...)` catches it.)

### Known limitations (not blockers — the core loop works without them)

- **String member access**, e.g. `print description.Length`, fails with "The name
  '...' does not exist in the current context". This is a **pre-existing,
  platform-independent** netcoredbg bug — it fails identically on Linux x64
  (`src/debugger/evaluator.cpp` `InternalWalkMembers` early-returns for
  `ELEMENT_TYPE_STRING`). Not Android-specific; left as-is.
- **Explicit method-call func-eval**, e.g. `print _count.ToString()`,
  `print description.ToUpper()`, `print Calculator.DescribeCount(3)`, prints
  NOTHING on Android (no result, no error, not even the eval-timeout message) —
  yet the SAME calls WORK on Linux x64. This is the one **genuinely
  Android-specific** eval gap: driving an arbitrary target method to completion
  on a debuggee thread does not complete. Arithmetic and object expansion are
  unaffected. It does not block breakpoints / stepping / locals / backtrace /
  exceptions; it is the next investigation for a later part.
- `$exception` does not expand (minor).

### Two operational requirements the runbook handles for you

- **The four harness workarounds are still required.** Dropping the `*.dll`/`*.pdb`
  open-redirect OR the TPA `opendir` redirect makes ATTACH FAIL with `0x80004005`.
  The `LD_PRELOAD` shim (`libtrace.so`) is proof-time scaffolding; the real fixes
  (PAL `kill(pid,0)` EPERM tolerance, Android-aware module/symbol path resolution)
  are Part 6.
- **Mark the app as the debug app** — `am set-debug-app --persistent <pkg>` — so
  ActivityManager does not ANR-kill it while it sits at a breakpoint (undo with
  `am clear-debug-app`). `run-debug-session.sh` does this.

---

## Rebuilding from source (each script refreshes its `prebuilt/<abi>/` file)

Each native build script takes an ABI argument, default `arm64-v8a`:

```bash
# arm64-v8a (default)                            # x86_64
android/dbgshim/build-dbgshim-android.sh         android/dbgshim/build-dbgshim-android.sh x86_64
android/harness/build-harness.sh                 android/harness/build-harness.sh x86_64
android/netcoredbg/build-netcoredbg-android.sh   android/netcoredbg/build-netcoredbg-android.sh x86_64
android/netcoredbg/build-managed-helper.sh   # architecture-independent; run once, serves both ABIs
```

Requirements per script: dbgshim/harness need the NDK; netcoredbg needs the NDK +
cmake + a system `dotnet`; the managed helper needs only `dotnet`.

`netcoredbg` is built from this repository's own `src/` (which carries the Part-3
fix); the other three build from the vendored source / `src/managed/` in this
clone. Pinned upstream commits and licenses are in `NOTICE.txt` and the
repository-root `THIRD-PARTY-NOTICES.txt`.

---

# Reference — how it works, and the Android specifics

Verified on a Pixel 4 XL (Android 13 / API 33, arm64-v8a) and a Google-API x86_64
emulator (API 37), against `com.codebrix.simpledebugapp` (`net11.0-android37.0`).
This is the minimum a future session needs to understand, extend, or productionize
the pieces above. Paths below use the arm64 ABI names; on x86_64 substitute the
ABI (see "Two ABI naming conventions" in the device fact sheet).

## The cast — every piece and where it runs

| Piece | What it is | Runs on | Origin |
|---|---|---|---|
| The app (`SimpleDebugApp`) | the debuggee; a `net11.0-android37.0` CoreCLR app | phone | CodeBrix.Android |
| `libcoreclr.so` | the app's .NET 11 runtime | phone | ships in the APK |
| `libmscordbi.so` | ICorDebug engine (the "right side" / RS) | phone | ships in the APK |
| `libmscordaccore.so` | the DAC — reads runtime data structures out of the debuggee | phone | ships in the APK |
| `netcoredbg` | the debugger executable (C++), an ICorDebug/dbgshim client | phone | this repo (built per device ABI: arm64-v8a + x86_64) |
| `libdbgshim.so` | bootstrap shim: finds the runtime, loads mscordbi, hands back ICorDebug | phone | vendored + built here |
| `ManagedPart.dll` + Roslyn | netcoredbg's MANAGED brain: PDB symbol reading + C# expression eval | phone | this repo's `src/managed/` |
| `libtrace.so` | the LD_PRELOAD harness (kill-mask + path redirects + trace) | phone | `harness/` (proof only) |
| The IDE / DAP client | CodeBrix.Develop, connects over an adb-forwarded port | **host** | CodeBrix.Develop (Parts 4-5) |

The non-obvious fact: **the debugger runs on the device (phone or emulator), not the laptop.**
ICorDebug cannot be called remotely, so the ICorDebug client (mscordbi, driven by
netcoredbg) must live with the debuggee. The laptop only ever talks to netcoredbg
over a forwarded port via the Debug Adapter Protocol (that wiring is Parts 4-5).

## The attach pipeline (as it runs on the device)

```
ManagedDebugger::AttachToProcess(pid)
  -> GetCLRPath(pid)                     find the app's libcoreclr.so
  -> CreateVersionStringFromModule(...)  dbgshim builds the version string
  -> CreateDebuggingInterfaceFromVersionEx(CorDebugVersion_4_0, ...)
        dbgshim -> loads libmscordbi.so -> returns ICorDebug
  -> Startup(pCordb):
        ICorDebug::Initialize()
        SetManagedHandler(ManagedCallback)
        ICorDebug::DebugActiveProcess(pid, FALSE)
              mscordbi opens the clr-debug-pipe FIFOs and runs the transport
              handshake: SessionRequest -> SessionAccept, GetDCB, WriteMemory
  -> ManagedCallback::CreateProcess() fires and calls Interop::Init(clrPath):
        coreclr_initialize(debuggee libcoreclr.so, TPA from .__override__, APP_PATHS)
        coreclr_create_delegate("ManagedPart", "SymbolReader", ...)   x22 delegates
     then NotifyProcessCreated() sets ProcessAttachedState::Attached
  -> AttachToProcess returns S_OK; breakpoints, stepping, eval all work
```

`Interop::Init` hosts a **second CoreCLR inside the netcoredbg process** to run
`ManagedPart.dll` (netcoredbg is C++ and cannot run managed code itself).
ManagedPart is the symbol reader (portable-PDB -> `file:line`, local names) and
the Roslyn-based C# evaluator. Hosting that second runtime is what earlier drafts
called "the wall" — a suspected `coreclr_create_delegate` deadlock. It is **not**
a deadlock: with `ManagedPart.dll` + Roslyn present next to netcoredbg and the
framework assembly probes redirected into the debuggee's `.__override__` dir (the
harness does both), the second runtime initializes, all delegates are created,
and the symbol reader runs. The one real failure on this path was the CoreLib
module-name bug fixed in Part 3.

## The five Android facts the harness works around

Each was isolated on hardware. Four are handled by the `LD_PRELOAD` harness and/or
the run scripts; one is benign.

1. **SELinux denies `kill(pid, 0)`.** The PAL probes debuggee liveness with
   `kill(pid,0)`; even at the same uid the kernel denies it across the `run-as`
   -> app domains (`avc: denied { signull }`), and the PAL reads `EPERM` as
   "process gone" and aborts. Harness: interpose `kill()`, answer `sig==0` from
   `/proc/<pid>`. Real fix: PAL tolerates `EPERM` on the signal-0 probe on Android.
2. **Stale transport state.** Attaching to a process that had an earlier debug
   session gets `MT_SessionResync` instead of `MT_SessionAccept`, and the attach
   times out (`CORDBG_E_TIMEOUT`). Not a code fix — **attach to a FRESH process**
   (force-stop + relaunch, then attach once). The run scripts do this.
3. **`sem_open` returns `ENOSYS`.** Android bionic has no working named POSIX
   semaphores. BENIGN on the attach path (an open-existing that already tolerates
   failure); flagged only because any path needing a cross-process named event
   would hit it.
4. **Managed assemblies are not next to `libcoreclr.so`.** After the session
   forms, mscordbi/DAC opens module files (e.g. `System.Private.CoreLib.dll`) next
   to `libcoreclr.so` — the read-only APK `lib/arm64` dir, which holds only `.so`.
   On Android the assemblies live in
   `/data/data/<pkg>/files/.__override__/arm64-v8a/` (and
   `/data/local/tmp/fastdeploy2/<pkg>/0/arm64-v8a/`). Harness: interpose
   `open`/`openat` and retry `*.dll`/`*.pdb` from `.__override__`; interpose
   `opendir` on the runtime dir so the hosted runtime's TPA scan (fact below)
   finds the framework. **Load-bearing:** without this redirect attach fails
   `0x80004005`. Real fix: Android-aware module/symbol path resolution in the
   debugger.
5. **The hosted second CoreCLR needs its framework.** `Interop::Init` builds the
   hosted runtime's TPA by scanning the dir next to `libcoreclr.so` (no `.dll`
   there) and loads `ManagedPart.dll` from netcoredbg's own dir. The harness's
   `opendir`/`open` redirects (fact 4) point the TPA scan and framework opens at
   `.__override__`; `ManagedPart.dll` + the four Roslyn DLLs are pushed next to
   netcoredbg. With those in place it works (see the attach pipeline). Roslyn is
   the only dependency shipped in the payload because it is a NuGet package, not
   part of the framework; everything else ManagedPart needs comes from the
   debuggee's framework via the redirect.

Positive corollary: the app has a `.NET DebugPipe` thread sitting in `fifo_open`
— the runtime's ICorDebug transport IS listening. CoreCLR on Android is
debuggable at the transport level.

## The harness (`libtrace.so`) and its switches

`harness/trace.c` -> `libtrace.so`, `LD_PRELOAD`ed into netcoredbg. Proof tooling,
not a shipped component. The run scripts set these; documented here for
extending them:

```
TRACE_OUT=<file>                write the syscall trace here (also dumps the
                                clr-debug-pipe FIFO traffic)
TRACE_MASK_KILL0=1              answer kill(pid,0) from /proc            (fact 1)
TRACE_REDIR_DIR=<dir>           retry failing *.dll/*.pdb opens here     (fact 4)
TRACE_TPA_DIR + TRACE_CLR_DIR   redirect opendir(clrDir) so the hosted
                                runtime's TPA scan finds the framework   (fact 4/5)
TRACE_EMU_SEM=1                 in-process named-semaphore emulation     (fact 3; benign)
```

`run-attach.sh` (Part 2) needs only `TRACE_MASK_KILL0`. `run-debug-session.sh`
(Part 3) sets the kill-mask plus the `*.dll`/`*.pdb` and TPA redirects.

## The clr-debug-pipe transport (brief)

The RS/LS transport (`DbgTransportSession`, CoreCLR
`debug/inc/dbgtransportsession.h`, vendored under `netcoredbg/coreclr-deps/`)
frames every exchange with a 48-byte little-endian header and runs over a pair of
FIFOs at `/data/data/<pkg>/cache/clr-debug-pipe-<pid>-<disamb>-{in,out}`. A healthy
fresh-process attach is `MT_SessionRequest(0)` -> `MT_SessionAccept(1)`, then
`MT_GetDCB(8)`, then a burst of `MT_WriteMemory(7)` round-trips, all acked. The
failure signature on a stale process is `MT_SessionResync(3)` with a non-zero
last-seen id instead of `MT_SessionAccept` (fact 2).

## Device fact sheet

- Debuggee package `com.codebrix.simpledebugapp`, activity `.MainActivity`.
- Debugger dir on device: `/data/data/<pkg>/ncdbg/` (the scripts push to
  `/data/local/tmp/ncdbg` then `run-as <pkg> cp` into the sandbox and `chmod 755`
  the binary — `/data/local/tmp` is noexec for the app uid).
- Framework + PDB on device: `/data/data/<pkg>/files/.__override__/<abi>/`
  and `/data/local/tmp/fastdeploy2/<pkg>/0/<abi>/`.
- Attach must be to a FRESH process; mark the app as the debug app so it is not
  ANR-killed at a breakpoint. (`am set-debug-app` must run BEFORE the fresh
  launch — applied to a running app it restarts the process and orphans the pid.)

**Two ABI naming conventions on the device** (the scripts handle both; know them
if you extend the paths). The device's primary ABI is `ro.product.cpu.abi`:
`arm64-v8a` or `x86_64`. The `.__override__` and `fastdeploy2` assembly dirs are
named by that FULL ABI (`arm64-v8a`, `x86_64`). But the extracted native-lib dir
under `/data/app/.../lib/` uses the SHORT name: `arm64` for arm64-v8a, `x86_64`
for x86_64. The scripts derive the lib dir straight from the process's
`/proc/<pid>/maps` rather than assuming a name, so they are ABI-agnostic.

## Sources

- ICorDebug cannot be remoted; the debugger runs in-process — Microsoft
  unmanaged-API docs (ICorDebug interface / `DebugActiveProcess`).
- Transport / message format — CoreCLR `debug/inc/dbgtransportsession.h`
  (vendored here under `netcoredbg/coreclr-deps/`).
- CoreCLR-on-Android is experimental — dotnet/runtime PR #112034 and issue
  #111955; rough edges tracked in dotnet/android #10588 / #10472.
- Roslyn 2.3.0 binary license — the packages' own nuspecs (Microsoft .NET Library
  License, `LinkId=529443`); see the repository-root `THIRD-PARTY-NOTICES.txt`,
  item 3, and `NOTICE.txt`.

---
---

# Roadmap — Parts 4, 5, and beyond

**Part 3's on-device debugging is proven on hardware** (attach, breakpoints,
stepping, locals, backtrace, first-chance exceptions). That makes **Part 4**
(remote DAP over an adb-forwarded port) and **Part 5** (the IDE one-click Debug
pipeline) the immediate next steps. The one open on-device gap that follows the
work along is the Android-specific method-call func-eval limitation (a later
part), which does not block the Part 4/5 integration.

The end goal: **in CodeBrix.Develop, open a solution with a .NET 11 CoreCLR
Android app, hit Debug once, and get full line-by-line debugging on the device —
breakpoints set in the editor bind and get hit, call stack and locals populate,
stepping and watches work.**

The encouraging part: once the on-device debugger can read symbols and bind
breakpoints (Part 3, done), most of what remains is **wiring existing pieces
together**, not inventing new ones. CodeBrix.Develop already has a DAP client,
breakpoint store, call-stack pad, gutter breakpoints, F5/F9/F10/F11, the paused
hover popover, and the Android device plumbing (adb bridge, device monitor,
device selection). So Parts 4-5 are mostly integration; Parts 6+ are hardening
and breadth.

Two framing notes:
- **The on-device debugger is a black box to the IDE.** Part 3 settled its
  internals (C++ netcoredbg + the hosted ManagedPart, working on Android). Parts
  4+ treat it as "a process that exposes a DAP server on the device," so the
  roadmap does not depend on those internals.
- **Workarounds ride along.** Parts 4-5 inherit the four Android workarounds from
  Part 2/3. They can stay the `LD_PRELOAD` stopgap until Part 6 makes them real,
  so they do not block progress.

## Part 4 — Remote debugging over the wire (device <-> off-device DAP, no IDE yet)

**Definition of done:** From the laptop, using a *plain* DAP client (a test
harness or stock VS Code), connect to the debugger running on the device and do a
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
work over the remote transport on Android — and note the method-call func-eval
gap from Part 3 will surface here for watches that call methods. This part
deliberately excludes the IDE so any problem is a transport-or-debugger problem,
not an IDE-wiring problem.

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
   ManagedPart + Roslyn), and mark it the debug app.
3. Launch the app **fresh** with debugging enabled and capture its pid.
4. Start the on-device debugger in server mode against that pid; `adb forward`
   the port.
5. Connect the IDE's **existing** DAP client to the forwarded port.
6. Flip `LaunchCapability`'s net11-Android arm from "not implemented" to offered
   — the one line the earlier work set up for exactly this moment. (Leave it
   refused until Parts 4 and 5 land, so the button drives a real end-to-end path.)

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
  file cleanup, handling multiple connected devices, and hardening attach against
  the flakiness seen after many rapid back-to-back sessions.

## Part 7 and beyond — breadth

- **Close the method-call func-eval gap** — the one Android-specific limitation
  left from Part 3, so watches and Immediate-window method calls work.
- **Launch, not just attach** — start the app *under* the debugger so you can
  break in `OnCreate`/startup, not only attach to a running app.
- **The version and RID matrix** — arm64-v8a and x86_64 are both covered now;
  remaining breadth is other .NET versions and a physical x64 device (only an
  x86_64 emulator has been exercised so far).
- **Richer breakpoints** — conditional and hit-count breakpoints, exception
  breakpoints (uncaught / "just my code" beyond the working first-chance stop).
- **Nice-to-haves** — Hot Reload, edit-and-continue where feasible, and CI that
  rebuilds and smoke-tests the payload.

## The critical path

**Parts 4 -> 5 reach the goal.** Part 4 proves the debugger works remotely with a
throwaway client; Part 5 is CodeBrix.Develop doing it for real on one button.
Part 6 turns "it worked once in a demo" into "a developer can rely on it";
Part 7+ is scope.
