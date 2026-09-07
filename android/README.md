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
