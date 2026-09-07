#!/usr/bin/env bash
# Build the debugger's MANAGED helper payload and refresh ./prebuilt/managed/.
#
# ManagedPart.dll is netcoredbg's symbol reader + expression evaluator; on the
# phone it runs inside a second CoreCLR that netcoredbg hosts in its own process.
# Part 3 (a real debug session: breakpoints, stepping, locals, expressions) needs
# it. Part 2 (the dbgshim attach proof) does not.
#
# Source is the PARENT repo's src/managed/ (ManagedPart.csproj + the four .cs
# files) -- part of this clone, MIT, same as netcoredbg. Its Roslyn dependency
# comes from nuget.org at build time. The payload is ARCHITECTURE-INDEPENDENT
# (netstandard2.0), so this same output is used on any device.
#
# We ship exactly five DLLs: ManagedPart.dll + the four Microsoft.CodeAnalysis*
# (Roslyn 2.3.0). ManagedPart's OTHER managed dependencies (System.Reflection.
# Metadata, System.Collections.Immutable, Microsoft.CSharp, System.Linq.
# Expressions, System.Reflection.Emit.*, ...) are NOT shipped: on the device they
# are loaded from the debuggee app's own .NET framework (the run scripts redirect
# the host runtime's assembly probes there). Roslyn is the exception because it is
# a NuGet package, not part of the framework, so it must travel with the debugger.
#
# Requirements: a `dotnet` on PATH. The SYSTEM .NET 10 SDK (10.0.400) is fine;
# the .NET 11 preview is NOT needed to build this. No NDK, no device.
#
# Output: ./prebuilt/managed/{ManagedPart,Microsoft.CodeAnalysis[.CSharp][.Scripting]}.dll
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
CSPROJ="$REPO/src/managed/ManagedPart.csproj"
OUT="$HERE/prebuilt/managed"
[ -f "$CSPROJ" ] || { echo "ERROR: $CSPROJ not found (run from a full clone of the repo)."; exit 1; }
command -v dotnet >/dev/null || { echo "ERROR: dotnet not on PATH."; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# publish (not build): a library `build` does not copy its NuGet dependencies, so
# it would emit ManagedPart.dll WITHOUT Roslyn. `publish` brings the full closure.
dotnet publish -c Release "$CSPROJ" -o "$TMP" >/dev/null

mkdir -p "$OUT"
for f in ManagedPart.dll \
         Microsoft.CodeAnalysis.dll \
         Microsoft.CodeAnalysis.CSharp.dll \
         Microsoft.CodeAnalysis.Scripting.dll \
         Microsoft.CodeAnalysis.CSharp.Scripting.dll; do
    [ -f "$TMP/$f" ] || { echo "ERROR: $f missing from publish output"; exit 1; }
    cp "$TMP/$f" "$OUT/$f"
done
echo "=== refreshed managed helper payload in $OUT"
ls -la "$OUT"
