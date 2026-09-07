================================================================================
README-INDEX: CodeBrix.Develop.Debug
Map of the README files in this repository
================================================================================

If you are an AI coding agent: find the NuGet package you are consuming below
and read its AGENT-README file in full. Read MAINTAINER-README.txt only if you
are changing this repository itself.

AGENT-README FILES (consumer documentation, one per NuGet package)
------------------------------------------------------------------
  AGENT-README.txt
      CodeBrix.Develop.Debug.LinuxX64 and CodeBrix.Develop.Debug.LinuxArm64 —
      the .NET debugger as linux-x64 / linux-arm64 native binaries, copied into
      your app's output folder — and CodeBrix.Develop.Debug.AndroidArm64 and
      CodeBrix.Develop.Debug.AndroidX64 — the same debugger built to run ON an
      Android device (arm64-v8a / x86_64) to debug .NET 11 CoreCLR Android
      apps over an adb-forwarded Debug Adapter Protocol port. ONE file covers
      all four packages; reference exactly one Linux package (matching the
      architecture your application runs on) and either or both Android
      packages (they land in separate folders, chosen by device ABI at run time).

MAINTAINER AND EXTRAS
---------------------
  MAINTAINER-README.txt
      Building, testing, packaging, versioning and provenance notes for
      maintainers.
  EXTRAS-README.txt
      Samples, tools and other non-package content in this repository.
  container-build/README.md
      How the published debugger binaries are built in manylinux containers,
      and why a plain host build must not be published.
  android/README.md
      The Android debugging bundle (arm64-v8a + x86_64): the runbook for
      building the on-device debugger pieces, proving them on a device (attach,
      a scripted debug session, and a remote Debug Adapter Protocol session
      over adb), packing the two Android NuGet packages, and the reference
      (how it works, the Android specifics, the roadmap).

GENERAL
-------
  README.md
      Human-facing overview shown on GitHub. It is NOT packed into either
      nupkg — each package ships its own readme, listed below.
  nuget/CodeBrix.Develop.Debug.LinuxX64/README.md
      The nuget.org readme for CodeBrix.Develop.Debug.LinuxX64.
  nuget/CodeBrix.Develop.Debug.LinuxArm64/README.md
      The nuget.org readme for CodeBrix.Develop.Debug.LinuxArm64.
  android/nuget/CodeBrix.Develop.Debug.AndroidArm64/README.md
      The nuget.org readme for CodeBrix.Develop.Debug.AndroidArm64.
  android/nuget/CodeBrix.Develop.Debug.AndroidX64/README.md
      The nuget.org readme for CodeBrix.Develop.Debug.AndroidX64.
  android/NOTICE.txt
      Provenance and licences of everything vendored or prebuilt under android/.
  THIRD-PARTY-NOTICES.txt
      What came from where, and under which licences.
  README-INDEX.txt
      This file.
================================================================================
