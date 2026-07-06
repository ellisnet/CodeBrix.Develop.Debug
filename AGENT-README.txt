================================================================================
AGENT-README: CodeBrix.Develop.Debug
A Comprehensive Guide for AI Coding Agents
================================================================================

OVERVIEW
--------
CodeBrix.Develop.Debug is an EXACT FORK of the Samsung netcoredbg project
(https://github.com/Samsung/netcoredbg), a native C++ debugger for the
.NET runtime that implements the GDB/MI and VSCode Debug Adapter Protocol
(DAP) interfaces plus an interactive CLI. The debugger is launched as a
child process and driven over stdio.

This repository differs from upstream ONLY by the addition of:
  - nuget/CodeBrix.Develop.Debug.LinuxX64/    (NuGet packaging project)
  - nuget/CodeBrix.Develop.Debug.LinuxArm64/  (NuGet packaging project)
  - the CodeBrix repo-standard files (this file, the AI-agent pointer
    stubs, THIRD-PARTY-NOTICES.txt, icon-codebrix-128.png)

Do NOT modify the C++/CMake source tree except by syncing from upstream -
keeping the fork exact is a deliberate policy so upstream releases can be
merged cleanly.


THE NUGET PACKAGES
------------------
This repository produces one single-arch package per supported Linux
architecture - each a carrier for that arch's native debugger binaries,
with NO managed library and NO NuGet dependencies:

  - CodeBrix.Develop.Debug.LinuxX64    (linux-x64,   tools/linux-x64/)
  - CodeBrix.Develop.Debug.LinuxArm64  (linux-arm64, tools/linux-arm64/)
  - CodeBrix.Develop.Debug.LinuxRiscV64  (linux-riscv64 - planned, once the
    RISC-V .NET toolchain matures; built on RVA23 hardware)

Each package carries its arch's binaries under tools/linux-<arch>/ plus a
build/*.targets file. The packages are deliberately kept as separate,
single-arch carriers (not one multi-arch package): the targets file copies
its binaries unconditionally, so a consumer references EXACTLY ONE package,
selected by host/target architecture (e.g. via $(NETCoreSdkRuntimeIdentifier)
in a conditional PackageReference). Every package lands its binaries at the
SAME output path (netcoredbg/netcoredbg), so consuming code is arch-agnostic:
    System.IO.Path.Combine(AppContext.BaseDirectory, "netcoredbg", "netcoredbg")

IMPORTANT: like other CodeBrix.Develop.* packages, the package ids carry
NO license-suffix. This is a deliberate, user-chosen deviation from the
CodeBrix family convention.

Referencing the package copies the debugger binaries into the consuming
app's output folder (netcoredbg/ subfolder) on every build and publish -
no RuntimeIdentifier required - and restores the executable bit on the
netcoredbg binary (nupkg archives cannot preserve file permissions; the
targets file runs chmod +x on Unix hosts after build/publish).

Consuming code launches the debugger from its own output folder:

    var path = System.IO.Path.Combine(
        System.AppContext.BaseDirectory, "netcoredbg", "netcoredbg");
    // start with --interpreter=vscode (DAP), =mi (GDB/MI), or =cli

Packaged files (produced by this repository's cmake build):
    netcoredbg                       native debugger executable
    ManagedPart.dll                  managed helper (expression evaluation,
                                     symbol reading), loaded by the debugger
    libdbgshim.so                    Microsoft debugger-shim native library
    Microsoft.CodeAnalysis*.dll (4)  Roslyn 2.x scripting stack used by
                                     ManagedPart


BUILDING THE DEBUGGER
---------------------
Prerequisites: cmake, clang (gcc is NOT supported), make, .NET runtime.
The cmake configure step auto-downloads the CoreCLR runtime sources and a
.NET SDK on first run (large download).

    cd <repo-root>
    mkdir -p build && cd build
    CC=clang CXX=clang++ cmake .. -DCMAKE_INSTALL_PREFIX=$PWD/../bin
    make -j$(nproc)
    make install

The build targets the architecture of the host it runs on: build on a
linux-x64 host for the x64 binaries, on a linux-arm64 host (e.g. a
Raspberry Pi 5) for the arm64 binaries - the commands are identical. The
installed artifacts land in <repo-root>/bin/ - this is exactly the file set
the NuGet packaging project packs.

NOTE: <repo-root>/bin/ is a SHARED output folder. It holds whichever arch
you last built, so pack the matching package immediately after building
(don't pack the LinuxX64 package from a bin/ that holds an arm64 build).


PACKING THE NUGET
-----------------
Build the debugger FIRST (the packaging project packs ../../bin/), then
pack the package that matches the arch currently in bin/:

    cd nuget/CodeBrix.Develop.Debug.LinuxX64     # or .../LinuxArm64
    dotnet build -c Release

The .nupkg lands in that project's bin/Release/. Versioning uses the
canonical CodeBrix date-stamped scheme with the MAJOR pinned to 3, matching
the major version of the NetCoreDbg debugger the package carries (same
pattern as CodeBrix.Platform.MediaPlayerCore's libvlc-pinned major). Each
arch package is packed independently, so their date-stamped versions differ
- that is expected.


LICENSING
---------
Everything shipped is MIT except the Roslyn 2.x DLLs (Apache-2.0 era).
See THIRD-PARTY-NOTICES.txt at the repository root (also packed into the
NuGet package) for full provenance: Samsung netcoredbg (MIT), vendored
C++ libraries compiled into the executable (nlohmann/json, libelfin,
linenoise-ng), .NET runtime-derived portions (MIT), libdbgshim (MIT),
and the Roslyn scripting DLLs (Apache-2.0).


TESTING
-------
Smoke test after a build:

    ./bin/netcoredbg --version

The upstream test-suite/ requires additional setup (see upstream docs).
The debugger can be exercised end-to-end by launching it with
--interpreter=vscode and speaking DAP over stdio.
================================================================================
