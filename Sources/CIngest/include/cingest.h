#ifndef CINGEST_H
#define CINGEST_H
#include <stdint.h>
#include <stddef.h>
#include <stdatomic.h>

// ---- XXH64 (seed 0), streaming ----
typedef struct {
    uint64_t total;
    uint64_t v[4];
    uint8_t  buf[32];
    uint32_t buffered;
} ci_xxh64;

void     ci_xxh64_init(ci_xxh64 *s, uint64_t seed);
void     ci_xxh64_update(ci_xxh64 *s, const void *data, size_t len);
uint64_t ci_xxh64_final(const ci_xxh64 *s);
uint64_t ci_xxh64_oneshot(const void *data, size_t len, uint64_t seed);

// ---- Result of a data operation ----
typedef struct {
    uint64_t hash;        // XXH64 of every byte actually read
    uint64_t bytes;       // bytes read (never trust st_size: some virtual volumes report 0)
    int      err;         // errno of the first failure, 0 if none
    int      stage;       // CI_STAGE_*
    int      weak_flush;  // 1 when the drive refused F_FULLFSYNC and only fsync succeeded
} ci_result;

enum { CI_STAGE_OK = 0, CI_STAGE_OPEN_SRC = 1, CI_STAGE_READ = 2, CI_STAGE_OPEN_DST = 3,
       CI_STAGE_WRITE = 4, CI_STAGE_FLUSH = 5, CI_STAGE_CANCELLED = 7 };

// Copies src to dst (dst must not exist; O_EXCL), hashing the bytes as read from the source.
// 8 MiB page-aligned chunks with two reads in flight, F_NOCACHE both ends,
// F_PREALLOCATE then ftruncate (best effort), F_FULLFSYNC before returning.
// `progress` is incremented by bytes written. `cancel` is polled between chunks.
ci_result ci_copy(const char *src, const char *dst, uint64_t size_hint,
                  void *cancel, void *progress);

// Reads a whole file from the device, not the cache: maps it, msync(MS_INVALIDATE), unmaps,
// then reads with F_NOCACHE + F_RDAHEAD 0 until EOF, hashing in file order, with two reads in flight on a large file.
// `invalidated` is set to 1 only when the cache was really invalidated. `progress`, if given, grows by bytes hashed.
ci_result ci_hash_uncached(const char *path, void *cancel, int *invalidated, void *progress);

// Quick fingerprint: hash of size + first 64 KiB + last 64 KiB. Files up to 128 KiB are hashed whole.
ci_result ci_quick_fingerprint(const char *path);

// Reads up to `cap` bytes at `offset` into `out`, returns bytes read or -1. For metadata parsing.
int64_t ci_pread(const char *path, uint64_t offset, void *out, size_t cap);

// ---- Walking ----
enum { CI_ENTRY_FILE = 0, CI_ENTRY_DIR = 1, CI_ENTRY_SYMLINK = 2, CI_ENTRY_OTHER = 3, CI_ENTRY_ERROR = 4 };

typedef struct {
    const char *path;     // absolute, exactly as the filesystem returned it
    int         type;     // CI_ENTRY_*
    int         depth;    // 1 = direct child of the root
    uint64_t    size;
    int64_t     mtime;    // seconds
    int64_t     mtime_ns;
    int         err;      // errno for CI_ENTRY_ERROR
} ci_entry;

// Return 0 to continue, 1 to skip this directory's contents.
typedef int (*ci_walk_cb)(const ci_entry *entry, void *ctx);
// Fast, for a drive index, which is only ever a hint. fts can end a directory early without saying so.
void ci_walk(const char *root, ci_walk_cb cb, void *ctx);
// For a card. Every failure to read a directory, or to stat an entry, reaches the callback as CI_ENTRY_ERROR,
// including failure on the root itself and a directory that stops being readable part way through.
void ci_walk_strict(const char *root, ci_walk_cb cb, void *ctx);

// ---- Finishing a file ----
// Atomic no-overwrite rename.
int ci_rename_excl(const char *from, const char *to);
// F_FULLFSYNC on a directory.
int ci_fsync_dir(const char *dir);
// sync_volume_np(path, FULLSYNC|WAIT).
int ci_sync_volume(const char *anypath);
// Sets mtime and birthtime to one time via setattrlist. Non-fatal for integrity.
int ci_set_times(const char *path, int64_t seconds, int64_t nanos);

// Swift can't touch C11 atomics directly.
typedef struct { _Atomic int v; } atomic_int_shim;
typedef struct { _Atomic uint64_t v; } atomic_u64_shim;
static inline void ci_store_int(atomic_int_shim *p, int v) { atomic_store(&p->v, v); }
static inline int  ci_load_int(atomic_int_shim *p) { return atomic_load(&p->v); }
static inline uint64_t ci_load_u64(atomic_u64_shim *p) { return atomic_load(&p->v); }
static inline void ci_store_u64(atomic_u64_shim *p, uint64_t v) { atomic_store(&p->v, v); }
static inline void ci_add_u64(atomic_u64_shim *p, uint64_t v) { atomic_fetch_add(&p->v, v); }
#endif
