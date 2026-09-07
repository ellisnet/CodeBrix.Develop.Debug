#!/usr/bin/env bash
#
# Build the netcoredbg debugger for one Linux architecture inside a manylinux
# container, so the result carries a glibc 2.28-era floor rather than the build
# host's. Run this on the HOST; it drives podman.
#
#     ./container-build/build-debugger.sh x64
#     ./container-build/build-debugger.sh arm64
#
# Output goes to container-build/output/linux-<arch>/ - the seven files the
# matching nuget/ packaging project packs. Run pack-package.sh next.
#
# The container image must exist first (once per machine, needs the network):
#     podman build -f container-build/Containerfile.x86_64  -t codebrix-ncdbg-build-x86_64  container-build
#     podman build -f container-build/Containerfile.aarch64 -t codebrix-ncdbg-build-aarch64 container-build
#
set -euo pipefail

ARCH="${1:-}"
case "$ARCH" in
  x64)   IMAGE=codebrix-ncdbg-build-x86_64:latest  ; DOTNET_ARCH=x64   ;;
  arm64) IMAGE=codebrix-ncdbg-build-aarch64:latest ; DOTNET_ARCH=arm64 ;;
  *) echo "usage: ${0##*/} x64|arm64" >&2; exit 2 ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
OUT="container-build/output/linux-$ARCH"

echo "=== building netcoredbg for linux-$ARCH in $IMAGE ==="

# The repository is mounted at /src. Rootless podman maps container root to the
# invoking user, so everything written back is owned by that user.
podman run --rm -v "$REPO":/src -w /src "$IMAGE" bash -euo pipefail -c "
  WORK=/src/build/$ARCH          # cmake tree + SDK; /build/ is gitignored
  OUT=/src/$OUT                  # installed binaries; these ARE committed
  mkdir -p \$WORK/cmake \$WORK/dotnet \$OUT

  # A .NET SDK for the TARGET architecture. Kept per-architecture so the x64
  # and arm64 builds never overwrite each other's SDK.
  if [ ! -x \$WORK/dotnet/dotnet ]; then
    curl -sSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
    bash /tmp/dotnet-install.sh --channel 10.0 --architecture $DOTNET_ARCH \
         --install-dir \$WORK/dotnet
  fi
  echo \"SDK: \$(\$WORK/dotnet/dotnet --version)\"

  # CoreCLR sources are architecture-independent, so both architectures share
  # one checkout. cmake clones it on first use; passing -DCORECLR_DIR when it
  # already exists skips a large re-clone AND keeps both packages pinned to the
  # same CoreCLR revision.
  CORECLR_ARG=''
  if [ -d /src/.coreclr/src/coreclr ]; then
    CORECLR_ARG='-DCORECLR_DIR=/src/.coreclr/src/coreclr'
  fi

  cd \$WORK/cmake
  # /usr/bin/cmake explicitly: the manylinux image also carries cmake 4.x
  # earlier on PATH, and cmake 4 rejects this tree's cmake_minimum_required
  # floor. The upstream CMake files are not ours to modify.
  CC=clang CXX=clang++ /usr/bin/cmake /src \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=\$OUT \
      -DDOTNET_DIR=\$WORK/dotnet \
      \$CORECLR_ARG
  make -j\$(nproc)
  make install
"

chmod +x "$REPO/$OUT/netcoredbg"

echo
echo "=== $OUT ==="
ls -la "$REPO/$OUT"
echo
echo "glibc floor: $(objdump -T "$REPO/$OUT/netcoredbg" | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1)"
echo "next: ./container-build/pack-package.sh $ARCH"
