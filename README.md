# CodeBrix.Develop.Debug

A debugger for the .NET runtime, packaged as native Linux binaries that a .NET application can launch as a child process and drive over [GDB/MI](https://sourceware.org/gdb/onlinedocs/gdb/GDB_002fMI.html), the [VSCode Debug Adapter Protocol](https://microsoft.github.io/debug-adapter-protocol/), or an interactive command line. It is the debugger engine behind CodeBrix.Develop, and is equally usable from any .NET 10 application that wants to debug other .NET programs.

CodeBrix.Develop.Debug is provided as two single-architecture NuGet packages - `CodeBrix.Develop.Debug.LinuxX64` and `CodeBrix.Develop.Debug.LinuxArm64`. Neither contains a managed library; each is a carrier for the native binaries of one Linux architecture.

CodeBrix.Develop.Debug supports applications and assemblies that target Microsoft .NET version 10.0 and later.
Microsoft .NET version 10.0 is a Long-Term Supported (LTS) version of .NET, and was released on Nov 11, 2025; and will be actively supported by Microsoft until Nov 14, 2028.
Please update your C#/.NET code and projects to the latest LTS version of Microsoft .NET.

## Installation

Reference exactly ONE package, matching the architecture of the machine your application will RUN on:

```
dotnet add package CodeBrix.Develop.Debug.LinuxX64
```

```
dotnet add package CodeBrix.Develop.Debug.LinuxArm64
```

* `CodeBrix.Develop.Debug.LinuxX64` - linux-x64 debugger binaries.
* `CodeBrix.Develop.Debug.LinuxArm64` - linux-arm64 debugger binaries.

Both packages land their binaries at the same relative output path, so referencing two of them at once makes the two architectures overwrite each other's files. Pick one.

Note that these package IDs carry no license suffix, unlike most CodeBrix packages; that is deliberate and shared with the other `CodeBrix.Develop.*` packages.

Neither package brings in any other NuGet package, and neither contributes managed types - there is nothing to `using`. A `RuntimeIdentifier` is not required and is not set by the package.

Requirements:

* Linux only. There is no Windows, macOS, riscv64, arm32 or x86 package.
* A .NET runtime must be installed on the machine where debugging happens.
* The consuming application must be able to start a child process and redirect that child's stdin/stdout, or to open a TCP connection to it in server mode.

## CodeBrix.Develop.Debug supports:

* Debugging .NET programs over the VSCode Debug Adapter Protocol (`--interpreter=vscode`).
* Debugging over GDB/MI (`--interpreter=mi`), for clients that already speak that protocol.
* An interactive command-line debugging mode (`--interpreter=cli`).
* Attaching to an already-running process, or launching the program under the debugger.
* Communicating over stdin/stdout, or over a TCP port in server mode.
* Automatic copy of the debugger into the consuming project's output folder on every build and publish, into a `netcoredbg/` subfolder, with the executable bit restored (a nupkg archive cannot preserve file permissions).
* Two Linux architectures, linux-x64 and linux-arm64, through the two packages above.

## Sample Code

### Launch the debugger and speak the Debug Adapter Protocol

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

The path is the same on both architectures, so this code needs no runtime identifier and no per-architecture branch.

### Debug a program from the command line

```
/path/to/netcoredbg --interpreter=mi -- /path/to/dotnet /path/to/program.dll
```

## Documentation

The NuGet package includes `AGENT-README.txt`, a complete API reference and usage guide written for AI coding agents - point your agent at that file when it is writing code against this package. One file covers both packages.

The debugger's own command-line manual and its mixed native/managed ("interop") and stepping notes are in this repository under [docs/](https://github.com/ellisnet/CodeBrix.Develop.Debug/tree/codebrix/docs).

## License

CodeBrix.Develop.Debug is licensed under the MIT License - see the
[LICENSE](https://github.com/ellisnet/CodeBrix.Develop.Debug/blob/codebrix/LICENSE) file.

For licensing and provenance information about the open source code included in
these packages, see [THIRD-PARTY-NOTICES.txt](https://github.com/ellisnet/CodeBrix.Develop.Debug/blob/codebrix/THIRD-PARTY-NOTICES.txt).
