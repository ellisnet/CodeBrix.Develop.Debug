# container-build

Reproducible container builds of the debugger binaries that the two `nuget/`
packaging projects ship.

Nothing in this folder is packed into either NuGet package. It exists so that
`CodeBrix.Develop.Debug.LinuxX64` and `CodeBrix.Develop.Debug.LinuxArm64` can be
rebuilt on one machine, from a checkout, with a predictable result.

## Why not just build on the dev box

The debugger links against the build host's C library, and the resulting binary
will not run on any distribution older than that host. Building on a current
desktop produced binaries that required **glibc 2.38** and **GLIBCXX_3.4.32**,
which excluded Ubuntu 22.04, Debian 12 and RHEL 8/9 — the binaries only ran on
machines as new as the one that built them.

Building inside a manylinux image instead pins the floor to that image's
toolchain:

| | built on the dev box | built here |
| --- | --- | --- |
| glibc | 2.38 | **2.17** |
| libstdc++ | GLIBCXX_3.4.32 (GCC 13) | **GLIBCXX_3.4.22 (GCC 6)** |

Same debugger, same sources, no added `NEEDED` libraries — only the floor moves.
That is the whole point of this folder.

## Layout

    Containerfile.x86_64     derived build image for linux-x64
    Containerfile.aarch64    derived build image for linux-arm64
    build-debugger.sh        compiles the debugger for one architecture
    pack-package.sh          stages one architecture into bin/ and packs it
    output/linux-x64/        the seven built files, committed
    output/linux-arm64/      the seven built files, committed

`output/` is committed on purpose, and the root `.gitignore` re-includes it
explicitly (the blanket `*.so` / `*.dll` rules would otherwise swallow it). The
cmake tree and the downloaded SDKs stay in the gitignored `build/` folder.

## Building

Create the images once per machine. This step downloads packages, so it needs
the network; the builds themselves do not install anything further.

    podman build -f container-build/Containerfile.x86_64  -t codebrix-ncdbg-build-x86_64  container-build
    podman build -f container-build/Containerfile.aarch64 -t codebrix-ncdbg-build-aarch64 container-build

Then, per architecture:

    ./container-build/build-debugger.sh x64
    ./container-build/pack-package.sh   x64

    ./container-build/build-debugger.sh arm64
    ./container-build/pack-package.sh   arm64

`pack-package.sh` copies the requested architecture into the shared `bin/`
folder and then **refuses to pack unless the binary in `bin/` reports that
architecture itself**. `bin/` holds whichever build landed there last and the
packaging projects pack whatever they find, so this gate is the only thing
standing between a distracted afternoon and a package full of the wrong CPU's
binaries. Pass `--no-pack` to stage and verify without packing.

The arm64 image runs under qemu user-mode emulation on an x64 host; no arm64
hardware is needed to build. Both architectures build in a few minutes.

## Things that will bite you

**`libicu` is mandatory in the image.** Without it every `dotnet` invocation
dies with *"Couldn't find a valid ICU package installed on the system"* before
it does any work. A bare manylinux image does not have it. This is the only
package missing from the base that the .NET SDK actually requires.

**Use `/usr/bin/cmake`, not whatever is first on `PATH`.** The manylinux images
carry cmake 4.x ahead of the dnf-installed 3.26.5, and cmake 4 refuses this
tree's `cmake_minimum_required` floor. `build-debugger.sh` hard-codes the path.
The upstream CMake files are not ours to modify, so this stays a build-side fix.

**gcc will not work.** Upstream requires clang; this is not a CodeBrix choice.

**CoreCLR sources are shared between architectures.** They are
architecture-independent, so `build-debugger.sh` passes `-DCORECLR_DIR` when
`.coreclr/` already exists. That skips a large re-clone and, more usefully,
keeps both packages pinned to the same CoreCLR revision. Delete `.coreclr/` if
you deliberately want to move to a newer one.

**A debugger cannot be functionally tested under emulation.** The arm64 binary
starts, reports `--buildinfo`, and sets breakpoints under qemu, but process
control fails with `Error: 0x80004005: E_FAIL` / `No process.`. This is not a
build defect — the previously published binary, built natively on a Raspberry
Pi 5, fails identically in the same emulated container. qemu user-mode does not
emulate the `ptrace`-based process control the debugger depends on. **Do not
chase this failure.** Functional validation of the arm64 package needs real
arm64 hardware. The x64 build can and should be exercised on the build host.

**Driving `--interpreter=cli` from a pipe needs stdin held open.** Piping a
command list closes stdin, and the resulting EOF tears the session down before
the breakpoint binds, which looks exactly like a broken debugger. Keep the pipe
alive instead:

    ( printf 'break Program.cs:3\nrun\n'; sleep 12; printf 'print x\ncontinue\n'; sleep 5; printf 'quit\n'; sleep 2 ) \
        | ./bin/netcoredbg --interpreter=cli -- /path/to/app

## Verifying a build

    objdump -T container-build/output/linux-x64/netcoredbg | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1
    file -b container-build/output/linux-arm64/netcoredbg

The first should print `GLIBC_2.17`; the second should say `ARM aarch64`. After
packing, the same two checks against `tools/linux-<arch>/netcoredbg` inside the
`.nupkg` confirm the package carries what its name promises.
