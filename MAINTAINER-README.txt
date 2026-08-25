================================================================================
MAINTAINER-README: CodeBrix.Develop.Debug
Notes for people and agents MAINTAINING this repository — not for package
consumers
================================================================================

PURPOSE AND SCOPE
=================
This repository is a fork of the Samsung netcoredbg project - a native C++
debugger for the .NET runtime implementing GDB/MI, the VSCode Debug Adapter
Protocol and an interactive CLI - plus the CodeBrix packaging that turns its
build output into NuGet packages.

It produces one single-architecture package per supported Linux architecture:

    CodeBrix.Develop.Debug.LinuxX64      nuget/CodeBrix.Develop.Debug.LinuxX64/
    CodeBrix.Develop.Debug.LinuxArm64    nuget/CodeBrix.Develop.Debug.LinuxArm64/

A third package, CodeBrix.Develop.Debug.LinuxRiscV64 (linux-riscv64), is
planned once the RISC-V .NET toolchain matures; it would be built on RVA23
hardware and follow exactly the same pattern.

Consumer documentation for BOTH packages lives in the single root
AGENT-README.txt. There is no per-package AGENT-README - both csproj files pack
the root one.

The package ids carry NO license suffix. That is a deliberate, user-chosen
deviation from the CodeBrix family convention, shared with the other
CodeBrix.Develop.* packages. Do not "fix" it.


REPOSITORY LAYOUT
=================
    src/                       the C++ debugger sources (upstream)
      main.cpp                 command-line parsing and startup
      protocols/               vscodeprotocol, miprotocol, cliprotocol
      debugger/                the debugger engine and dbgshim loader
      managed/                 CoreCLR hosting for ManagedPart
      unittests/               Catch2 unit tests (opt-in, see TESTING)
    docs/                      upstream documentation (cli, interop, stepping,
                               plus a LaTeX guide under docs/guide/)
    test-suite/                upstream protocol test-suite (95 entries)
    tools/                     upstream developer helper scripts
    third_party/               vendored C++ libraries compiled into the binary
    packaging/                 upstream distro-packaging inputs and the
                               Roslyn scripting nupkgs the build consumes
    CMakeLists.txt, *.cmake    the cmake build (upstream)
    bin/                       cmake "make install" output - SHARED, see below
    build/                     cmake build tree (gitignored)
    .coreclr/, .dotnet/        auto-downloaded build dependencies (gitignored)
    nuget/<PackageId>/         the two CodeBrix packaging projects
      <PackageId>.csproj       packaging-only project (no managed output)
      build/<PackageId>.targets  the targets file that ships in the package
      README.md                the package's nuget.org readme
    AGENT-README.txt           consumer documentation for BOTH packages
    MAINTAINER-README.txt      this file
    EXTRAS-README.txt          non-package content in the repository
    README-INDEX.txt           map of the README files
    THIRD-PARTY-NOTICES.txt    packed into both packages
    icon-codebrix-128.png      packed into both packages

This repository differs from upstream ONLY by the addition of the two
nuget/ packaging projects and the CodeBrix repo-standard files (AGENT-README,
MAINTAINER-README, EXTRAS-README, README-INDEX, the AI-agent pointer stubs,
THIRD-PARTY-NOTICES.txt, icon-codebrix-128.png). Do NOT modify the C++/CMake
source tree except by syncing from upstream - keeping the fork exact is a
deliberate policy so upstream releases can be merged cleanly.


BUILDING
========
Prerequisites: cmake, clang (gcc is NOT supported), make, a .NET runtime. The
cmake configure step auto-downloads the CoreCLR runtime sources into .coreclr/
and a .NET SDK into .dotnet/ on first run (a large download); both directories
are gitignored.

    cd <repo-root>
    mkdir -p build && cd build
    CC=clang CXX=clang++ cmake .. -DCMAKE_INSTALL_PREFIX=$PWD/../bin
    make -j$(nproc)
    make install

The build targets the architecture of the host it runs on: build on a linux-x64
host for the x64 binaries, on a linux-arm64 host (for example a Raspberry Pi 5)
for the arm64 binaries - the commands are identical. The installed artifacts
land in <repo-root>/bin/, which is exactly the file set the packaging projects
pack:

    netcoredbg  ManagedPart.dll  libdbgshim.so
    Microsoft.CodeAnalysis.dll  Microsoft.CodeAnalysis.CSharp.dll
    Microsoft.CodeAnalysis.Scripting.dll
    Microsoft.CodeAnalysis.CSharp.Scripting.dll

Useful cmake options (all upstream):
    -DDOTNET_DIR=/path/to/sdk -DCORECLR_DIR=/path/to/coreclr
                                   use pre-downloaded dependencies
    -DCMAKE_BUILD_TYPE=Debug|Release   (Release is the default)
    -DBUILD_TESTING=ON                 build the Catch2 unit tests
    -DINTEROP_DEBUGGING=1              compile in interop (mixed native/managed)
                                       debugging; needs libunwind-dev
    -DDBGSHIM_DIR=<dir>                hard-code where libdbgshim is looked up
                                       (leave EMPTY for the packages - the
                                       shipped binary must resolve it next to
                                       its own executable)
    -DCLR_CMAKE_ENABLE_CODE_COVERAGE   source-based coverage
    -DASAN=1                           address sanitizer

WHAT THE SHIPPED BINARIES ARE BUILT WITHOUT
-------------------------------------------
The published packages are built WITHOUT -DINTEROP_DEBUGGING and without
NCDB_DOTNET_STARTUP_HOOK, so --interop-debugging and --hot-reload are not
compiled in and are rejected as unknown options. AGENT-README.txt states this
as a limitation; if that ever changes, update AGENT-README.txt's "WHAT THESE
PACKAGES DO NOT DO" section in the same commit. DBGSHIM_DIR must stay empty so
the binary keeps loading libdbgshim.so from its own directory - the whole
output-path contract in AGENT-README.txt depends on it.

SHARED bin/ FOLDER
------------------
<repo-root>/bin/ is a SHARED output folder. It holds whichever architecture you
last built, so pack the matching package IMMEDIATELY after building. Do not
pack the LinuxX64 package from a bin/ that holds an arm64 build - nothing
checks, and the resulting package is silently wrong. The LinuxArm64 csproj
carries a comment saying exactly this.


TESTING
=======
Smoke tests after a build:

    ./bin/netcoredbg --version
    ./bin/netcoredbg --buildinfo     (prints build type/date, target OS, arch -
                                      the quickest way to confirm which
                                      architecture is currently in bin/)
    ./bin/netcoredbg --help          (confirms which optional features were
                                      compiled in)

Protocol test-suite: build and install into bin/ first, then

    cd test-suite
    ./run_tests.sh                   (add -c or --coverage for a coverage
                                      report; requires the coverage cmake
                                      option)
    ./run_cli_test.sh                (the CLI-mode tests)

See test-suite/README.md for the full instructions, including the sdb/Tizen
runners and the TCP-server test flow. Note the upstream test-suite README asks
for an old .NET SDK; treat it as upstream's own requirement, not a CodeBrix one.

Unit tests: configure with -DBUILD_TESTING=ON, then `make test` in the build
tree. See src/unittests/README.md.

There is no CodeBrix xunit test project in this repository - the packages carry
no managed code to test.


PACKAGING AND PUBLISHING
========================
Build the debugger FIRST (the packed files come from ../../bin/), then pack the
package that matches the architecture currently in bin/:

    cd nuget/CodeBrix.Develop.Debug.LinuxX64        # or .../LinuxArm64
    dotnet build -c Release

Both projects set GeneratePackageOnBuild=true, so a plain build produces the
.nupkg in that project's bin/Release/. Both also set IncludeBuildOutput=false
and SuppressDependenciesWhenPacking=true: the compiled (empty) assembly is not
packed and the package declares no dependencies.

WHAT SHIPS IN EACH NUPKG
------------------------
    tools/linux-<arch>/    the seven files listed under BUILDING
    build/<PackageId>.targets
    README.md              from nuget/<PackageId>/ (the nuget.org readme)
    AGENT-README.txt       the ROOT AGENT-README - both packages pack the same
                           file, which is why it documents both packages
    THIRD-PARTY-NOTICES.txt  from the repository root
    icon-codebrix-128.png    from the repository root

MAINTAINER-README.txt, EXTRAS-README.txt and README-INDEX.txt are NOT packed.
If you add a per-package AGENT-README later, update both csproj files and
README-INDEX.txt together.

VERSIONING - THE MAJOR=3 EXCEPTION
----------------------------------
Both packages use the canonical CodeBrix date-stamped scheme with the MAJOR
field PINNED TO 3, matching the major version of the NetCoreDbg debugger the
packages carry (the same pattern as CodeBrix.Platform.MediaPlayerCore's
libvlc-pinned major):

    3.<x>.<y>.<z>     all fields derived from System.DateTime.UtcNow
      3   major       always 3 for this repository
      x   minor       whole years since _VersionBaseYear (2026 = 0)
      y   build       day of year, UTC, 1-based (Jan 1 = 1)
      z   revision    minute of day, UTC, 0..1439

The value is strictly increasing over time. Because it depends on the clock,
every build produces a new version, and two builds within the same UTC minute
produce the SAME version - do not publish two packages from within one minute.
This is date-stamp versioning, not SemVer: major/minor do not signal API
compatibility. To re-baseline the minor number, change _VersionBaseYear in the
csproj. The full explanation is in a comment block at the top of each csproj.

Each architecture package is packed independently, so their date-stamped
versions differ. That is expected and does not need reconciling.

Keep the version scheme, the MAJOR=3 pin and the no-license-suffix package ids
OUT of AGENT-README.txt - they are maintainer facts and consumers must not pin
to them.

TARGETS FILE
------------
build/<PackageId>.targets is the entire consumer-facing behaviour of the
package. The two files are identical apart from the package id and the
linux-<arch> folder name. They:
  - add tools/linux-<arch>/**/* as linked None items under a netcoredbg\ link
    prefix with CopyToOutputDirectory=PreserveNewest;
  - run chmod +x on $(OutputPath)netcoredbg/netcoredbg after Build
    (target CodeBrixDevelopDebugRestoreExecutableBit) and on
    $(PublishDir)netcoredbg/netcoredbg after Publish
    (target CodeBrixDevelopDebugRestoreExecutableBitOnPublish), both gated on
    '$(OS)' == 'Unix' and on the file existing.
They ship in build/, not buildTransitive/, so the behaviour applies only to the
project that references the package directly. If that ever changes, the
"class library" pitfall in AGENT-README.txt must change with it.


PROVENANCE AND VENDORED SOURCES
===============================
Upstream:   https://github.com/Samsung/netcoredbg  (MIT), release lineage 3.2.0
            (src/version.h carries the exact string)
Fork:       https://github.com/ellisnet/CodeBrix.Develop.Debug

Git remotes and branches in this working copy:
    origin     the CodeBrix fork
    upstream   Samsung/netcoredbg
    master     tracks upstream
    codebrix   the CodeBrix branch - all packaging work lives here, and it is
               the branch the GitHub links in AGENT-README.txt point at
There is no "main" branch in this repository.

To sync a new upstream release: fetch upstream, merge master, then merge master
into codebrix. Because the fork adds files rather than editing them, that merge
should stay clean. Re-verify AGENT-README.txt's option table against
`./bin/netcoredbg --help` and src/main.cpp afterwards, and re-verify the DAP
command/event lists against src/protocols/vscodeprotocol.cpp.

Third-party content, all detailed in THIRD-PARTY-NOTICES.txt:
    netcoredbg + ManagedPart              MIT (Samsung Electronics Co., LTD)
    nlohmann/json, libelfin               MIT, compiled into the executable
    linenoise-ng                          BSD-style, compiled into the executable
    portions derived from dotnet/runtime  MIT
    libdbgshim.so (dotnet/diagnostics)    MIT
    Microsoft.CodeAnalysis* (Roslyn 2.x)  Apache-2.0
The repository LICENSE file is upstream's MIT license; the csproj declares
PackageLicenseExpression=MIT.

.coreclr/ and .dotnet/ are build dependencies downloaded by cmake, not vendored
source, and are gitignored. Do not read or edit them.


CODING CONVENTIONS
==================
  - The C++/CMake tree follows UPSTREAM conventions, not CodeBrix ones. Do not
    apply CodeBrix C# conventions, file headers or naming to it, and do not
    reformat it. The only acceptable reason to touch it is an upstream sync.
  - The two csproj files are the CodeBrix-owned surface. Keep them identical
    apart from the package id, the linux-<arch> path, the package tags and the
    bin/-folder warning comment.
  - Documentation edits go to the root .txt files (AGENT-README,
    MAINTAINER-README, EXTRAS-README, README-INDEX). docs/ belongs to upstream.
  - No version numbers in AGENT-README.txt other than the one-line upstream
    provenance statement.


NOTES
=====
  - The upstream sources support Windows, macOS, arm32, x86, riscv64 and
    loongarch64. Only linux-x64 and linux-arm64 are packaged, so anything the
    upstream README says about other platforms is background, not a package
    promise.
  - `git status` will show nuget/*/bin and nuget/*/obj as ignored build
    artifacts; previously packed .nupkg files can linger there. Confirm the
    version you are about to publish is the one you just built.
  - The vscode protocol implementation applies a 15-second timeout to every
    queued request. If a change makes an operation slower than that, consumers
    see "Command execution timed out." rather than a hang - check
    src/protocols/vscodeprotocol.cpp before blaming a client.
================================================================================
