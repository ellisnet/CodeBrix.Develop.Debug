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
      your app's output folder. ONE file covers both packages; reference
      exactly one of them, matching the architecture your application runs on.

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
      The Android arm64 debugging bundle: runbook for building, deploying and
      debugging a .NET 11 CoreCLR Android app on a phone with this debugger,
      plus the full research record behind it.

GENERAL
-------
  README.md
      Human-facing overview shown on GitHub. It is NOT packed into either
      nupkg — each package ships its own readme, listed below.
  nuget/CodeBrix.Develop.Debug.LinuxX64/README.md
      The nuget.org readme for CodeBrix.Develop.Debug.LinuxX64.
  nuget/CodeBrix.Develop.Debug.LinuxArm64/README.md
      The nuget.org readme for CodeBrix.Develop.Debug.LinuxArm64.
  THIRD-PARTY-NOTICES.txt
      What came from where, and under which licences.
  README-INDEX.txt
      This file.
================================================================================
