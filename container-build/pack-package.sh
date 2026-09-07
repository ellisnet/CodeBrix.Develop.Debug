#!/usr/bin/env bash
#
# Stage one architecture's binaries into the shared bin/ folder and pack the
# matching NuGet package.
#
#     ./container-build/pack-package.sh x64
#     ./container-build/pack-package.sh arm64
#     ./container-build/pack-package.sh arm64 --no-pack   (stage + verify only)
#
# WHY THIS SCRIPT EXISTS: bin/ is a SHARED folder that holds whichever
# architecture was installed into it last, and the packaging projects pack
# whatever they find there. Packing the x64 package from a bin/ holding an
# arm64 build produces a silently wrong package that nothing else checks. This
# script copies the requested architecture in and then REFUSES to pack unless
# the binary in bin/ reports that architecture itself.
#
set -euo pipefail

ARCH="${1:-}"
NOPACK="${2:-}"
case "$ARCH" in
  x64)   PROJECT=CodeBrix.Develop.Debug.LinuxX64  ;;
  arm64) PROJECT=CodeBrix.Develop.Debug.LinuxArm64;;
  *) echo "usage: ${0##*/} x64|arm64 [--no-pack]" >&2; exit 2 ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
SRC="$REPO/container-build/output/linux-$ARCH"

FILES="netcoredbg ManagedPart.dll libdbgshim.so
       Microsoft.CodeAnalysis.dll Microsoft.CodeAnalysis.CSharp.dll
       Microsoft.CodeAnalysis.Scripting.dll Microsoft.CodeAnalysis.CSharp.Scripting.dll"

for f in $FILES; do
  [ -f "$SRC/$f" ] || { echo "missing $SRC/$f - run build-debugger.sh $ARCH first" >&2; exit 1; }
done

echo "=== staging linux-$ARCH into bin/ ==="
mkdir -p "$REPO/bin"
for f in $FILES; do cp -f "$SRC/$f" "$REPO/bin/$f"; done
chmod +x "$REPO/bin/netcoredbg"

# The gate. An arm64 binary cannot run on an x64 host, so ask the matching
# container to read it when the architectures differ.
echo "=== verifying bin/ really holds $ARCH ==="
# `|| true` matters: a wrong-architecture binary fails to exec at all, and
# without it `set -e` would kill the script here with a bare non-zero status
# instead of reaching the explicit, readable failure below.
REPORTED=""
case "$(uname -m):$ARCH" in
  x86_64:x64|aarch64:arm64)
    REPORTED=$("$REPO/bin/netcoredbg" --buildinfo 2>/dev/null | awk '/Target arch:/{print $3}') || true ;;
  *)
    IMG=codebrix-ncdbg-build-aarch64:latest
    [ "$ARCH" = x64 ] && IMG=codebrix-ncdbg-build-x86_64:latest
    REPORTED=$(podman run --rm -v "$REPO/bin":/nc:ro "$IMG" \
                 /nc/netcoredbg --buildinfo 2>/dev/null | awk '/Target arch:/{print $3}') || true ;;
esac

echo "bin/ reports: ${REPORTED:-<none>}"
[ "$REPORTED" = "$ARCH" ] || { echo "ABORT: bin/ does not hold $ARCH - refusing to pack" >&2; exit 1; }

if [ "$NOPACK" = "--no-pack" ]; then
  echo "--no-pack given; stopping after verification."
  exit 0
fi

echo "=== packing $PROJECT ==="
cd "$REPO/nuget/$PROJECT"
dotnet build -c Release | grep -E "Successfully created package|Warning\(s\)|Error\(s\)"
