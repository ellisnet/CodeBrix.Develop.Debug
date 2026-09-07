#!/usr/bin/env bash
# Pack the two Android NuGet packages from the committed prebuilt payload:
#
#     android/scripts/pack-android-packages.sh            pack both (arm64-v8a + x86_64)
#     android/scripts/pack-android-packages.sh arm64-v8a  pack one ABI
#     android/scripts/pack-android-packages.sh x86_64
#
# The packages are android/nuget/CodeBrix.Develop.Debug.AndroidArm64 (ABI arm64-v8a) and
# android/nuget/CodeBrix.Develop.Debug.AndroidX64 (ABI x86_64). Each packs its prebuilt
# netcoredbg + libdbgshim.so from ../*/prebuilt/<abi>/ plus the architecture-independent
# managed helper from ../netcoredbg/prebuilt/managed/. Rebuild those FIRST when the source
# changed (build-netcoredbg-android.sh <abi>, build-dbgshim-android.sh <abi>,
# build-managed-helper.sh); this script only checks that they exist, are the right
# architecture, and carry the built-in Android compatibility layer, then packs.
#
# Needs: a system `dotnet` (10.x) on PATH and the NDK's llvm-readelf/llvm-nm (for the checks).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
NDK="${ANDROID_NDK_ROOT:-$HOME/Android/Sdk/ndk/29.0.14206865}"
READELF="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf"
NM="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-nm"
ABIS="${1:-arm64-v8a x86_64}"

for ABI in $ABIS; do
  case "$ABI" in
    arm64-v8a) PROJECT=CodeBrix.Develop.Debug.AndroidArm64; MACHINE="AArch64" ;;
    x86_64)    PROJECT=CodeBrix.Develop.Debug.AndroidX64;   MACHINE="X86-64" ;;
    *) echo "usage: ${0##*/} [arm64-v8a|x86_64]" >&2; exit 2 ;;
  esac
  NCDBG="$ROOT/netcoredbg/prebuilt/$ABI/netcoredbg"
  SHIM="$ROOT/dbgshim/prebuilt/$ABI/libdbgshim.so"
  MANAGED="$ROOT/netcoredbg/prebuilt/managed"
  for f in "$NCDBG" "$SHIM" "$MANAGED/ManagedPart.dll" "$MANAGED/Microsoft.CodeAnalysis.dll" \
           "$MANAGED/Microsoft.CodeAnalysis.CSharp.dll" "$MANAGED/Microsoft.CodeAnalysis.Scripting.dll" \
           "$MANAGED/Microsoft.CodeAnalysis.CSharp.Scripting.dll"; do
    [ -f "$f" ] || { echo "ABORT: missing $f - run the build-*.sh scripts first" >&2; exit 1; }
  done

  echo "=== verifying the $ABI payload ==="
  if [ -x "$READELF" ]; then
    for bin in "$NCDBG" "$SHIM"; do
      M="$("$READELF" -h "$bin" | awk -F: '/Machine:/{gsub(/^ +/,"",$2); print $2}')"
      case "$M" in *"$MACHINE"*) echo "  $(basename "$bin"): $M" ;; *) echo "ABORT: $bin is '$M', expected $MACHINE" >&2; exit 1 ;; esac
    done
    # The Android compatibility layer exports these from the executable (see src/utils/android_compat.cpp).
    EXPORTED="$("$NM" -D --defined-only "$NCDBG" | awk '{print $3}' | grep -cE '^(kill|open|openat|__open_2|__openat_2|open64)$' || true)"
    if [ "$EXPORTED" -lt 6 ]; then
      echo "ABORT: $NCDBG exports only $EXPORTED of the 6 compat symbols - rebuild it with build-netcoredbg-android.sh $ABI" >&2; exit 1
    fi
    echo "  netcoredbg exports the 6 Android compat symbols"
  else
    echo "  (NDK llvm-readelf not found at $READELF - skipping the architecture/symbol checks)"
  fi

  echo "=== packing $PROJECT ==="
  ( cd "$ROOT/nuget/$PROJECT" && dotnet build -c Release -nologo -v:minimal | grep -E "Successfully created package|warning|error" || true )
  ls -1t "$ROOT/nuget/$PROJECT/bin/Release/"*.nupkg | head -1
done
