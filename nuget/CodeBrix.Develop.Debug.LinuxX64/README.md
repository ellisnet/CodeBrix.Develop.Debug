# CodeBrix.Develop.Debug.LinuxX64

The [NetCoreDbg](https://github.com/ellisnet/CodeBrix.Develop.Debug) debugger
for the .NET runtime, packaged as **linux-x64 native binaries**. NetCoreDbg
implements the [GDB/MI](https://sourceware.org/gdb/onlinedocs/gdb/GDB_002fMI.html)
and [VSCode Debug Adapter Protocol](https://microsoft.github.io/debug-adapter-protocol/)
interfaces, allowing an application to debug .NET programs by launching the
debugger as a child process and speaking either protocol over stdio.

This package supports **linux-x64 only** — it is a carrier for native
binaries, contains no managed library, and adds no NuGet dependencies.
It is derived from the [Samsung netcoredbg](https://github.com/Samsung/netcoredbg)
project (MIT license); see `THIRD-PARTY-NOTICES.txt` inside this package for
full provenance and license details.

## What referencing this package does

On every build of the consuming project, the debugger binaries are copied to
a `netcoredbg/` subfolder of the output directory, and the executable bit is
restored on the `netcoredbg` binary (nupkg archives cannot preserve file
permissions). No `RuntimeIdentifier` is required. The same happens on
`dotnet publish`.

Your application launches the debugger from its own output folder, e.g.:

```csharp
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

Interpreter options: `--interpreter=vscode` (Debug Adapter Protocol),
`--interpreter=mi` (GDB/MI), or `--interpreter=cli` (interactive command
line).

## Contents

| File | Purpose |
|---|---|
| `netcoredbg` | The native debugger executable |
| `ManagedPart.dll` | Managed helper loaded by the debugger (expression evaluation, symbol reading) |
| `libdbgshim.so` | Microsoft's debugger-shim native library |
| `Microsoft.CodeAnalysis*.dll` (4 files) | Roslyn scripting stack used by ManagedPart |

## License

The project is licensed under the MIT License. see: https://en.wikipedia.org/wiki/MIT_License
