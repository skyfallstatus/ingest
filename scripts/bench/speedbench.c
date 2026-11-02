// Raw measurements behind docs/research/speed.md. Only reads what it's given, except `copy`, which writes into <dest_dir>.
//   cc -O2 -ISources/CIngest/include scripts/bench/speedbench.c Sources/CIngest/*.c -o /tmp/speedbench
//   read   <buf_mib> <qd> <nocache> <rdahead> <limit_mib> <file...>    one read pass, each file purged first
//   xxh                                                                 hash speed, inline and on its own thread
//   msync  <file...>                                                    map, invalidate, unmap, per file
//   hash   <file...>                                                    ci_hash_uncached per file
//   copy   <dest_dir> <file...>                                         ci_copy per file, then removes the copy
//   fp     <file...>                                                    ci_quick_fingerprint per file
#define _DARWIN_C_SOURCE
#include "cingest.h"
#include <errno.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static double now(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return mach_absolute_time() * (double)tb.numer / tb.denom / 1e9;
}

// Drops any cached pages so a test can't read RAM, and says how many it found left.
static long purge(const char *path, off_t size) {
    if (size == 0) return 0;
    int fd = open(path, O_RDONLY);
    if (fd < 0) return -1;
    void *m = mmap(NULL, (size_t)size, PROT_READ, MAP_SHARED, fd, 0);
    if (m == MAP_FAILED) { close(fd); return -1; }
    msync(m, (size_t)size, MS_INVALIDATE);
    size_t pages = ((size_t)size + 16383) / 16384;
    char *v = malloc(pages);
    long left = 0;
    if (mincore(m, (size_t)size, v) == 0) for (size_t i = 0; i < pages; i++) left += (v[i] & MINCORE_INCORE) ? 1 : 0;
    free(v); munmap(m, (size_t)size); close(fd);
    return left;
}

typedef struct { int fd; off_t size; _Atomic int64_t next; size_t buf; uint64_t done; } job;
static void *worker(void *arg) {
    job *j = arg;
    void *b = NULL; posix_memalign(&b, 16384, j->buf);
    for (;;) {
        int64_t off = atomic_fetch_add(&j->next, (int64_t)j->buf);
        if (off >= j->size) break;
        size_t want = j->buf, got = 0;
        if ((off_t)(off + want) > j->size) want = (size_t)(j->size - off);
        while (got < want) {
            ssize_t n = pread(j->fd, (char *)b + got, want - got, off + (off_t)got);
            if (n <= 0) { if (n < 0 && errno == EINTR) continue; break; }
            got += (size_t)n;
        }
        __atomic_fetch_add(&j->done, got, __ATOMIC_RELAXED);
    }
    free(b);
    return NULL;
}

static int cmd_read(int ac, char **av) {
    size_t buf = (size_t)atol(av[0]) << 20;
    int qd = atoi(av[1]), nc = atoi(av[2]), ra = atoi(av[3]);
    uint64_t limit = (uint64_t)atol(av[4]) << 20, total = 0;
    double busy = 0; long resident = 0;
    for (int i = 5; i < ac && total < limit; i++) {
        struct stat st; if (stat(av[i], &st) != 0) continue;
        long left = purge(av[i], st.st_size); if (left > 0) resident += left;
        int fd = open(av[i], O_RDONLY); if (fd < 0) continue;
        fcntl(fd, F_NOCACHE, nc); fcntl(fd, F_RDAHEAD, ra);
        off_t size = st.st_size;
        if ((uint64_t)size > limit - total) size = (off_t)(limit - total);
        job j = { .fd = fd, .size = size, .buf = buf };
        pthread_t t[64];
        double t0 = now();
        for (int k = 0; k < qd; k++) pthread_create(&t[k], NULL, worker, &j);
        for (int k = 0; k < qd; k++) pthread_join(t[k], NULL);
        busy += now() - t0;
        total += j.done;
        close(fd);
    }
    printf("read buf=%zuMiB qd=%d nocache=%d rdahead=%d: %.0f MB/s (%.2f GB in %.2f s, resident pages found %ld)\n",
           buf >> 20, qd, nc, ra, total / busy / 1e6, total / 1e9, busy, resident);
    return 0;
}

typedef struct { uint8_t *data; size_t len; _Atomic int full; int stop; } handoff;
static void *hasher(void *arg) {
    handoff *h = arg; ci_xxh64 x; ci_xxh64_init(&x, 0);
    for (;;) {
        while (!atomic_load_explicit(&h->full, memory_order_acquire)) {}
        if (h->stop) break;
        ci_xxh64_update(&x, h->data, h->len);
        atomic_store_explicit(&h->full, 0, memory_order_release);
    }
    return NULL;
}
static int cmd_xxh(void) {
    size_t n = 8u << 20; uint8_t *d = malloc(n);
    uint64_t v = 0x9E3779B97F4A7C15ULL;
    for (size_t i = 0; i < n; i++) { v ^= v << 13; v ^= v >> 7; v ^= v << 17; d[i] = (uint8_t)v; }
    for (int run = 0; run < 3; run++) {
        ci_xxh64 x; ci_xxh64_init(&x, 0);
        double t = now();
        for (int i = 0; i < 400; i++) ci_xxh64_update(&x, d, n);
        double a = now() - t;
        handoff h = { .data = d, .len = n };
        pthread_t th; pthread_create(&th, NULL, hasher, &h);
        t = now();
        for (int i = 0; i < 400; i++) { atomic_store_explicit(&h.full, 1, memory_order_release); while (atomic_load_explicit(&h.full, memory_order_acquire)) {} }
        double b = now() - t;
        h.stop = 1; atomic_store_explicit(&h.full, 1, memory_order_release); pthread_join(th, NULL);
        printf("xxh64: inline %.2f GB/s, own thread %.2f GB/s, one 8 MiB block %.0f us\n", 400.0 * n / a / 1e9, 400.0 * n / b / 1e9, a / 400 * 1e6);
    }
    return 0;
}

static int cmd_msync(int ac, char **av) {
    double all = 0;
    for (int i = 0; i < ac; i++) {
        struct stat st; if (stat(av[i], &st) != 0 || st.st_size == 0) continue;
        size_t size = (size_t)st.st_size;
        int fd = open(av[i], O_RDONLY);
        double t0 = now();
        void *m = mmap(NULL, size, PROT_READ, MAP_SHARED, fd, 0);
        double t1 = now();
        if (m == MAP_FAILED) { perror("mmap"); close(fd); continue; }
        int rc = msync(m, size, MS_INVALIDATE); int e = errno;
        double t2 = now();
        munmap(m, size);
        double t3 = now();
        close(fd);
        all += t3 - t0;
        printf("%12zu bytes  mmap %.3f ms  msync %.3f ms (rc %d err %d)  munmap %.3f ms\n", size, (t1 - t0) * 1e3, (t2 - t1) * 1e3, rc, rc ? e : 0, (t3 - t2) * 1e3);
    }
    printf("msync total %.3f s\n", all);
    return 0;
}

static int cmd_hash(int ac, char **av) {
    double t0 = now(); uint64_t total = 0; int bad = 0;
    for (int i = 0; i < ac; i++) { int inv = 0; ci_result r = ci_hash_uncached(av[i], NULL, &inv, NULL); total += r.bytes; bad += (r.stage != 0) + !inv; }
    double t = now() - t0;
    printf("ci_hash_uncached: %d files %.2f GB %.2f s %.0f MB/s, problems %d\n", ac, total / 1e9, t, total / t / 1e6, bad);
    return 0;
}

static int cmd_copy(int ac, char **av) {
    uint64_t total = 0; double t0 = now(); char dst[1024]; double flushless = 0;
    for (int i = 1; i < ac; i++) {
        struct stat st; if (stat(av[i], &st) != 0) continue;
        snprintf(dst, sizeof dst, "%s/speedbench-%d", av[0], i);
        double a = now();
        ci_result r = ci_copy(av[i], dst, (uint64_t)st.st_size, NULL, NULL);
        flushless += now() - a;
        total += r.bytes;
        if (r.stage) printf("copy failed stage %d err %d\n", r.stage, r.err);
        unlink(dst);
        snprintf(dst, sizeof dst, "%s/._speedbench-%d", av[0], i); unlink(dst);
    }
    double t = now() - t0;
    printf("ci_copy: %d files %.2f GB, copy %.2f s %.0f MB/s, with unlink %.2f s\n", ac - 1, total / 1e9, flushless, total / flushless / 1e6, t);
    return 0;
}

static int cmd_fp(int ac, char **av) {
    double t0 = now(); int bad = 0;
    for (int i = 0; i < ac; i++) bad += ci_quick_fingerprint(av[i]).stage != 0;
    double t = now() - t0;
    printf("ci_quick_fingerprint: %d files %.3f s, %.2f ms per file, problems %d\n", ac, t, t / ac * 1e3, bad);
    return 0;
}

int main(int ac, char **av) {
    if (ac < 2) return 2;
    if (!strcmp(av[1], "read") && ac >= 8) return cmd_read(ac - 2, av + 2);
    if (!strcmp(av[1], "xxh")) return cmd_xxh();
    if (!strcmp(av[1], "msync")) return cmd_msync(ac - 2, av + 2);
    if (!strcmp(av[1], "hash")) return cmd_hash(ac - 2, av + 2);
    if (!strcmp(av[1], "copy")) return cmd_copy(ac - 2, av + 2);
    if (!strcmp(av[1], "fp")) return cmd_fp(ac - 2, av + 2);
    return 2;
}
