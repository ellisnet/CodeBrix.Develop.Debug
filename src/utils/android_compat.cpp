// Copyright (c) 2026 Jeremy Ellis and contributors
// See the LICENSE file in the project root for more information.

/// \file android_compat.cpp
/// Android-only libc compatibility layer, compiled INTO the netcoredbg binary
/// (see the ANDROID branch in src/CMakeLists.txt). It replaces the LD_PRELOAD
/// proof harness in android/harness/trace.c, so nothing has to be preloaded on
/// the device. This file is not part of any non-Android build.
///
/// Two Android facts are handled here:
///
///  1. SELinux denies kill(pid, 0) across the `run-as` -> app domain boundary
///     even at the same uid (avc: denied { signull }). The PAL inside
///     libmscordbi.so uses that call as its "is the debuggee still alive?"
///     probe and reads EPERM as "the process is gone", which aborts the attach.
///     The kill() below answers the signal-0 probe from /proc/<pid> instead.
///     Always active on Android; no environment variable needed.
///
///  2. The debuggee's managed assemblies are not next to libcoreclr.so. The
///     APK's native library directory is read-only and holds only .so files,
///     while the assemblies live in the app's
///     /data/data/<pkg>/files/.__override__/<abi>/ directory. mscordbi and the
///     DAC open "<clrDir>/<name>.dll" (and the app's .pdb) and fail. The open
///     family below retries a failing *.dll / *.pdb open from the directory
///     named by NETCOREDBG_ANDROID_ASSEMBLY_DIR. Only active when that variable
///     is set to a non-empty value.
///
/// The bionic fortify entry points __open_2 / __openat_2 are interposed too:
/// code compiled with _FORTIFY_SOURCE (the NDK default, and what the loaded
/// runtime libraries are built with) calls those instead of open / openat.
///
/// These definitions must end up in the executable's dynamic symbol table:
/// bionic resolves the symbols of every dlopen()ed library against the global
/// group first, and the executable heads that group (executable, LD_PRELOAD,
/// DT_NEEDED). That is what makes libdbgshim.so, libmscordbi.so,
/// libmscordaccore.so and the hosted libcoreclr.so pick these up instead of
/// libc's. src/CMakeLists.txt links the Android binary with one
/// -Wl,--export-dynamic-symbol=<name> per interposer for exactly that reason,
/// and every definition here carries default visibility in case the build
/// ever turns on -fvisibility=hidden.
///
/// Environment variables read by this file:
///   NETCOREDBG_ANDROID_ASSEMBLY_DIR  Directory holding the debuggee's managed
///                                    assemblies. Enables the *.dll / *.pdb
///                                    open retry. Unset or empty: no redirect.
///   NETCOREDBG_ANDROID_TRACE         Path of a file that receives one line per
///                                    redirect or kill(pid, 0) decision.
///                                    Unset or empty: no tracing. Untouched
///                                    calls are never logged.

// bionic's fortify headers turn open() / openat() / open64() into inline
// overloads, which cannot coexist with out-of-line definitions of the same
// symbols in this translation unit. Turn fortify off for THIS FILE ONLY (the
// NDK toolchain file passes -D_FORTIFY_SOURCE=2 for the whole build); every
// other source file keeps the toolchain default.
#undef _FORTIFY_SOURCE
#define _FORTIFY_SOURCE 0

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <unistd.h>

// Declared by <bits/fortify/fcntl.h>, which is only reachable with fortify
// enabled -- and fortify is off in this file (see above).
extern "C" int __open_2(const char *path, int flags);
extern "C" int __openat_2(int dirfd, const char *path, int flags);

// The interposed symbols have to survive -fvisibility=hidden and any dead
// symbol stripping, whatever the build ever switches on.
#define ANDROID_COMPAT_EXPORT __attribute__((visibility("default"), used))

namespace
{

typedef int (*KillFn)(pid_t pid, int sig);
typedef int (*OpenFn)(const char *path, int flags, ...);
typedef int (*OpenatFn)(int dirfd, const char *path, int flags, ...);
typedef int (*Open2Fn)(const char *path, int flags);
typedef int (*Openat2Fn)(int dirfd, const char *path, int flags);

const size_t PathBufferSize = 1024;

const char EnvAssemblyDir[] = "NETCOREDBG_ANDROID_ASSEMBLY_DIR";
const char EnvTraceFile[] = "NETCOREDBG_ANDROID_TRACE";

pthread_once_t g_initOnce = PTHREAD_ONCE_INIT;
char g_assemblyDir[PathBufferSize];
int g_traceFd = -1;

// Read the environment exactly once. getenv() returns a pointer into `environ',
// so the value is copied out rather than cached as a pointer.
void InitFromEnv()
{
    const char *dir = getenv(EnvAssemblyDir);
    if (dir != nullptr && dir[0] != '\0' && strlen(dir) < sizeof(g_assemblyDir))
        strcpy(g_assemblyDir, dir);

    const char *tracePath = getenv(EnvTraceFile);
    if (tracePath != nullptr && tracePath[0] != '\0')
    {
        // Straight to the kernel: this must not re-enter the open() below.
        g_traceFd = (int)syscall(__NR_openat, AT_FDCWD, tracePath,
                                 O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    }
}

inline void EnsureInit()
{
    pthread_once(&g_initOnce, InitFromEnv);
}

// One line per decision, and only for calls this file actually changed.
// errno is preserved: callers inspect it right after the interposed call.
void TraceLine(const char *format, ...)
{
    if (g_traceFd < 0)
        return;

    int savedErrno = errno;

    char buffer[PathBufferSize * 2 + 128];
    va_list args;
    va_start(args, format);
    int length = vsnprintf(buffer, sizeof(buffer), format, args);
    va_end(args);

    if (length > 0)
    {
        if (length >= (int)sizeof(buffer))
            length = (int)sizeof(buffer) - 1;

        ssize_t ignored = write(g_traceFd, buffer, (size_t)length);
        (void)ignored;
    }

    errno = savedErrno;
}

// Last-resort forwarding when dlsym(RTLD_NEXT, ...) cannot find the real libc
// entry point. aarch64 has no __NR_open, so openat is used for both.
inline int SyscallOpenat(int dirfd, const char *path, int flags, mode_t mode)
{
    return (int)syscall(__NR_openat, dirfd, path, flags, mode);
}

inline bool FlagsCarryMode(int flags)
{
#ifdef O_TMPFILE
    if ((flags & O_TMPFILE) == O_TMPFILE)
        return true;
#endif
    return (flags & O_CREAT) != 0;
}

// Returns `path' unchanged unless every one of these holds:
//   - NETCOREDBG_ANDROID_ASSEMBLY_DIR is set and non-empty;
//   - the path ends with ".dll" or ".pdb";
//   - the path does NOT exist;
//   - "<assembly dir>/<basename>" DOES exist.
// In that case the replacement path is written into `scratch' and returned.
const char *RedirectPath(const char *path, char *scratch, size_t scratchSize)
{
    if (path == nullptr || g_assemblyDir[0] == '\0')
        return path;

    size_t length = strlen(path);
    if (length <= 4)
        return path;

    const char *extension = path + length - 4;
    if (strcmp(extension, ".dll") != 0 && strcmp(extension, ".pdb") != 0)
        return path;

    // Only step in when the original really is missing.
    if (access(path, F_OK) == 0)
        return path;

    const char *baseName = strrchr(path, '/');
    baseName = (baseName != nullptr) ? baseName + 1 : path;

    int written = snprintf(scratch, scratchSize, "%s/%s", g_assemblyDir, baseName);
    if (written <= 0 || (size_t)written >= scratchSize)
        return path;

    if (access(scratch, F_OK) != 0)
        return path;

    TraceLine("[android_compat] redirect \"%s\" -> \"%s\"\n", path, scratch);
    return scratch;
}

} // unnamed namespace

// The PAL's liveness probe. Pass-through in every case except the one SELinux
// breaks: a signal-0 probe refused with EPERM/EACCES is answered from /proc.
extern "C" ANDROID_COMPAT_EXPORT int kill(pid_t pid, int sig)
{
    static KillFn realKill = nullptr;
    if (realKill == nullptr)
        realKill = reinterpret_cast<KillFn>(dlsym(RTLD_NEXT, "kill"));

    int result = (realKill != nullptr) ? realKill(pid, sig) : (int)syscall(__NR_kill, pid, sig);
    if (result >= 0 || sig != 0)
        return result;

    int savedErrno = errno;
    if (savedErrno != EPERM && savedErrno != EACCES)
    {
        errno = savedErrno;
        return result;
    }

    EnsureInit();

    char procPath[64];
    snprintf(procPath, sizeof(procPath), "/proc/%d", (int)pid);

    if (access(procPath, F_OK) == 0)
    {
        TraceLine("[android_compat] kill(%d, 0) %s masked: /proc/%d exists, returning 0\n",
                  (int)pid, (savedErrno == EPERM) ? "EPERM" : "EACCES", (int)pid);
        errno = savedErrno;
        return 0;
    }

    TraceLine("[android_compat] kill(%d, 0) %s masked: /proc/%d gone, returning ESRCH\n",
              (int)pid, (savedErrno == EPERM) ? "EPERM" : "EACCES", (int)pid);
    errno = ESRCH;
    return -1;
}

extern "C" ANDROID_COMPAT_EXPORT int open(const char *path, int flags, ...)
{
    mode_t mode = 0;
    if (FlagsCarryMode(flags))
    {
        va_list args;
        va_start(args, flags);
        mode = (mode_t)va_arg(args, int);
        va_end(args);
    }

    EnsureInit();

    char scratch[PathBufferSize];
    const char *actualPath = RedirectPath(path, scratch, sizeof(scratch));

    static OpenFn realOpen = nullptr;
    if (realOpen == nullptr)
        realOpen = reinterpret_cast<OpenFn>(dlsym(RTLD_NEXT, "open"));

    if (realOpen != nullptr)
        return realOpen(actualPath, flags, mode);

    return SyscallOpenat(AT_FDCWD, actualPath, flags, mode);
}

extern "C" ANDROID_COMPAT_EXPORT int open64(const char *path, int flags, ...)
{
    mode_t mode = 0;
    if (FlagsCarryMode(flags))
    {
        va_list args;
        va_start(args, flags);
        mode = (mode_t)va_arg(args, int);
        va_end(args);
    }

    EnsureInit();

    char scratch[PathBufferSize];
    const char *actualPath = RedirectPath(path, scratch, sizeof(scratch));

    static OpenFn realOpen64 = nullptr;
    if (realOpen64 == nullptr)
        realOpen64 = reinterpret_cast<OpenFn>(dlsym(RTLD_NEXT, "open64"));

    if (realOpen64 != nullptr)
        return realOpen64(actualPath, flags, mode);

    return SyscallOpenat(AT_FDCWD, actualPath, flags, mode);
}

extern "C" ANDROID_COMPAT_EXPORT int openat(int dirfd, const char *path, int flags, ...)
{
    mode_t mode = 0;
    if (FlagsCarryMode(flags))
    {
        va_list args;
        va_start(args, flags);
        mode = (mode_t)va_arg(args, int);
        va_end(args);
    }

    EnsureInit();

    // A relative path against a real directory fd is not ours to rewrite.
    char scratch[PathBufferSize];
    const char *actualPath = path;
    if (path != nullptr && (dirfd == AT_FDCWD || path[0] == '/'))
        actualPath = RedirectPath(path, scratch, sizeof(scratch));

    static OpenatFn realOpenat = nullptr;
    if (realOpenat == nullptr)
        realOpenat = reinterpret_cast<OpenatFn>(dlsym(RTLD_NEXT, "openat"));

    if (realOpenat != nullptr)
        return realOpenat(dirfd, actualPath, flags, mode);

    return SyscallOpenat(dirfd, actualPath, flags, mode);
}

// bionic fortify entry point for open(path, flags) with no mode.
extern "C" ANDROID_COMPAT_EXPORT int __open_2(const char *path, int flags)
{
    EnsureInit();

    char scratch[PathBufferSize];
    const char *actualPath = RedirectPath(path, scratch, sizeof(scratch));

    static Open2Fn realOpen2 = nullptr;
    if (realOpen2 == nullptr)
        realOpen2 = reinterpret_cast<Open2Fn>(dlsym(RTLD_NEXT, "__open_2"));

    if (realOpen2 != nullptr)
        return realOpen2(actualPath, flags);

    return SyscallOpenat(AT_FDCWD, actualPath, flags, 0);
}

// bionic fortify entry point for openat(dirfd, path, flags) with no mode.
extern "C" ANDROID_COMPAT_EXPORT int __openat_2(int dirfd, const char *path, int flags)
{
    EnsureInit();

    char scratch[PathBufferSize];
    const char *actualPath = path;
    if (path != nullptr && (dirfd == AT_FDCWD || path[0] == '/'))
        actualPath = RedirectPath(path, scratch, sizeof(scratch));

    static Openat2Fn realOpenat2 = nullptr;
    if (realOpenat2 == nullptr)
        realOpenat2 = reinterpret_cast<Openat2Fn>(dlsym(RTLD_NEXT, "__openat_2"));

    if (realOpenat2 != nullptr)
        return realOpenat2(dirfd, actualPath, flags);

    return SyscallOpenat(dirfd, actualPath, flags, 0);
}
