#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <semaphore.h>
#include <sys/uio.h>
#include <sys/ptrace.h>
#include <sys/socket.h>
#include <sys/syscall.h>
static int tracefd = -1;
static void logline(const char *fmt, ...) {
    char buf[1024]; va_list ap; va_start(ap, fmt); int n = vsnprintf(buf, sizeof buf, fmt, ap); va_end(ap);
    if (tracefd < 0) { const char *p = getenv("TRACE_OUT"); tracefd = p ? syscall(__NR_openat, AT_FDCWD, p, O_WRONLY|O_CREAT|O_APPEND, 0644) : 2; if (tracefd < 0) tracefd = 2; }
    if (n > 0) write(tracefd, buf, n < (int)sizeof buf ? n : (int)sizeof buf);
}
#define REAL(name) static __typeof__(name) *real_##name; if (!real_##name) real_##name = (__typeof__(name)*)dlsym(RTLD_NEXT, #name)
static int interesting(const char *p) { return p && (strstr(p, "clr-debug") || strstr(p, "/proc/") || strstr(p, "/data/") || strstr(p, "/tmp")); }
static const char *redirect(const char *path, char *scratch, size_t n) {
    const char *dir = getenv("TRACE_REDIR_DIR");
    if (!dir || !path) return path;
    size_t l = strlen(path);
    int isdll = (l > 4 && strcmp(path + l - 4, ".dll") == 0);
    int ispdb = (l > 4 && strcmp(path + l - 4, ".pdb") == 0);
    if (!isdll && !ispdb) return path;
    /* only redirect when the original does not exist */
    if (access(path, F_OK) == 0) return path;
    const char *base = strrchr(path, '/'); base = base ? base + 1 : path;
    snprintf(scratch, n, "%s/%s", dir, base);
    if (access(scratch, F_OK) == 0) { logline("[trace] REDIR %s -> %s\n", path, scratch); return scratch; }
    return path;
}

int open(const char *path, int flags, ...) {
    mode_t mode = 0; if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = va_arg(ap, int); va_end(ap); }
    char sc[512]; path = redirect(path, sc, sizeof sc);
    REAL(open); int r = real_open(path, flags, mode); int e = errno;
    if (interesting(path)) logline("[trace] open(\"%s\", 0x%x) = %d %s\n", path, flags, r, r < 0 ? strerror(e) : "");
    errno = e; return r;
}
int open64(const char *path, int flags, ...) {
    mode_t mode = 0; if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = va_arg(ap, int); va_end(ap); }
    char sc[512]; path = redirect(path, sc, sizeof sc);
    REAL(open64); int r = real_open64(path, flags, mode); int e = errno;
    if (interesting(path)) logline("[trace] open64(\"%s\", 0x%x) = %d %s\n", path, flags, r, r < 0 ? strerror(e) : "");
    errno = e; return r;
}
int openat(int dirfd, const char *path, int flags, ...) {
    mode_t mode = 0; if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = va_arg(ap, int); va_end(ap); }
    char sc[512]; if (dirfd == AT_FDCWD || path[0] == '/') path = redirect(path, sc, sizeof sc);
    REAL(openat); int r = real_openat(dirfd, path, flags, mode); int e = errno;
    if (interesting(path)) logline("[trace] openat(%d, \"%s\", 0x%x) = %d %s\n", dirfd, path, flags, r, r < 0 ? strerror(e) : "");
    errno = e; return r;
}
ssize_t process_vm_readv(pid_t pid, const struct iovec *lv, unsigned long lc, const struct iovec *rv, unsigned long rc, unsigned long fl) {
    REAL(process_vm_readv); ssize_t r = real_process_vm_readv(pid, lv, lc, rv, rc, fl); int e = errno;
    static int n; if (r < 0 || n++ < 3) logline("[trace] process_vm_readv(pid %d, remote %p len %zu) = %zd %s\n", pid, rc ? rv[0].iov_base : NULL, rc ? rv[0].iov_len : 0, r, r < 0 ? strerror(e) : "");
    errno = e; return r;
}
long ptrace(int req, ...) {
    va_list ap; va_start(ap, req); pid_t pid = va_arg(ap, pid_t); void *addr = va_arg(ap, void*); void *data = va_arg(ap, void*); va_end(ap);
    REAL(ptrace); long r = real_ptrace(req, pid, addr, data); int e = errno;
    logline("[trace] ptrace(req %d, pid %d) = %ld %s\n", req, pid, r, r < 0 ? strerror(e) : "");
    errno = e; return r;
}
int kill(pid_t pid, int sig) {
    REAL(kill); int r = real_kill(pid, sig); int e = errno;
    logline("[trace] kill(%d, %d) = %d %s\n", pid, sig, r, r < 0 ? strerror(e) : "");
    if (r < 0 && sig == 0 && (e == EPERM || e == EACCES) && getenv("TRACE_MASK_KILL0")) {
        char path[32]; snprintf(path, sizeof path, "/proc/%d", pid);
        if (access(path, F_OK) == 0) { logline("[trace]   -> masked: /proc/%d exists, returning 0\n", pid); return 0; }
        logline("[trace]   -> masked: /proc/%d gone, returning ESRCH\n", pid); errno = ESRCH; return -1;
    }
    errno = e; return r;
}
int socket(int d, int t, int p) { REAL(socket); int r = real_socket(d, t, p); int e = errno; logline("[trace] socket(%d,%d,%d) = %d %s\n", d, t, p, r, r < 0 ? strerror(e) : ""); errno = e; return r; }
int connect(int fd, const struct sockaddr *a, socklen_t l) { REAL(connect); int r = real_connect(fd, a, l); int e = errno; logline("[trace] connect(fd %d) = %d %s\n", fd, r, r < 0 ? strerror(e) : ""); errno = e; return r; }
/* ---- fortify entry points and pipe traffic ---- */
static int pipefds[64];
static void track(const char *path, int fd) { if (fd >= 0 && fd < 64 && path && strstr(path, "clr-debug")) pipefds[fd] = 1; }
int __open_2(const char *path, int flags) {
    char sc[512]; path = redirect(path, sc, sizeof sc);
    REAL(__open_2); int r = real___open_2(path, flags); int e = errno;
    if (interesting(path)) logline("[trace] __open_2(\"%s\", 0x%x) = %d %s\n", path, flags, r, r < 0 ? strerror(e) : "");
    track(path, r); errno = e; return r;
}
int __openat_2(int dirfd, const char *path, int flags) {
    char sc[512]; if (dirfd == AT_FDCWD || path[0] == '/') path = redirect(path, sc, sizeof sc);
    REAL(__openat_2); int r = real___openat_2(dirfd, path, flags); int e = errno;
    if (interesting(path)) logline("[trace] __openat_2(%d, \"%s\", 0x%x) = %d %s\n", dirfd, path, flags, r, r < 0 ? strerror(e) : "");
    track(path, r); errno = e; return r;
}
static void hexdump(char *out, size_t outsz, const void *p, size_t n) { const unsigned char *b = p; size_t o = 0; for (size_t i = 0; i < n && o + 3 < outsz; i++) o += snprintf(out + o, outsz - o, "%02x ", b[i]); }
ssize_t write(int fd, const void *buf, size_t n) {
    REAL(write); ssize_t r = real_write(fd, buf, n); int e = errno;
    if (fd >= 0 && fd < 64 && pipefds[fd]) { char h[80]; hexdump(h, sizeof h, buf, n < 24 ? n : 24); logline("[trace] write(pipe fd %d, %zu) = %zd %s [%s]\n", fd, n, r, r < 0 ? strerror(e) : "", h); }
    errno = e; return r;
}
ssize_t read(int fd, void *buf, size_t n) {
    REAL(read); ssize_t r = real_read(fd, buf, n); int e = errno;
    if (fd >= 0 && fd < 64 && pipefds[fd]) { char h[80] = ""; if (r > 0) hexdump(h, sizeof h, buf, r < 24 ? r : 24); logline("[trace] read(pipe fd %d, %zu) = %zd %s [%s]\n", fd, n, r, r < 0 ? strerror(e) : "", h); }
    errno = e; return r;
}
int close(int fd) {
    REAL(close); int r = real_close(fd); int e = errno;
    if (fd >= 0 && fd < 64 && pipefds[fd]) { logline("[trace] close(pipe fd %d) = %d\n", fd, r); pipefds[fd] = 0; }
    errno = e; return r;
}
/* ---- named-semaphore emulation (Android bionic sem_open is ENOSYS) ---- */
#include <pthread.h>
struct named_sem { char name[128]; sem_t sem; int used; };
static struct named_sem g_sems[64];
static pthread_mutex_t g_sems_lock = PTHREAD_MUTEX_INITIALIZER;
sem_t *sem_open(const char *name, int flags, ...) {
    if (!getenv("TRACE_EMU_SEM")) {
        REAL(sem_open); mode_t mode = 0; unsigned value = 0;
        if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = va_arg(ap, int); value = va_arg(ap, unsigned); va_end(ap); }
        sem_t *r = real_sem_open(name, flags, mode, value); int e = errno;
        logline("[trace] sem_open(\"%s\", 0x%x) = %p %s\n", name, flags, r, r == SEM_FAILED ? strerror(e) : ""); errno = e; return r;
    }
    unsigned value = 0; if (flags & O_CREAT) { va_list ap; va_start(ap, flags); (void)va_arg(ap, int); value = va_arg(ap, unsigned); va_end(ap); }
    pthread_mutex_lock(&g_sems_lock);
    struct named_sem *slot = NULL, *freeslot = NULL;
    for (int i = 0; i < 64; i++) {
        if (g_sems[i].used && strcmp(g_sems[i].name, name) == 0) { slot = &g_sems[i]; break; }
        if (!g_sems[i].used && !freeslot) freeslot = &g_sems[i];
    }
    sem_t *ret = SEM_FAILED;
    if (slot) {
        if ((flags & O_CREAT) && (flags & O_EXCL)) { errno = EEXIST; }
        else ret = &slot->sem;
    } else if ((flags & O_CREAT) && freeslot) {
        strncpy(freeslot->name, name, sizeof(freeslot->name) - 1); freeslot->name[sizeof(freeslot->name)-1] = 0;
        sem_init(&freeslot->sem, 1 /*pshared*/, value); freeslot->used = 1; ret = &freeslot->sem;
    } else if (!slot) { errno = ENOENT; }
    pthread_mutex_unlock(&g_sems_lock);
    logline("[trace] sem_open(EMU \"%s\", 0x%x) = %s\n", name, flags, ret == SEM_FAILED ? "FAILED" : "ok");
    return ret;
}
int sem_close(sem_t *s) { logline("[trace] sem_close(EMU)\n"); return 0; }
int sem_unlink(const char *name) {
    if (!getenv("TRACE_EMU_SEM")) { REAL(sem_unlink); return real_sem_unlink(name); }
    pthread_mutex_lock(&g_sems_lock);
    for (int i = 0; i < 64; i++) if (g_sems[i].used && strcmp(g_sems[i].name, name) == 0) { sem_destroy(&g_sems[i].sem); g_sems[i].used = 0; }
    pthread_mutex_unlock(&g_sems_lock);
    logline("[trace] sem_unlink(EMU \"%s\")\n", name); return 0;
}

/* ---- opendir redirect: point the TPA scan at the real framework dir ---- */
#include <dirent.h>
DIR *opendir(const char *name) {
    REAL(opendir);
    const char *tpa = getenv("TRACE_TPA_DIR");
    const char *clrdir = getenv("TRACE_CLR_DIR");
    if (tpa && clrdir && name && strcmp(name, clrdir) == 0) {
        logline("[trace] opendir REDIR %s -> %s\n", name, tpa);
        return real_opendir(tpa);
    }
    return real_opendir(name);
}
