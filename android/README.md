# Android debugging bundle (arm64-v8a + x86_64)

Everything needed to reproduce, on a fresh clone on another machine, debugging
of **.NET 11 CoreCLR Android apps** with this debugger — from the first
on-device attach to the one-click Debug button in CodeBrix.Develop — and to
rebuild and re-pack the two NuGet packages that ship the on-device debugger:

| Package | Device ABI | Project |
|---|---|---|
| `CodeBrix.Develop.Debug.AndroidArm64` | `arm64-v8a` (phones, tablets) | `android/nuget/CodeBrix.Develop.Debug.AndroidArm64/` |
| `CodeBrix.Develop.Debug.AndroidX64` | `x86_64` (emulators, x64 devices) | `android/nuget/CodeBrix.Develop.Debug.AndroidX64/` |

**Status: Parts 1 to 6 are done and proven on both an arm64-v8a device
(Pixel 4 XL, Android 13) and an x86_64 device (Google-API emulator, API 37).**
CodeBrix.Develop opens a .NET 11 Android project, the user picks the device
and presses F5, and the app is built, installed, launched fresh, and attached
to on the device; breakpoints set in the editor bind and hit, the call stack
and hover evaluation populate, stepping works, and Stop cleans the device up.
The four Android workarounds that used to need an `LD_PRELOAD` shim are now
compiled into the debugger itself.

This folder is self-contained: the source for every binary is vendored and
pinned (or is this repository's own `src/`), each binary is committed prebuilt
for **both** ABIs, and the packaging projects pack exactly those prebuilt files.
A fresh clone can run the proof scripts, rebuild any piece with no network, and
re-pack the packages. The two things this folder does **not** include (by
design) are the app being debugged and the .NET 11 SDK — see Prerequisites.

The first half of this document is the runbook: Parts 1 to 6, then rebuilding
and packing. The second half is the
**[Reference](#reference--how-it-works-and-the-android-specifics)** (how the
pieces fit, the Android facts the compatibility layer handles, the device fact
sheet) and the **[Roadmap](#roadmap--part-7-and-beyond)**.

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
    prebuilt/arm64-v8a/libdbgshim.so   prebuilt arm64 binary (packed)
    prebuilt/x86_64/libdbgshim.so      prebuilt x64 binary  (packed)
  netcoredbg/
    coreclr-deps/               pinned CoreCLR header/IDL subset (coreclr/ + native/)
    build-netcoredbg-android.sh build [<abi>] from THIS repo's src/ (with the Android
                                compatibility layer) against coreclr-deps; strips the
                                output and refreshes prebuilt/<abi>/netcoredbg
    build-managed-helper.sh     builds + refreshes prebuilt/managed/ from THIS repo's src/managed/
    prebuilt/arm64-v8a/netcoredbg      prebuilt arm64 binary, stripped (packed)
    prebuilt/x86_64/netcoredbg         prebuilt x64 binary, stripped  (packed)
    prebuilt/managed/           the managed helper pushed to the device: ManagedPart.dll +
                                the four Microsoft.CodeAnalysis*.dll (Roslyn) — the symbol
                                reader + C# evaluator that run in netcoredbg's hosted runtime.
                                ARCHITECTURE-INDEPENDENT (netstandard2.0); packed into BOTH packages
  harness/
    trace.c                     the LD_PRELOAD TRACING harness from the investigation
    build-harness.sh            build [<abi>]; refreshes prebuilt/<abi>/libtrace.so
    prebuilt/<abi>/libtrace.so  prebuilt (NOT packed; a diagnostic tool, see the Reference)
  dap-probe/
    DapProbe.csproj, Program.cs a plain C# Debug Adapter Protocol client (no IDE code) that
                                attaches over an adb-forwarded port and drives a scripted
                                session with a VERDICT — the Part 4 proof
  scripts/
    run-attach.sh               Part 2 in one command: place, attach, report the verdict
    run-debug-session.sh        Part 3 in one command: CLI over a FIFO, scripted session, verdict
    run-dap-session.sh          Part 4 in one command: DAP server on the device + the probe
    pack-android-packages.sh    Part 6: verify the prebuilt payload and pack both packages
  nuget/
    CodeBrix.Develop.Debug.AndroidArm64/   packaging project: csproj, build/*.targets, README.md
    CodeBrix.Develop.Debug.AndroidX64/     packaging project: csproj, build/*.targets, README.md
```

The run scripts detect the device's primary ABI (`ro.product.cpu.abi`) and use
the matching `prebuilt/<abi>/` binaries; `<abi>` is `arm64-v8a` or `x86_64`.
The prebuilt binaries are the exact ones the packages carry and the proofs ran;
use them as-is, or rebuild any with the matching `build-*.sh [<abi>]` (default
`arm64-v8a`; each rebuild refreshes its `prebuilt/<abi>/` file in place, and
each was verified to build from the vendored source alone). The netcoredbg
source is not vendored under `android/` — it is this repository's own `src/`,
which the clone already has, including the Android-only
`src/utils/android_compat.cpp`.

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
  not a Play image — `run-as` (which everything relies on) only works on
  debuggable/Google-API images. The `arm64` and `x86_64` builds are independent,
  so an x86_64 emulator exercises the real x64 path, not arm64-via-translation.

### For Parts 2 to 4 and for rebuilding (the debugger pieces)
- **Android platform-tools** (`adb`) on PATH.
- **Android NDK 29.0.14206865** at `~/Android/Sdk/ndk/29.0.14206865`, or set
  `ANDROID_NDK_ROOT`. Clang 21; deliberately the stable NDK, not an rc. Only
  rebuilding the native pieces needs the NDK (the pack script also uses its
  `llvm-readelf`/`llvm-nm` for verification and skips that check without it).
- **cmake 3.31.x** — **NOT cmake 4.x** (this source tree sets
  `cmake_minimum_required` below 4 and 4.x refuses it).
- A **`dotnet` on PATH** for the netcoredbg build (a tiny code-gen tool,
  `generrmsg`, is built with `dotnet build`), for the managed helper
  (`build-managed-helper.sh` runs `dotnet publish`), for the DAP probe, and for
  packing. The **system .NET 10 SDK (10.0.400) is fine**; the .NET 11 preview is
  **not** needed for any of that. (Do not confuse this with Part 1, which does
  need .NET 11.)

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

### For Part 5 (the IDE)
- CodeBrix.Develop built from its repository, with the two Android packages
  referenced (see Part 6). In the IDE, File > Options > General needs BOTH
  "Additional SDK installation folders" (= `/home/<you>/dotnet11`) and "Allow
  preview MSBuild" — the folder says where the .NET 11 SDK is, the checkbox
  grants permission to use a preview.

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
- This is exactly what CodeBrix.Develop runs on F5 (Part 5), through its
  build service with the solution's SDK.

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
Part 2 is the one script that still uses the `LD_PRELOAD` tracing harness on
purpose: its verdict is read out of the harness's dump of the transport traffic.
It must attach to a **freshly launched** app process (see the Reference for why).

---

## Part 3 — full on-device debugging works (CLI)

One command reproduces the whole session (detects the ABI; uses the matching
prebuilt binaries + the managed helper; relies on the compatibility layer built
into netcoredbg — add `-t` to use the `LD_PRELOAD` tracing harness instead):

```bash
android/scripts/run-debug-session.sh -s <serial>
```

It places `netcoredbg` + `libdbgshim.so` **and the managed helper**
(`ManagedPart.dll` + the four Roslyn assemblies) into the app sandbox, marks the
app as the debug app, launches it fresh, attaches, and drives a scripted
breakpoint / stepping / locals / expression / exception session over a FIFO.
Success looks like:

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

### The one bug that was fixed (Part 3)

`print this` (any expression whose expansion triggers a func-eval) used to abort
the whole debugger with `libc++abi: terminating due to uncaught exception of type
HRException*`. Root cause: netcoredbg detected `System.Private.CoreLib` by the
exact string `"System.Private.CoreLib.dll"`, but CoreCLR on Android reports that
module by simple name with no path and no `.dll`, so the cross-thread-dependency
notification class was never set up and the first func-eval passed NULL into
mscordbi, which threw an `HRException*` (by pointer) that nothing caught. Fixed in
this repo's C++ source and built into `netcoredbg/prebuilt/<abi>/netcoredbg` for both ABIs:

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
  exceptions; it is the first item of Part 7.
- `$exception` does not expand (minor).

---

## Part 4 — remote debugging over the wire (DAP over adb forward, no IDE)

One command (detects the ABI; uses the prebuilt binaries + managed helper; the
built-in compatibility layer, or `-t` for the tracing harness):

```bash
android/scripts/run-dap-session.sh -s <serial> [-H <host port>]
```

It places the same payload as Part 3, marks the debug app, launches the app
fresh, starts **`netcoredbg --interpreter=vscode --server=4711`** under `run-as`
inside the app sandbox, runs `adb forward tcp:<host port> tcp:4711`, and then
runs **`android/dap-probe`** — a deliberately plain C# Debug Adapter Protocol
client with its own Content-Length framing and no IDE code — which connects,
attaches, and drives a scripted session. Success looks like:

```
==================== Part 4 VERDICT (plain DAP client over adb forward) ====================
connected over TCP (adb forward)                    : YES   (127.0.0.1:4711 after 5 ms)
initialize                                          : YES   (supportsConfigurationDoneRequest=True)
initialized event                                   : YES
setBreakpoints accepted before attach               : YES   (MainActivity.cs:47 verified=False (unverified before attach is normal))
attach completed (configurationDone + attach responses): YES   (254 ms)
threads listed                                      : YES   (2 threads)
tapped count_button                                 : YES
breakpoint hit (stopped event)                      : YES   (reason=breakpoint threadId=27562)
stackTrace top frame has file:line                  : YES   (SimpleDebugApp.MainActivity.OnCountClicked() at .../MainActivity.cs:47)
scopes/variables list locals                        : YES   (this={SimpleDebugApp.MainActivity}, description=null)
evaluate _count                                     : YES   (1)
evaluate this (object expansion, func-eval)         : YES   ({SimpleDebugApp.MainActivity} ref=3)
this expands to members                             : YES   (125 members: _count, _statusText, _counterText, ...)
next (step over the DescribeCount call)             : YES   (... at MainActivity.cs:48)
stepIn (into ShowCount)                             : YES   (SimpleDebugApp.MainActivity.ShowCount() at MainActivity.cs:100)
stepOut (back to OnCountClicked)                    : YES   (... at MainActivity.cs:48)
setBreakpoints while attached binds immediately     : YES   (Calculator.cs:56 verified=True)
breakpoint re-hit on a second tap                   : YES
stepIn into Calculator.DescribeCount                : YES   (... at Calculator.cs:53)
evaluate arithmetic (count % 2)                     : YES   (0)
second breakpoint hit (Calculator.cs:56)            : YES   (... at Calculator.cs:56)
evaluate local isSquare at line 56                  : YES   (false)
first-chance exception stop                         : YES   (exception: Exception thrown: 'System.InvalidOperationException' in SimpleDebugApp.dll)
exceptionInfo names the exception                   : YES   (CLR/System.InvalidOperationException)
exception stack trace at the throw site             : YES   (SimpleDebugApp.Calculator.ThrowForDemo() at Calculator.cs:64)
detach left the app running (same pid)              : YES   (pid before=27562 after=27562)
>>> ALL CHECKS PASSED
```

All 25 checks pass on both the Pixel and the emulator, with the tracing harness
and with the built-in compatibility layer alike. The transcript of every DAP
message and the debugger's own log are saved under `/tmp/ncdbg-dap.*/`.

### What Part 4 established (facts the IDE relies on)

- **The DAP attach shape.** netcoredbg's `attach {processId}` request only
  records the pid; the REAL attach runs inside `configurationDone`
  (`ManagedDebugger::RunIfReady`). So the order is `initialize` → `attach`
  (sent, not awaited) → `initialized` event → `setBreakpoints` per file →
  `configurationDone` → then the `attach` response. On both device kinds the
  attach takes **about 250 ms**, far below the adapter's 15-second per-request
  timeout (which is nonetheless raisable, see Part 6).
- Breakpoints sent **before** attach are accepted unverified and bind when the
  module loads; breakpoints sent **while attached** bind immediately
  (`verified: true`).
- The PDB records the build machine's absolute source paths; sending those
  paths in `setBreakpoints` matches.
- `disconnect {terminateDebuggee: false}` detaches and leaves the app running;
  the debugger exits after `disconnect`.
- `--server` binds `INADDR_ANY`, accepts one connection, and speaks DAP over it.
  **`adb forward` accepts the host side of a connection before it tries the
  device side**, so a successful TCP connect proves nothing about whether the
  debugger is listening yet — the first message finds the connection closed if
  it is not. Anything that connects must first wait for the port to be in
  `LISTEN` state on the device (`/proc/net/tcp`), which is what the IDE does.

---

## Part 5 — CodeBrix.Develop drives it: the one-click Debug pipeline

**Done.** In CodeBrix.Develop, open a solution containing a .NET 11 CoreCLR
Android project (a bare `.csproj` opened as the solution works), pick the device
in the toolbar's Android device picker, set breakpoints in the editor, and press
**F5**. The IDE runs, in order:

1. `dotnet build <csproj> -c Debug -t:Install -p:AdbTarget=-s <serial>` with the
   solution's SDK (the isolated .NET 11), through the same build service as
   every other build.
2. Reads the device ABI, picks the matching payload folder from its own output
   (`netcoredbg-android-arm64/` or `netcoredbg-android-x64/`, placed there by
   the two Android packages), and pushes it into the app sandbox **only if it
   changed** (a SHA-256 stamp over the payload is kept on the device as
   `ncdbg/payload.sha256`).
3. `am set-debug-app --persistent <pkg>` (before the launch, on purpose),
   `am force-stop`, resolves the launcher activity
   (`cmd package resolve-activity --brief`), `am start -n`, polls `pidof`,
   and reads `/proc/<pid>/maps` for the directory holding `libcoreclr.so` (a
   process with no CoreCLR mapped is refused with the MonoVM explanation).
4. Kills any orphaned debugger, starts `netcoredbg --interpreter=vscode
   --server=4711` under `run-as` with the compatibility-layer environment
   (below), **waits until the device shows the debugger process alive and the
   port in LISTEN state**, then `adb forward tcp:<free host port> tcp:4711`,
   connects, and runs the DAP attach flow through the IDE's existing DAP client.
   If the attach does not complete, one retry is made on a completely fresh app
   process.
5. From here the session is an ordinary CodeBrix.Develop debug session: gutter
   breakpoints (also ones added mid-session), F5/F10/F11/Shift+F11, the Call
   Stack pad, hover evaluation, Application Output, and **Run > Break on All
   Exceptions** (a remembered check item; on, the debuggee stops at every
   throw site before any catch runs — toggled before or during a session).
6. **Stop (Shift+F5)** detaches (a DAP terminate cannot signal the app from the
   debugger's SELinux domain and would only wait out a timeout), then cleans the
   device up: kills the debugger, removes the port forward, `am
   clear-debug-app`, and `am force-stop` — Stop means stop, exactly as for a
   plain Android run. The same cleanup runs when the session ends for any other
   reason, and on every failure path of the launch.

`LaunchCapability` now offers Debug for `.NET 11+` Android projects and still
refuses `.NET 10` and older (MonoVM) with the runtime explanation.

### Verified

- **Through the IDE's own classes on both devices** (a device-level harness
  that drives `BuildService`, `AndroidDebugLaunch` and `DebugService` exactly as
  the workbench does, without the GTK front end): build+install, attach
  (1.3–1.5 s from F5 to attached, after an incremental build), breakpoint hit
  surfaced through `DebugService.Paused` with `file:line`, hover evaluation,
  step over / into / out, a breakpoint added during the session binding and
  hitting in a second file, evaluation of a local there, Break on All
  Exceptions toggled on mid-session stopping at `Calculator.cs:64` on the next
  throw (and not stopping once toggled off), Stop ending the session in 0.1 s,
  and the device left clean (no app process, no debugger, no forward, stamp
  recorded). 18/18 on the Pixel and 18/18 on the emulator.
- **Through the real GTK IDE, driven with xdotool on X11**, on the Pixel and on
  the emulator (device chosen through the remembered-device preference the
  picker writes): expand the project, open `MainActivity.cs`, F9 on line 47,
  F5 — Application Output shows every step of the pipeline and "Attached to
  com.codebrix.simpledebugapp (process …)"; tapping Count on the device
  highlights line 47 and fills the Call Stack pad; hovering `_count` shows
  `_count = 1`; F10 moves the execution marker to line 48; Shift+F5 ends with
  "Debugging ended" and the device clean.
- The IDE's unit tests cover every rule the pipeline follows (command strings,
  quoting, parsers, the stamp, the listen-state parser, the TCP transport, and
  the DAP attach order): 716 tests, 0 failures.

Where the IDE code lives (CodeBrix.Develop repository): `Core/Android/AndroidDebugger.cs`
(the pure rules), `Core/Debugging/TcpDebuggerTransport.cs`,
`Core/Debugging/DebugSession.cs` (`AttachAsync`), `Core/Android/AndroidDebugBridge.cs`
(adb runners), `Ide/Android/AndroidDebugLaunch.cs` (the pipeline),
`Ide/Debugging/DebugService.cs` (`StartAttachedAsync`, `StopAsync(bool)`),
`Ide/Gui/Workbench.cs` (`DebugOnAndroidAsync`, cleanup on session end).

---

## Part 6 — productionize: the compatibility layer, the packages, robustness

### The Android compatibility layer (no more LD_PRELOAD)

The four workarounds the investigation pioneered in `harness/trace.c` are now
**compiled into netcoredbg**, for Android builds only:

- `src/utils/android_compat.cpp` (compiled only when CMake's `ANDROID` is set)
  defines `kill`, `open`, `open64`, `openat`, `__open_2` and `__openat_2` with C
  linkage and default visibility, each forwarding to libc via
  `dlsym(RTLD_NEXT, …)`:
  - `kill(pid, 0)` that fails with `EPERM`/`EACCES` is answered from
    `/proc/<pid>` (0 if it exists, else `ESRCH`). Always on. This is the PAL's
    liveness probe inside `libmscordbi.so`, which Android's SELinux denies even
    between processes of the same uid.
  - A `*.dll`/`*.pdb` open that fails because the file does not exist is retried
    from `NETCOREDBG_ANDROID_ASSEMBLY_DIR` when the file exists there. This is
    mscordbi/DAC opening managed assemblies "next to libcoreclr.so", which on
    Android is a read-only APK folder holding only `.so` files.
  - `__open_2`/`__openat_2` are the bionic fortify entry points; **all four**
    .NET runtime libraries call `__open_2`, so those are the load-bearing ones.
    The file switches `_FORTIFY_SOURCE` off for itself (the NDK passes
    `-D_FORTIFY_SOURCE=2` build-wide, which turns `open` into an inline overload
    that cannot coexist with an out-of-line definition).
- `src/CMakeLists.txt` adds that file and links the Android binary with one
  `-Wl,--export-dynamic-symbol=<name>` per interposer. Exactly those six symbols
  are exported (a plain `--export-dynamic` would also export ~1,700 statically
  linked libc++ symbols); bionic resolves every `dlopen`ed library's symbols
  against the executable first, so `libdbgshim.so`, `libmscordbi.so`,
  `libmscordaccore.so` and the hosted `libcoreclr.so` all pick these up.
- `src/managed/interop.cpp` `Init()`: when `NETCOREDBG_ANDROID_ASSEMBLY_DIR` is
  set, the hosted (second) CoreCLR's TPA list is built from that directory
  before `clrDir` — where the framework assemblies actually are on Android.
  This replaces the harness's `opendir` redirect.
- `src/protocols/vscodeprotocol.cpp`: the 15 000 ms per-request timeout is
  overridable with `NETCOREDBG_COMMAND_TIMEOUT_MS` (read once; invalid or 0
  falls back to the default). The device attach takes ~250 ms so this is a
  safety net; the IDE sets 60 000.

All of it is inert on Linux (Android-only compilation, or environment-gated
with the upstream default), so the Linux packages are unaffected.

**The environment the launcher sets** (what the scripts and the IDE do):

```
NETCOREDBG_ANDROID_ASSEMBLY_DIR=/data/data/<pkg>/files/.__override__/<abi>   REQUIRED
NETCOREDBG_ANDROID_CLR_DIR=<dir of libcoreclr.so>                            informational
LD_LIBRARY_PATH=<dir of libcoreclr.so>                                       the hosted runtime's native companions
TMPDIR=/data/data/<pkg>/cache                                                the transport and --log need a writable dir
NETCOREDBG_COMMAND_TIMEOUT_MS=60000                                          optional
NETCOREDBG_ANDROID_TRACE=<file>                                              optional: one line per decision
```

Verification: `run-dap-session.sh` (default mode, no `LD_PRELOAD`) passes all
25 checks on both devices, and the trace file shows exactly the two behaviours
firing — 46 masked `kill(pid,0)` `EACCES` probes and one
`System.Private.CoreLib.dll` redirect — during one session. The
`run-debug-session.sh` (Part 3) verdict is also all-YES in the default mode.
The stripped binaries export 8 dynamic symbols in total (the six plus upstream's
`wait`/`waitpid`).

The harness (`harness/`) is kept as what it always really was: a **tracing
tool** (`-t` on the Part 3 and Part 4 scripts; Part 2 still uses it to read the
transport handshake). It is not packed.

### The packages

`android/nuget/CodeBrix.Develop.Debug.AndroidArm64/` and
`android/nuget/CodeBrix.Develop.Debug.AndroidX64/` are packaging-only projects
in the exact shape of the Linux pair (`nuget/`): same date-stamped
`3.<years>.<day>.<minute>` version scheme with MAJOR pinned to 3, MIT, no
license suffix, `GeneratePackageOnBuild`, no dependencies, and they pack the
root `AGENT-README.txt`, `THIRD-PARTY-NOTICES.txt`, icon, plus their own
`README.md`. Each packs its ABI's prebuilt `netcoredbg` + `libdbgshim.so` and
its own copy of the managed helper (5 DLLs) into `tools/android-<arch>/`, and
ships a `build/<PackageId>.targets` that copies that folder into the consumer's
output as `netcoredbg-android-arm64/` or `netcoredbg-android-x64/`
(`PreserveNewest`, no chmod — nothing runs on the build machine). The two land
in **different** folders on purpose, so an IDE references both and picks by
device ABI at run time.

```bash
android/scripts/pack-android-packages.sh              # both ABIs
android/scripts/pack-android-packages.sh x86_64       # one
```

The pack script refuses to pack unless each prebuilt binary is the right ELF
machine (`AArch64` / `X86-64`) **and** the netcoredbg exports the six
compatibility symbols — i.e. it was rebuilt with the layer. Output:
`android/nuget/<PackageId>/bin/Release/<PackageId>.<version>.nupkg`
(the packed payload is about 2.2 MB of netcoredbg + 0.5 MB dbgshim + 6.5 MB
Roslyn/ManagedPart per package).

**Consuming them in CodeBrix.Develop** (already in its `CodeBrix.Develop.csproj`):

```xml
<ItemGroup>
  <PackageReference Include="CodeBrix.Develop.Debug.AndroidArm64" Version="3.0.250.1243" />
  <PackageReference Include="CodeBrix.Develop.Debug.AndroidX64" Version="3.0.250.1243" />
</ItemGroup>
```

Those versions are the nupkgs packed on 2026-09-07 and used for every Part 5
verification; publish exactly those files and the reference resolves from
nuget.org (until then they resolve from the local NuGet cache they were restored
into). If they are re-packed before publishing, the version changes — update the
two references to match.

### Robustness (what the IDE pipeline does beyond the scripts)

- Waits for the debugger to be **listening** before connecting (the
  `adb forward` accept-before-connect fact from Part 4); a debugger that dies
  instead is reported with its own output.
- One attach **retry** on a genuinely fresh launch.
- **Push only if changed** (the payload stamp), so the second and every later
  debug session on a device skips the copy.
- Every failure path and every session end runs the same device **cleanup**
  (kill debugger, remove forward, clear debug-app, force-stop), each step
  best-effort so an unplugged device cannot wedge the IDE.
- **Detach on Stop**, then `am force-stop`: instant on both device kinds
  (a terminate took 5 s on the Pixel before timing out, for the SELinux reason
  above).
- Multiple attached devices: everything is keyed by the serial the toolbar
  picker holds; the host port is a free ephemeral port per session.

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

`netcoredbg` is built from this repository's own `src/` (which carries the Part 3
fixes and the Part 6 compatibility layer); the build script strips the output
(`llvm-strip --strip-unneeded`, 33 MB → 2.2 MB; `.dynsym` and the six exports
survive) and prints the exported compat symbols as a check. The other three
build from the vendored source / `src/managed/` in this clone. Pinned upstream
commits and licenses are in `NOTICE.txt` and the repository-root
`THIRD-PARTY-NOTICES.txt`.

After a rebuild, before packing: `run-dap-session.sh -s <serial>` on an
arm64-v8a **and** an x86_64 device, expect `>>> ALL CHECKS PASSED` on both, then
`pack-android-packages.sh`.

---

# Reference — how it works, and the Android specifics

Verified on a Pixel 4 XL (Android 13 / API 33, arm64-v8a) and a Google-API x86_64
emulator (API 37), against `com.codebrix.simpledebugapp` (`net11.0-android37.0`).
This is the minimum a future session needs to understand, extend, or maintain
the pieces above. Paths below use the arm64 ABI names; on x86_64 substitute the
ABI (see "Two ABI naming conventions" in the device fact sheet).

## The cast — every piece and where it runs

| Piece | What it is | Runs on | Origin |
|---|---|---|---|
| The app (`SimpleDebugApp`) | the debuggee; a `net11.0-android37.0` CoreCLR app | device | CodeBrix.Android |
| `libcoreclr.so` | the app's .NET 11 runtime | device | ships in the APK |
| `libmscordbi.so` | ICorDebug engine (the "right side" / RS) | device | ships in the APK |
| `libmscordaccore.so` | the DAC — reads runtime data structures out of the debuggee | device | ships in the APK |
| `netcoredbg` | the debugger executable (C++), an ICorDebug/dbgshim client, with the Android compatibility layer | device | this repo (built per device ABI) |
| `libdbgshim.so` | bootstrap shim: finds the runtime, loads mscordbi, hands back ICorDebug | device | vendored + built here |
| `ManagedPart.dll` + Roslyn | netcoredbg's MANAGED brain: PDB symbol reading + C# expression eval | device | this repo's `src/managed/` |
| `libtrace.so` | the LD_PRELOAD tracing harness (syscall trace + pipe dump) | device | `harness/` (diagnostics only) |
| The IDE / DAP client | CodeBrix.Develop (or `dap-probe`), connects over an adb-forwarded port | **host** | CodeBrix.Develop / this repo |

The non-obvious fact: **the debugger runs on the device (phone or emulator), not the laptop.**
ICorDebug cannot be called remotely, so the ICorDebug client (mscordbi, driven by
netcoredbg) must live with the debuggee. The laptop only ever talks to netcoredbg
over a forwarded port via the Debug Adapter Protocol.

## The attach pipeline (as it runs on the device)

```
ManagedDebugger::AttachToProcess(pid)             <- inside DAP configurationDone
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
        coreclr_initialize(debuggee libcoreclr.so, TPA from NETCOREDBG_ANDROID_ASSEMBLY_DIR, APP_PATHS)
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
framework assemblies found in `NETCOREDBG_ANDROID_ASSEMBLY_DIR`, the second
runtime initializes, all delegates are created, and the symbol reader runs. The
one real failure on this path was the CoreLib module-name bug fixed in Part 3.

## The five Android facts the compatibility layer handles

Each was isolated on hardware. Four are handled by the built-in layer and the
launch sequence; one is benign.

1. **SELinux denies `kill(pid, 0)`.** The PAL probes debuggee liveness with
   `kill(pid,0)`; even at the same uid the kernel denies it across the `run-as`
   -> app domains (`avc: denied { signull }`), and the PAL reads `EPERM` as
   "process gone" and aborts. Layer: the interposed `kill()` answers `sig==0`
   from `/proc/<pid>`. (Consequence for Stop: the debugger cannot signal the app
   either, so a DAP terminate cannot work; the IDE detaches and uses
   `am force-stop`.)
2. **Stale transport state.** Attaching to a process that had an earlier debug
   session gets `MT_SessionResync` instead of `MT_SessionAccept`, and the attach
   times out (`CORDBG_E_TIMEOUT`). Not a code fix — **attach to a FRESH process**
   (force-stop + relaunch, then attach once). The scripts and the IDE do this,
   and the IDE retries once on a fresh process if an attach fails.
3. **`sem_open` returns `ENOSYS`.** Android bionic has no working named POSIX
   semaphores. BENIGN on the attach path (an open-existing that already tolerates
   failure); flagged only because any path needing a cross-process named event
   would hit it.
4. **Managed assemblies are not next to `libcoreclr.so`.** After the session
   forms, mscordbi/DAC opens module files (e.g. `System.Private.CoreLib.dll`) next
   to `libcoreclr.so` — the read-only APK `lib/arm64` dir, which holds only `.so`.
   On Android the assemblies live in
   `/data/data/<pkg>/files/.__override__/arm64-v8a/` (and
   `/data/local/tmp/fastdeploy2/<pkg>/0/arm64-v8a/`). Layer: the interposed
   open family retries `*.dll`/`*.pdb` from `NETCOREDBG_ANDROID_ASSEMBLY_DIR`.
   **Load-bearing:** without it attach fails `0x80004005`.
5. **The hosted second CoreCLR needs its framework.** `Interop::Init` used to
   build the hosted runtime's TPA by scanning the dir next to `libcoreclr.so`
   (no `.dll` there). Layer: `Init` scans `NETCOREDBG_ANDROID_ASSEMBLY_DIR`
   for the TPA; `ManagedPart.dll` + the four Roslyn DLLs are pushed next to
   netcoredbg and found through `APP_PATHS`. Roslyn is the only dependency
   shipped in the payload because it is a NuGet package, not part of the
   framework; everything else ManagedPart needs comes from the debuggee's
   framework.

Positive corollary: the app has a `.NET DebugPipe` thread sitting in `fifo_open`
— the runtime's ICorDebug transport IS listening. CoreCLR on Android is
debuggable at the transport level.

## The tracing harness (`libtrace.so`) and its switches

`harness/trace.c` -> `libtrace.so`, `LD_PRELOAD`ed into netcoredbg by
`run-attach.sh` and by `-t` on the Part 3/4 scripts. Diagnostics, not a shipped
component:

```
TRACE_OUT=<file>                write the syscall trace here (also dumps the
                                clr-debug-pipe FIFO traffic)
TRACE_MASK_KILL0=1              answer kill(pid,0) from /proc            (fact 1)
TRACE_REDIR_DIR=<dir>           retry failing *.dll/*.pdb opens here     (fact 4)
TRACE_TPA_DIR + TRACE_CLR_DIR   redirect opendir(clrDir) so the hosted
                                runtime's TPA scan finds the framework   (fact 4/5)
TRACE_EMU_SEM=1                 in-process named-semaphore emulation     (fact 3; benign)
```

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

- Debuggee package `com.codebrix.simpledebugapp`, activity `.MainActivity`
  (the IDE resolves the launcher activity of any package with
  `cmd package resolve-activity --brief <pkg>`, last line).
- Debugger dir on device: `/data/data/<pkg>/ncdbg/` (the scripts push to
  `/data/local/tmp/ncdbg`, the IDE to `/data/local/tmp/codebrix-ncdbg`, then
  `run-as <pkg> cp` into the sandbox and `chmod 755` the binary —
  `/data/local/tmp` is noexec for the app uid). The IDE also writes
  `ncdbg/payload.sha256` there; the debugger's stdout/stderr go to `ncdbg/ncdbg.out`.
- Framework + PDB on device: `/data/data/<pkg>/files/.__override__/<abi>/`
  and `/data/local/tmp/fastdeploy2/<pkg>/0/<abi>/`.
- Attach must be to a FRESH process; mark the app as the debug app so it is not
  ANR-killed at a breakpoint. (`am set-debug-app` must run BEFORE the fresh
  launch — applied to a running app it restarts the process and orphans the pid.)
- The DAP server port on the device is 4711; the host side is any free port,
  `adb forward tcp:<host> tcp:4711`. Wait for `/proc/net/tcp` to show
  `:1267` (4711) in state `0A` (LISTEN) before connecting.

**Two ABI naming conventions on the device** (the scripts and the IDE handle
both; know them if you extend the paths). The device's primary ABI is
`ro.product.cpu.abi`: `arm64-v8a` or `x86_64`. The `.__override__` and
`fastdeploy2` assembly dirs are named by that FULL ABI (`arm64-v8a`, `x86_64`).
But the extracted native-lib dir under `/data/app/.../lib/` uses the SHORT name:
`arm64` for arm64-v8a, `x86_64` for x86_64. The scripts and the IDE derive the
lib dir straight from the process's `/proc/<pid>/maps` rather than assuming a
name, so they are ABI-agnostic.

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
- bionic symbol lookup order for `dlopen`ed libraries (executable, `LD_PRELOAD`,
  `DT_NEEDED`, then the local group) — the reason the compatibility layer's
  exported symbols interpose on the runtime libraries.

---
---

# Roadmap — Part 7 and beyond

**Parts 1 to 6 are done.** The goal stated at the start — in CodeBrix.Develop,
open a solution with a .NET 11 CoreCLR Android app, hit Debug once, and get full
line-by-line debugging on the device — is reached and verified on both ABIs.
What remains is breadth.

## Part 7 and beyond — breadth

- **Close the method-call func-eval gap** — the one Android-specific limitation
  left from Part 3 (`print x.ToString()` returns nothing on Android, works on
  Linux), so watches and Immediate-window method calls work. Investigation
  starts at `ICorDebugEval` against the target thread on Android.
- **Exception breakpoints in the IDE** — DONE for the first-chance case
  (Run > Break on All Exceptions, `setExceptionBreakpoints ["all"]`). Still
  open: the `user-unhandled` filter as a second mode, and an exception-details
  popup (the adapter's `exceptionInfo`) at the stop.
- **Launch, not just attach** — start the app *under* the debugger so you can
  break in `OnCreate`/startup, not only attach to a running app.
- **The version and RID matrix** — arm64-v8a and x86_64 are both covered;
  remaining breadth is other .NET versions and a physical x64 device (only an
  x86_64 emulator has been exercised so far).
- **Richer breakpoints** — conditional and hit-count breakpoints (the adapter
  supports `condition`), and "just my code" refinements.
- **Nice-to-haves** — Hot Reload, edit-and-continue where feasible, and CI that
  rebuilds and smoke-tests the payload against an emulator.
