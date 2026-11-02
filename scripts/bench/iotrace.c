// Times every system call a process makes, without changing the process. Build with
//   cc -O2 -dynamiclib -o iotrace.dylib scripts/bench/iotrace.c
// and load it with
//   INGEST_TRACE_OUT=/tmp/t.bin INGEST_TRACE_A=/Volumes/Card INGEST_TRACE_B=/Volumes/Drive \
//   DYLD_INSERT_LIBRARIES=iotrace.dylib ingestctl …
// then read the result with iotrace.py. A = card, B = drive. Overhead is about 100 ns per call.
#define _DARWIN_C_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/stdio.h>
#include <unistd.h>

#define INTERPOSE(mine, theirs) \
    __attribute__((used)) static struct { const void *a, *b; } i_##theirs \
    __attribute__((section("__DATA,__interpose"))) = { (const void *)mine, (const void *)theirs };

enum { C_READ, C_WRITE, C_FULLSYNC, C_FSYNC, C_MSYNC, C_MMAP, C_MUNMAP, C_OPEN, C_CLOSE, C_META, C_RENAME, C_UNLINK,
       C_MKDIR, C_TIMES, C_TRUNC, C_PREALLOC, C_FCNTL, C_SYNCVOL, C_WAIT, C_LIST };
typedef struct { uint64_t t0, t1, bytes; uint32_t thread; uint8_t cat, side, pad[2]; } ev;
#define MAX_EVENTS (8u * 1024 * 1024)
static ev *events;
static _Atomic uint32_t next_event;
static _Atomic uint32_t next_thread;
static pthread_key_t thread_key;
static uint8_t sides[65536];
static const char *a_root, *b_root;
static mach_timebase_info_data_t tb;

static inline uint64_t now(void) { return mach_absolute_time(); }
static uint32_t thread_id(void) {
    uintptr_t v = (uintptr_t)pthread_getspecific(thread_key);
    if (!v) { v = atomic_fetch_add(&next_thread, 1) + 1; pthread_setspecific(thread_key, (void *)v); }
    return (uint32_t)v;
}
static uint8_t side_of(const char *p) {
    if (a_root && strncmp(p, a_root, strlen(a_root)) == 0) return 1;
    if (b_root && strncmp(p, b_root, strlen(b_root)) == 0) return 2;
    return 0;
}
static inline void rec(int cat, uint8_t side, uint64_t t0, uint64_t bytes) {
    if (!events) return;
    uint64_t t1 = now();
    uint32_t i = atomic_fetch_add(&next_event, 1);
    if (i < MAX_EVENTS) events[i] = (ev){ t0, t1, bytes, thread_id(), (uint8_t)cat, side, {0, 0} };
}
static void dump(void) {
    const char *out = getenv("INGEST_TRACE_OUT");
    if (!out || !events) return;
    ev *e = events; events = NULL;
    FILE *f = fopen(out, "wb");
    if (!f) return;
    uint32_t n = atomic_load(&next_event); if (n > MAX_EVENTS) n = MAX_EVENTS;
    uint32_t header[2] = { tb.numer, tb.denom };
    fwrite(header, sizeof header, 1, f);
    fwrite(e, sizeof(ev), n, f);
    fclose(f);
}
__attribute__((constructor)) static void setup(void) {
    mach_timebase_info(&tb);
    pthread_key_create(&thread_key, NULL);
    a_root = getenv("INGEST_TRACE_A"); b_root = getenv("INGEST_TRACE_B");
    events = calloc(MAX_EVENTS, sizeof(ev));
    atexit(dump);
}

static ssize_t t_read(int fd, void *b, size_t n) { uint64_t t = now(); ssize_t r = read(fd, b, n); int e = errno; rec(C_READ, fd >= 0 && fd < 65536 ? sides[fd] : 0, t, r > 0 ? r : 0); errno = e; return r; }
static ssize_t t_pread(int fd, void *b, size_t n, off_t o) { uint64_t t = now(); ssize_t r = pread(fd, b, n, o); int e = errno; rec(C_READ, fd >= 0 && fd < 65536 ? sides[fd] : 0, t, r > 0 ? r : 0); errno = e; return r; }
static ssize_t t_write(int fd, const void *b, size_t n) { uint64_t t = now(); ssize_t r = write(fd, b, n); int e = errno; rec(C_WRITE, fd >= 0 && fd < 65536 ? sides[fd] : 0, t, r > 0 ? r : 0); errno = e; return r; }
static int t_open(const char *p, int fl, ...) {
    va_list ap; va_start(ap, fl); int mode = va_arg(ap, int); va_end(ap);
    uint64_t t = now(); int fd = open(p, fl, mode); int e = errno; uint8_t s = side_of(p);
    if (fd >= 0 && fd < 65536) sides[fd] = s;
    rec(C_OPEN, s, t, 0); errno = e; return fd;
}
static int t_close(int fd) { uint64_t t = now(); uint8_t s = fd >= 0 && fd < 65536 ? sides[fd] : 0; int r = close(fd); int e = errno; rec(C_CLOSE, s, t, 0); errno = e; return r; }
static int t_fcntl(int fd, int cmd, ...) {
    va_list ap; va_start(ap, cmd); void *arg = va_arg(ap, void *); va_end(ap);
    uint64_t t = now(); int r = fcntl(fd, cmd, arg); int e = errno;
    int cat = cmd == F_FULLFSYNC ? C_FULLSYNC : cmd == F_PREALLOCATE ? C_PREALLOC : C_FCNTL;
    rec(cat, fd >= 0 && fd < 65536 ? sides[fd] : 0, t, 0); errno = e; return r;
}
static int t_fsync(int fd) { uint64_t t = now(); int r = fsync(fd); int e = errno; rec(C_FSYNC, fd >= 0 && fd < 65536 ? sides[fd] : 0, t, 0); errno = e; return r; }
static int t_msync(void *a, size_t n, int fl) { uint64_t t = now(); int r = msync(a, n, fl); int e = errno; rec(C_MSYNC, 0, t, n); errno = e; return r; }
static void *t_mmap(void *a, size_t n, int pr, int fl, int fd, off_t o) { uint64_t t = now(); void *r = mmap(a, n, pr, fl, fd, o); int e = errno; rec(C_MMAP, fd >= 0 && fd < 65536 ? sides[fd] : 0, t, n); errno = e; return r; }
static int t_munmap(void *a, size_t n) { uint64_t t = now(); int r = munmap(a, n); int e = errno; rec(C_MUNMAP, 0, t, n); errno = e; return r; }
static int t_lstat(const char *p, struct stat *s) { uint64_t t = now(); int r = lstat(p, s); int e = errno; rec(C_META, side_of(p), t, 0); errno = e; return r; }
static int t_stat(const char *p, struct stat *s) { uint64_t t = now(); int r = stat(p, s); int e = errno; rec(C_META, side_of(p), t, 0); errno = e; return r; }
static int t_fstat(int fd, struct stat *s) { uint64_t t = now(); int r = fstat(fd, s); int e = errno; rec(C_META, fd >= 0 && fd < 65536 ? sides[fd] : 0, t, 0); errno = e; return r; }
static int t_rename(const char *a, const char *b) { uint64_t t = now(); int r = rename(a, b); int e = errno; rec(C_RENAME, side_of(a), t, 0); errno = e; return r; }
static int t_renamex(const char *a, const char *b, unsigned f) { uint64_t t = now(); int r = renamex_np(a, b, f); int e = errno; rec(C_RENAME, side_of(a), t, 0); errno = e; return r; }
static int t_unlink(const char *p) { uint64_t t = now(); int r = unlink(p); int e = errno; rec(C_UNLINK, side_of(p), t, 0); errno = e; return r; }
static int t_mkdir(const char *p, mode_t m) { uint64_t t = now(); int r = mkdir(p, m); int e = errno; rec(C_MKDIR, side_of(p), t, 0); errno = e; return r; }
static int t_setattr(const char *p, void *al, void *b, size_t n, unsigned int o) { uint64_t t = now(); int r = setattrlist(p, al, b, n, o); int e = errno; rec(C_TIMES, side_of(p), t, 0); errno = e; return r; }
static int t_ftruncate(int fd, off_t l) { uint64_t t = now(); int r = ftruncate(fd, l); int e = errno; rec(C_TRUNC, fd >= 0 && fd < 65536 ? sides[fd] : 0, t, 0); errno = e; return r; }
static int t_syncvol(const char *p, int fl) { uint64_t t = now(); int r = sync_volume_np(p, fl); int e = errno; rec(C_SYNCVOL, side_of(p), t, 0); errno = e; return r; }
static int t_cond(pthread_cond_t *c, pthread_mutex_t *m) { uint64_t t = now(); int r = pthread_cond_wait(c, m); rec(C_WAIT, 0, t, 0); return r; }
static struct dirent *t_readdir(DIR *d) { uint64_t t = now(); struct dirent *r = readdir(d); int e = errno; rec(C_LIST, 0, t, 0); errno = e; return r; }

INTERPOSE(t_read, read) INTERPOSE(t_pread, pread) INTERPOSE(t_write, write) INTERPOSE(t_open, open) INTERPOSE(t_close, close)
INTERPOSE(t_fcntl, fcntl) INTERPOSE(t_fsync, fsync) INTERPOSE(t_msync, msync) INTERPOSE(t_mmap, mmap) INTERPOSE(t_munmap, munmap)
INTERPOSE(t_lstat, lstat) INTERPOSE(t_stat, stat) INTERPOSE(t_fstat, fstat) INTERPOSE(t_rename, rename) INTERPOSE(t_renamex, renamex_np)
INTERPOSE(t_unlink, unlink) INTERPOSE(t_mkdir, mkdir) INTERPOSE(t_setattr, setattrlist) INTERPOSE(t_ftruncate, ftruncate)
INTERPOSE(t_syncvol, sync_volume_np) INTERPOSE(t_cond, pthread_cond_wait) INTERPOSE(t_readdir, readdir)
