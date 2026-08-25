================================================================================
EXTRAS-README: CodeBrix.Develop.Debug
Samples, tools and other content in this repository that is not part of a NuGet
package
================================================================================

This repository is a fork of a native C++ debugger, so most of what is here is
upstream engineering content rather than CodeBrix samples. Only the two
nuget/ packaging projects and the files they pack ship to consumers; everything
described below stays in the repository.

There are no CodeBrix sample applications and no CodeBrix test project in this
repository - the packages carry no managed code.


docs/ - UPSTREAM DOCUMENTATION
==============================
Not packed. Referenced from AGENT-README.txt by GitHub URL because it is the
best available user-facing documentation for the debugger.

    docs/cli.md
        The full command table for --interpreter=cli (break, run, continue,
        next, step, finish, print, backtrace, list, info, set, delete, catch,
        attach, detach, source, save, help) with worked terminal transcripts,
        plus the Just-My-Code and <EmbedAllSources> notes.

    docs/interop.md
        Interop (mixed native/managed) debugging: how to start a session, what
        is supported and what is not, and the CoreCLR libraries that can never
        be stepped into. The published packages are built WITHOUT interop
        support, so this is background reading only.

    docs/stepping.md
        How stepping is implemented, including async/await stepping through
        yield and resume offsets and the ObjectIdForDebugger trick. Explains
        stepping behaviour that the Debug Adapter Protocol specification alone
        does not.

    docs/files/
        The .drawio sources and rendered .png diagrams used by stepping.md.

    docs/guide/
        The NetCoreDbg Developer's Guide as LaTeX (netcoredbg-guide.tex) with a
        Makefile. Building it needs dia, rsvg-convert and a LaTeX installation;
        see docs/guide/README.md for the package list. Nothing else in the
        repository depends on it.


test-suite/ - UPSTREAM PROTOCOL TEST SUITE
==========================================
Not packed. 95 entries, of which 30 are VSCodeTest* projects (Debug Adapter
Protocol), 44 are MITest* projects (GDB/MI) and 2 are CLITest* projects, plus
the shared harness.

    test-suite/NetcoreDbgTest/
        The shared harness: DebuggerClient, the VSCode/ and MI/ protocol
        clients, checkpoint/label scripting and assertions. VSCode/
        VSCodeLocaleDebuggerClient.cs is a compact reference implementation of
        the Content-Length framing on both the send and the receive side.

    test-suite/VSCodeTest*/ , test-suite/MITest*/ , test-suite/CLITest*/
        One small C# program each, driving a complete debug session over the
        respective protocol. AGENT-README.txt points consumers at
        VSCodeTestBreakpoint, VSCodeTestAttach and VSCodeTestEvaluate as the
        clearest worked examples.

    test-suite/run_tests.sh, run_cli_test.sh
        The Linux runners. Build and `make install` the debugger into bin/
        first. -c / --coverage produces a source-based coverage report and
        needs the matching cmake option.

    test-suite/sdb_run_tests.sh, sdb_run_tizen_tests.sh, llvm-gcov.sh
        Tizen/sdb device runners and a gcov shim. Not used for the CodeBrix
        packages.

    test-suite/test-suite.sln, test-suite/README.md
        Solution for the whole suite and the upstream instructions, including
        the TCP-server (--server) test flow.

How to run them is a maintainer task; see MAINTAINER-README.txt.


src/unittests/ - UPSTREAM UNIT TESTS
====================================
Not packed, and not built by default. Catch2-based C++ unit tests for the
low-level utilities (string_view, span, streams, iosystem, ioredirect, escaped
strings). Configure cmake with -DBUILD_TESTING=ON, then `make test`. See
src/unittests/README.md.


tools/ - UPSTREAM DEVELOPER SCRIPTS
===================================
Not packed. Neither tool is required to build or use the packages.

    tools/getvscodecmd/get-vscodecmd.py
        Experimental script that extracts the client-side Debug Adapter
        Protocol commands out of a captured debugger log and rewrites them as a
        Content-Length framed command file, so a session can be replayed in
        batch:
            get-vscodecmd.py vscode_output > cmd
            unix2dos cmd
            netcoredbg --interpreter=vscode --engineLogging=/tmp < cmd
        Useful for reproducing a protocol-level bug. See its own README.md for
        the caveats - replay is sensitive to values that change between runs.

    tools/generrmsg/GenErrMsg.cs
        Small C# generator that turns an XML error-message definition into the
        generated .cpp/.h error-message tables used by the debugger build.
            generrmessage XML-file [result-cpp-file] [result-h-file]


packaging/ - UPSTREAM DISTRO PACKAGING AND BUILD INPUTS
=======================================================
Not packed, and unrelated to the NuGet packaging under nuget/.

    packaging/netcoredbg.spec, netcoredbg.manifest
        RPM/Tizen packaging inputs used by the upstream release process.
    packaging/nuget.xml
        A NuGet configuration that points at a local package folder and
        disables nuget.org - used by offline/isolated upstream builds.
    packaging/microsoft.codeanalysis.*.nupkg
        The Roslyn scripting packages the build consumes to produce the
        Microsoft.CodeAnalysis* DLLs that end up beside the debugger.


third_party/ - VENDORED C++ LIBRARIES
=====================================
Not packed as files: these are compiled INTO the netcoredbg executable
(nlohmann/json, libelfin, linenoise-ng). Licensing is recorded in
THIRD-PARTY-NOTICES.txt, which IS packed. Do not edit; they come from upstream.


OTHER NON-PACKAGE FILES
=======================
    .coreclr/ , .dotnet/       build dependencies auto-downloaded by cmake;
                               gitignored; do not read or edit them
    build/ , bin/              cmake build tree and install output; gitignored
    .ahub/sam/exclude.txt      upstream static-analysis exclusion list
    .github/pull_request_template.md
                               upstream pull-request template
    AUTHORS                    upstream maintainers and contributors
    *.cmake, CMakeLists.txt    the upstream build system
================================================================================
