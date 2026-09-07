//
// Program.cs
//
// Copyright (c) 2026 Jeremy Ellis and contributors
// SPDX-License-Identifier: MIT
//

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace DapProbe;

/// <summary>
/// A plain Debug Adapter Protocol client that connects to a netcoredbg
/// running in server mode on an Android device (reached through an
/// adb-forwarded TCP port), attaches to the sample app, and drives a scripted
/// session: breakpoints, a button tap, stack trace, scopes and variables,
/// evaluation, stepping, a first-chance exception stop, and a detach that
/// leaves the app running. Prints a VERDICT at the end and writes a full wire
/// transcript.
/// </summary>
static class Program
{
    static int Main(string[] args)
    {
        var options = ProbeOptions.Parse(args);
        if (options == null)
        {
            Console.Error.WriteLine(ProbeOptions.Usage);
            return 2;
        }
        try
        {
            return new ProbeSession(options).RunAsync().GetAwaiter().GetResult() ? 0 : 1;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"PROBE FAILED: {ex}");
            return 1;
        }
    }
}

/// <summary>Command-line options of the probe.</summary>
sealed class ProbeOptions
{
    public int Port;
    public int ProcessId;
    public string Serial = "";
    public string Package = "com.codebrix.simpledebugapp";
    public string SourceDirectory = "";
    public string Transcript = "";
    public int ConnectTimeoutSeconds = 30;
    public int AttachTimeoutSeconds = 90;

    public const string Usage =
        "usage: DapProbe --port <hostPort> --pid <pid> --serial <adb serial> --source-dir <dir of MainActivity.cs>\n" +
        "               [--package <id>] [--transcript <file>] [--connect-timeout <s>] [--attach-timeout <s>]";

    public static ProbeOptions Parse(string[] args)
    {
        var o = new ProbeOptions();
        for (var i = 0; i < args.Length; i++)
        {
            string Next() => ++i < args.Length ? args[i] : throw new ArgumentException($"missing value after {args[i - 1]}");
            switch (args[i])
            {
                case "--port": o.Port = int.Parse(Next(), CultureInfo.InvariantCulture); break;
                case "--pid": o.ProcessId = int.Parse(Next(), CultureInfo.InvariantCulture); break;
                case "--serial": o.Serial = Next(); break;
                case "--package": o.Package = Next(); break;
                case "--source-dir": o.SourceDirectory = Next(); break;
                case "--transcript": o.Transcript = Next(); break;
                case "--connect-timeout": o.ConnectTimeoutSeconds = int.Parse(Next(), CultureInfo.InvariantCulture); break;
                case "--attach-timeout": o.AttachTimeoutSeconds = int.Parse(Next(), CultureInfo.InvariantCulture); break;
                default: return null;
            }
        }
        if (o.Port <= 0 || o.ProcessId <= 0 || o.Serial.Length == 0 || o.SourceDirectory.Length == 0)
            return null;
        return o;
    }
}

/// <summary>
/// Content-Length framed JSON over a stream: requests with response
/// correlation, and an event queue the scripted session waits on.
/// </summary>
sealed class DapConnection : IDisposable
{
    readonly Stream stream;
    readonly TextWriter transcript;
    readonly object writeGate = new object();
    readonly Dictionary<int, TaskCompletionSource<JsonDocument>> pending = new Dictionary<int, TaskCompletionSource<JsonDocument>>();
    readonly List<(string Name, JsonElement Body)> events = new List<(string, JsonElement)>();
    readonly SemaphoreSlim eventSignal = new SemaphoreSlim(0);
    int nextSeq;
    volatile bool closed;

    public DapConnection(Stream stream, TextWriter transcript)
    {
        this.stream = stream;
        this.transcript = transcript;
        new Thread(ReadLoop) { IsBackground = true, Name = "dap-read" }.Start();
    }

    public bool IsClosed => closed;

    public async Task<JsonElement> RequestAsync(string command, object arguments, TimeSpan timeout, bool throwOnFailure = true)
    {
        var seq = Interlocked.Increment(ref nextSeq);
        var completion = new TaskCompletionSource<JsonDocument>(TaskCreationOptions.RunContinuationsAsynchronously);
        lock (pending)
            pending[seq] = completion;
        var payload = JsonSerializer.SerializeToUtf8Bytes(new { seq, type = "request", command, arguments });
        Write(payload);
        using var response = await completion.Task.WaitAsync(timeout).ConfigureAwait(false);
        var root = response.RootElement;
        var success = root.TryGetProperty("success", out var s) && s.GetBoolean();
        if (!success && throwOnFailure)
        {
            var message = root.TryGetProperty("message", out var m) ? m.GetString() : "(no message)";
            throw new InvalidOperationException($"'{command}' failed: {message}");
        }
        return root.TryGetProperty("body", out var body) ? body.Clone() : default;
    }

    /// <summary>Sends a request without waiting for its response; returns the task to await later.</summary>
    public Task<JsonElement> RequestLaterAsync(string command, object arguments, TimeSpan timeout)
        => RequestAsync(command, arguments, timeout);

    public async Task<JsonElement?> WaitForEventAsync(string name, TimeSpan timeout, Func<JsonElement, bool> predicate = null)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (true)
        {
            lock (events)
            {
                for (var i = 0; i < events.Count; i++)
                {
                    if (events[i].Name == name && (predicate == null || predicate(events[i].Body)))
                    {
                        var body = events[i].Body;
                        events.RemoveAt(i);
                        return body;
                    }
                }
            }
            var remaining = deadline - DateTime.UtcNow;
            if (remaining <= TimeSpan.Zero || closed)
                return null;
            await eventSignal.WaitAsync(remaining).ConfigureAwait(false);
        }
    }

    public void DiscardEvents(string name)
    {
        lock (events)
            events.RemoveAll(e => e.Name == name);
    }

    void Write(byte[] payload)
    {
        var header = Encoding.ASCII.GetBytes($"Content-Length: {payload.Length}\r\n\r\n");
        lock (writeGate)
        {
            transcript.WriteLine($"[{DateTime.Now:HH:mm:ss.fff}] -> {Encoding.UTF8.GetString(payload)}");
            transcript.Flush();
            stream.Write(header, 0, header.Length);
            stream.Write(payload, 0, payload.Length);
            stream.Flush();
        }
    }

    void ReadLoop()
    {
        try
        {
            while (!closed)
            {
                var payload = ReadMessage();
                if (payload == null)
                    break;
                lock (writeGate)
                {
                    transcript.WriteLine($"[{DateTime.Now:HH:mm:ss.fff}] <- {Encoding.UTF8.GetString(payload)}");
                    transcript.Flush();
                }
                Dispatch(payload);
            }
        }
        catch (Exception ex)
        {
            if (!closed)
                Console.Error.WriteLine($"read loop ended: {ex.Message}");
        }
        closed = true;
        lock (pending)
        {
            foreach (var p in pending.Values)
                p.TrySetException(new IOException("connection closed"));
            pending.Clear();
        }
        eventSignal.Release();
    }

    byte[] ReadMessage()
    {
        var contentLength = -1;
        var line = new StringBuilder();
        while (true)
        {
            var b = stream.ReadByte();
            if (b < 0)
                return null;
            if (b == '\n')
            {
                var text = line.ToString().TrimEnd('\r');
                line.Clear();
                if (text.Length == 0)
                    break;
                if (text.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase))
                    contentLength = int.Parse(text.Substring("Content-Length:".Length).Trim(), CultureInfo.InvariantCulture);
            }
            else
            {
                line.Append((char) b);
            }
        }
        if (contentLength < 0)
            throw new InvalidDataException("message without Content-Length");
        var payload = new byte[contentLength];
        var read = 0;
        while (read < contentLength)
        {
            var n = stream.Read(payload, read, contentLength - read);
            if (n <= 0)
                return null;
            read += n;
        }
        return payload;
    }

    void Dispatch(byte[] payload)
    {
        var document = JsonDocument.Parse(payload);
        var root = document.RootElement;
        var type = root.TryGetProperty("type", out var t) ? t.GetString() : "";
        if (type == "response")
        {
            var requestSeq = root.GetProperty("request_seq").GetInt32();
            TaskCompletionSource<JsonDocument> completion;
            lock (pending)
                pending.Remove(requestSeq, out completion);
            if (completion != null)
                completion.TrySetResult(document);
            else
                document.Dispose();
            return;
        }
        using (document)
        {
            if (type == "event")
            {
                var name = root.TryGetProperty("event", out var e) ? e.GetString() : "";
                var body = root.TryGetProperty("body", out var b) ? b.Clone() : default;
                lock (events)
                    events.Add((name, body));
                eventSignal.Release();
            }
        }
    }

    public void Dispose()
    {
        closed = true;
        try { stream.Dispose(); } catch { /* best effort */ }
    }
}

/// <summary>Runs adb commands against the device (button taps, liveness checks).</summary>
static class Adb
{
    public static string Run(string serial, params string[] arguments)
    {
        var startInfo = new ProcessStartInfo("adb")
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
        };
        startInfo.ArgumentList.Add("-s");
        startInfo.ArgumentList.Add(serial);
        foreach (var a in arguments)
            startInfo.ArgumentList.Add(a);
        using var process = Process.Start(startInfo);
        var stdout = process.StandardOutput.ReadToEnd();
        process.StandardError.ReadToEnd();
        process.WaitForExit();
        return stdout.Replace("\r", "");
    }

    /// <summary>Taps the view with the given resource id, located by its on-screen bounds (resolution-independent).</summary>
    public static bool TapById(string serial, string package, string id)
    {
        Run(serial, "shell", "uiautomator", "dump", "/sdcard/ui.xml");
        var xml = Run(serial, "shell", "cat", "/sdcard/ui.xml");
        var match = Regex.Match(xml, $"resource-id=\"{Regex.Escape(package)}:id/{Regex.Escape(id)}\"[^>]*bounds=\"\\[(\\d+),(\\d+)\\]\\[(\\d+),(\\d+)\\]\"");
        if (!match.Success)
        {
            // The bounds attribute can precede resource-id depending on the dump; try the other order.
            match = Regex.Match(xml, $"bounds=\"\\[(\\d+),(\\d+)\\]\\[(\\d+),(\\d+)\\]\"[^>]*resource-id=\"{Regex.Escape(package)}:id/{Regex.Escape(id)}\"");
            if (!match.Success)
                return false;
        }
        var x = (int.Parse(match.Groups[1].Value) + int.Parse(match.Groups[3].Value)) / 2;
        var y = (int.Parse(match.Groups[2].Value) + int.Parse(match.Groups[4].Value)) / 2;
        Run(serial, "shell", "input", "tap", x.ToString(CultureInfo.InvariantCulture), y.ToString(CultureInfo.InvariantCulture));
        return true;
    }

    public static int? PidOf(string serial, string package)
    {
        var text = Run(serial, "shell", "pidof", package).Trim();
        var first = text.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        return first.Length > 0 && int.TryParse(first[0], out var pid) ? pid : null;
    }
}

/// <summary>The scripted Part 4 session and its verdict.</summary>
sealed class ProbeSession
{
    readonly ProbeOptions options;
    readonly List<(string Check, bool Ok, string Detail)> verdict = new List<(string, bool, string)>();
    readonly TimeSpan requestTimeout = TimeSpan.FromSeconds(30);

    public ProbeSession(ProbeOptions options)
    {
        this.options = options;
    }

    void Log(string text) => Console.WriteLine($"[{DateTime.Now:HH:mm:ss}] {text}");

    void Check(string name, bool ok, string detail = "")
    {
        verdict.Add((name, ok, detail));
        Log($"{(ok ? "OK  " : "FAIL")} {name}{(detail.Length > 0 ? " -- " + detail : "")}");
    }

    public async Task<bool> RunAsync()
    {
        using var transcript = options.Transcript.Length > 0
            ? new StreamWriter(options.Transcript, append: false)
            : TextWriter.Null;

        var mainActivity = Path.Combine(options.SourceDirectory, "MainActivity.cs");
        var calculator = Path.Combine(options.SourceDirectory, "Calculator.cs");

        // 1. connect (the server may still be starting)
        var client = new TcpClient();
        var connectDeadline = DateTime.UtcNow + TimeSpan.FromSeconds(options.ConnectTimeoutSeconds);
        var connectStopwatch = Stopwatch.StartNew();
        while (true)
        {
            try
            {
                await client.ConnectAsync("127.0.0.1", options.Port).ConfigureAwait(false);
                break;
            }
            catch (SocketException) when (DateTime.UtcNow < connectDeadline)
            {
                client.Dispose();
                client = new TcpClient();
                await Task.Delay(250).ConfigureAwait(false);
            }
            catch (SocketException ex)
            {
                Check("connected over TCP (adb forward)", false, ex.Message);
                PrintVerdict();
                return false;
            }
        }
        Check("connected over TCP (adb forward)", true, $"127.0.0.1:{options.Port} after {connectStopwatch.ElapsedMilliseconds} ms");

        using var dap = new DapConnection(client.GetStream(), transcript);

        // 2. initialize
        var capabilities = await dap.RequestAsync("initialize", new
        {
            clientID = "codebrix-dap-probe",
            clientName = "CodeBrix DAP probe",
            adapterID = "coreclr",
            linesStartAt1 = true,
            columnsStartAt1 = true,
            pathFormat = "path",
            locale = "en-US",
        }, requestTimeout).ConfigureAwait(false);
        Check("initialize", true, $"supportsConfigurationDoneRequest={capabilities.TryGetProperty("supportsConfigurationDoneRequest", out var c) && c.GetBoolean()}");

        // 3. attach (the response comes after configurationDone completes the real attach)
        var attachTask = dap.RequestLaterAsync("attach", new { processId = options.ProcessId },
            TimeSpan.FromSeconds(options.AttachTimeoutSeconds));

        var initialized = await dap.WaitForEventAsync("initialized", requestTimeout).ConfigureAwait(false);
        Check("initialized event", initialized != null);

        // 4. breakpoints BEFORE the attach (deferred binding on module load)
        var bp1 = await dap.RequestAsync("setBreakpoints", new
        {
            source = new { path = mainActivity },
            breakpoints = new[] { new { line = 47 } },
        }, requestTimeout).ConfigureAwait(false);
        Check("setBreakpoints accepted before attach", true,
            $"MainActivity.cs:47 verified={Verified(bp1)} (unverified before attach is normal)");

        // 5. configurationDone performs the attach
        var attachStopwatch = Stopwatch.StartNew();
        JsonElement configurationDone;
        try
        {
            configurationDone = await dap.RequestAsync("configurationDone", null,
                TimeSpan.FromSeconds(options.AttachTimeoutSeconds)).ConfigureAwait(false);
            await attachTask.ConfigureAwait(false);
            Check("attach completed (configurationDone + attach responses)", true, $"{attachStopwatch.ElapsedMilliseconds} ms");
        }
        catch (Exception ex)
        {
            Check("attach completed (configurationDone + attach responses)", false, $"{ex.Message} after {attachStopwatch.ElapsedMilliseconds} ms");
            PrintVerdict();
            return false;
        }

        // Breakpoints bind as modules load: netcoredbg reports that with "breakpoint" events (reason changed).
        await Task.Delay(1500).ConfigureAwait(false);
        var threads = await dap.RequestAsync("threads", null, requestTimeout).ConfigureAwait(false);
        var threadCount = threads.TryGetProperty("threads", out var threadList) ? threadList.GetArrayLength() : 0;
        Check("threads listed", threadCount > 0, $"{threadCount} threads");

        // 6. tap Count -> breakpoint 1 on the UI thread
        dap.DiscardEvents("stopped");
        var tapped = Adb.TapById(options.Serial, options.Package, "count_button");
        Check("tapped count_button", tapped);
        var stopped = await dap.WaitForEventAsync("stopped", TimeSpan.FromSeconds(20)).ConfigureAwait(false);
        var reason = stopped?.TryGetProperty("reason", out var r) == true ? r.GetString() : "";
        var threadId = stopped?.TryGetProperty("threadId", out var tid) == true ? tid.GetInt32() : -1;
        Check("breakpoint hit (stopped event)", stopped != null && reason == "breakpoint", $"reason={reason} threadId={threadId}");
        if (stopped == null)
        {
            PrintVerdict();
            return false;
        }

        // 7. stack trace with file:line
        var frames = await dap.RequestAsync("stackTrace", new { threadId, startFrame = 0, levels = 20 }, requestTimeout).ConfigureAwait(false);
        var top = TopFrame(frames);
        Check("stackTrace top frame has file:line", top.File.EndsWith("MainActivity.cs", StringComparison.Ordinal) && top.Line == 47,
            $"{top.Name} at {top.File}:{top.Line}");

        // 8. scopes + variables
        var scopes = await dap.RequestAsync("scopes", new { frameId = top.Id }, requestTimeout).ConfigureAwait(false);
        var localsReference = 0;
        foreach (var scope in scopes.GetProperty("scopes").EnumerateArray())
        {
            if (scope.GetProperty("name").GetString() == "Locals")
                localsReference = scope.GetProperty("variablesReference").GetInt32();
        }
        var variableNames = new List<string>();
        if (localsReference > 0)
        {
            var variables = await dap.RequestAsync("variables", new { variablesReference = localsReference }, requestTimeout).ConfigureAwait(false);
            foreach (var v in variables.GetProperty("variables").EnumerateArray())
                variableNames.Add($"{v.GetProperty("name").GetString()}={v.GetProperty("value").GetString()}");
        }
        Check("scopes/variables list locals", variableNames.Count > 0, string.Join(", ", variableNames));

        // 9. evaluate a field and the object graph (func-eval path)
        var count = await EvaluateAsync(dap, "_count", top.Id).ConfigureAwait(false);
        Check("evaluate _count", count.Ok && int.TryParse(count.Result, out _), count.Result);
        var self = await EvaluateAsync(dap, "this", top.Id).ConfigureAwait(false);
        Check("evaluate this (object expansion, func-eval)", self.Ok && self.VariablesReference > 0, $"{self.Result} ref={self.VariablesReference}");
        if (self.VariablesReference > 0)
        {
            var members = await dap.RequestAsync("variables", new { variablesReference = self.VariablesReference }, requestTimeout).ConfigureAwait(false);
            var names = new List<string>();
            foreach (var v in members.GetProperty("variables").EnumerateArray())
                names.Add(v.GetProperty("name").GetString());
            Check("this expands to members", names.Contains("_count"), $"{names.Count} members: {string.Join(", ", names.GetRange(0, Math.Min(names.Count, 8)))}...");
        }

        // 10. step over line 47 (the DescribeCount call, no breakpoint inside it yet), step into
        //     ShowCount() on line 48, step back out
        var next = await StepAsync(dap, "next", threadId).ConfigureAwait(false);
        Check("next (step over the DescribeCount call)", next != null && next.Value.File.EndsWith("MainActivity.cs", StringComparison.Ordinal) && next.Value.Line == 48, Describe(next));
        var stepIn = await StepAsync(dap, "stepIn", threadId).ConfigureAwait(false);
        Check("stepIn (into ShowCount)", stepIn != null && stepIn.Value.Name.Contains("ShowCount"), Describe(stepIn));
        var stepOut = await StepAsync(dap, "stepOut", threadId).ConfigureAwait(false);
        Check("stepOut (back to OnCountClicked)", stepOut != null && stepOut.Value.Name.Contains("OnCountClicked"), Describe(stepOut));

        // 11. add a breakpoint in a second file WHILE ATTACHED, continue; tap Count again -> breakpoint 1
        //     again, step into DescribeCount, then continue into breakpoint 2 (Calculator.cs:56)
        var bp2 = await dap.RequestAsync("setBreakpoints", new
        {
            source = new { path = calculator },
            breakpoints = new[] { new { line = 56 } },
        }, requestTimeout).ConfigureAwait(false);
        Check("setBreakpoints while attached binds immediately", Verified(bp2), $"Calculator.cs:56 verified={Verified(bp2)}");
        await dap.RequestAsync("continue", new { threadId }, requestTimeout).ConfigureAwait(false);
        dap.DiscardEvents("stopped");
        Adb.TapById(options.Serial, options.Package, "count_button");
        var second = await dap.WaitForEventAsync("stopped", TimeSpan.FromSeconds(20)).ConfigureAwait(false);
        Check("breakpoint re-hit on a second tap", second != null && second.Value.GetProperty("reason").GetString() == "breakpoint");
        if (second != null)
        {
            threadId = second.Value.GetProperty("threadId").GetInt32();
            var into = await StepAsync(dap, "stepIn", threadId).ConfigureAwait(false);
            Check("stepIn into Calculator.DescribeCount", into != null && into.Value.File.EndsWith("Calculator.cs", StringComparison.Ordinal), Describe(into));
            if (into != null)
            {
                var expression = await EvaluateAsync(dap, "count % 2", into.Value.Id).ConfigureAwait(false);
                Check("evaluate arithmetic (count % 2)", expression.Ok && (expression.Result == "0" || expression.Result == "1"), expression.Result);
                await dap.RequestAsync("continue", new { threadId }, requestTimeout).ConfigureAwait(false);
                var bp2Hit = await dap.WaitForEventAsync("stopped", TimeSpan.FromSeconds(20)).ConfigureAwait(false);
                var bp2Frames = bp2Hit != null ? await dap.RequestAsync("stackTrace", new { threadId, startFrame = 0, levels = 5 }, requestTimeout).ConfigureAwait(false) : default;
                var bp2Top = bp2Hit != null ? TopFrame(bp2Frames) : default;
                Check("second breakpoint hit (Calculator.cs:56)", bp2Hit != null && bp2Top.Line == 56, bp2Hit != null ? Describe(bp2Top) : "no stop");
                if (bp2Hit != null)
                {
                    var isSquare = await EvaluateAsync(dap, "isSquare", bp2Top.Id).ConfigureAwait(false);
                    // isSquare is assigned ON line 56, so before it runs the local is still default (false).
                    Check("evaluate local isSquare at line 56", isSquare.Ok, isSquare.Result);
                    await dap.RequestAsync("continue", new { threadId }, requestTimeout).ConfigureAwait(false);
                }
            }
        }

        // 12. first-chance exception stop
        await dap.RequestAsync("setExceptionBreakpoints", new { filters = new[] { "all" } }, requestTimeout).ConfigureAwait(false);
        dap.DiscardEvents("stopped");
        Adb.TapById(options.Serial, options.Package, "throw_button");
        var exceptionStop = await dap.WaitForEventAsync("stopped", TimeSpan.FromSeconds(20)).ConfigureAwait(false);
        var exceptionReason = exceptionStop?.TryGetProperty("reason", out var er) == true ? er.GetString() : "";
        Check("first-chance exception stop", exceptionStop != null && exceptionReason == "exception",
            exceptionStop?.TryGetProperty("text", out var et) == true ? $"{exceptionReason}: {et.GetString()}" : exceptionReason);
        if (exceptionStop != null)
        {
            threadId = exceptionStop.Value.GetProperty("threadId").GetInt32();
            var info = await dap.RequestAsync("exceptionInfo", new { threadId }, requestTimeout, throwOnFailure: false).ConfigureAwait(false);
            var exceptionId = info.ValueKind == JsonValueKind.Object && info.TryGetProperty("exceptionId", out var eid) ? eid.GetString() : "";
            Check("exceptionInfo names the exception", exceptionId.Contains("InvalidOperationException"), exceptionId);
            var exceptionFrames = await dap.RequestAsync("stackTrace", new { threadId, startFrame = 0, levels = 5 }, requestTimeout).ConfigureAwait(false);
            var exceptionTop = TopFrame(exceptionFrames);
            Check("exception stack trace at the throw site", exceptionTop.File.EndsWith("Calculator.cs", StringComparison.Ordinal) && exceptionTop.Line == 64, Describe(exceptionTop));
            await dap.RequestAsync("setExceptionBreakpoints", new { filters = Array.Empty<string>() }, requestTimeout).ConfigureAwait(false);
            await dap.RequestAsync("continue", new { threadId }, requestTimeout).ConfigureAwait(false);
        }

        // 13. detach, leaving the app alive
        await Task.Delay(500).ConfigureAwait(false);
        await dap.RequestAsync("disconnect", new { terminateDebuggee = false }, requestTimeout).ConfigureAwait(false);
        await Task.Delay(1500).ConfigureAwait(false);
        var pidAfter = Adb.PidOf(options.Serial, options.Package);
        Check("detach left the app running (same pid)", pidAfter == options.ProcessId, $"pid before={options.ProcessId} after={pidAfter?.ToString(CultureInfo.InvariantCulture) ?? "gone"}");

        PrintVerdict();
        return verdict.TrueForAll(v => v.Ok);
    }

    static bool Verified(JsonElement setBreakpointsBody)
    {
        if (!setBreakpointsBody.TryGetProperty("breakpoints", out var list))
            return false;
        foreach (var b in list.EnumerateArray())
            return b.TryGetProperty("verified", out var v) && v.GetBoolean();
        return false;
    }

    struct Frame
    {
        public int Id;
        public string Name;
        public string File;
        public int Line;
    }

    static Frame TopFrame(JsonElement stackTraceBody)
    {
        foreach (var f in stackTraceBody.GetProperty("stackFrames").EnumerateArray())
        {
            return new Frame
            {
                Id = f.GetProperty("id").GetInt32(),
                Name = f.TryGetProperty("name", out var n) ? n.GetString() : "?",
                Line = f.TryGetProperty("line", out var l) ? l.GetInt32() : 0,
                File = f.TryGetProperty("source", out var s) && s.ValueKind == JsonValueKind.Object && s.TryGetProperty("path", out var p) ? p.GetString() ?? "" : "",
            };
        }
        return new Frame { Name = "(no frames)", File = "" };
    }

    static string Describe(Frame? frame) => frame == null ? "no stop" : Describe(frame.Value);
    static string Describe(Frame frame) => $"{frame.Name} at {Path.GetFileName(frame.File)}:{frame.Line}";

    async Task<Frame?> StepAsync(DapConnection dap, string command, int threadId)
    {
        dap.DiscardEvents("stopped");
        await dap.RequestAsync(command, new { threadId }, requestTimeout).ConfigureAwait(false);
        var stopped = await dap.WaitForEventAsync("stopped", TimeSpan.FromSeconds(20)).ConfigureAwait(false);
        if (stopped == null)
            return null;
        var frames = await dap.RequestAsync("stackTrace", new { threadId, startFrame = 0, levels = 5 }, requestTimeout).ConfigureAwait(false);
        return TopFrame(frames);
    }

    struct Evaluation
    {
        public bool Ok;
        public string Result;
        public int VariablesReference;
    }

    async Task<Evaluation> EvaluateAsync(DapConnection dap, string expression, int frameId)
    {
        try
        {
            var body = await dap.RequestAsync("evaluate", new { expression, frameId, context = "hover" }, requestTimeout).ConfigureAwait(false);
            return new Evaluation
            {
                Ok = true,
                Result = body.TryGetProperty("result", out var r) ? r.GetString() ?? "" : "",
                VariablesReference = body.TryGetProperty("variablesReference", out var v) ? v.GetInt32() : 0,
            };
        }
        catch (Exception ex)
        {
            return new Evaluation { Ok = false, Result = ex.Message };
        }
    }

    void PrintVerdict()
    {
        Console.WriteLine();
        Console.WriteLine("==================== Part 4 VERDICT (plain DAP client over adb forward) ====================");
        foreach (var (check, ok, detail) in verdict)
            Console.WriteLine($"{check,-52}: {(ok ? "YES" : "NO")}{(detail.Length > 0 ? "   (" + detail + ")" : "")}");
        Console.WriteLine(verdict.TrueForAll(v => v.Ok) ? ">>> ALL CHECKS PASSED" : ">>> SOME CHECKS FAILED");
    }
}
