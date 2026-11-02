#include "cingest.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <fts.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/stdio.h>
#include <unistd.h>

#define COPY_CHUNK (8u * 1024 * 1024)
#define CHECK_CHUNK (2u * 1024 * 1024)      // small, so a hard drive still sees a nearly sequential read
#define READERS 2                           // two reads in flight reach a device's ceiling, one falls 5 to 30% short
#define SLOTS 4                             // those two, the one in use, and one spare
#define OVERLAP_MIN (16u * 1024 * 1024)     // below this, threads gain nothing
#define BUF_ALIGN 16384

static ci_result fail(int stage, int err) { ci_result r; memset(&r, 0, sizeof r); r.stage = stage; r.err = err; return r; }

// ---- Reading a file ahead ----
// Reads run ahead of the caller, which takes chunks strictly in file order and stops at the first short one, so it sees
// exactly what one sequential read would. A small file, or one whose size can't be trusted (virtual volumes report 0),
// is read in line on the caller's thread, until end of file either way.
typedef struct { uint8_t *data; size_t len; int err, full; } chunk;

typedef struct {
    int fd;
    size_t size;                    // of one chunk
    int nslots, nthreads;
    chunk slots[SLOTS];
    uint64_t claimed, taken;        // chunk numbers, in file order
    int stop;                       // claim nothing more
    pthread_mutex_t m;
    pthread_cond_t filled, freed;
    pthread_t threads[READERS];
} reader;

static void fill(const reader *g, chunk *c, uint64_t number) {
    off_t base = (off_t)number * (off_t)g->size;
    size_t got = 0;
    int err = 0;
    while (got < g->size) {
        ssize_t n = pread(g->fd, c->data + got, g->size - got, base + (off_t)got);
        if (n < 0) {
            if (errno == EINTR) continue;
            err = errno ? errno : EIO;
            break;
        }
        if (n == 0) break;
        got += (size_t)n;
    }
    c->len = got;
    c->err = err;
}

static void *read_ahead(void *arg) {
    reader *g = arg;
    pthread_mutex_lock(&g->m);
    for (;;) {
        while (!g->stop && g->claimed - g->taken >= SLOTS) pthread_cond_wait(&g->freed, &g->m);
        if (g->stop) break;
        uint64_t number = g->claimed++;
        chunk *c = &g->slots[number % SLOTS];
        pthread_mutex_unlock(&g->m);
        fill(g, c, number);
        pthread_mutex_lock(&g->m);
        c->full = 1;
        if (c->err || c->len < g->size) g->stop = 1;    // nothing past the end of the file or a failure is wanted
        pthread_cond_broadcast(&g->filled);
    }
    pthread_mutex_unlock(&g->m);
    return NULL;
}

static int reader_open(reader *g, int fd, size_t chunk_size, uint64_t file_size) {
    memset(g, 0, sizeof *g);
    g->fd = fd;
    g->size = chunk_size;
    g->nslots = file_size >= OVERLAP_MIN ? SLOTS : 1;
    for (int i = 0; i < g->nslots; i++) {
        if (posix_memalign((void **)&g->slots[i].data, BUF_ALIGN, chunk_size) != 0) {
            for (int j = 0; j < i; j++) free(g->slots[j].data);
            return ENOMEM;
        }
    }
    pthread_mutex_init(&g->m, NULL);
    pthread_cond_init(&g->filled, NULL);
    pthread_cond_init(&g->freed, NULL);
    if (g->nslots > 1) {
        for (int i = 0; i < READERS; i++) {
            if (pthread_create(&g->threads[g->nthreads], NULL, read_ahead, g) != 0) break;  // fewer threads only means slower
            g->nthreads++;
        }
    }
    return 0;
}

// The next chunk in file order. Check `err`, then `len`: shorter than a whole chunk is the end of the file.
static chunk *next_chunk(reader *g) {
    if (g->nthreads == 0) {
        fill(g, &g->slots[0], g->taken);
        return &g->slots[0];
    }
    chunk *c = &g->slots[g->taken % SLOTS];
    pthread_mutex_lock(&g->m);
    while (!c->full) pthread_cond_wait(&g->filled, &g->m);
    pthread_mutex_unlock(&g->m);
    return c;
}

static void chunk_done(reader *g, chunk *c) {
    if (g->nthreads == 0) { g->taken++; return; }
    pthread_mutex_lock(&g->m);
    c->full = 0;
    g->taken++;
    pthread_cond_broadcast(&g->freed);
    pthread_mutex_unlock(&g->m);
}

static void reader_close(reader *g) {
    pthread_mutex_lock(&g->m);
    g->stop = 1;
    pthread_cond_broadcast(&g->freed);
    pthread_mutex_unlock(&g->m);
    for (int i = 0; i < g->nthreads; i++) pthread_join(g->threads[i], NULL);
    for (int i = 0; i < g->nslots; i++) free(g->slots[i].data);
    pthread_mutex_destroy(&g->m);
    pthread_cond_destroy(&g->filled);
    pthread_cond_destroy(&g->freed);
}

ci_result ci_copy(const char *src, const char *dst, uint64_t size_hint, void *cancel_, void *progress_) {
    _Atomic int *cancel = cancel_;
    _Atomic uint64_t *progress = progress_;
    int rfd = open(src, O_RDONLY);
    if (rfd < 0) return fail(CI_STAGE_OPEN_SRC, errno);
    int wfd = open(dst, O_WRONLY | O_CREAT | O_EXCL, 0644);
    if (wfd < 0) { int e = errno; close(rfd); return fail(CI_STAGE_OPEN_DST, e); }
    fcntl(rfd, F_NOCACHE, 1);
    fcntl(rfd, F_RDAHEAD, 0);
    fcntl(wfd, F_NOCACHE, 1);

    if (size_hint > 0) {  // best effort: failure here must never fail a copy
        fstore_t fs = { F_ALLOCATECONTIG | F_ALLOCATEALL, F_PEOFPOSMODE, 0, (off_t)size_hint, 0 };
        if (fcntl(wfd, F_PREALLOCATE, &fs) == -1) {
            fs.fst_flags = F_ALLOCATEALL;
            (void)fcntl(wfd, F_PREALLOCATE, &fs);
        }
    }

    struct stat st;
    if (fstat(rfd, &st) != 0) st.st_size = 0;
    reader g;
    int e = reader_open(&g, rfd, COPY_CHUNK, (uint64_t)st.st_size);
    if (e != 0) { close(rfd); close(wfd); unlink(dst); return fail(CI_STAGE_WRITE, e); }

    ci_result r; memset(&r, 0, sizeof r);
    ci_xxh64 x; ci_xxh64_init(&x, 0);
    for (;;) {
        if (cancel && atomic_load(cancel)) { r.stage = CI_STAGE_CANCELLED; break; }
        chunk *c = next_chunk(&g);
        if (c->err) { r.stage = CI_STAGE_READ; r.err = c->err; break; }
        ci_xxh64_update(&x, c->data, c->len);
        r.bytes += c->len;
        size_t off = 0;
        while (off < c->len) {
            ssize_t n = write(wfd, c->data + off, c->len - off);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) { r.stage = CI_STAGE_WRITE; r.err = n < 0 && errno ? errno : EIO; break; }
            off += (size_t)n;
            if (progress) atomic_fetch_add(progress, (uint64_t)n);
        }
        int last = c->len < g.size;
        chunk_done(&g, c);
        if (r.stage != 0 || last) break;
    }
    reader_close(&g);
    r.hash = ci_xxh64_final(&x);

    if (r.stage == 0) {
        if (ftruncate(wfd, (off_t)r.bytes) != 0) { r.stage = CI_STAGE_WRITE; r.err = errno; }
    }
    if (r.stage == 0 && fcntl(wfd, F_FULLFSYNC) != 0) {
        // Some drives refuse the full flush. fsync is weaker, so the caller must report it, never hide it.
        if (fsync(wfd) == 0) r.weak_flush = 1;
        else { r.stage = CI_STAGE_FLUSH; r.err = errno; }
    }
    close(rfd);
    if (close(wfd) != 0 && r.stage == 0) { r.stage = CI_STAGE_WRITE; r.err = errno; }
    return r;
}

ci_result ci_hash_uncached(const char *path, void *cancel_, int *invalidated, void *progress_) {
    _Atomic int *cancel = cancel_;
    _Atomic uint64_t *progress = progress_;
    if (invalidated) *invalidated = 0;
    int fd = open(path, O_RDONLY);
    if (fd < 0) return fail(CI_STAGE_OPEN_SRC, errno);
    struct stat st;
    if (fstat(fd, &st) != 0) { int e = errno; close(fd); return fail(CI_STAGE_READ, e); }

    if (st.st_size == 0) {
        if (invalidated) *invalidated = 1;  // nothing cached can be misleading
    } else {
        void *map = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_SHARED, fd, 0);
        if (map != MAP_FAILED) {
            if (msync(map, (size_t)st.st_size, MS_INVALIDATE) == 0 && invalidated) *invalidated = 1;
            munmap(map, (size_t)st.st_size);
        }
    }
    fcntl(fd, F_NOCACHE, 1);
    fcntl(fd, F_RDAHEAD, 0);

    reader g;
    int e = reader_open(&g, fd, CHECK_CHUNK, (uint64_t)st.st_size);
    if (e != 0) { close(fd); return fail(CI_STAGE_READ, e); }
    ci_result r; memset(&r, 0, sizeof r);
    ci_xxh64 x; ci_xxh64_init(&x, 0);
    for (;;) {
        if (cancel && atomic_load(cancel)) { r.stage = CI_STAGE_CANCELLED; break; }
        chunk *c = next_chunk(&g);
        if (c->err) { r.stage = CI_STAGE_READ; r.err = c->err; break; }
        ci_xxh64_update(&x, c->data, c->len);
        r.bytes += c->len;
        if (progress) atomic_fetch_add(progress, (uint64_t)c->len);
        int last = c->len < g.size;
        chunk_done(&g, c);
        if (last) break;
    }
    reader_close(&g);
    r.hash = ci_xxh64_final(&x);
    close(fd);
    return r;
}

#define QUICK (64u * 1024)

// Hashes [off, end), stopping at end of file. A read error lands in `r`.
static void hash_range(int fd, uint8_t *buf, uint64_t off, uint64_t end, ci_xxh64 *x, ci_result *r) {
    while (off < end) {
        ssize_t n = pread(fd, buf, (size_t)(end - off), (off_t)off);
        if (n < 0) { if (errno == EINTR) continue; r->stage = CI_STAGE_READ; r->err = errno; return; }
        if (n == 0) return;
        ci_xxh64_update(x, buf, (size_t)n);
        off += (uint64_t)n; r->bytes += (uint64_t)n;
    }
}

ci_result ci_quick_fingerprint(const char *path) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return fail(CI_STAGE_OPEN_SRC, errno);
    struct stat st;
    if (fstat(fd, &st) != 0) { int e = errno; close(fd); return fail(CI_STAGE_READ, e); }
    fcntl(fd, F_NOCACHE, 1);
    fcntl(fd, F_RDAHEAD, 0);
    uint8_t *buf = NULL;
    if (posix_memalign((void **)&buf, BUF_ALIGN, QUICK * 2) != 0) { close(fd); return fail(CI_STAGE_READ, ENOMEM); }
    ci_result r; memset(&r, 0, sizeof r);
    ci_xxh64 x; ci_xxh64_init(&x, 0);
    uint64_t size = (uint64_t)st.st_size;
    ci_xxh64_update(&x, &size, sizeof size);
    hash_range(fd, buf, 0, size <= QUICK * 2 ? size : QUICK, &x, &r);
    if (r.stage == 0 && size > QUICK * 2) hash_range(fd, buf, size - QUICK, size, &x, &r);
    r.hash = ci_xxh64_final(&x);
    free(buf);
    close(fd);
    return r;
}

int64_t ci_pread(const char *path, uint64_t offset, void *out, size_t cap) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return -1;
    size_t got = 0;
    while (got < cap) {
        ssize_t n = pread(fd, (uint8_t *)out + got, cap - got, (off_t)(offset + got));
        if (n < 0) { if (errno == EINTR) continue; close(fd); return -1; }
        if (n == 0) break;
        got += (size_t)n;
    }
    close(fd);
    return (int64_t)got;
}

void ci_walk(const char *root, ci_walk_cb cb, void *ctx) {
    char *paths[2] = { (char *)root, NULL };
    FTS *fts = fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, NULL);
    if (!fts) return;
    FTSENT *e;
    while ((e = fts_read(fts)) != NULL) {
        ci_entry ent; memset(&ent, 0, sizeof ent);
        ent.path = e->fts_path;
        ent.depth = (int)e->fts_level;
        if (e->fts_statp) {
            ent.size = (uint64_t)e->fts_statp->st_size;
            ent.mtime = e->fts_statp->st_mtimespec.tv_sec;
            ent.mtime_ns = e->fts_statp->st_mtimespec.tv_nsec;
        }
        switch (e->fts_info) {
            case FTS_D:      ent.type = CI_ENTRY_DIR; break;
            case FTS_DP:     continue;                     // post-order visit
            case FTS_F:      ent.type = CI_ENTRY_FILE; break;
            case FTS_SL:
            case FTS_SLNONE: ent.type = CI_ENTRY_SYMLINK; break;
            case FTS_DEFAULT: ent.type = CI_ENTRY_OTHER; break;
            case FTS_DOT:    continue;
            case FTS_DC:     ent.type = CI_ENTRY_ERROR; ent.err = ELOOP; break;
            case FTS_DNR:
            case FTS_ERR:
            case FTS_NS:     ent.type = CI_ENTRY_ERROR; ent.err = e->fts_errno ? e->fts_errno : EIO; break;
            default:         ent.type = CI_ENTRY_OTHER; break;
        }
        if (e->fts_level == 0 && ent.type == CI_ENTRY_DIR) continue;  // the root itself
        if (cb(&ent, ctx) == 1 && e->fts_info == FTS_D) fts_set(fts, e, FTS_SKIP);
    }
    fts_close(fts);
}

typedef struct { ci_walk_cb cb; void *ctx; } strict_walk;

static void strict_error(strict_walk *w, const char *path, int depth, int err) {
    ci_entry e; memset(&e, 0, sizeof e);
    e.path = path; e.type = CI_ENTRY_ERROR; e.depth = depth; e.err = err ? err : EIO;
    w->cb(&e, w->ctx);
}

static void strict_dir(strict_walk *w, const char *path, int depth) {
    DIR *d = opendir(path);
    if (!d) { strict_error(w, path, depth, errno); return; }
    size_t base = strlen(path);
    for (;;) {
        errno = 0;
        struct dirent *de = readdir(d);
        if (!de) {
            // NULL means the end only when errno stayed 0. Anything else is a short listing.
            if (errno != 0) strict_error(w, path, depth, errno);
            break;
        }
        if (de->d_name[0] == '.' && (de->d_name[1] == 0 || (de->d_name[1] == '.' && de->d_name[2] == 0))) continue;
        size_t n = base + 1 + strlen(de->d_name) + 1;
        char *child = malloc(n);
        if (!child) { strict_error(w, path, depth, ENOMEM); break; }
        snprintf(child, n, "%s/%s", path, de->d_name);
        struct stat st;
        if (lstat(child, &st) != 0) {
            strict_error(w, child, depth + 1, errno);
            free(child);
            continue;
        }
        ci_entry e; memset(&e, 0, sizeof e);
        e.path = child; e.depth = depth + 1;
        e.size = (uint64_t)st.st_size; e.mtime = st.st_mtimespec.tv_sec; e.mtime_ns = st.st_mtimespec.tv_nsec;
        if (S_ISDIR(st.st_mode)) e.type = CI_ENTRY_DIR;
        else if (S_ISREG(st.st_mode)) e.type = CI_ENTRY_FILE;
        else if (S_ISLNK(st.st_mode)) e.type = CI_ENTRY_SYMLINK;
        else e.type = CI_ENTRY_OTHER;
        if (w->cb(&e, w->ctx) != 1 && e.type == CI_ENTRY_DIR) strict_dir(w, child, depth + 1);
        free(child);
    }
    closedir(d);
}

void ci_walk_strict(const char *root, ci_walk_cb cb, void *ctx) {
    strict_walk w = { cb, ctx };
    strict_dir(&w, root, 0);
}

// FSKit exFAT answers RENAME_EXCL with EEXIST when the target exists, but ENOTSUP when it doesn't.
// So on ENOTSUP the target was absent a moment ago: confirm that, then do a plain rename.
int ci_rename_excl(const char *from, const char *to) {
    if (renamex_np(from, to, RENAME_EXCL) == 0) return 0;
    int e = errno;
    if (e != ENOTSUP && e != EINVAL) return e;
    struct stat st;
    if (lstat(to, &st) == 0) return EEXIST;
    if (errno != ENOENT) return errno;
    return rename(from, to) == 0 ? 0 : errno;
}

int ci_fsync_dir(const char *dir) {
    int fd = open(dir, O_RDONLY);
    if (fd < 0) return errno;
    int rc = fcntl(fd, F_FULLFSYNC) == 0 ? 0 : errno;
    close(fd);
    return rc;
}

int ci_sync_volume(const char *anypath) {
    return sync_volume_np(anypath, SYNC_VOLUME_FULLSYNC | SYNC_VOLUME_WAIT);
}

int ci_set_times(const char *path, int64_t seconds, int64_t nanos) {
    struct attrlist al; memset(&al, 0, sizeof al);
    al.bitmapcount = ATTR_BIT_MAP_COUNT;
    al.commonattr = ATTR_CMN_CRTIME | ATTR_CMN_MODTIME;
    struct { struct timespec cr, mod; } __attribute__((packed)) buf;
    buf.cr.tv_sec = buf.mod.tv_sec = seconds;
    buf.cr.tv_nsec = buf.mod.tv_nsec = nanos;
    return setattrlist(path, &al, &buf, sizeof buf, FSOPT_NOFOLLOW) == 0 ? 0 : errno;
}
