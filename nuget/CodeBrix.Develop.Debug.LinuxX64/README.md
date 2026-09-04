# CodeBrix.Develop.Debug.LinuxX64

A debugger for the .NET runtime, packaged as **linux-x64 native binaries**. It implements the [GDB/MI](https://sourceware.org/gdb/onlinedocs/gdb/GDB_002fMI.html) and [VSCode Debug Adapter Protocol](https://microsoft.github.io/debug-adapter-protocol/) interfaces, so an application can debug .NET programs by launching the debugger as a child process and speaking either protocol over stdio.

This package supports **linux-x64 only** — it is a carrier for native binaries, contains no managed library, and adds no NuGet dependencies.

CodeBrix.Develop.Debug.LinuxX64 supports applications and assemblies that target Microsoft .NET version 10.0 and later.
Microsoft .NET version 10.0 is a Long-Term Supported (LTS) version of .NET, and was released on Nov 11, 2025; and will be actively supported by Microsoft until Nov 14, 2028.
Please update your C#/.NET code and projects to the latest LTS version of Microsoft .NET.

## Installation

```
dotnet add package CodeBrix.Develop.Debug.LinuxX64
```

Reference exactly ONE package of this family, matching the architecture of the machine your application will RUN on:

* `CodeBrix.Develop.Debug.LinuxX64` — linux-x64 debugger binaries.
* `CodeBrix.Develop.Debug.LinuxArm64` — linux-arm64 debugger binaries.

Both land their binaries at the same relative output path, so referencing two of them at once makes the two architectures overwrite each other's files.

Note that these package IDs carry no license suffix, unlike most CodeBrix packages; that is deliberate and shared with the other `CodeBrix.Develop.*` packages. The package contributes no managed types, so there is nothing to `using`, and no `RuntimeIdentifier` is required.

## CodeBrix.Develop.Debug.LinuxX64 supports:

* Debugging .NET programs over the VSCode Debug Adapter Protocol (`--interpreter=vscode`).
* Debugging over GDB/MI (`--interpreter=mi`), for clients that already speak that protocol.
* An interactive command-line debugging mode (`--interpreter=cli`).
* Attaching to an already-running process, or launching the program under the debugger.
* Communicating over stdin/stdout, or over a TCP port in server mode.
* Automatic copy of the debugger into the consuming project's output folder, on linux-x64.

## What referencing this package does

On every build of the consuming project, the debugger binaries are copied to a `netcoredbg/` subfolder of the output directory, and the executable bit is restored on the `netcoredbg` binary (nupkg archives cannot preserve file permissions). No `RuntimeIdentifier` is required. The same happens on `dotnet publish`.

Interpreter options: `--interpreter=vscode` (Debug Adapter Protocol), `--interpreter=mi` (GDB/MI), or `--interpreter=cli` (interactive command line).

## Sample Code

### Launch the debugger and speak the Debug Adapter Protocol

Your application launches the debugger from its own output folder, e.g.:

```csharp
using System;
using System.Diagnostics;
using System.IO;

var debuggerPath = Path.Combine(AppContext.BaseDirectory, "netcoredbg", "netcoredbg");

var startInfo = new ProcessStartInfo(debuggerPath)
{
    RedirectStandardInput = true,
    RedirectStandardOutput = true,
};
startInfo.ArgumentList.Add("--interpreter=vscode");

using var debugger = Process.Start(startInfo);
// Speak the VSCode Debug Adapter Protocol over debugger.StandardInput /
// debugger.StandardOutput ...
```

## Contents

| File | Purpose |
|---|---|
| `netcoredbg` | The native debugger executable |
| `ManagedPart.dll` | Managed helper loaded by the debugger (expression evaluation, symbol reading) |
| `libdbgshim.so` | Microsoft's debugger-shim native library |
| `Microsoft.CodeAnalysis*.dll` (4 files) | Roslyn scripting stack used by ManagedPart |

## Documentation

This package includes `AGENT-README.txt`, a complete reference and usage guide written for AI coding agents - point your agent at that file when it is writing code against this package. One file covers both architecture packages.

## License

CodeBrix.Develop.Debug.LinuxX64 is licensed under the MIT License - see the
[LICENSE](https://github.com/ellisnet/CodeBrix.Develop.Debug/blob/codebrix/LICENSE) file.

For licensing and provenance information about the open source code included in
this package, see the `THIRD-PARTY-NOTICES.txt` file inside the package, or
[THIRD-PARTY-NOTICES.txt](https://github.com/ellisnet/CodeBrix.Develop.Debug/blob/codebrix/THIRD-PARTY-NOTICES.txt) in the repository.
