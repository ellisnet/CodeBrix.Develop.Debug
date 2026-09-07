================================================================================
AGENT-README: CodeBrix.Develop.Debug
A Guide for AI Coding Agents — CONSUMING the CodeBrix.Develop.Debug.LinuxX64,
.LinuxArm64, .AndroidArm64 and .AndroidX64 NuGet packages
================================================================================

OVERVIEW
========
These NuGet packages carry the NetCoreDbg debugger for the .NET runtime as
prebuilt native binaries - one package per CPU architecture. There is no
managed library in any package and no public C# API: referencing a package
drops a working debugger into your application's output folder, and your code
starts it and talks to it over a protocol.

Two kinds of package, same debugger:

    Linux packages (.LinuxX64, .LinuxArm64)
        The debugger runs on the machine your application runs on. Your code
        starts it as a child process and speaks DAP over its stdio.
    Android packages (.AndroidArm64, .AndroidX64)
        The debugger runs ON AN ANDROID DEVICE, inside the sandbox of the .NET
        11 (CoreCLR) Android app being debugged. Your code pushes it there with
        adb, starts it in server mode, forwards the port, and speaks the SAME
        DAP over TCP. See ANDROID PACKAGES: DEBUGGING ON THE DEVICE below.

NetCoreDbg debugs .NET programs. It speaks three interfaces, selected by a
command-line option when you start it:

    --interpreter=vscode   VSCode Debug Adapter Protocol (DAP), JSON over
                           stdio - the interface to use from code
    --interpreter=mi       GDB/MI, line-oriented text over stdio
    --interpreter=cli      interactive command-line front end for humans

Consuming projects target .NET 10 or later. The debugger itself is a native
executable and does not care what your application targets; the .NET version
that matters at run time is the one the DEBUGGED program uses.

Provenance: this is an exact fork of the Samsung netcoredbg project
(https://github.com/Samsung/netcoredbg), with CodeBrix
packaging added on top. Because nothing managed is shipped, there are no
upstream namespaces to avoid and no type names to remap.


INSTALLATION
============
Package ids (they carry NO license suffix - a deliberate deviation from the
CodeBrix family convention, shared by the other CodeBrix.Develop.* packages):

    CodeBrix.Develop.Debug.LinuxX64      linux-x64 debugger binaries (host)
    CodeBrix.Develop.Debug.LinuxArm64    linux-arm64 debugger binaries (host)
    CodeBrix.Develop.Debug.AndroidArm64  on-device payload for arm64-v8a devices
    CodeBrix.Develop.Debug.AndroidX64    on-device payload for x86_64 devices/emulators

    dotnet add package CodeBrix.Develop.Debug.LinuxX64
      -- or --
    dotnet add package CodeBrix.Develop.Debug.LinuxArm64
      -- plus, to debug Android apps on devices --
    dotnet add package CodeBrix.Develop.Debug.AndroidArm64
    dotnet add package CodeBrix.Develop.Debug.AndroidX64

NuGet dependencies: NONE. No package brings in any other package.

License: MIT. The packaged third-party binaries are MIT except the Roslyn
scripting DLLs, which are under the Microsoft .NET Library License (the
licence their 2.x-era NuGet packages declare). Full provenance ships inside
the package as THIRD-PARTY-NOTICES.txt.

Requirements:
  - Linux hosts only for the Linux packages. There is no Windows, macOS,
    riscv64, arm32 or x86 package. The Android packages are host-agnostic
    files that are pushed to a device; using them needs adb on the host.
  - A .NET runtime must be installed on the machine where debugging happens.
    The debugger finds the CoreCLR of the process being debugged and loads its
    own managed helper (ManagedPart.dll) into that runtime.
  - The consuming application must be able to start a child process and to
    redirect that child's stdin/stdout (or to open a TCP connection to it in
    server mode).

WHICH ONE DO I REFERENCE
------------------------
Of the LINUX packages, exactly ONE, matching the architecture of the machine
your application will RUN on:

    linux-x64    -> CodeBrix.Develop.Debug.LinuxX64
    linux-arm64  -> CodeBrix.Develop.Debug.LinuxArm64

The Linux packages are single-arch carriers on purpose. Each one's
build/*.targets copies its binaries unconditionally and both land them at the
SAME output path (netcoredbg/), so referencing two of them at once makes the
two architectures fight over the same files. Pick one; see ARCHITECTURE
SELECTION below for the conditional PackageReference that does the picking.

Of the ANDROID packages, EITHER OR BOTH: they land in DIFFERENT output folders
(netcoredbg-android-arm64/ and netcoredbg-android-x64/), and which one to push
is decided at run time by the device's ABI (`adb shell getprop
ro.product.cpu.abi` -> arm64-v8a or x86_64). A tool that must debug on phones
AND on the Android Studio emulator references both.


KEY NAMESPACES / USINGS
=======================
The packages contribute no managed types, so there is nothing from them to
`using`. The code you write around the debugger typically needs:

    using System;                   // AppContext.BaseDirectory
    using System.Diagnostics;       // Process, ProcessStartInfo
    using System.IO;                // Path, Stream
    using System.Text;              // Encoding (Content-Length framing)
    using System.Text.Json;         // JsonSerializer  (DAP payloads)
    using System.Text.Json.Nodes;   // JsonNode, JsonObject


CORE API REFERENCE
==================
The API reference is organised by feature area in the sections that follow.

WHAT REFERENCING THE PACKAGE DOES
=================================
Inside the nupkg the binaries live under tools/linux-<arch>/ :

    tools/linux-x64/...      (CodeBrix.Develop.Debug.LinuxX64)
    tools/linux-arm64/...    (CodeBrix.Develop.Debug.LinuxArm64)
    tools/android-arm64/...  (CodeBrix.Develop.Debug.AndroidArm64)
    tools/android-x64/...    (CodeBrix.Develop.Debug.AndroidX64)

The rest of this section describes the LINUX packages. The Android packages
copy the same way but into netcoredbg-android-arm64/ or netcoredbg-android-x64/,
do NO chmod (nothing runs on the build machine), and are covered in ANDROID
PACKAGES: DEBUGGING ON THE DEVICE.

The package's build/<PackageId>.targets file adds those files to the consuming
project as linked None items with CopyToOutputDirectory=PreserveNewest, all
under a netcoredbg\ link prefix. So on every build - and on every publish - the
debugger appears in a netcoredbg/ SUBFOLDER of the output directory. No
RuntimeIdentifier is required, and none is set by the package.

The same targets file then restores the executable bit that a nupkg (a zip
archive) cannot preserve, with two targets:

    CodeBrixDevelopDebugRestoreExecutableBit           AfterTargets="Build"
    CodeBrixDevelopDebugRestoreExecutableBitOnPublish  AfterTargets="Publish"

Both run `chmod +x` on the netcoredbg binary and are gated on '$(OS)' == 'Unix'
plus the file actually existing at $(OutputPath)netcoredbg/netcoredbg or
$(PublishDir)netcoredbg/netcoredbg.

THE OUTPUT-PATH CONTRACT
------------------------
Every package in this family lands its binaries at the same relative path, so
your code is architecture-agnostic and never needs a RID at run time:

    var debuggerPath = System.IO.Path.Combine(
        System.AppContext.BaseDirectory, "netcoredbg", "netcoredbg");

FILES THAT LAND IN netcoredbg/
------------------------------
    netcoredbg
        The native debugger executable - the thing you start.
    ManagedPart.dll
        Managed helper (symbol reading, expression evaluation) that the
        debugger loads into the debuggee's CoreCLR.
    libdbgshim.so
        Microsoft's debugger-shim native library.
    Microsoft.CodeAnalysis.dll
    Microsoft.CodeAnalysis.CSharp.dll
    Microsoft.CodeAnalysis.Scripting.dll
    Microsoft.CodeAnalysis.CSharp.Scripting.dll
        The Roslyn scripting stack that ManagedPart uses to evaluate
        expressions.

Keep the folder intact. The debugger resolves libdbgshim.so and ManagedPart.dll
relative to its OWN executable path (it also adds that directory to the
CoreCLR APP_PATHS it creates), so moving the netcoredbg binary out of the
folder, or copying it alone, breaks it at startup.


ARCHITECTURE SELECTION
======================
Nothing in the package chooses an architecture for you - the targets file
copies unconditionally. Put the choice in your own csproj. The reliable
selector is the SDK's own RID, with the project's RuntimeIdentifier taking
precedence when one is set:

    <PropertyGroup>
      <!-- Prefer an explicit RuntimeIdentifier; fall back to the SDK's RID. -->
      <DebuggerArchRid Condition="'$(RuntimeIdentifier)' != ''">$(RuntimeIdentifier)</DebuggerArchRid>
      <DebuggerArchRid Condition="'$(DebuggerArchRid)' == ''">$(NETCoreSdkRuntimeIdentifier)</DebuggerArchRid>
    </PropertyGroup>

    <ItemGroup>
      <PackageReference Include="CodeBrix.Develop.Debug.LinuxX64"
                        Version="*"
                        Condition="'$(DebuggerArchRid)' == 'linux-x64'" />
      <PackageReference Include="CodeBrix.Develop.Debug.LinuxArm64"
                        Version="*"
                        Condition="'$(DebuggerArchRid)' == 'linux-arm64'" />
    </ItemGroup>

Notes:
  - Replace Version="*" with the version you actually restored; `dotnet add
    package <id>` writes the current one for you.
  - $(NETCoreSdkRuntimeIdentifier) is set by the .NET SDK and describes the
    machine running the build (for example linux-x64 on an x64 build host).
    $(NETCoreSdkPortableRuntimeIdentifier) is the portable form of the same
    value and works equally well as a selector.
  - PackageReference conditions are evaluated at RESTORE time. A
    RuntimeIdentifier passed only on a later command line (`dotnet publish -r
    linux-arm64`) will not have been visible to the restore that chose the
    package, so pass -r to the restore as well, or set RuntimeIdentifier in the
    csproj, or use RuntimeIdentifiers plus per-RID publishing.
  - Cross-architecture builds are fine: the linux-arm64 package can be
    restored and published from an x64 host. Only the exec-bit fix-up is
    host-sensitive (see COMMON PITFALLS).


LAUNCHING THE DEBUGGER: COMMAND-LINE OPTIONS
============================================
These are the options the shipped binary accepts (`netcoredbg --help`):

    --interpreter=vscode        VSCode Debug Adapter Protocol mode
    --interpreter=mi            GDB/MI mode
    --interpreter=cli           interactive Command Line Interface mode
    --attach <process-id>       attach to an already running process; the id is
                                a separate argument, not --attach=<id>
    --run                       start the program immediately instead of
                                waiting for a launch/run command
    --server[=port_num]         listen for protocol requests on a TCP/IP port
                                instead of stdin/stdout; the default port is
                                4711
    --command=<file>            read debugger commands from a file at start
    -ex "<command>"             execute one command at start (repeatable)
    --engineLogging[=<path>]    log the protocol traffic; with no path the log
                                is emitted as DAP "output" events on the
                                console category, with a path it is written to
                                that file
    --log[=<type>]              enable the internal debug log. Bare --log writes
                                <program>.<pid>.log into the system temp
                                directory; --log=<value> sets the LOG_OUTPUT
                                environment variable to <value> (the same
                                variable you can export yourself)
    --version                   print version and exit
    --buildinfo                 print build type, build date, target OS and
                                target architecture, then exit
    --help                      print the option list and exit
    -- <program> [args...]      everything after a bare -- is the program to
                                debug and its arguments

Rules the debugger enforces at startup (it prints an error and exits with a
failure code if you break one):

  - -ex and --command work ONLY with --interpreter=cli.
  - --server cannot be combined with --interpreter=cli.
  - --run requires a program after `--`.
  - --engineLogging works ONLY with --interpreter=vscode.

DEFAULT INTERPRETER - READ THIS
-------------------------------
If you do NOT pass --interpreter, the debugger picks one by looking at stdin:
a terminal selects the interactive CLI, anything else (a pipe, which is exactly
what redirected stdin is) selects GDB/MI. A program that forgets --interpreter
and then writes DAP JSON gets an MI parser on the other end. Always pass the
interpreter explicitly.

Typical one-liner shape from a shell:

    netcoredbg --interpreter=vscode -- dotnet /path/to/App.dll arg1 arg2


DEBUG ADAPTER PROTOCOL (vscode) MODE
====================================
WIRE FRAMING
------------
Every message in both directions is a header block, a blank line, then a UTF-8
JSON body:

    Content-Length: <number of BYTES in the JSON body>\r\n
    \r\n
    {...json...}

The length is a byte count of the UTF-8 encoding, not a character count. The
debugger writes and expects exactly this framing, with "Content-Length: "
spelled with that single space, and \r\n\r\n between header and body.

MESSAGE SHAPES
--------------
Requests you send:

    { "seq": 1, "type": "request", "command": "initialize",
      "arguments": { ... } }

  "seq" and "command" are required and "type" must be the string "request";
  a message missing them is answered with success=false and a "can't parse"
  message. "arguments" may be omitted (treated as an empty object).

Responses you get back:

    { "seq": 3, "type": "response", "request_seq": 1, "command": "initialize",
      "success": true, "body": { ... } }

  On failure, success is false and "message" carries the reason - either a
  message the command produced, or a generic
  "Failed command '<name>' : 0x<hresult>".

Events you get back:

    { "seq": 4, "type": "event", "event": "stopped", "body": { ... } }

  The debugger numbers its own outgoing "seq" independently of yours; correlate
  responses with requests through "request_seq", never through "seq".

HANDSHAKE ORDER
---------------
This is the exact order the debugger produces, and it is not the order the DAP
specification suggests you would guess:

    -> initialize                      (request)
    <- event "capabilities"            (emitted BEFORE the response)
    <- response to initialize          (body carries the same capabilities)
    <- event "initialized"             (emitted AFTER the response)
    -> launch  (or attach)
    -> setBreakpoints / setFunctionBreakpoints / setExceptionBreakpoints
    -> configurationDone
    <- event "stopped" / "output" / "thread" / "module" / ...

configurationDone, disconnect and terminate are handled synchronously: the
debugger will not start reading your next request until they are done. Every
other request is queued and executed on a worker.

SUPPORTED REQUESTS
------------------
The vscode interpreter implements exactly these commands; anything else gets a
success=false response (the underlying handler returns "not implemented"):

    initialize                configurationDone         launch
    attach                    disconnect                terminate
    setBreakpoints            setFunctionBreakpoints    setExceptionBreakpoints
    exceptionInfo             threads                   stackTrace
    scopes                    variables                 evaluate
    setVariable               setExpression             continue
    pause                     next                      stepIn
    stepOut                   cancel

CAPABILITIES REPORTED
---------------------
    supportsConfigurationDoneRequest  true
    supportsFunctionBreakpoints       true
    supportsConditionalBreakpoints    true
    supportTerminateDebuggee          true
    supportsSetVariable               true
    supportsSetExpression             true
    supportsTerminateRequest          true
    supportsCancelRequest             true
    supportsExceptionInfoRequest      true
    supportsExceptionFilterOptions    true
    supportsExceptionOptions          false
    exceptionBreakpointFilters        list of {filter,label} pairs

EVENTS EMITTED
--------------
    initialized    capabilities   stopped     continued    exited
    terminated     thread         module      breakpoint   process    output

  "output" carries body.category of "console", "stdout" or "stderr" plus
  body.output, and an optional body.source of {name, path}.
  "process" carries body.name, body.systemProcessId, body.isLocalProcess and
  body.startMethod.
  "breakpoint" carries body.reason of "new", "changed" or "removed" plus
  body.breakpoint.

REQUEST ARGUMENTS THAT MATTER
-----------------------------
launch:
    program              path to the program. If it ends in ".dll" the debugger
                         runs it as `dotnet <program> <args...>`; otherwise the
                         path is treated as an executable and run directly.
    args                 array of strings, optional
    cwd                  working directory, optional
    env                  object of name/value strings, optional; a malformed
                         env object is ignored rather than fatal
    stopAtEntry          bool, default false
    justMyCode           bool, default TRUE
    enableStepFiltering  bool, default TRUE
  If you started the debugger with `-- <program> [args]` on the command line,
  that program wins and the "program"/"args" members of the launch request are
  ignored.

attach:
    processId            number OR numeric string; anything else fails with an
                         invalid-argument response

setBreakpoints:
    source.path          required, the source file path
    breakpoints          required array of { line, condition? }
  Each call REPLACES the whole breakpoint set for that source file - send the
  full list every time, and send an empty array to clear the file.

setFunctionBreakpoints:
    breakpoints          array of { name, condition? }
  The name is parsed for an optional module and an optional parameter list:
      "MyApp.Program.Main"
      "MyApp.dll!MyApp.Program.Main"
      "MyApp.Program.Overloaded(int)"

setExceptionBreakpoints:
    filters              array of filter ids (from exceptionBreakpointFilters)
    filterOptions        array of objects, when supportsExceptionFilterOptions
                         is used

cancel:
    requestId            the seq of a queued request. Requests that configure
                         the debugger (initialize, launch, attach, disconnect,
                         terminate, configurationDone, setBreakpoints,
                         setFunctionBreakpoints, setExceptionBreakpoints) are
                         never cancelled; the cancel response then has
                         success=false with the message "CancelRequest is not
                         supported for requestId."
  Sending continue, next, stepIn, stepOut, disconnect or terminate also flushes
  cancellable requests already sitting in the queue - each of those gets a
  success=false response saying the operation was canceled. Do not treat that
  as an error in your client; treat it as a superseded request.

COMMAND TIMEOUT
---------------
Each queued request is given 15 seconds. If a handler has not returned by then,
the debugger answers with success=false and message "Command execution timed
out." and keeps going. Long evaluations (a property getter that blocks, a
deeply nested `variables` expansion) hit this.


GDB/MI AND CLI MODES
====================
--interpreter=mi is the classic GDB/MI machine interface: line-oriented text
with no Content-Length framing. You write one command per line and read result
records (`^done`, `^error`) and asynchronous records (`*stopped`) back. The
implemented command set includes -exec-run, -exec-continue, -exec-next,
-exec-step, -break-insert, -stack-list-frames, -var-create and -gdb-exit.
Prefer the vscode interpreter for new code; MI exists for GDB-style front ends.

--interpreter=cli is meant for a human at a terminal: `break Program.cs:66`,
`run`, `continue`, `next`, `step`, `finish`, `print <expr>`, `backtrace`,
`list`, `info break`, `delete <n>`, `set args ...`, `set just-my-code 0`,
`quit`, with command history and editing. It is also usable in batch form:
`--interpreter=cli -ex "..." -ex "..."` or `--interpreter=cli --command=<file>`.
The full command table is in docs/cli.md (link at the end of this file).

Debugging Release-built assemblies needs Just-My-Code off: `set just-my-code 0`
in CLI mode, or "justMyCode": false in the DAP launch arguments. Showing source
lines for a debuggee also requires <EmbedAllSources>true</EmbedAllSources> in
the DEBUGGED project.


COMPLETE EXAMPLES
=================
EXAMPLE 1 - end-to-end DAP session: launch a program, stop at a breakpoint
-------------------------------------------------------------------------
    using System;
    using System.Diagnostics;
    using System.IO;
    using System.Text;
    using System.Text.Json;
    using System.Text.Json.Nodes;

    var debuggerPath = Path.Combine(
        AppContext.BaseDirectory, "netcoredbg", "netcoredbg");

    var psi = new ProcessStartInfo(debuggerPath)
    {
        RedirectStandardInput = true,
        RedirectStandardOutput = true,
        RedirectStandardError = true,
        UseShellExecute = false,
    };
    psi.ArgumentList.Add("--interpreter=vscode");

    using var debugger = Process.Start(psi)
        ?? throw new InvalidOperationException("could not start netcoredbg");

    Stream toDebugger = debugger.StandardInput.BaseStream;
    Stream fromDebugger = debugger.StandardOutput.BaseStream;
    int nextSeq = 1;

    int Send(string command, object arguments = null)
    {
        int seq = nextSeq++;
        var message = new JsonObject
        {
            ["seq"] = seq,
            ["type"] = "request",
            ["command"] = command,
        };
        if (arguments != null)
        {
            message["arguments"] = JsonSerializer.SerializeToNode(arguments);
        }

        byte[] body = Encoding.UTF8.GetBytes(message.ToJsonString());
        byte[] header = Encoding.ASCII.GetBytes(
            "Content-Length: " + body.Length + "\r\n\r\n");
        toDebugger.Write(header, 0, header.Length);
        toDebugger.Write(body, 0, body.Length);
        toDebugger.Flush();
        return seq;
    }

    JsonNode Receive()
    {
        var line = new StringBuilder();
        int contentLength = -1;

        while (true)
        {
            int b = fromDebugger.ReadByte();
            if (b < 0) { return null; }             // debugger exited
            if (b != '\n') { line.Append((char)b); continue; }

            string header = line.ToString().TrimEnd('\r');
            line.Clear();
            if (header.Length == 0) { break; }      // end of header block
            if (header.StartsWith("Content-Length:", StringComparison.Ordinal))
            {
                contentLength = int.Parse(
                    header.Substring("Content-Length:".Length).Trim());
            }
        }

        if (contentLength < 0) { return null; }

        byte[] buffer = new byte[contentLength];
        int read = 0;
        while (read < contentLength)
        {
            int n = fromDebugger.Read(buffer, read, contentLength - read);
            if (n <= 0) { return null; }
            read += n;
        }
        return JsonNode.Parse(Encoding.UTF8.GetString(buffer));
    }

    // 1. handshake
    Send("initialize", new
    {
        clientID = "my-tool",
        adapterID = "coreclr",
        pathFormat = "path",
        linesStartAt1 = true,
        columnsStartAt1 = true,
    });

    // 2. start the debuggee (a .dll is run through `dotnet` automatically)
    Send("launch", new
    {
        program = "/abs/path/to/App.dll",
        cwd = "/abs/path/to",
        stopAtEntry = true,
        justMyCode = true,
    });

    // 3. breakpoints, then tell the debugger configuration is finished
    Send("setBreakpoints", new
    {
        source = new { path = "/abs/path/to/Program.cs" },
        breakpoints = new[] { new { line = 12 } },
    });
    Send("configurationDone");

    // 4. pump events until the debuggee is gone
    int? stoppedThread = null;
    while (true)
    {
        JsonNode message = Receive();
        if (message == null) { break; }

        string type = (string)message["type"];
        if (type == "event")
        {
            string name = (string)message["event"];
            if (name == "output")
            {
                Console.Write((string)message["body"]["output"]);
            }
            else if (name == "stopped")
            {
                stoppedThread = (int)message["body"]["threadId"];
                Console.WriteLine("stopped: " +
                    (string)message["body"]["reason"] +
                    " on thread " + stoppedThread);
                Send("stackTrace", new { threadId = stoppedThread, levels = 20 });
                Send("continue", new { threadId = stoppedThread });
            }
            else if (name == "terminated")
            {
                break;
            }
        }
        else if (type == "response")
        {
            Console.WriteLine("response " + (string)message["command"] +
                " success=" + (bool)message["success"]);
        }
    }

    Send("disconnect", new { restart = false });
    debugger.WaitForExit(5000);

EXAMPLE 2 - attach to a process that is already running
-------------------------------------------------------
Two equivalent routes. From the command line, before any protocol traffic:

    psi.ArgumentList.Add("--interpreter=vscode");
    psi.ArgumentList.Add("--attach");
    psi.ArgumentList.Add(targetProcessId.ToString());

or as a DAP request in place of "launch", after "initialize":

    Send("attach", new { processId = targetProcessId });
    Send("configurationDone");

EXAMPLE 3 - one-shot CLI batch run, no protocol client needed
-------------------------------------------------------------
    var psi = new ProcessStartInfo(debuggerPath) { UseShellExecute = false };
    psi.ArgumentList.Add("--interpreter=cli");
    psi.ArgumentList.Add("-ex");
    psi.ArgumentList.Add("break Program.cs:12");
    psi.ArgumentList.Add("--run");
    psi.ArgumentList.Add("--");
    psi.ArgumentList.Add("dotnet");
    psi.ArgumentList.Add("/abs/path/to/App.dll");
    using var cli = Process.Start(psi);
    cli.WaitForExit();

(-ex and --command are CLI-only, and --run requires the program after `--`.)

EXAMPLE 4 - server mode over TCP instead of stdio
-------------------------------------------------
    psi.ArgumentList.Add("--interpreter=vscode");
    psi.ArgumentList.Add("--server=4711");
    using var server = Process.Start(psi);

    using var client = new System.Net.Sockets.TcpClient();
    client.Connect("127.0.0.1", 4711);
    // same Content-Length framing, over client.GetStream()

Useful when the debugger runs on another machine or in another container. Not
combinable with --interpreter=cli.


ANDROID PACKAGES: DEBUGGING ON THE DEVICE
=========================================
WHAT THEY ARE
-------------
A .NET 11 Android app runs on CoreCLR, and CoreCLR's debugging interface
(ICorDebug) cannot be driven remotely - the debugger must run in the same
place as the app. So the Android packages carry the SAME netcoredbg, built with
the Android NDK for the device's ABI, plus its shim and managed helper:

    netcoredbg-android-arm64/   (from CodeBrix.Develop.Debug.AndroidArm64)
    netcoredbg-android-x64/     (from CodeBrix.Develop.Debug.AndroidX64)
        netcoredbg                    the debugger, with an Android
                                      compatibility layer built in
        libdbgshim.so                 finds the app's runtime, loads mscordbi
        ManagedPart.dll               symbol reader + expression evaluator
        Microsoft.CodeAnalysis*.dll   (4) Roslyn, used by ManagedPart

Your tool pushes that folder into the app's sandbox on the device, starts the
debugger there in DAP server mode, forwards the port with adb, and then speaks
exactly the DAP described above over TCP - attach instead of launch, because
Android starts the app.

PREREQUISITES ON THE DEBUGGED APP
---------------------------------
  - net11.0-android (CoreCLR). A .NET 10 Android app runs on MonoVM, which
    this debugger cannot attach to.
  - A DEBUG build installed with the SDK's Install target (fast deployment):
    `dotnet build -c Debug -t:Install -p:AdbTarget="-s <serial>"`. That makes
    the app debuggable and puts loose assemblies + the portable PDB on the
    device under /data/data/<pkg>/files/.__override__/<abi>/. A raw
    `adb install` of a Debug APK does neither.
  - `run-as <pkg>` must work: a debuggable app on any device, or a Google-APIs
    (not Play) emulator image.
  - The PDB records the build machine's absolute source paths; send those
    same paths in setBreakpoints and the debugger matches them.

THE SEQUENCE (all verified on arm64-v8a and x86_64)
---------------------------------------------------
    1. ABI:      adb -s S shell getprop ro.product.cpu.abi      -> arm64-v8a | x86_64
    2. Push the payload folder somewhere adb can write, then copy it INTO the
       sandbox as the app's own uid (the debugger must run as that uid):
         adb -s S push <payload>/. /data/local/tmp/codebrix-ncdbg
         adb -s S shell run-as PKG sh -c 'mkdir -p /data/data/PKG/ncdbg &&
             cp /data/local/tmp/codebrix-ncdbg/* /data/data/PKG/ncdbg/ &&
             chmod 755 /data/data/PKG/ncdbg/netcoredbg'
       (/data/local/tmp is noexec for the app uid; the sandbox copy is what runs.)
    3. Mark the app as the debug app BEFORE launching it, so ActivityManager
       does not ANR-kill it while it sits at a breakpoint:
         adb -s S shell am set-debug-app --persistent PKG
       (undo later with `am clear-debug-app`; applied to an already-running
       app it RESTARTS the app, which is why it comes first.)
    4. Launch the app FRESH and take its pid. A process that was debugged
       before answers a new attach with a transport resync and the attach
       times out, so always force-stop and relaunch:
         adb -s S shell am force-stop PKG
         adb -s S shell am start -n PKG/<activity>      (resolve the launcher
             activity with `cmd package resolve-activity --brief PKG`)
         adb -s S shell pidof PKG
    5. Find the app's native-library directory (it holds libcoreclr.so; the
       name is /data/app/.../lib/arm64 or .../lib/x86_64 - read it from the
       process rather than guessing):
         adb -s S shell run-as PKG cat /proc/<pid>/maps | grep -o '/data/app/[^ ]*/lib/[a-z0-9_]*' | sort -u
    6. Start the debugger in server mode inside the sandbox, backgrounded,
       with the environment the compatibility layer reads:
         adb -s S shell run-as PKG sh -c 'cd /data/data/PKG/ncdbg && (
             NETCOREDBG_ANDROID_ASSEMBLY_DIR=/data/data/PKG/files/.__override__/<abi>
             NETCOREDBG_ANDROID_CLR_DIR=<libdir>
             LD_LIBRARY_PATH=<libdir>
             TMPDIR=/data/data/PKG/cache
             NETCOREDBG_COMMAND_TIMEOUT_MS=60000
             ./netcoredbg --interpreter=vscode --server=4711 > ncdbg.out 2>&1 &)'
    7. Forward and connect:
         adb -s S forward tcp:<hostPort> tcp:4711
         TcpClient -> 127.0.0.1:<hostPort>   (retry briefly; the server may
                                              still be starting)
    8. DAP, attach flavour:
         initialize -> attach {processId: <pid>} (send, do not wait)
         -> initialized event -> setBreakpoints per file
         -> configurationDone   <- the REAL attach happens inside this request
                                   (about 250 ms on both device kinds)
         -> attach response -> then stopped / stackTrace / scopes / variables /
            evaluate / next / stepIn / stepOut / continue /
            setExceptionBreakpoints exactly as in the local session.
    9. End: disconnect {terminateDebuggee: false} detaches and leaves the app
       running (true terminates it); the debugger exits after disconnect.
       Then `adb forward --remove tcp:<hostPort>` and, when you are done
       debugging that app, `am clear-debug-app`.

THE ENVIRONMENT VARIABLES (the built-in Android compatibility layer)
--------------------------------------------------------------------
    NETCOREDBG_ANDROID_ASSEMBLY_DIR
        The app's assembly directory (/data/data/<pkg>/files/.__override__/<abi>).
        The runtime's debugging library opens managed assemblies and PDBs next
        to libcoreclr.so, which on Android is a read-only APK folder holding
        only .so files; when such an open fails, the debugger retries it here.
        The debugger's own hosted runtime (which runs ManagedPart.dll) also
        takes its framework assemblies from here. REQUIRED - without it the
        attach fails with 0x80004005.
    NETCOREDBG_ANDROID_CLR_DIR
        The native-library directory of the app (from step 5). Informational
        for the layer; LD_LIBRARY_PATH must point there too so the debugger's
        hosted runtime finds libcoreclr.so's native companions.
    NETCOREDBG_ANDROID_TRACE
        Optional: a file path; the layer appends one line per redirect or
        liveness-probe decision. Diagnostics only.
    NETCOREDBG_COMMAND_TIMEOUT_MS
        Optional (any platform): the per-request timeout, default 15000.
        60000 is a safe value for device sessions.
    TMPDIR
        Must be writable by the app uid (/data/data/<pkg>/cache): the debug
        transport and --log use it.
    Always on, no variable: the liveness probe kill(pid, 0) that Android's
    SELinux denies even between processes of the same uid is answered from
    /proc/<pid> instead.

WHAT WORKS ON THE DEVICE
------------------------
Attach; line breakpoints (set before or after attach; UI thread, thread-pool
threads, loops, async continuations); stack traces with file:line for app
frames (framework frames without); locals, fields, arrays, List<T>, full
object expansion of `this`; arithmetic expressions; next / stepIn / stepOut;
first-chance exception stops (setExceptionBreakpoints ["all"]) with
exceptionInfo and the throw-site stack; detach leaving the app running.

Known limitations (not Android-specific unless stated): string member access
in expressions (`s.Length`) fails - use `s.get_Length()`; explicit METHOD-CALL
evaluation (`x.ToString()`, `Foo.Bar(3)`) returns nothing on Android (works
on Linux); `$exception` does not expand.


MINIMUM VIABLE PROJECT
======================
DebugHost.csproj
    <Project Sdk="Microsoft.NET.Sdk">

      <PropertyGroup>
        <OutputType>Exe</OutputType>
        <TargetFramework>net10.0</TargetFramework>
        <Nullable>disable</Nullable>
      </PropertyGroup>

      <PropertyGroup>
        <DebuggerArchRid Condition="'$(RuntimeIdentifier)' != ''">$(RuntimeIdentifier)</DebuggerArchRid>
        <DebuggerArchRid Condition="'$(DebuggerArchRid)' == ''">$(NETCoreSdkRuntimeIdentifier)</DebuggerArchRid>
      </PropertyGroup>

      <ItemGroup>
        <PackageReference Include="CodeBrix.Develop.Debug.LinuxX64"
                          Version="*"
                          Condition="'$(DebuggerArchRid)' == 'linux-x64'" />
        <PackageReference Include="CodeBrix.Develop.Debug.LinuxArm64"
                          Version="*"
                          Condition="'$(DebuggerArchRid)' == 'linux-arm64'" />
      </ItemGroup>

    </Project>

Program.cs
    using System;
    using System.Diagnostics;
    using System.IO;

    string debuggerPath = Path.Combine(
        AppContext.BaseDirectory, "netcoredbg", "netcoredbg");

    if (!File.Exists(debuggerPath))
    {
        Console.Error.WriteLine(
            "netcoredbg was not copied to the output folder - is exactly one " +
            "CodeBrix.Develop.Debug.* package referenced for this architecture?");
        return 1;
    }

    var psi = new ProcessStartInfo(debuggerPath)
    {
        RedirectStandardOutput = true,
        UseShellExecute = false,
    };
    psi.ArgumentList.Add("--buildinfo");

    using var probe = Process.Start(psi);
    Console.WriteLine(probe.StandardOutput.ReadToEnd());
    probe.WaitForExit();
    return probe.ExitCode;

    // Prints build type, build date, target OS and target architecture -
    // the cheapest proof that the right architecture landed in the output
    // folder and that the executable bit survived.


PERFORMANCE TIPS
================
  - Start the debugger ONCE per debug session, not per request. Process
    startup pays for loading libdbgshim.so and, on the first symbol read,
    spinning up CoreCLR plus the Roslyn scripting stack inside the debuggee's
    runtime.
  - Every queued request has a 15-second budget. Keep `variables` expansions
    shallow and lazy: request child variables only for the scope the user
    actually opened, not for the whole tree.
  - Leave justMyCode and enableStepFiltering at their default (true) unless
    you must step into framework code. Both defaults exist to keep stepping
    from walking through machine-generated frames.
  - setBreakpoints replaces the whole set for a file, so batch all of a file's
    breakpoints into one request instead of sending one request per line.
  - Read stdout on a dedicated loop or thread. The debugger writes events
    (notably "output" from the debuggee) at any time; a client that only reads
    while waiting for a specific response will stall the pipe and, once the OS
    buffer fills, deadlock the debugger.
  - Turn --engineLogging OFF in production. Without a path it doubles the
    traffic on your own stdout by re-emitting every message as an output event.
  - The copy into the output folder is PreserveNewest, so incremental builds do
    not re-copy the ~9 MB of binaries; the chmod target, however, runs after
    every build.


COMMON PITFALLS TO AVOID
========================
  - Referencing BOTH Linux architecture packages. They copy to the same
    netcoredbg/ folder and will overwrite each other's files; the app then
    fails with an exec-format error at run time. Reference exactly one.
    (The two ANDROID packages are the opposite case: separate folders, both
    may be referenced.)
  - Android: attaching to an app process that was debugged before. The
    runtime's transport answers with a resync and the attach times out.
    Force-stop and relaunch, then attach once.
  - Android: calling `am set-debug-app` AFTER the app is running. It restarts
    the app and the pid you captured is dead. Set it, THEN launch.
  - Android: running the debugger from /data/local/tmp. That folder is
    noexec for the app's uid; copy into /data/data/<pkg>/ncdbg with run-as.
  - Android: omitting NETCOREDBG_ANDROID_ASSEMBLY_DIR. The attach fails with
    0x80004005 because the runtime's debugging library cannot open the
    framework assemblies next to libcoreclr.so.
  - Android: using `adb install` for a Debug build. Fast deployment means the
    APK has no assemblies; the app exits at startup. Use `-t:Install`.
  - Forgetting --interpreter. With stdin redirected, the default is GDB/MI,
    not DAP and not CLI.
  - Referencing the package from a class LIBRARY and expecting the app to get
    the debugger. The targets file ships in the package's build/ folder, not
    buildTransitive/, so it applies only to the project that references the
    package directly. Reference it from the executable project.
  - Publishing a Linux app from a Windows host. The chmod targets are gated on
    '$(OS)' == 'Unix', so a Windows build machine leaves netcoredbg without its
    executable bit and the launch fails with "permission denied". Restore it on
    the Linux side (chmod +x, or the +x bit inside your container image or tar
    archive).
  - Copying just the netcoredbg binary somewhere else. It resolves
    libdbgshim.so and ManagedPart.dll from its own directory; move the whole
    netcoredbg/ folder or nothing.
  - Zipping the output folder with a tool that drops permissions. The same
    exec-bit problem, one layer later.
  - Using AppDomain.CurrentDomain.BaseDirectory or Environment.CurrentDirectory
    instead of AppContext.BaseDirectory to build the path. The debugger sits
    next to the app's assemblies, not next to whatever directory the user
    happened to be in.
  - Computing Content-Length from string.Length. It is a UTF-8 BYTE count;
    non-ASCII in an evaluate expression or a path will desynchronize the stream
    if you count characters.
  - Correlating a response by "seq". Use "request_seq"; the debugger's own
    "seq" counter is independent of yours.
  - Sending -ex or --command with the vscode or mi interpreter, or --server
    with the cli interpreter, or --engineLogging with anything but vscode. The
    debugger exits immediately with an error on stderr - capture stderr so you
    can see it.
  - Expecting a stopped event without configurationDone. Nothing runs until
    that request is answered.
  - Treating "The operation was canceled." responses as failures. Sending
    continue/next/stepIn/stepOut/disconnect/terminate deliberately cancels
    queued non-configuration requests.
  - Debugging a Release build and seeing no breakpoints. Turn Just-My-Code off
    (justMyCode:false, or `set just-my-code 0`), and build the DEBUGGED project
    with <EmbedAllSources>true</EmbedAllSources> if you also want source lines.
  - Assuming the debugged program's runtime does not matter. The debugger
    attaches to the CoreCLR of the debuggee, so a .NET runtime has to be
    installed on that machine; the debuggee also needs its PDBs, or the
    debugger cannot resolve a single breakpoint.


WHAT THESE PACKAGES DO NOT DO
=============================
  - No Windows and no macOS package. The upstream debugger builds on both, but
    only linux-x64, linux-arm64, android-arm64 and android-x64 are published
    here.
  - No riscv64, arm32, x86, loongarch64 package, and no 32-bit Android ABI
    (armeabi-v7a, x86). The upstream sources support those architectures; no
    package carries them.
  - No debugging of .NET 10 (MonoVM) Android apps, and no Mono soft-debugger
    client. Only CoreCLR (.NET 11+) Android apps can be debugged.
  - No adb, no device management, no app install. The Android packages are the
    on-device payload; the tool that uses them drives adb itself.
  - No managed API, no wrapper, no types, no extension methods. Nothing to
    reference in C# code - the package's entire contract is "a working
    debugger appears at netcoredbg/netcoredbg in your output folder".
  - No DAP or MI CLIENT. You write the protocol client (or bring one); the
    package gives you the server end of the conversation.
  - No interop (mixed native/managed) debugging. The shipped binary is built
    without that option, so --interop-debugging is not among its accepted
    options and passing it is a startup error. The mode is described in
    docs/interop.md for completeness only.
  - No Hot Reload option. --hot-reload is likewise not compiled into the
    shipped binary.
  - No Tizen/dlog integration paths, no sdb helpers.
  - No debugging of CoreCLR itself, and no debugging of native code.
  - No RuntimeIdentifier handling, RID-specific asset selection, or
    architecture detection. The targets copy unconditionally; the conditional
    PackageReference above is yours to write.
  - No automatic PDB acquisition, no symbol server. The debuggee's own PDBs
    must be on disk beside it.
  - Not a self-contained debugger host: it does not bring a .NET runtime with
    it.


WORKING EXAMPLES ON GITHUB
==========================
The fork keeps the upstream documentation and the upstream protocol test-suite,
which together are the best worked examples of driving the debugger.

Documentation:
    https://github.com/ellisnet/CodeBrix.Develop.Debug/blob/codebrix/docs/cli.md
        Full CLI command table (break, run, continue, next, step, finish,
        print, backtrace, list, info, set, delete, catch, attach, detach,
        source, save, help) with worked terminal transcripts.
    https://github.com/ellisnet/CodeBrix.Develop.Debug/blob/codebrix/docs/interop.md
        What interop (mixed native/managed) debugging is and its restrictions.
        Not enabled in the shipped binaries - background reading.
    https://github.com/ellisnet/CodeBrix.Develop.Debug/blob/codebrix/docs/stepping.md
        How stepping is implemented, including async/await stepping via yield
        and resume offsets - useful when your stepping requests behave in ways
        the DAP specification alone does not explain.

Protocol clients you can read:
    https://github.com/ellisnet/CodeBrix.Develop.Debug/tree/codebrix/test-suite
        Thirty VSCodeTest* projects and forty-four MITest* projects, each a
        small C# program that starts the debugger and drives a complete
        session.
    https://github.com/ellisnet/CodeBrix.Develop.Debug/blob/codebrix/test-suite/VSCodeTestBreakpoint/Program.cs
        The clearest end-to-end DAP flow: initialize, launch(stopAtEntry),
        setBreakpoints, configurationDone, wait for stopped(reason "entry"),
        continue, wait for stopped(reason "breakpoint"), disconnect.
    https://github.com/ellisnet/CodeBrix.Develop.Debug/blob/codebrix/test-suite/NetcoreDbgTest/VSCode/VSCodeLocaleDebuggerClient.cs
        A minimal, readable implementation of the Content-Length framing on
        both the send and the receive side.
    https://github.com/ellisnet/CodeBrix.Develop.Debug/tree/codebrix/test-suite/VSCodeTestAttach
        The attach flow.
    https://github.com/ellisnet/CodeBrix.Develop.Debug/tree/codebrix/test-suite/VSCodeTestEvaluate
        Expression evaluation and the variables/scopes tree.


QUICK REFERENCE CARD
====================
    Pick a package
      linux-x64                 CodeBrix.Develop.Debug.LinuxX64
      linux-arm64               CodeBrix.Develop.Debug.LinuxArm64
      how many (Linux)          exactly one
      Android arm64-v8a         CodeBrix.Develop.Debug.AndroidArm64
      Android x86_64            CodeBrix.Develop.Debug.AndroidX64
      how many (Android)        either or both (separate folders)

    Path to the debugger
      Path.Combine(AppContext.BaseDirectory, "netcoredbg", "netcoredbg")
      Android payload folders   netcoredbg-android-arm64/  netcoredbg-android-x64/

    Android in one breath
      set-debug-app -> force-stop -> am start -> pidof -> run-as sh -c
      'NETCOREDBG_ANDROID_ASSEMBLY_DIR=... LD_LIBRARY_PATH=<libdir>
       TMPDIR=<cache> ./netcoredbg --interpreter=vscode --server=4711 &'
      -> adb forward tcp:H tcp:4711 -> initialize, attach{pid}, initialized,
      setBreakpoints, configurationDone (does the attach) -> debug as usual

    Start it
      DAP over stdio            --interpreter=vscode
      GDB/MI over stdio         --interpreter=mi
      interactive CLI           --interpreter=cli
      DAP/MI over TCP           --interpreter=vscode --server[=4711]
      attach                    --attach <pid>
      run at once               --run -- dotnet App.dll args
      CLI batch                 --interpreter=cli -ex "break Program.cs:12"
      protocol log              --engineLogging[=<path>]   (vscode only)
      internal log              --log[=<path>]  or  LOG_OUTPUT=<path>
      identify the binary       --version | --buildinfo | --help

    DAP framing
      Content-Length: <utf8 byte count>\r\n\r\n<json>

    DAP order
      initialize -> (capabilities event) -> response -> (initialized event)
      -> launch|attach -> setBreakpoints -> configurationDone -> stopped

    DAP requests
      initialize configurationDone launch attach disconnect terminate
      setBreakpoints setFunctionBreakpoints setExceptionBreakpoints
      exceptionInfo threads stackTrace scopes variables evaluate
      setVariable setExpression continue pause next stepIn stepOut cancel

    DAP events
      initialized capabilities stopped continued exited terminated
      thread module breakpoint process output

    Defaults to remember
      no --interpreter + redirected stdin  ->  GDB/MI
      justMyCode                           ->  true
      enableStepFiltering                  ->  true
      stopAtEntry                          ->  false
      --server port                        ->  4711
      per-request timeout                  ->  15 seconds

    Sanity checks
      output folder             <output>/netcoredbg/netcoredbg exists
      executable bit            ls -l shows -rwxr-xr-x
      it runs                   ./netcoredbg --version
================================================================================
