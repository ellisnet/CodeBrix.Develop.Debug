# CodeBrix.Develop.Debug.AndroidArm64

A debugger for the .NET runtime, packaged as **android-arm64 native binaries that run on an Android device** to debug .NET 11 CoreCLR Android apps. It implements the [VSCode Debug Adapter Protocol](https://microsoft.github.io/debug-adapter-protocol/) (plus GDB/MI and an interactive command line), so a development tool on your computer can debug an Android app by pushing this payload into the app's sandbox with adb, starting it there in server mode, and speaking the protocol over an adb-forwarded TCP port.

This package supports **android-arm64 only** (64-bit ARM (arm64-v8a) devices - most phones and tablets). It is a carrier for native binaries, contains no managed library, and adds no NuGet dependencies.

CodeBrix.Develop.Debug.AndroidArm64 supports applications and assemblies that target Microsoft .NET version 11.0 and later.

## Installation

```
dotnet add package CodeBrix.Develop.Debug.AndroidArm64
```

The Android packages of this family are:

* `CodeBrix.Develop.Debug.AndroidArm64` - the payload for devices whose primary ABI is `arm64-v8a`.
* `CodeBrix.Develop.Debug.AndroidX64` - the payload for devices whose primary ABI is `x86_64`.

Unlike the Linux packages of the family, the two Android packages land in DIFFERENT output folders, so an application that must debug on either kind of device references BOTH and picks the folder matching the device's `ro.product.cpu.abi` at run time.

Note that these package IDs carry no license suffix, unlike most CodeBrix packages; that is deliberate and shared with the other `CodeBrix.Develop.*` packages. The package contributes no managed types, so there is nothing to `using`, and no `RuntimeIdentifier` is required.

## CodeBrix.Develop.Debug.AndroidArm64 supports:

* Debugging .NET 11 (CoreCLR) Android apps on the device, over the VSCode Debug Adapter Protocol (`--interpreter=vscode --server=<port>`).
* Attaching to the running app process (breakpoints, stepping, call stack, locals, expression evaluation, first-chance exception stops).
* Debugging over GDB/MI (`--interpreter=mi`) or the interactive command line (`--interpreter=cli`) for other clients.
* An Android compatibility layer built into the debugger (activated by environment variables) that copes with the on-device assembly layout and the SELinux sandbox - no extra native pieces to push.
* Automatic copy of the payload into the consuming project's output folder.

## What referencing this package does

On every build of the consuming project, the on-device payload is copied to a `netcoredbg-android-arm64/` subfolder of the output directory. Nothing is run on the build machine and no executable bit is needed there: the files are pushed to the device and made executable inside the app's sandbox. The same happens on `dotnet publish`.

## Sample Code

### Push the payload and start the debugger on the device

Your application locates the payload in its own output folder, pushes it into the debugged app's sandbox, starts the debugger in server mode, forwards the port, and connects a Debug Adapter Protocol client:

```csharp
using System;
using System.Diagnostics;
using System.IO;

var payload = Path.Combine(AppContext.BaseDirectory, "netcoredbg-android-arm64");
var package = "com.example.myapp";           // the debugged app's application id
var device = "<adb serial>";

// 1. push the payload where run-as can copy it into the app sandbox
Process.Start("adb", $"-s {device} push \"{payload}/.\" /data/local/tmp/codebrix-ncdbg").WaitForExit();
Process.Start("adb", $"-s {device} shell run-as {package} sh -c 'mkdir -p /data/data/{package}/ncdbg && cp /data/local/tmp/codebrix-ncdbg/* /data/data/{package}/ncdbg/ && chmod 755 /data/data/{package}/ncdbg/netcoredbg'").WaitForExit();

// 2. mark the app as the debug app, launch it FRESH, and note its pid ...
// 3. start the debugger in server mode inside the sandbox (see the AGENT-README for the
//    exact environment variables), then:
Process.Start("adb", $"-s {device} forward tcp:4711 tcp:4711").WaitForExit();
// 4. connect a DAP client to 127.0.0.1:4711 and send initialize / attach / configurationDone.
```

The complete, tested sequence (including the environment the debugger needs on the device) is in the `AGENT-README.txt` inside the package and in the repository's `android/README.md`.

## Contents

| File | Purpose |
|---|---|
| `netcoredbg` | The native debugger executable (android-arm64), with the Android compatibility layer built in |
| `libdbgshim.so` | The debugger shim that finds the app's runtime and loads its debugging interface (android-arm64) |
| `ManagedPart.dll` | Managed helper loaded by the debugger on the device (expression evaluation, symbol reading) |
| `Microsoft.CodeAnalysis*.dll` (4 files) | Roslyn scripting stack used by ManagedPart |

## Documentation

This package includes `AGENT-README.txt`, a complete reference and usage guide written for AI coding agents - point your agent at that file when it is writing code against this package. One file covers every package of the family.

## License

CodeBrix.Develop.Debug.AndroidArm64 is licensed under the MIT License - see the
[LICENSE](https://github.com/ellisnet/CodeBrix.Develop.Debug/blob/codebrix/LICENSE) file.

For licensing and provenance information about the open source code included in
this package, see the `THIRD-PARTY-NOTICES.txt` file inside the package, or
[THIRD-PARTY-NOTICES.txt](https://github.com/ellisnet/CodeBrix.Develop.Debug/blob/codebrix/THIRD-PARTY-NOTICES.txt) in the repository.
