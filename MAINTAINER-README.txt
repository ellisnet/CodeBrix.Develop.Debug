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

There is likewise NO root solution file, and that too is deliberate. Every
other CodeBrix repository has a <Repo>.slnx carrying "Solution Items" and
"Tests" folders; this one is a C++/cmake repository whose two packaging
projects are built and packed individually, so a root solution would have
nothing useful to hold. The only solution here is test-suite/test-suite.sln,
which is upstream's. Do not add a root .slnx, and do not report its absence as
repository drift.

For the same reason there is no root global.json: the repo has no dotnet test
run to point at a test runner.


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
for the arm64 binaries - the commands are identical.

DO NOT use a bare host build for the PUBLISHED packages. A binary built this way
inherits the build host's glibc, and a current desktop produces binaries that
will not run on Ubuntu 22.04, Debian 12 or RHEL 8/9. Build the published
binaries with container-build/ instead, which pins the floor to glibc 2.17 - see
container-build/README.md. The host build above remains the right thing for
day-to-day development and for running the test-suite. The installed artifacts
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

For container-built binaries, use the packing script instead - it stages the
requested architecture into bin/ and refuses to pack unless the binary there
reports that same architecture, which is the SHARED bin/ FOLDER hazard below:

    ./container-build/pack-package.sh x64           # or arm64

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
  - NO version numbers in AGENT-README.txt at all -- not even in the upstream
    provenance statement. Write it version-free ("a fork of the Samsung
    netcoredbg project"); the exact release lineage belongs here and in
    THIRD-PARTY-NOTICES.txt.
  - README.md is the CodeBrix package page: it follows the family README
    template and carries no build instructions. Build, test and developer
    material belongs in this file -- see the three "(moved here from
    README.md)" sections at the end.


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


BUILDING FROM SOURCE CODE (moved here from README.md)
=====================================================
The material below was the root README.md's own build documentation. It is
reproduced here verbatim in substance -- README.md is now the CodeBrix package
page and carries none of it. Where it overlaps the BUILDING section above,
BUILDING above is the CodeBrix-maintained summary and this section is the
fuller original.

The sources can be built on Linux, MacOS, or Windows.

Supported architectures (upstream; only linux-x64 and linux-arm64 are
packaged):
    ARM 32-bit, ARM 64-bit, x64, x86, RISC-V 64-bit, LoongArch 64-bit

UNIX
----
The build requires Microsoft's .NET, and as such can only be built in Linux.
Microsoft supports a few distributions, the details of which can be found here:
https://learn.microsoft.com/en-us/dotnet/core/install/linux

Prerequisites:

  1. Install `cmake`, and either `make` or `ninja`.
  2. Install the clang C++ compiler (the build does NOT work with gcc).
  3. Microsoft's .NET RUNTIME should be installed:
     https://dotnet.microsoft.com/download
  4. You may also need common developer tools not mentioned here, such as Git
     (https://www.git-scm.com/downloads).
  5. It is expected that you place the sources within a directory.
  6. Optional: the build requires the CoreCLR RUNTIME SOURCE CODE, which is
     typically downloaded automatically, but can also be downloaded manually
     from https://github.com/dotnet/runtime -- for example, you can check out
     tag v8.x.
  7. Optional: the build requires the .NET SDK, which is typically downloaded
     automatically, but can also be downloaded manually from
     https://dotnet.microsoft.com/download

Compiling. Configure the build with:

    $ mkdir build
    $ cd build
    build$ CC=clang CXX=clang++ cmake ..

In order to run tests after a successful build, add the option
`-DCMAKE_INSTALL_PREFIX=$PWD/../bin`.

To enable the Source-Based Code Coverage feature
(https://clang.llvm.org/docs/SourceBasedCodeCoverage.html), add the
`-DCLR_CMAKE_ENABLE_CODE_COVERAGE` option.

If you have previously downloaded the .NET SDK or CoreCLR sources, add:
`-DDOTNET_DIR=/path/to/sdk/dir -DCORECLR_DIR=/path/to/coreclr/sources`.

If cmake tries to download the .NET SDK or CoreCLR sources and fails, see
bullet numbers 6 and 7 above -- any required files can be downloaded manually.

After configuration has finished, build and install:

    build$ make
    ...
    build$ make install

To perform a build from scratch, including the configuration step, delete any
artifacts first:

    build$ cd ..
    $ rm -rf build src/debug/netcoredbg/bin bin

NOTE: the `bin` directory contains the "installed" binaries used for tests. If
you have installed the debugger in other places, for example in
/usr/local/bin, remove it manually -- the build system does not currently
implement automatic uninstalling.

Prerequisites and compiling with INTEROP MODE support (Linux and Tizen OSes
only). The prerequisites and compiling process are the same as above with the
following changes:

  1. Depending on your distro, install either the `libunwind-dev` or the
     `libunwind-devel` package.
  2. Configure the build with:

    build$ CC=clang CXX=clang++ cmake .. -DINTEROP_DEBUGGING=1

For more detail on interop mode, see docs/interop.md.

MACOS
-----
Install homebrew from https://brew.sh/ . After this, the build instructions
are the same as for Unix, including the prerequisites.

NOTE: the MacOS arm64 build (M1) is community supported and may not work as
expected; some tests may fail.

WINDOWS
-------
Prerequisites:

  1. Download and install CMake from https://cmake.org/download
  2. Download and install Microsoft's Visual Studio 2019 or newer from
     https://visualstudio.microsoft.com/downloads . During installation you
     should install all of the options required for C# and C++ development on
     Windows.
  3. Download and install Git; a few options:
       - original Git:  https://git-scm.com/download/win
       - TortoiseGit:   https://tortoisegit.org/download
       - git in cygwin: https://cygwin.com/install.html
  4. Use Git to place the sources in a directory.
  5. May be omitted -- cmake will automatically download all necessary files.
     If it fails, manually download the CoreCLR SOURCES into another directory
     from https://github.com/dotnet/runtime -- for example, you can use the
     latest tag v8.x.
  6. May also be omitted -- cmake will automatically download all necessary
     files. If it fails, manually download and install the .NET SDK from
     https://dotnet.microsoft.com/download

Compiling. Configure the build with the following commands, given in the
source tree:

    C:\...\netcoredbg> md build
    C:\...\netcoredbg> cd build
    C:\...\netcoredbg\build> cmake .. -G "Visual Studio 16 2019"

NOTE: run this command from cmd.exe, NOT from cygwin's shell.

The `-G` option specifies which instance of Visual Studio should build the
project. The minimum requirement for the build is the Visual Studio 2019
version.

To run tests after a successful build, add the option
`-DCMAKE_INSTALL_PREFIX="%cd%\..\bin"`.

If you have downloaded either the .NET SDK or the .NET Core sources manually,
add: `-DDOTNET_DIR="c:\Program Files\dotnet" -DCORECLR_DIR="path\to\coreclr"`

To compile and install:

    C:\...\netcoredbg\build> cmake --build . --target install

To perform a build from scratch, including the configuration step, delete any
artifacts first:

    C:\...\netcoredbg\build> cd ..
    C:\...\netcoredbg> rmdir /s /q build src\debug\netcoredbg\bin bin

NOTE: the `bin` directory contains the "installed" binaries used for tests. If
you have installed the debugger in other places, remove it manually -- the
build system does not currently perform automatic uninstalling.


RUNNING THE DEBUGGER FROM A BUILD (moved here from README.md)
============================================================
After the instructions above, the `netcoredbg` binary and its additional
libraries are installed in some directory. For development purposes (running
tests, debugging, etc.) the `bin` directory in the source tree is typically
used.

Running the debugger with the `--help` option should look like this:

    $ ../bin/netcoredbg --help
    .NET Core debugger

    Options:
    --buildinfo                           Print build info.
    --attach <process-id>                 Attach the debugger to the specified process id.
    --interpreter=cli                     Runs the debugger with Command Line Interface.
    --interpreter=mi                      Puts the debugger into MI mode.
    --interpreter=vscode                  Puts the debugger into VS Code Debugger mode.
    --command=<file>                      Interpret commands file at the start.
    -ex "<command>"                       Execute command at the start
    --run                                 Run program without waiting commands
    --engineLogging[=<path to log file>]  Enable logging to VsDbg-UI or file for the engine.
                                          Only supported by the VsCode interpreter.
    --server[=port_num]                   Start the debugger listening for requests on the
                                          specified TCP/IP port instead of stdin/out. If port is not specified
                                          TCP 4711 will be used.
    --log[=<type>]                        Enable logging. Supported logging to file and to dlog (only for Tizen)
                                          File log by default. File is created in 'current' folder.
    --version                             Displays the current version.

Basically, to debug .NET code, run the debugger with the following command
line:

    $ /path/to/netcoredbg --interpreter=TYPE -- /path/to/dotnet /path/to/program.dll


NOTES FOR DEVELOPERS (moved here from README.md)
================================================
Running the tests
-----------------
Detailed instructions on how to run tests are in the `test-suite` directory:
test-suite/README.md . You simply need to build and install into the `bin`
directory (in the source tree), then change directory to `test-suite` and run
the script `./run_tests.sh`.

For a "Source-Based Code Coverage" report, add a `-c` or `--coverage` option to
the command line, i.e. `./run_tests.sh -c [[testname1][testname2]..]`. For that
case the build configuration must have been made with the
`-DCLR_CMAKE_ENABLE_CODE_COVERAGE` option (see above). This feature is
currently only supported on Unix-like platforms.

Building and running unit tests
-------------------------------
To build the unit tests, add the CMake option `-DBUILD_TESTING=ON`. After a
successful build, run them with `make test`. See src/unittests/README.md.

Enabling logs
-------------
On the Tizen platform the debugger sends logs to the system logger. On other
platforms, specify the file logs will be written to by setting an environment
variable, for example:

    export LOG_OUTPUT=/tmp/log.txt

Each line of the log file uses the same format, explained below:

    5280715.183 D/NETCOREDBG(P12036, T12036): cliprotocol.cpp: evalCommands(1309) > evaluating: 'source file.txt'
          ^     ^  ^          ^       ^        ^               ^            ^       ^
          |     |  |          |       |        |               |            |       `-- Message itself.
          |     |  |          |       |        |               |            |
          |     |  |          |       |        |               |            `-- Source line number.
          |     |  |          |       |        |               |
          |     |  |          |       |        |               `-- This is function name.
          |     |  |          |       |        |
          |     |  |          |       |        `-- This is file name in which logging is performed.
          |     |  |          |       |
          |     |  |          |       `-- This is thread ID.
          |     |  |          |
          |     |  |          `-- This is process PID
          |     |  |
          |     |  `-- This program name (always NETCOREDBG).
          |     |
          |     `-- This is log level: E is for error, W is for warnings, D is for debug...
          |
          `--- This is time in seconds from the boot time (might be wrapped around).

Selecting between Debug and Release builds
------------------------------------------
Select the build type with one of the following CMake options:

  * -DCMAKE_BUILD_TYPE=Debug     a debug build (zero optimizations, but
                                 suitable for debugging)
  * -DCMAKE_BUILD_TYPE=Release   a release build (optimized, but difficult to
                                 debug)

By default the build system creates release builds.

Using the address sanitizer
---------------------------
Example:

    CC=clang-10 CXX=clang++-10 cmake .. -DCMAKE_INSTALL_PREFIX=$PWD/../bin -DCMAKE_BUILD_TYPE=Debug -DCORECLR_DIR=/path/to/coreclr -DDOTNET_DIR=/usr/share/dotnet -DASAN=1

Using clang-tidy
----------------
First, install clang-10. Next, to use clang-tidy, modify the commands used to
configure the build as below:

    CC=clang-10 CXX=clang++-10 cmake .. . -DCMAKE_CXX_CLANG_TIDY=clang-tidy-10 -DCMAKE_INSTALL_PREFIX=$PWD/../bin

Then just run `make`. Any and all errors will be printed to stderr. See:
https://blog.kitware.com/static-checks-with-cmake-cdash-iwyu-clang-tidy-lwyu-cpplint-and-cppcheck/

NOTE: due to miscellaneous problems, the following tools currently will not
work here: clang-analyzer (scan-build), cpplint, cppcheck, and iwyu.
================================================================================


================================================================================
ROSLYN (Microsoft.CodeAnalysis) — PROVENANCE, VERSION, AND LICENSING FINDINGS
2026-09-07. Recorded here so the licensing story is not re-derived every time.
================================================================================

WHERE IT COMES FROM
  Roslyn is inherited from upstream Samsung netcoredbg, NOT added by CodeBrix.
  ManagedPart (netcoredbg's managed expression evaluator) uses the Roslyn
  scripting APIs to compile watch/evaluate expressions at debug time.
    - Reference:  src/managed/ManagedPart.csproj
        <PackageReference Include="Microsoft.CodeAnalysis.CSharp.Scripting"
                          Version="[2.3,)" />
    - Consumers:  src/managed/StackMachine.cs
        using Microsoft.CodeAnalysis; using Microsoft.CodeAnalysis.CSharp;
    - The csproj + evaluator predate the CodeBrix fork (git history on that file:
      "Add first stage of new evaluation implementation", "Refactor managed
      part", "Add .NET 7 build support" — all netcoredbg-lineage commits).

WHICH VERSION ACTUALLY SHIPS
  The version constraint "[2.3,)" has NO upper bound, so NuGet resolves it to the
  LOWEST satisfying version, which is 2.3.0. Confirmed in the build output:
      build/src/ManagedPart.deps.json  ->
        Microsoft.CodeAnalysis.Common/2.3.0
        Microsoft.CodeAnalysis.CSharp/2.3.0
        Microsoft.CodeAnalysis.CSharp.Scripting/2.3.0
        Microsoft.CodeAnalysis.Scripting.Common/2.3.0
  So the four Microsoft.CodeAnalysis*.dll files packaged with the debugger are
  the 2.3.0 (2.x-era) release. (Raw `strings` on the DLLs can show "4.0.0.0",
  which is a frozen assembly-version / unrelated embedded string — do not trust
  it; the deps.json is authoritative.)

THE LICENSE — SUBTLE, AND PREVIOUSLY MIS-STATED
  These 2.3.0 BINARY packages are under the MICROSOFT .NET LIBRARY LICENSE, not
  Apache-2.0. Evidence, from the packages' own nuspec (in the NuGet cache,
  e.g. ~/.nuget/packages/microsoft.codeanalysis.common/2.3.0/*.nuspec):
      <licenseUrl>http://go.microsoft.com/fwlink/?LinkId=529443</licenseUrl>
      <requireLicenseAcceptance>true</requireLicenseAcceptance>
      (no <license type="expression"> element)
  fwlink LinkId=529443 redirects (HTTP 302) to
      https://www.microsoft.com/net/dotnet_library_license.htm
  i.e. the "Microsoft .NET Library License". requireLicenseAcceptance=true is a
  hallmark of that EULA; open-source (MIT/Apache) packages set it false and carry
  a <license> expression instead.

  THE DISTINCTION THAT CAUSED THE ERROR: the Roslyn SOURCE repo
  (github.com/dotnet/roslyn) is Apache-2.0, but the redistributed 2.3.0 NuGet
  BINARIES are under the Microsoft .NET Library License. It is the package
  license that governs the DLLs we ship. THIRD-PARTY-NOTICES.txt item 3 (and
  AGENT-README.txt) originally listed "Apache-2.0"; THIRD-PARTY-NOTICES.txt has
  been corrected (2026-09-07). AGENT-README.txt still carries the old
  "Apache-2.0 / Roslyn 2.x era" wording (around its "packaged third-party
  binaries" note) and should be corrected to match if/when that file is next
  revised.

  For contrast, MODERN Roslyn is MIT: the 4.0.1 and 4.8.0
  Microsoft.CodeAnalysis.Common nuspecs declare
      <license type="expression">MIT</license>.

OPTIONS IF CLEAN MIT LICENSING IS WANTED
  1. Keep 2.3.0 and attribute it correctly as the Microsoft .NET Library License
     (done in THIRD-PARTY-NOTICES.txt). No code change.
  2. Bump the ManagedPart dependency to a modern Roslyn (>= 4.x), which is MIT.
     This is a FUNCTIONAL change to the evaluator and must be built and tested
     (API differences between Roslyn 2.3 and 4.x scripting); not a doc-only edit.

NOTE: none of this concerns the android/ folder — that bundle contains no Roslyn.
================================================================================
