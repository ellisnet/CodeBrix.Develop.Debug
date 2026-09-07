================================================================================
EXTRAS-README: CodeBrix.Develop.Debug
Samples, tools and other content in this repository that is not part of a NuGet
package
================================================================================

This repository is a fork of a native C++ debugger, so most of what is here is
upstream engineering content rather than CodeBrix samples. Only the four
packaging projects (nuget/ for Linux, android/nuget/ for Android) and the files
they pack ship to consumers; everything described below stays in the
repository.

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


container-build/ - CODEBRIX CONTAINER BUILDS OF THE SHIPPED BINARIES
==================================================================
Not packed, but it produces the files that ARE packed. Podman/manylinux builds
of the debugger for both packaged architectures, so the published binaries carry
a glibc 2.17 floor instead of the build host's. This is CodeBrix content, not
upstream.

    container-build/README.md
        Why the container build exists, how to run it, and the traps
        (libicu is mandatory, cmake 4.x must be avoided, a debugger cannot be
        functionally tested under emulation).
    container-build/Containerfile.x86_64, Containerfile.aarch64
        Derived build images, manylinux bases pinned by digest.
    container-build/build-debugger.sh
        Builds the debugger for one architecture into output/linux-<arch>/.
    container-build/pack-package.sh
        Stages one architecture into bin/ and packs the matching package,
        refusing to pack if bin/ holds the wrong architecture.
    container-build/output/linux-x64/, output/linux-arm64/
        The built binaries, COMMITTED (the root .gitignore re-includes them),
        so a checkout can reproduce the published packages.


android/ - THE ANDROID DEBUGGING BUNDLE (CodeBrix content)
=========================================================
Everything needed to build, prove and package the on-device debugger for
Android, self-contained and committed (vendored pinned sources + prebuilt
binaries) so the two Android packages can be reproduced from a checkout. The
full runbook and reference is android/README.md; the provenance is
android/NOTICE.txt. Not packed as a whole - only the prebuilt payload files
listed in the packaging projects ship.

    android/dbgshim/            pinned dotnet/diagnostics subset + a wrapper
                                CMakeLists that builds libdbgshim.so per ABI
                                (build-dbgshim-android.sh; prebuilt/<abi>/)
    android/netcoredbg/         pinned CoreCLR header/IDL subset the Android
                                netcoredbg build compiles against; the per-ABI
                                netcoredbg build script (build-netcoredbg-
                                android.sh -> prebuilt/<abi>/, stripped); the
                                managed helper build (build-managed-helper.sh
                                -> prebuilt/managed/)
    android/harness/            trace.c -> libtrace.so, the LD_PRELOAD tracing
                                harness used during the investigation (syscall
                                trace + clr-debug-pipe dump). The workarounds it
                                pioneered are now compiled INTO netcoredbg
                                (src/utils/android_compat.cpp); the harness is
                                kept as a diagnostic tool and is NOT packed.
    android/dap-probe/          a plain C# Debug Adapter Protocol client (no IDE
                                code) that attaches to the app over an adb-
                                forwarded port and drives a scripted session
                                with a VERDICT - the Part 4 proof and a handy
                                smoke test for a rebuilt payload.
    android/scripts/            run-attach.sh (Part 2), run-debug-session.sh
                                (Part 3, CLI over a FIFO), run-dap-session.sh
                                (Part 4, DAP server + the probe; -n = the
                                built-in compat layer, no LD_PRELOAD), and
                                pack-android-packages.sh (verify + pack both
                                Android packages).
    android/nuget/              the two Android packaging projects (see
                                MAINTAINER-README.txt, ANDROID PACKAGES).


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
                               (container-build/output/ is the committed copy)
    .ahub/sam/exclude.txt      upstream static-analysis exclusion list
    .github/pull_request_template.md
                               upstream pull-request template
    AUTHORS                    upstream maintainers and contributors
    *.cmake, CMakeLists.txt    the upstream build system
================================================================================
