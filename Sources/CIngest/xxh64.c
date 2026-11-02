// XXH64, written from the public specification. Tested against the official vectors.
#include "cingest.h"
#include <string.h>

#define P1 11400714785074694791ULL
#define P2 14029467366897019727ULL
#define P3 1609587929392839161ULL
#define P4 9650029242287828579ULL
#define P5 2870177450012600261ULL

static inline uint64_t rotl(uint64_t x, int r) { return (x << r) | (x >> (64 - r)); }
static inline uint64_t rd64(const uint8_t *p) { uint64_t v; memcpy(&v, p, 8); return v; }
static inline uint32_t rd32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }
static inline uint64_t round1(uint64_t acc, uint64_t in) { return rotl(acc + in * P2, 31) * P1; }
static inline uint64_t merge(uint64_t h, uint64_t v) { return (h ^ round1(0, v)) * P1 + P4; }

void ci_xxh64_init(ci_xxh64 *s, uint64_t seed) {
    memset(s, 0, sizeof *s);
    s->v[0] = seed + P1 + P2;
    s->v[1] = seed + P2;
    s->v[2] = seed;
    s->v[3] = seed - P1;
}

void ci_xxh64_update(ci_xxh64 *s, const void *data, size_t len) {
    const uint8_t *p = data, *end = p + len;
    s->total += len;
    if (s->buffered + len < 32) {
        if (len) memcpy(s->buf + s->buffered, p, len);
        s->buffered += (uint32_t)len;
        return;
    }
    if (s->buffered) {
        size_t fill = 32 - s->buffered;
        memcpy(s->buf + s->buffered, p, fill);
        p += fill;
        s->v[0] = round1(s->v[0], rd64(s->buf));
        s->v[1] = round1(s->v[1], rd64(s->buf + 8));
        s->v[2] = round1(s->v[2], rd64(s->buf + 16));
        s->v[3] = round1(s->v[3], rd64(s->buf + 24));
        s->buffered = 0;
    }
    uint64_t a = s->v[0], b = s->v[1], c = s->v[2], d = s->v[3];
    while ((size_t)(end - p) >= 32) {
        a = round1(a, rd64(p));
        b = round1(b, rd64(p + 8));
        c = round1(c, rd64(p + 16));
        d = round1(d, rd64(p + 24));
        p += 32;
    }
    s->v[0] = a; s->v[1] = b; s->v[2] = c; s->v[3] = d;
    if (p < end) { s->buffered = (uint32_t)(end - p); memcpy(s->buf, p, s->buffered); }
}

uint64_t ci_xxh64_final(const ci_xxh64 *s) {
    uint64_t h;
    if (s->total >= 32) {
        h = rotl(s->v[0], 1) + rotl(s->v[1], 7) + rotl(s->v[2], 12) + rotl(s->v[3], 18);
        h = merge(h, s->v[0]); h = merge(h, s->v[1]); h = merge(h, s->v[2]); h = merge(h, s->v[3]);
    } else {
        h = s->v[2] + P5;
    }
    h += s->total;
    const uint8_t *p = s->buf, *end = p + s->buffered;
    while (p + 8 <= end) { h = rotl(h ^ round1(0, rd64(p)), 27) * P1 + P4; p += 8; }
    if (p + 4 <= end)   { h = rotl(h ^ ((uint64_t)rd32(p) * P1), 23) * P2 + P3; p += 4; }
    while (p < end)     { h = rotl(h ^ (*p * P5), 11) * P1; p++; }
    h ^= h >> 33; h *= P2; h ^= h >> 29; h *= P3; h ^= h >> 32;
    return h;
}

uint64_t ci_xxh64_oneshot(const void *data, size_t len, uint64_t seed) {
    ci_xxh64 s; ci_xxh64_init(&s, seed); ci_xxh64_update(&s, data, len); return ci_xxh64_final(&s);
}
