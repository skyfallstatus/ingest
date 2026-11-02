# Card ingest: integrity and macOS platform research

Date: 2026-11-01. Test machine: Apple M5 Max, 128 GB, macOS 27.2 (26B123), Swift 6.3.3, CLT only, SDK 26.5.
Working drive: a 4 TB USB SSD holding the author's archive, exFAT, 128 KiB clusters, 5.9% free, mounted through FSKit.

Evidence labels:

- **VERIFIED-SOURCE**: read in a primary source (URL, or a local Apple man page or SDK header). "(secondary)" means a good non-Apple source.
- **TESTED**: run on this machine. Raw read-back and flush output is in Appendix A. The programs are in `integrity-tests/`, with a recipe for running them on disk images.
- **UNVERIFIED**: inferred or not tested. Treat as a hypothesis.

Limits that apply to every TESTED claim below:

- macOS 27.2 only. The deployment target is macOS 14, and nothing was run on 14, 15 or 26.
- The tamper, sync, Unicode, UUID and FSEvents tests ran on 200 MB disk images. No test exercised a real USB drive's write path, because the working drive must not be written to and no spare drive was connected.
- No camera card was available. Behaviour of real cameras and card readers is unverified.
- An editing app had the working drive open during the walks and read tests, so its timings carry some noise.

---

## 0. Decisions at a glance

| Topic | Decision |
|---|---|
| A. Read-back | Write with `F_NOCACHE`, `F_FULLFSYNC`, then `msync(MS_INVALIDATE)` over the whole file, then read with `F_NOCACHE`. Never rely on `F_NOCACHE` alone. |
| A. Meaning of "safe" | File count matches the listing, source re-read matches, destination read-back matches, flush returned success. State plainly that the drive's own cache can't be bypassed. |
| B. Copy | Own pipeline: 8 MiB page-aligned chunks, two reads in flight, `F_NOCACHE` on both ends, `F_PREALLOCATE` then `ftruncate`. Not `copyfile`. Numbers in `speed.md`. |
| B. Metadata | `setattrlist` for mtime and birthtime, compare at volume precision. Never use time as integrity evidence. |
| B. Names | Match on NFC + case-fold. Use the name exactly as `readdir` gave it. Any entry that can't be opened blocks "safe". |
| C. Hash | XXH64, seed 0, canonical big-endian hex. |
| D. MHL | Write ASC MHL v2.0 by hand. About 100 lines. Always record `._*` as an ignore pattern. |
| E. Detection | DiskArbitration for events and classification. `lsof` to name eject blockers. Add `NSRemovableVolumesUsageDescription`. |
| F. Index | Single-threaded `getattrlistbulk` or `fts`. Rescan on every mount of exFAT. FSEvents only while mounted. |
| G. Distribution | Ad-hoc works for friendly testers. Buy a Developer ID before calling it "works for anyone". |

---

## A. Verification that really reads the disk

### A.1 How the test works

Timing can't prove where bytes came from, so the rig tampers instead:

1. Write a file through the filesystem and call `F_FULLFSYNC`.
2. Find each 4 KiB block on the raw device of the disk image.
3. Invert the bytes on the device, behind the cache.
4. Read the file through the filesystem and classify each block: original bytes mean it came from the cache, inverted bytes mean it came from the device.

`mincore` gives UBC residency alongside. The file is 8 MiB + 5,000 bytes (2,050 blocks, 513 16 KiB pages), so the partial tail is covered.

Controls and rig bugs found and fixed along the way:

- HFS+ tampered through the raw device and through the `.dmg` gave identical results, which validates the `.dmg` path used for APFS (its physical store is held exclusively).
- An early run showed 0/2050 blocks on the device. That was a stale raw fd after the FSKit remount, not a durability problem. A direct poll showed the data on the device immediately.
- A later anomaly (a few "cached" blocks with zero resident pages) was stale copies from earlier runs in freed clusters. With unique IDs and duplicate detection it vanished. Only the clean final runs are reported.

### A.2 Results (TESTED, identical on exFAT, APFS and HFS+ unless noted)

Blocks returned from the device, out of 2,050:

| Written with | Then | Device blocks | Verdict |
|---|---|---|---|
| buffered | plain read | 0 | cache |
| buffered | **`F_NOCACHE` read** | **0** | **cache: verifies RAM, not the disk** |
| buffered | `F_NOCACHE` + `F_RDAHEAD 0` | 0 | cache |
| buffered | `F_NOCACHE` misaligned buffer, 4 KiB or 1000-byte chunks | 0 | cache |
| buffered | mmap read | 0 | cache |
| buffered | `msync(MS_KILLPAGES)` or `MS_DEACTIVATE`, then read | 0 | no effect |
| buffered | **`msync(MS_INVALIDATE)`, then plain or `F_NOCACHE` read** | **2050** | **device** |
| buffered | unmount and remount, then plain read (exFAT, HFS+) | 2050 | device |
| `F_NOCACHE` | plain or `F_NOCACHE` read | 2050 | device |
| `F_NOCACHE` | **another process reads it, then `F_NOCACHE` read** | **0** | **cache: the Spotlight or QuickLook trap** |
| `F_NOCACHE` | another process reads it, `MS_INVALIDATE`, `F_NOCACHE` read | 2050 | device |

Also TESTED:

- `F_NOCACHE` writes left 0 pages resident at every size from 1,000 bytes to 8 MiB + 5,000, with chunks down to 1,000 bytes, misaligned buffers and misaligned offsets (57/57 cases, fresh-fd probe). The XNU comment about writes under 16 KiB staying in the UBC did not show up here. Device tamper confirmed this for 1 KB and 12 KB files, which matters for sidecars, and for 1,000-byte and 4,096-byte write chunks on exFAT and HFS+.
- `msync(MS_INVALIDATE)` with dirty pages and no prior sync lost nothing on any filesystem. Sync first anyway.
- `purge` as a normal user fails: `Unable to purge disk buffers: Operation not permitted`.
- `O_DIRECT` isn't in the SDK. `F_NOCACHE` and the newer `F_NOCACHE_EXT` are.
- Cost of invalidation: 28.3 ms for a 6.45 GiB fully resident file on APFS, about 0 ms with nothing resident. `mincore` over 7 GiB took about 100 ms.

### A.3 Why (VERIFIED-SOURCE)

- `F_NOCACHE` does not evict. In XNU's `cluster_read_direct`, resident pages are used first: "First look for pages already in the cache and move them to user space", via `cluster_copy_ubc_data_internal`. https://github.com/apple-oss-distributions/xnu/blob/main/bsd/vfs/vfs_cluster.c (lines 5576 to 5588 of the current `main`).
- Alignment: if the file offset or memory address is misaligned, the code sets `misaligned` and "fire[s] an I/O through the cache for this entire vector" (same file, lines 5503 to 5509). So misalignment costs you the direct path. Use page-aligned buffers (16 KiB on Apple silicon, and that also satisfies Intel).
- Under 16 KiB: "we have not historically allowed the write to bypass the UBC" (same file, lines 278 to 282). My tests didn't reproduce residency, so don't rely on either behaviour. The invalidate step covers both.
- `man 2 fcntl` (macOS 27.2) on `F_NOCACHE`: "Turns data caching off/on." It says nothing about eviction. On `F_RDAHEAD`: read-ahead only.
- XNU's cluster layer covers kernel filesystems. APFS is closed source, and exFAT and FAT run in user space: "provided by services running in user-space instead of by kernel extensions" since macOS 14, https://developer.apple.com/documentation/macos-release-notes/macos-14-release-notes. `mount` shows `fskit` for both here (TESTED). The behaviour matched anyway (TESTED), but the source only explains the kernel path.

Why invalidate-then-read closes the race (reasoning, UNVERIFIED by a concurrency test): once the file is synced and pages are invalidated, any page that later enters the UBC was filled from the device, because nobody else is writing. A concurrent Spotlight read therefore can't reintroduce a stale write-path page.

### A.4 Flush semantics

| Call | Meaning | Evidence |
|---|---|---|
| `fsync` | Host to drive only. "the drive itself may not physically write the data" | VERIFIED-SOURCE `man 2 fsync` |
| `F_FULLFSYNC` | `fsync` then asks the drive to flush, acts as a barrier | VERIFIED-SOURCE `man 2 fcntl`. The man page lists HFS, MS-DOS, UDF and APFS, **not exFAT** |
| `F_BARRIERFSYNC` | Ordering only: "no assumption should be made on what has been persisted or not when this call returns" | VERIFIED-SOURCE `man 2 fcntl`. Not good enough for "safe" |
| `sync_volume_np(path, FULLSYNC\|WAIT)` | Volume-wide flush, declared in `unistd.h` | TESTED rc=0 on all four, 4 to 10 ms |

On exFAT, `F_FULLFSYNC` returned 0 and took 6.6 ms against 0.4 ms for `fsync` on the same 8 MiB write (TESTED on an image). That's consistent with a real flush to the image's backing store, but it's indirect: nothing proves a USB drive gets the flush through FSKit. **UNVERIFIED.**

On FSKit exFAT, buffered data was on the raw device right after `close()` even with no sync at all (TESTED, image). Don't depend on that.

### A.5 External drives that ignore flushes

- Apple: "`F_FULLFSYNC` represents a best-effort guarantee ... data can still be lost in the case of sudden power loss" (written about iOS). VERIFIED-SOURCE https://developer.apple.com/documentation/xcode/reducing-disk-writes
- `man 2 fcntl`: "Certain FireWire drives have also been known to ignore the request to flush their buffered data." VERIFIED-SOURCE (local)
- Bitcoin Core hit external drives or filesystems where `F_FULLFSYNC` fails, and some that accept it but behave like `fsync`. VERIFIED-SOURCE (secondary) https://mirror.b10c.me/bitcoin-bitcoin/26534/
- Half of the internal NVMe SSDs in one informal test lost flushed data on power cut. VERIFIED-SOURCE (secondary, not USB drives) https://mjtsai.com/blog/2022/02/17/apple-ssd-benchmarks-and-f_fullsync
- I found no credible public test of current USB SSD bridges. **UNVERIFIED** either way.

Consequences:

- The OS exposes no FUA read or cache bypass, so even a correct read-back can be served from the drive's own DRAM. Only a power cycle clears that. TESTED methods clear the OS cache, not the device cache.
- If `F_FULLFSYNC` fails, fall back to `fsync` but report the weaker state rather than "safe".
- Optional paranoid mode: eject, have the user unplug and replug, verify again. This is the only method that defeats a lying drive cache.

### A.6 Recommended read-back sequence

1. Copy with `F_NOCACHE` on source and destination.
2. `F_FULLFSYNC` the file, treat failure as a non-safe result.
3. `F_FULLFSYNC` the directory after the rename, then `sync_volume_np` at the end of the job.
4. For each destination file: open read-only, map whole file, `msync(MS_INVALIDATE)`, unmap.
5. Read with `F_NOCACHE` + `F_RDAHEAD 0`, hash, compare.
6. Re-read the **source** the same way and compare too. If you only hash the buffer you wrote, a bad card read produces identical wrong bytes on both sides and passes. OffShoot's "Source & Destination" mode and Silverstack's default both do this independent verification, and OffShoot warns against file-size-only modes before erasing cards: https://docs.hedge.video/offshoot/features/verification, https://pomfort.com/article/backup-shooting-data-verification-behavior/

### A.7 Filesystem matrix

| | exFAT (FSKit) | FAT (FSKit) | APFS | HFS+ |
|---|---|---|---|---|
| `F_NOCACHE` read and write | works | not tampered, same fcntls ok | works | works |
| `msync(MS_INVALIDATE)` eviction | works | not tampered | works | works |
| `F_FULLFSYNC` file, dir, read-only fd | rc=0 | rc=0 | rc=0 | rc=0 |
| `F_BARRIERFSYNC` | rc=0 | rc=0 | rc=0 | rc=0 |
| `F_LOG2PHYS_EXT` | ENOTSUP | ENOTSUP | ok | ok |
| `RENAME_EXCL` | **correction, tested during build:** EEXIST when the target exists, ENOTSUP when it doesn't. Fall back to lstat then rename | works | works | works |
| `RENAME_SWAP`, `clonefile` | ENOTSUP | ENOTSUP | ok | ENOTSUP |

---

## B. Copy fidelity

### B.1 Throughput (TESTED)

Read-only `F_NOCACHE` from a 96 GiB file on the working drive, fresh 4 GiB region per test:

| Buffer | QD1 | QD2 | QD4 | QD8 |
|---|---|---|---|---|
| 128 KiB | 280 MB/s | | | |
| 256 KiB | 405 | | | |
| 1 MiB | 652 | 915 | 929 | 938 |
| 4 MiB | 873 | 970 | 942 | 986 |
| 8 MiB | 916 | 966 | 966 | 969 |
| 16 MiB | 944 | 1001 | 995 | 997 |
| 64 MiB | 996 | 1005 | 959 | 985 |

The ceiling is about 1 GB/s (10 Gbit/s USB). 8 MiB with two concurrent I/Os is enough. Larger buffers add little.

Copy from the working drive to internal APFS, one sample each on different 5.7 to 8.1 GiB files:

| Method | Speed | CPU | Notes |
|---|---|---|---|
| 8 MiB, 3 slots, reader + writer thread, `F_NOCACHE` | 931 MB/s | 0.35 s | 0 pages resident |
| same, single thread | 899 MB/s | 0.40 s | 0 pages resident |
| same, buffered | 994 MB/s | 0.69 s | 100% of file resident, 2x CPU, can't be verified without invalidation |
| `copyfile(COPYFILE_DATA)` | 662 MB/s | 0.61 s | no fsync |
| `copyfile(COPYFILE_ALL)` | 642 MB/s | 0.70 s | no fsync, only one that kept mtime |

`copyfile` adds xattrs, ACLs and times, but no read-back control and about 30% less speed. `fcopyfile` was not measured (too few suitable files in the list). Writing to an external drive was not measured, so these numbers show source-side limits only.

Hash inline on the read thread: XXH64 runs at 26 GB/s, so it isn't a bottleneck.

### B.2 Preallocation (TESTED)

`F_PREALLOCATE` with `F_ALLOCATECONTIG|F_ALLOCATEALL` succeeded on all four. On exFAT `st_blocks` stays 0 until `ftruncate` extends the file. Asking for too much gives EINVAL on exFAT, EFBIG on FAT, ENOSPC on APFS and HFS+, so check `statfs` first and treat preallocation failure as non-fatal. FAT32's limit shows up as `FILESIZEBITS=33`.

### B.3 Timestamps

Set with `setattrlist(ATTR_CMN_CRTIME|ATTR_CMN_MODTIME)`. Results for mtime `...097.123456789` and birthtime `...751.987654321` (TESTED):

| FS | mtime stored | birthtime stored | Rule |
|---|---|---|---|
| exFAT | `.12` | `.98` (reads `.00` until remount) | 10 ms, truncated |
| FAT | `...096.0` | `...750.0` | 2 s, floored |
| HFS+ | `.0` | `.0` | 1 s |
| APFS | exact | exact | 1 ns |

Spec: `DoubleSeconds` plus a `10msIncrement`, and a `UtcOffset` with an `OffsetValid` bit. VERIFIED-SOURCE https://learn.microsoft.com/en-us/windows/win32/fileio/exfat-specification sections 7.4.8 to 7.4.10.

Timezone behaviour (TESTED, by parsing raw directory entries):

- **Writing:** at 03:15 local, +01:00 (02:15 UTC), macOS stored `01:15` with offset `-60 min`. The spec says this field is local time and the offset is from UTC, so the expected value is `03:15`, `+60 min`. The sign is inverted. It's self-consistent (local minus offset gives the right instant), so macOS round-trips and spec-following readers get the right instant. A reader that ignores the offset would be 2 hours off.
- **Reading a valid offset:** `+9h`, `+1h` and `UTC` entries all decoded to the correct instant.
- **Reading no offset (`OffsetValid=0`):** a 14:30 July stamp came back as 13:30 UTC, using today's offset (+01:00), not July's (+02:00). So these stamps are interpreted with the Mac's *current* offset and shift with timezone and DST.
- FAT has no offset field, so UNVERIFIED but expected to behave the same way as the no-offset case. Whether specific cameras set `OffsetValid` is UNVERIFIED.

Range (TESTED): before 1980 clamps to 1980 on exFAT and FAT. Past 2107, exFAT clamps but FAT wrapped to a nonsense date.

Rule for matching card to copy: compare size, plus mtime at the coarser precision, allowing differences of whole 15-minute multiples. Use this only to recognise an already-ingested card, never as integrity evidence.

### B.4 File names

- Max length: 255 UTF-16 units. VERIFIED-SOURCE spec 7.6.3. TESTED on exFAT and FAT: 255 ok, 256 `ENAMETOOLONG`. 127 emoji ok (254 units), 128 fails.
- APFS accepted 255 `é` in NFC (510 UTF-8 bytes). HFS+ failed at 128 `é`, since it stores them decomposed. So a legal exFAT name can exceed HFS+'s limit (TESTED).
- Spec's invalid characters: `0000h` to `001Fh`, `"`, `*`, `/`, `:`, `<`, `>`, `?`, `\`, `|`. VERIFIED-SOURCE spec table 35.
- macOS accepts all of these except `/`, by storing Private Use Area characters: `:` is U+F022, `\` is U+F026, `*` is U+F021, 0x01 is U+F001, trailing `.` is U+F029, trailing space is U+F028 (TESTED from raw entries). Windows would show odd characters. `CON`, `AUX`, `nul` are accepted.
- Case: all four volumes here are case-insensitive and case-preserving, including `É`/`é`. Collisions return `EEXIST` (TESTED).

### B.5 A file can be listed but not opened (TESTED, real example in the author's archive)

A `.zip` in the author's archive, with a space before the extension (14,035,400,386 bytes), and its `._` sibling appear in `readdir`, `ls` and `getattrlistbulk`, but `lstat`, `open`, and open by file ID all fail. `/.vol` gives ENOENT, `fsgetpath` ENOTSUP, `openbyid_np` EPERM.

Reproduced on an image by patching a raw name to carry U+F028 in the *middle*: `readdir` shows a plain space, `lstat` and `open` give ENOENT. That's the same symptom. The real file's raw entry wasn't read (needs root), so this is the likely cause, not proof. macOS 27.2 itself didn't create such a name: `x y .zip` was stored with a plain space and opened fine. So the file probably came from an older driver or another OS. (UNVERIFIED.)

The fix for the app: a walker can't assume listed means readable.

- `fts` and `getattrlistbulk` report the entry with its size, so you only find out at `open`.
- A `readdir`+`lstat` walker sees an error and could silently skip 14 GB.
- **Every listed entry must end as copied-and-verified or as a reported failure. Any failure blocks "safe to format".**

### B.6 Normalization (TESTED)

| | Stored | `readdir` returns | Open via either form |
|---|---|---|---|
| exFAT | NFC (even when created as NFD, raw check) | always NFD | works |
| FAT | not raw-checked | always NFD | works |
| HFS+ | decomposed | NFD | works |
| APFS | as given | as given | works |

On the working drive: 574 non-ASCII paths, 540 NFD-only, 0 NFC-only.

Traps on FSKit:

- exFAT: a file created as NFC can't be unlinked with the NFD name `readdir` returns (ENOENT, the file stays, survives remount). The same happens with NFD-created files and an NFC unlink.
- FAT: same pattern for `rename` instead of `unlink`.
- `open` and `stat` work in every combination.

Rules:

1. Create destination files using the name exactly as `readdir` gave it.
2. Match names across volumes on NFC + case-fold, never on bytes.
3. On `unlink` or `rename` ENOENT when the file exists, retry with the other form.
4. Use an ASCII temp name while copying, so cleanup never depends on Unicode behaviour.

### B.7 AppleDouble `._` files (TESTED)

- On exFAT and FAT, every new file immediately gets a 4,096-byte `._name` holding `com.apple.provenance`. It appears at `open()`, before any write. It happened for a plain C tool, Apple's own `touch`, `cp`, `cp -X`, `ditto --norsrc --noextattr` and Python in my process tree, and for an ad-hoc app launched by LaunchServices outside that tree.
- The working drive has 199,814 `._` files out of 451,688. In a 600-file sample, 578 held only provenance. At 128 KiB per cluster that's roughly 26 GB of wasted space.
- `fremovexattr` returns 0 and changes nothing.
- `unlink("._name")` while the file is open or after the last write works: `listxattr` then shows nothing and it stays gone. Rewriting the file brings it back.
- `rename` carries the `._` with the file.
- Deleting a file removes its `._`, so a later unlink of the `._` gives ENOENT. That's expected.

Background on provenance: VERIFIED-SOURCE (secondary) https://eclecticlight.co/2023/05/10/how-macos-now-tracks-the-provenance-of-apps/ and https://developer.apple.com/forums/thread/723397. I found no source for the exFAT effect, so that part rests on testing.

Recommendation: delete `._name` as the last step of each file, and always exclude `._*` from matching and manifests.

### B.8 Directory durability (TESTED rc only)

`open(dir, O_RDONLY)` then `fcntl(fd, F_FULLFSYNC)` returned 0 on all four filesystems, about 3 ms on exFAT. `fsync(dir)` also returned 0. exFAT has no journal (capability bit `JOURNAL=0`), so a crash mid-update can still leave directory damage. Actual crash durability wasn't tested (UNVERIFIED).

Order: write temp name, `F_FULLFSYNC`, `RENAME_EXCL` to final name, `F_FULLFSYNC` the directory, set times, remove `._`, then verify.

---

## C. Hash choice

Single thread, best of 6, 64 MiB random data, arm64, clang -O3, `xxhash.h` 0.8.5 with NEON, CommonCrypto for the rest (TESTED):

| Hash | GB/s |
|---|---|
| XXH64 | 26.2 |
| XXH3 64 | 20.0 |
| XXH128 | 19.9 |
| SHA-256 | 3.29 |
| SHA-1 | 3.28 |
| SHA-512 | 1.88 |
| MD5 | 0.88 |

XXH64 beat XXH3 here, which is the opposite of the usual x86 result. Intel wasn't measured (Rosetta isn't on this machine). MD5 is the only one below USB 10 Gbit/s speed.

What pro tools use:

- OffShoot: "XXH64BE Checksums are always generated" and stored in logs and MHLs, with MD5, SHA1 and C4 as optional legacy. VERIFIED-SOURCE https://docs.hedge.video/offshoot/features/verification
- Silverstack: MD5 default in a 2018 Pomfort article. VERIFIED-SOURCE https://pomfort.com/article/backup-shooting-data-verification-behavior/ This may be dated.
- A 2026 article says OffShoot, ShotPut Pro, Silverstack and YoYotta default to xxHash. VERIFIED-SOURCE (secondary) https://www.newsshooter.com/2026/07/15/stow-free-copy-verification-software/
- `ascmhl` CLI default is `xxh128` (TESTED in its `__version__.py`).
- ASC MHL XXH64 is seed 0 and big-endian. VERIFIED-SOURCE spec Appendix D.

Choose **XXH64**: fastest here, matches OffShoot, valid in both MHL versions (`xxh64` in ASC, `xxhash64be` in v1.1). It catches accidents, not deliberate forgery. Offer SHA-256 later only if a delivery spec asks for it.

### XXH64 test vectors

**Official repository vectors use a generated buffer, not strings.** `"a"` and `"abc"` aren't in the official repo. I'm giving both kinds, and they test different things.

Official table: https://github.com/Cyan4973/xxHash/blob/dev/tests/sanity_test_vectors.h. Buffer generator: https://github.com/Cyan4973/xxHash/blob/dev/cli/xsum_sanity_check.c (`XSUM_fillTestBuffer`):

```
byteGen = 2654435761 (64-bit)
for each byte: buffer[i] = byteGen >> 56; byteGen *= 11400714785074694797 (wrapping)
```

The first 8 bytes must be `00 52 92 9b b7 32 a3 24`. TESTED: all 8,322 XXH64 entries (len 0 to 4160, seeds 0 and 0x9E3779B1) passed against `xxhash.h` 0.8.5.

| Prefix length of buffer | Seed | Expected |
|---|---|---|
| 0 | 0 | `EF46DB3751D8E999` |
| 0 | 0x9E3779B1 | `AC75FDA2929B17EF` |
| 1 | 0 | `E934A84ADB052768` |
| 1 | 0x9E3779B1 | `5014607643A9B4C3` |
| 3 | 0 | `FF7E1959CB50794A` |
| 4 | 0 | `9136A0DCA57457EE` |
| 8 | 0 | `CDBCF538E71D1348` |
| 31 | 0 | `299B39A290E6D783` |
| 32 | 0 | `18B216492BB44B70` |
| 33 | 0 | `55C8DC3E578F5B59` |
| 64 | 0 | `EF558F8ACAC2B5CD` |
| 100 | 0 | `4BFE019CD91D9EA4` |

String vectors, computed with the official `xxhash.h` 0.8.5 (TESTED), and independently matched by python-xxhash 4.0.2 (libxxhash 0.8.3) for all but the last two rows. `""`, `"a"` and the 63-byte string also match the Go test table at https://raw.githubusercontent.com/cespare/xxhash/main/xxhash_test.go:

| Input (ASCII, seed 0) | Len | Expected |
|---|---|---|
| (empty) | 0 | `ef46db3751d8e999` |
| `a` | 1 | `d24ec4f1a98c6e5b` |
| `abc` | 3 | `44bc2cf5ad770999` |
| `Nobody inspects the spammish repetition` | 39 | `fbcea83c8a378bf1` |
| `The quick brown fox jumps over the lazy dog` | 43 | `0b242d361fda71bc` |
| `Call me Ishmael. Some years ago--never mind how long precisely-` | 63 | `02a2e85470d6fd96` |
| `0123456789abcdef0123456789abcdef` | 32 | `642a94958e71e6c5` |
| `0123456789abcdef0123456789abcdefX` | 33 | `ce5a102349511ece` |

Streaming at every split point of the 43-byte string equalled the one-shot result (TESTED). Test splits in the C implementation too: the 32-byte stripe boundary is where hand-written versions usually break.

---

## D. ASC MHL

Sources:

- Spec v1.0 (format version 2.0): https://github.com/ascmitc/mhl-specification/blob/master/Specification/ASCMHL_Specification_v1.0.pdf
- XSD: https://raw.githubusercontent.com/ascmitc/mhl/master/xsd/ASCMHL.xsd, `ASCMHLDirectory.xsd`, `ASCMHLDirectory__combined.xsd` in the same folder
- Tool: https://github.com/ascmitc/mhl

### D.1 Layout (VERIFIED-SOURCE, TESTED)

```
CARDNAME/
  ascmhl/
    0001_CARDNAME_2026-11-01_021117Z.mhl
    ascmhl_chain.xml
  DCIM/...
```

- `ascmhl/` sits at the root of the scope, next to the media (spec 5.2).
- Naming: `<numbering>_<foldername>_<date>_<time>.mhl`. Numbering is 4 digits or more, starting at 1. Date `YYYY-MM-DD`, time `HHMMSSZ` in UTC, fixed at the start of the operation (spec 6.3).
- Manifests are immutable once created (spec 5.2).
- The chain has one `hashlist` per generation, `sequencenr` continuous from 1, and a `c4` of the manifest file's bytes (spec, chain file section).

### D.2 Minimal valid manifest (TESTED, passes the official tool)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<hashlist version="2.0" xmlns="urn:ASC:MHL:v2.0">
  <creatorinfo>
    <creationdate>2026-11-01T03:11:17+01:00</creationdate>
    <hostname>mac.local</hostname>
    <tool version="0.1">card-ingest</tool>
  </creatorinfo>
  <processinfo>
    <process>transfer</process>
    <ignore>
      <pattern>.DS_Store</pattern>
      <pattern>ascmhl</pattern>
      <pattern>ascmhl/</pattern>
      <pattern>._*</pattern>
    </ignore>
  </processinfo>
  <hashes>
    <hash>
      <path size="5000" lastmodificationdate="2026-11-01T03:09:52+01:00">DCIM/A001/C001.MP4</path>
      <xxh64 action="original" hashdate="2026-11-01T03:11:17+01:00">09d2a836a8393e27</xxh64>
    </hash>
  </hashes>
</hashlist>
```

Chain file:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<ascmhldirectory xmlns="urn:ASC:MHL:DIRECTORY:v2.0">
  <hashlist sequencenr="1">
    <path>0001_CARDNAME_2026-11-01_021117Z.mhl</path>
    <c4>c4...</c4>
  </hashlist>
</ascmhldirectory>
```

Rules:

- **Required:** `creatorinfo` (`creationdate`, `hostname`, `tool`), `processinfo` (`process`), and `hashes` or `references`. `version` is fixed at `2.0`. Follow the XSD's order: `hashes` comes before `metadata`. The spec's prose lists them the other way round.
- **Optional:** `author`, `location`, `comment`, `roothash`, `directoryhash`. The official tool accepted a manifest with none of them.
- **Hash text:** lower-case hex. XXH64 is 16 characters.
- **C4:** `"c4"` + base58 of SHA-512, big-endian integer, left-padded with `1` to 88 characters, alphabet `123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz`. Total 90 characters.
- **Paths:** relative, forward slashes, no leading slash, no `..`, case and spaces preserved (spec 6.4.8). XML-escape `&`, `<`, `>`.
- **`action`:** `original` for the first hash in a history, `verified` when checked against an earlier generation, `failed` on mismatch.
- **Existing history:** Pomfort says a history can start in-camera, in which case the offload is generation 2 with `verified` hashes (VERIFIED-SOURCE https://pomfort.com/article/how-to-establish-an-asc-mhl-workflow-with-silverstack-and-mediaverify/). So if a card already has `ascmhl/`, copy it and append. Never overwrite it.
- **Directory hashes** (if wanted later): hash of sorted child hash bytes, spec Appendix G. The structure hash also mixes names. Not needed for validity.

### D.3 Proven with the official CLI (TESTED)

Using a 40-line Python writer (`integrity-tests/handwriter.py`), on a tree with `&`, `<`, `>`, a space and NFD non-ASCII in its paths:

- `ascmhl-debug xsd-schema-check`: manifest and chain validated.
- `ascmhl-debug verify`: rc 0. `ascmhl diff`: rc 0.
- `ascmhl create` appended generation 2 to the hand-written history.
- After changing one byte in a file, `verify` reported the hash mismatch with rc 11.
- After damaging the chain's c4, `verify` reported "Modified ASC MHL manifest", rc 31.

So yes, a writer is realistic in a few hundred lines of Swift, probably closer to 100.

Testing setup: `ascmhl` needs Python 3.11 or later. On Apple's Python 3.9, pip picks 1.0.1, which crashes with `module 'datetime' has no attribute 'UTC'`. Use `/opt/homebrew/bin/python3.14 -m venv /tmp/...` then `pip install ascmhl` (gives 1.2). `xsd-schema-check` needs an `xsd/` folder with all three schemas in the working directory.

Two traps found on exFAT (TESTED):

- **`._` files:** with default ignores, `ascmhl create` hashed every `._` file into the manifest, and a later `diff` failed with rc 21 on `._ascmhl`. Adding the `._*` pattern fixed both.
- **Unicode:** a manifest with NFD paths (what `readdir` returns) passed. The same manifest with NFC paths failed `verify` (rc 21) and `diff` (rc 10). The spec doesn't address normalization. Write the `readdir` form. A Windows or Linux verifier sees NFC on the disk and may fail on an NFD manifest. **UNVERIFIED**, and so is how Silverstack or OffShoot handle this. Test with real files before promising interop.

### D.4 Who reads it

- ASC page: "leading vendors, including Red, Arri, Pomfort, YoYotta, OffShoot, and Imagine Products, have implemented native support". VERIFIED-SOURCE https://theasc.com/news/asc-2026-hpa-innovation-technology-award-nominations
- Silverstack Lab, Silverstack XT and Offload Manager create, verify and continue histories, and MediaVerify validates them. VERIFIED-SOURCE Pomfort article above.
- OffShoot reads ASC MHL (uses listed checksums instead of rereading when size and date match), and lists it in Pro. VERIFIED-SOURCE https://docs.hedge.video/offshoot/features/verification, https://hedge.co/blog/ibc-2023
- ShotPut Pro and YoYotta: only the ASC statement above. Feature-level detail **UNVERIFIED**.
- None of these tools was run. Real interop is **UNVERIFIED**.

### D.5 MHL v1

Schema: https://mediahashlist.org/download/MediaHashList_v1_1.xsd (v1.1, 2016). Spec page: https://mediahashlist.org/mhl-specification/. Root `hashlist` with a `version` attribute, then `creatorinfo` (`name` optional, `username`, `hostname`, `tool`, `source` optional, `startdate`, `finishdate`, `log` optional) and `hash` entries (`file`, `size`, optional `creationdate`, `lastmodificationdate`, then one or more of `md5`, `sha1`, `xxhash`, `xxhash64`, `xxhash64be`, `null`, then `hashdate`). `xxhash64` is the deprecated little-endian form, so use `xxhash64be`. VERIFIED-SOURCE.

It's incompatible with v2 (spec 6.4.1). Write ASC MHL first. Add v1 only if a client asks. No v1 validator was run.

---

## E. Detection, eject, TCC

### E.1 Events (TESTED)

Timeline for one image attach and eject:

```
1.943 DA appeared disk10s1 (VolumePath nil)
1.983 DA description changed, VolumePath set
1.987 NSWorkspace didMount
4.292 NSWorkspace willUnmount   <- attempt failed, volume stayed mounted
4.614 NSWorkspace willUnmount   <- attempt failed
4.958 NSWorkspace willUnmount
5.150 DA description changed, VolumePath nil
5.151 NSWorkspace didUnmount
5.233 DA disappeared
```

- `willUnmount` fires even for failed attempts, so it can't mean "stop now".
- At registration, DA reports already-present disks, so no separate startup scan is needed.
- Use DA: appeared, description changed on VolumePath, disappeared. Consider `DARegisterDiskUnmountApprovalCallback` to refuse ejection during a copy (not tested).

### E.2 Classification (TESTED)

| Volume | removable | ejectable | internal | browsable | Notes |
|---|---|---|---|---|---|
| USB SSD | false | false | false | true | DAMediaEjectable=0, Protocol USB |
| Disk image | true | true | nil | per mount | Protocol "Virtual Interface", Model "Disk Image" |
| System volumes | false | false | true | false | under `/System/Volumes` |
| autofs `/home` | false | false | nil | false | local=false |

- `volumeIsInternal` means "connected to an internal bus". VERIFIED-SOURCE https://developer.apple.com/documentation/foundation/urlresourcekey/volumeisinternalkey
- **An internal SD reader is the trap:** a forum dump shows Protocol "Secure Digital", Device Location Internal, Removable. VERIFIED-SOURCE (secondary) https://forums.macg.co/threads/carte-sd-impossible-a-lire.1336001/ So `internal=true` doesn't exclude a card. Not tested here, and M-series readers are UNVERIFIED.
- USB SSDs report removable=false and ejectable=false, so those flags can't define "eject button".

Rule: exclude non-local, non-browsable and `Virtual Interface` volumes. Then call it a card if it has camera structure (`DCIM`, `PRIVATE/M4ROOT`, `CLIP`, and so on) and media is removable or protocol is Secure Digital. Everything else that's writable is a candidate destination, and the user confirms. Let the user override, because a USB-SSD recorder reports like a drive. Time Machine detection (`Backups.backupdb`, APFS backup role) is UNVERIFIED.

### E.3 Eject (TESTED, image, one file held open)

- `DADiskUnmount`: dissenter status `0x0000c010` (low bits are EBUSY), status string nil.
- `NSWorkspace.unmountAndEjectDevice(at:)`: `NSOSStatusErrorDomain -47`, empty `userInfo`, no detail.
- `lsof +f -- <mount>` named process, fd and file in 0.13 s.
- With the file closed: `DADiskUnmount` then `DADiskEject` on the whole disk succeeded.

Use DA, then run `lsof` on failure and show the process name. Don't force-unmount. Ejecting a device with `DAMediaEjectable=0` such as the working drive wasn't tested, so treat the result as UNVERIFIED.

### E.4 TCC

- An ad-hoc app launched by LaunchServices reading a USB SSD under `/Volumes` triggered `kTCCServiceSystemPolicyRemovableVolumes`, and the `opendir` blocked until answered. So a USB SSD counts as a removable volume although it reports removable=false (TESTED from `tccd` logs: `display_prompt`, then `auth_value=2`).
- `tccd` logged "No usage string found (key:NSRemovableVolumesUsageDescription)", and the prompt still showed. Add the key (TESTED).
- Plan for the first file call blocking: do it off the main thread with UI that explains why (TESTED behaviour, design inference).
- Full Disk Access isn't needed for volumes. Removable Volumes covered it (TESTED). It's only relevant for things like other apps' protected data.
- Whether a disk image triggers the prompt: UNVERIFIED (the grant was already in place).
- Network volumes have their own TCC service. UNVERIFIED here.
- Rebuilds: "Ad hoc signed code ... has a DR but it's tied to that specific version of the code... If you tweak the code and run it again, macOS repeats that prompt." VERIFIED-SOURCE TN3127, https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements. Quinn: https://developer.apple.com/forums/thread/795739. I didn't repeat this test, to avoid more prompts. A stable self-signed certificate reportedly keeps grants across rebuilds. VERIFIED-SOURCE (secondary) https://raw.githubusercontent.com/jackielii/skhd.zig/main/docs/CODE_SIGNING.md
- macOS 27: "Apps can no longer access the local TCC database directly." VERIFIED-SOURCE https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes. TESTED: the folder returns ENOENT.
- `tccutil reset` fails with -10814 for an app in `/tmp`, because LaunchServices doesn't resolve it. It works from `/Volumes` (TESTED).

### E.5 Volume UUID (TESTED, exFAT and FAT, images)

| Event | UUID |
|---|---|
| Remount | stable |
| Rename volume | stable |
| Reformat, same name | **changes** (serial changes) |
| Byte clone | **duplicate**, both mounted with the same UUID (second at `/Volumes/NAME 1`) |
| FAT serial zeroed | `00000000-0000-0000-0000-000000000000` |
| exFAT serial zeroed | a fixed derived UUID, not all zeros |

- exFAT's UUID is version-3 style and derived from the serial, not random (the v3 layout is visible in the values, the derivation itself is UNVERIFIED).
- Format serial is meant to be unique, combining date and time. VERIFIED-SOURCE spec 3.1.11. In practice it's only 32 bits and consecutive formats gave near-identical values (`6ae6a138`, `6ae6a13b`).
- Whether cameras write unique serials is UNVERIFIED. Treat UUID as a hint.

Card identity = UUID + volume name + total size + hash of the first files' names, sizes and times. A reformatted card gets a new UUID, which is what you want. Treat all-zero UUID as unknown.

---

## F. Fast drive indexing

### F.1 Working drive walk (TESTED, read-only, seconds, 3 rounds each)

| Method | Threads | Runs | Mean |
|---|---|---|---|
| `getattrlistbulk` | 1 | 10.66, 11.19, 11.50 | 11.1 |
| `getattrlistbulk` | 4 | 9.82, 9.89, 10.30 | 10.0 |
| `getattrlistbulk` | 8 | 18.18, 10.09, 10.75 | 13.0 |
| `getattrlistbulk` | 16 | 7.52, 10.10, 9.75 | 9.1 |
| `fts` with stat | 1 | 10.62, 11.65, 10.29 | 10.9 |
| `fts` no stat | 1 | 13.87, 11.40, 9.59 | 11.6 |
| `FileManager` enumerator | 1 | 9.84, 9.99, 11.38 | 10.4 |
| `readdir` + `fstatat` | 1 | 50.78, 53.31, 58.15 | 54.1 |
| `readdir` + `fstatat` | 4 | 34.99, 36.83, 36.51 | 36.1 |
| `readdir` + `fstatat` | 8 | 34.29, 35.01, 35.77 | 35.0 |

Other readings: the coldest available `getattrlistbulk` passes were 30.3 s and 19.2 s (warmth unknown, no root to purge and the drive couldn't be unmounted). `find -type f` took 7.7 s, avoiding stat.

Conclusions:

- **Threads don't help on exFAT.** FSKit appears to serialise metadata. Single thread is about as fast and simpler.
- Avoid per-file `stat`: five times slower.
- `fts` gives the same results as `getattrlistbulk` and is far simpler. Internally it likely uses bulk attributes (UNVERIFIED, inferred from identical speed and counts).
- exFAT reports `VOL_CAP_INT_READDIRATTR=0`, which suggests no native bulk path in the driver (the bit is TESTED, the interpretation is UNVERIFIED).
- **`FileManager` silently hides `._` files:** 252,888 files against 451,688 from `fts` and bulk. If you use it, your count won't match other tools. Apple documents `skipsHiddenFiles` as an option, but this was with options empty, so the behaviour is undocumented.
- In-progress copies alongside a walk: not measured.

### F.2 Directory mtime (TESTED, same on exFAT, FAT, APFS)

| Action | Parent mtime changes? | Grandparent? |
|---|---|---|
| create, rename, delete a child, create subdir | yes | no |
| append or rewrite a child's content | **no** | no |
| set a child's mtime | **no** | no |
| create a grandchild inside a subdir | no (for the outer dir) | no |

- It persists across remount on exFAT. The exFAT root has no timestamp: the working drive's root shows 1970.
- Non-macOS writers: the spec only defines "last modified" for a directory's clusters. Whether Windows and cameras update it is UNVERIFIED.
- `lstat` on all 15,811 directories of the working drive took 0.02 to 0.33 s warm. Cold is unknown.

So directory mtimes detect added, removed or renamed entries but not content changes, and don't propagate upward.

### F.3 FSEvents (TESTED)

- Live events on exFAT work, file-level, with `._` noise (`Modified` on `._a.txt` before `Created` on `a.txt`).
- A volume mounted `nobrowse` gets no `.fseventsd`, and `FSEventsCopyUUIDForDevice` is nil. Check before relying on it.
- Across eject, with a 45 s flush wait, 3 cycles each:

| FS | FSEvents UUID stable | Logs on volume | Replayed offline-stream events |
|---|---|---|---|
| exFAT | **no, 3/3 changed** | 0 | **0** |
| HFS+ | yes | grew | yes (5 entries) |
| APFS | yes | grew | yes (5 entries) |

- The working drive agrees: replay since id 1 gave 106,067 events in 27 s, no `MustScanSubDirs`, and started at a Mount event. `fseventsd-uuid` is dated to the last mount (Oct 31 01:22) and the oldest log is later than that. History doesn't survive a mount.
- A change made behind the driver (raw edit while unmounted, standing in for a camera or Windows) was invisible to replay, on a `nobrowse` mount. A change made by another OS doesn't reach FSEvents at all (logic, consistent with the test).
- Contract: "If the database gets discarded then its replacement will have a different UUID so that clients will be able to detect this situation". VERIFIED-SOURCE `FSEvents.h` in the SDK.

### F.4 Cache strategy that holds

1. Key the cache by volume UUID, name and total size.
2. Store the FSEvents UUID and last event id.
3. **On mount:** if FSEvents UUID is non-nil and unchanged, replay from the stored id. If it changed or is nil, which on exFAT is every mount, treat the cache as a hint and run a background walk (10 to 30 s on the working drive), then diff.
4. **While mounted:** apply live FSEvents, ignoring `._*`. On `MustScanSubDirs`, dropped or `RootChanged`, rescan.
5. Show cached results immediately, marked as refreshing.

`sinceWhen` across remounts, directory mtime as a change signal, and capacity or free-space checks don't hold on exFAT on their own. A cheap extra is `lstat` on known directories after mount, to prioritise changed folders. It can't replace the walk.

---

## G. Distribution without Xcode or Developer ID

### G.1 Ad-hoc universal app (TESTED build)

`swiftc` per architecture with `-target`, `lipo`, `codesign -f -s -` all work with CLT and SDK 26.5. Result: `flags=0x2(adhoc)`, `TeamIdentifier=not set`, `codesign --verify --strict` valid.

- `spctl -a -vv -t exec`: **rejected** (TESTED).
- `syspolicy_check distribution`: "Adhoc Signed App" (warning) and "Notary Ticket Missing" (fatal) (TESTED).
- Not tested: launching a really quarantined copy. It would leave a dialog open.

What the recipient sees:

- **macOS 14 and earlier:** Control-click, Open still overrides. Inferred from the next item.
- **macOS 15 and later:** "users will no longer be able to Control-click to override Gatekeeper ... They'll need to visit System Settings > Privacy & Security". VERIFIED-SOURCE https://developer.apple.com/news/?id=saqachfa (2024-08-06)
- **Current steps** (Apple's guide, page set to macOS 27): try to open, then System Settings, Privacy & Security, Security section, Open, Open Anyway, enter login password. "This button is available for about an hour after you try to open the app." VERIFIED-SOURCE https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac
- **macOS 27 notes:** the only Gatekeeper item is `spctl --purge`. No behaviour change found. VERIFIED-SOURCE release notes above. macOS 26's notes list no Gatekeeper section either (searched).
- A 15.1 report of *unsigned* apps getting no Open Anyway at all: VERIFIED-SOURCE (secondary) https://www.osnews.com/story/141055/bug-or-intentional-macos-15-1-completely-removes-ability-to-launch-unsigned-applications/ Unresolved, and ad-hoc is different from unsigned.
- Quarantine only applies to apps from quarantining downloaders. Removing it with `xattr -d com.apple.quarantine` is the common workaround (UNVERIFIED here).

### G.2 Notarization with CLT only

- `notarytool` and `stapler` are present in `/Library/Developer/CommandLineTools/usr/bin` (TESTED). Apple's page only mentions Xcode 13 or later: https://developer.apple.com/documentation/security/customizing-the-notarization-workflow
- Needs a paid Developer ID certificate, hardened runtime, secure timestamp, and an app-specific password or API key. VERIFIED-SOURCE same page.
- A real submission wasn't tested (no credentials). **UNVERIFIED**, but nothing in the flow needs Xcode.

### G.3 SMAppService (TESTED)

The status can lag. In the system log of a real click, on an ad-hoc build outside `/Applications` on macOS 27.2: `notFound` (3) before, `notRegistered` (0) straight after `register()`, `enabled` (1) at the next read nine seconds later, with no approval asked. So read the status again after a change, and don't treat `notFound` as a fault on an app that has never registered.

Ad-hoc app, `SMAppService.mainApp`, status `notFound` (3), `register()` ok, `enabled` (1), `unregister()` ok, `notRegistered` (0). Apple's API docs state no signing requirement in the pages read (https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp). Not tested: whether it actually launches at login, macOS 14, or surviving a rebuild, which could break because the identity changes.

### G.4 UserNotifications (TESTED)

- **From `/tmp`:** `UNErrorDomain Code=1 "Notifications are not allowed for this application"`. `usernoted` logged "Failed to find or validate client". This is the failure people blame on signing, and here it was the location.
- **From a mounted volume, same ad-hoc bundle:** `usernoted` presented the real `com.apple.notificationcenter.askpermissions` request. No error.
- Not tested: granting and receiving a notification (nobody answered, the app timed out).
- So ad-hoc authorization works, provided the app is somewhere LaunchServices resolves. Corroboration: `codesign -s -` was enough for Bitcoin Core: https://mirror.b10c.me/bitcoin-core-gui/112/. App Translocation (quarantined app run from a Downloads zip) might hit the `/tmp`-style failure. **UNVERIFIED**, so tell users to move the app to `/Applications`.

---

## I. Open items worth testing on real hardware

1. A spare USB SSD and a real SD card in an internal and a USB reader: repeat A, `DADiskEject`, classification and write throughput.
2. A power-pull test of a spare drive to learn whether `F_FULLFSYNC` is honoured through FSKit on USB.
3. macOS 14 and 15: repeat the tamper rig. FSKit vs older user-space exFAT may differ.
4. Interop: load our manifest in Silverstack and OffShoot, including NFD paths.
5. The 14 GB `.zip` from B.5: confirm the file is reachable from Windows or by raw inspection, since macOS 27.2 couldn't open it.

---

## Appendix A. Raw results

Output to compare a run of `integrity-tests/tamper` and `probe` against.

### A1. Tamper rig, exFAT (columns: blocks cache/dev/mix in body, then tail)

```text
mnt=/tmp/ingest-research/mnt/exfat raw=/dev/rdisk4s1 devbs=512 devsize=209714688 pagesize=16384 file=8393608 syncmode=1
total pages=513
write read method                 | res_wr  on_dev res_prd |  cache    dev  mix |   tc   td   tm | res_after
BUFRD plain read                  |    513 2050/2050     513 |   2048      0    0 |    2    0    0 | 513
BUFRD F_NOCACHE read              |    513 2050/2050     513 |   2048      0    0 |    2    0    0 | 513
BUFRD F_NOCACHE+RDAHEAD0          |    513 2050/2050     513 |   2048      0    0 |    2    0    0 | 513
BUFRD F_NOCACHE misaligned buf    |    513 2050/2050     513 |   2048      0    0 |    2    0    0 | 513
BUFRD F_NOCACHE 4K chunks         |    513 2050/2050     513 |   2048      0    0 |    2    0    0 | 513
BUFRD F_NOCACHE 1000-byte chunks  |    513 2050/2050     513 |   2048      0    0 |    2    0    0 | 513
BUFRD msync(INVALIDATE)+plain     |    513 2050/2050     513 |      0   2048    0 |    0    2    0 | 513
BUFRD msync(INVALIDATE)+NOCACHE   |    513 2050/2050     513 |      0   2048    0 |    0    2    0 | 0
BUFRD msync(SYNC|INVAL)+NOCACHE   |    513 2050/2050     513 |      0   2048    0 |    0    2    0 | 0
BUFRD msync(KILLPAGES)+plain      |    513 2050/2050     513 |   2048      0    0 |    2    0    0 | 513
BUFRD msync(KILLPAGES)+NOCACHE    |    513 2050/2050     513 |   2048      0    0 |    2    0    0 | 513
BUFRD msync(DEACTIVATE)+NOCACHE   |    513 2050/2050     513 |   2048      0    0 |    2    0    0 | 513
BUFRD mmap read                   |    513 2050/2050     513 |   2048      0    0 |    2    0    0 | 513
BUFRD 3rd-party read,then NOCACHE |    513 2050/2050     513 |   2048      0    0 |    2    0    0 | 513
BUFRD 3rd-party,msync(INV)+NOCACHE |    513 2050/2050     513 |      0   2048    0 |    0    2    0 | 0
BUFRD unmount/mount+plain         |    513 2050/2050     513 |      0   2048    0 |    0    2    0 | 513
NOCAC plain read                  |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 513
NOCAC F_NOCACHE read              |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 0
NOCAC F_NOCACHE+RDAHEAD0          |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 0
NOCAC F_NOCACHE misaligned buf    |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 0
NOCAC F_NOCACHE 4K chunks         |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 0
NOCAC F_NOCACHE 1000-byte chunks  |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 0
NOCAC msync(INVALIDATE)+plain     |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 513
NOCAC msync(INVALIDATE)+NOCACHE   |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 0
NOCAC msync(SYNC|INVAL)+NOCACHE   |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 0
NOCAC msync(KILLPAGES)+plain      |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 513
NOCAC msync(KILLPAGES)+NOCACHE    |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 0
NOCAC msync(DEACTIVATE)+NOCACHE   |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 0
NOCAC mmap read                   |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 513
NOCAC 3rd-party read,then NOCACHE |    513 2050/2050     513 |   2048      0    0 |    2    0    0 | 513
NOCAC 3rd-party,msync(INV)+NOCACHE |    513 2050/2050     513 |      0   2048    0 |    0    2    0 | 0
NOCAC unmount/mount+plain         |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 513
```

### A2. Tamper rig, APFS (via .dmg)

```text
mnt=/tmp/ingest-research/mnt/apfs raw=/tmp/ingest-research/a/t_apfs.dmg devbs=512 devsize=209715200 pagesize=16384 file=8393608 syncmode=1
total pages=513
write read method                 | res_wr  on_dev res_prd |  cache    dev  mix |   tc   td   tm | res_after
BUFRD plain read                  |    513 2050/2050     513 |   2048      0    0 |    2    0    0 | 513
BUFRD F_NOCACHE read              |    513 2050/2050     513 |   2048      0    0 |    2    0    0 | 513
BUFRD F_NOCACHE+RDAHEAD0          |    513 2050/2050     513 |   2048      0    0 |    2    0    0 | 513
BUFRD F_NOCACHE misaligned buf    |    513 2050/2050     513 |   2048      0    0 |    2    0    0 | 513
BUFRD F_NOCACHE 4K chunks         |    513 2050/2050     513 |   2048      0    0 |    2    0    0 | 513
BUFRD F_NOCACHE 1000-byte chunks  |    513 2050/2050     513 |   2048      0    0 |    2    0    0 | 513
BUFRD msync(INVALIDATE)+plain     |    513 2050/2050     513 |      0   2048    0 |    0    2    0 | 513
BUFRD msync(INVALIDATE)+NOCACHE   |    513 2050/2050     513 |      0   2048    0 |    0    2    0 | 0
BUFRD msync(SYNC|INVAL)+NOCACHE   |    513 2050/2050     513 |      0   2048    0 |    0    2    0 | 0
BUFRD msync(KILLPAGES)+plain      |    513 2050/2050     513 |   2048      0    0 |    2    0    0 | 513
BUFRD msync(KILLPAGES)+NOCACHE    |    513 2050/2050     513 |   2048      0    0 |    2    0    0 | 513
BUFRD msync(DEACTIVATE)+NOCACHE   |    513 2050/2050     513 |   2048      0    0 |    2    0    0 | 513
BUFRD mmap read                   |    513 2050/2050     513 |   2048      0    0 |    2    0    0 | 513
BUFRD 3rd-party read,then NOCACHE |    513 2050/2050     513 |   2048      0    0 |    2    0    0 | 513
BUFRD 3rd-party,msync(INV)+NOCACHE |    513 2050/2050     513 |      0   2048    0 |    0    2    0 | 0
NOCAC plain read                  |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 513
NOCAC F_NOCACHE read              |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 0
NOCAC F_NOCACHE+RDAHEAD0          |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 0
NOCAC F_NOCACHE misaligned buf    |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 0
NOCAC F_NOCACHE 4K chunks         |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 0
NOCAC F_NOCACHE 1000-byte chunks  |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 0
NOCAC msync(INVALIDATE)+plain     |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 513
NOCAC msync(INVALIDATE)+NOCACHE   |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 0
NOCAC msync(SYNC|INVAL)+NOCACHE   |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 0
NOCAC msync(KILLPAGES)+plain      |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 513
NOCAC msync(KILLPAGES)+NOCACHE    |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 0
NOCAC msync(DEACTIVATE)+NOCACHE   |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 0
NOCAC mmap read                   |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 513
NOCAC 3rd-party read,then NOCACHE |    513 2050/2050     513 |   2048      0    0 |    2    0    0 | 513
NOCAC 3rd-party,msync(INV)+NOCACHE |    513 2050/2050     513 |      0   2048    0 |    0    2    0 | 0
```

### A3. Tamper rig, HFS+ (via raw device)

```text
mnt=/tmp/ingest-research/mnt/hfs raw=/dev/rdisk8s1 devbs=512 devsize=209674240 pagesize=16384 file=8393608 syncmode=1
total pages=513
write read method                 | res_wr  on_dev res_prd |  cache    dev  mix |   tc   td   tm | res_after
BUFRD plain read                  |    513 2050/2050     513 |   2048      0    0 |    2    0    0 | 513
BUFRD F_NOCACHE read              |    513 2050/2050     513 |   2048      0    0 |    2    0    0 | 513
BUFRD F_NOCACHE+RDAHEAD0          |    513 2050/2050     513 |   2048      0    0 |    2    0    0 | 513
BUFRD F_NOCACHE misaligned buf    |    513 2050/2050     513 |   2048      0    0 |    2    0    0 | 513
BUFRD F_NOCACHE 4K chunks         |    513 2050/2050     513 |   2048      0    0 |    2    0    0 | 513
BUFRD F_NOCACHE 1000-byte chunks  |    513 2050/2050     513 |   2048      0    0 |    2    0    0 | 513
BUFRD msync(INVALIDATE)+plain     |    513 2050/2050     513 |      0   2048    0 |    0    2    0 | 513
BUFRD msync(INVALIDATE)+NOCACHE   |    513 2050/2050     513 |      0   2048    0 |    0    2    0 | 0
BUFRD msync(SYNC|INVAL)+NOCACHE   |    513 2050/2050     513 |      0   2048    0 |    0    2    0 | 0
BUFRD msync(KILLPAGES)+plain      |    513 2050/2050     513 |   2048      0    0 |    2    0    0 | 513
BUFRD msync(KILLPAGES)+NOCACHE    |    513 2050/2050     513 |   2048      0    0 |    2    0    0 | 513
BUFRD msync(DEACTIVATE)+NOCACHE   |    513 2050/2050     513 |   2048      0    0 |    2    0    0 | 513
BUFRD mmap read                   |    513 2050/2050     513 |   2048      0    0 |    2    0    0 | 513
BUFRD 3rd-party read,then NOCACHE |    513 2050/2050     513 |   2048      0    0 |    2    0    0 | 513
BUFRD 3rd-party,msync(INV)+NOCACHE |    513 2050/2050     513 |      0   2048    0 |    0    2    0 | 0
BUFRD unmount/mount+plain         |    513 2050/2050     513 |      0   2048    0 |    0    2    0 | 513
NOCAC plain read                  |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 513
NOCAC F_NOCACHE read              |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 0
NOCAC F_NOCACHE+RDAHEAD0          |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 0
NOCAC F_NOCACHE misaligned buf    |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 0
NOCAC F_NOCACHE 4K chunks         |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 0
NOCAC F_NOCACHE 1000-byte chunks  |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 0
NOCAC msync(INVALIDATE)+plain     |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 513
NOCAC msync(INVALIDATE)+NOCACHE   |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 0
NOCAC msync(SYNC|INVAL)+NOCACHE   |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 0
NOCAC msync(KILLPAGES)+plain      |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 513
NOCAC msync(KILLPAGES)+NOCACHE    |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 0
NOCAC msync(DEACTIVATE)+NOCACHE   |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 0
NOCAC mmap read                   |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 513
NOCAC 3rd-party read,then NOCACHE |    513 2050/2050     513 |   2048      0    0 |    2    0    0 | 513
NOCAC 3rd-party,msync(INV)+NOCACHE |    513 2050/2050     513 |      0   2048    0 |    0    2    0 | 0
NOCAC unmount/mount+plain         |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 513
```

### A4. Tamper rig, HFS+ (via .dmg, control for the APFS method)

```text
mnt=/tmp/ingest-research/mnt/hfs raw=/tmp/ingest-research/a/t_hfs.dmg devbs=512 devsize=209715200 pagesize=16384 file=8393608 syncmode=1
total pages=513
write read method                 | res_wr  on_dev res_prd |  cache    dev  mix |   tc   td   tm | res_after
BUFRD plain read                  |    513 2050/2050     513 |   2048      0    0 |    2    0    0 | 513
BUFRD F_NOCACHE read              |    513 2050/2050     513 |   2048      0    0 |    2    0    0 | 513
BUFRD F_NOCACHE+RDAHEAD0          |    513 2050/2050     513 |   2048      0    0 |    2    0    0 | 513
BUFRD F_NOCACHE misaligned buf    |    513 2050/2050     513 |   2048      0    0 |    2    0    0 | 513
BUFRD F_NOCACHE 4K chunks         |    513 2050/2050     513 |   2048      0    0 |    2    0    0 | 513
BUFRD F_NOCACHE 1000-byte chunks  |    513 2050/2050     513 |   2048      0    0 |    2    0    0 | 513
BUFRD msync(INVALIDATE)+plain     |    513 2050/2050     513 |      0   2048    0 |    0    2    0 | 513
BUFRD msync(INVALIDATE)+NOCACHE   |    513 2050/2050     513 |      0   2048    0 |    0    2    0 | 0
BUFRD msync(SYNC|INVAL)+NOCACHE   |    513 2050/2050     513 |      0   2048    0 |    0    2    0 | 0
BUFRD msync(KILLPAGES)+plain      |    513 2050/2050     513 |   2048      0    0 |    2    0    0 | 513
BUFRD msync(KILLPAGES)+NOCACHE    |    513 2050/2050     513 |   2048      0    0 |    2    0    0 | 513
BUFRD msync(DEACTIVATE)+NOCACHE   |    513 2050/2050     513 |   2048      0    0 |    2    0    0 | 513
BUFRD mmap read                   |    513 2050/2050     513 |   2048      0    0 |    2    0    0 | 513
BUFRD 3rd-party read,then NOCACHE |    513 2050/2050     513 |   2048      0    0 |    2    0    0 | 513
BUFRD 3rd-party,msync(INV)+NOCACHE |    513 2050/2050     513 |      0   2048    0 |    0    2    0 | 0
NOCAC plain read                  |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 513
NOCAC F_NOCACHE read              |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 0
NOCAC F_NOCACHE+RDAHEAD0          |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 0
NOCAC F_NOCACHE misaligned buf    |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 0
NOCAC F_NOCACHE 4K chunks         |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 0
NOCAC F_NOCACHE 1000-byte chunks  |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 0
NOCAC msync(INVALIDATE)+plain     |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 513
NOCAC msync(INVALIDATE)+NOCACHE   |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 0
NOCAC msync(SYNC|INVAL)+NOCACHE   |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 0
NOCAC msync(KILLPAGES)+plain      |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 513
NOCAC msync(KILLPAGES)+NOCACHE    |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 0
NOCAC msync(DEACTIVATE)+NOCACHE   |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 0
NOCAC mmap read                   |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 513
NOCAC 3rd-party read,then NOCACHE |    513 2050/2050     513 |   2048      0    0 |    2    0    0 | 513
NOCAC 3rd-party,msync(INV)+NOCACHE |    513 2050/2050     513 |      0   2048    0 |    0    2    0 | 0
```

### A5. Small files (1 KB and 12 KB)

```text
== tamper_1k exfat
BUFRD F_NOCACHE read              |      1   1/1         1 |      0      0    0 |    1    0    0 | 1
BUFRD msync(INVALIDATE)+NOCACHE   |      1   1/1         1 |      0      0    0 |    0    1    0 | 0
NOCAC plain read                  |      0   1/1         0 |      0      0    0 |    0    1    0 | 1
NOCAC F_NOCACHE read              |      0   1/1         0 |      0      0    0 |    0    1    0 | 0
== tamper_1k apfs
BUFRD F_NOCACHE read              |      1   1/1         1 |      0      0    0 |    1    0    0 | 1
BUFRD msync(INVALIDATE)+NOCACHE   |      1   1/1         1 |      0      0    0 |    0    1    0 | 0
NOCAC plain read                  |      0   1/1         0 |      0      0    0 |    0    1    0 | 1
NOCAC F_NOCACHE read              |      0   1/1         0 |      0      0    0 |    0    1    0 | 0
== tamper_1k hfs
BUFRD F_NOCACHE read              |      1   1/1         1 |      0      0    0 |    1    0    0 | 1
BUFRD msync(INVALIDATE)+NOCACHE   |      1   1/1         1 |      0      0    0 |    0    1    0 | 0
NOCAC plain read                  |      0   1/1         0 |      0      0    0 |    0    1    0 | 1
NOCAC F_NOCACHE read              |      0   1/1         0 |      0      0    0 |    0    1    0 | 0
== tamper_12k exfat
BUFRD F_NOCACHE read              |      1   4/4         1 |      3      0    0 |    1    0    0 | 1
BUFRD msync(INVALIDATE)+NOCACHE   |      1   4/4         1 |      0      3    0 |    0    1    0 | 0
NOCAC plain read                  |      0   4/4         0 |      0      3    0 |    0    1    0 | 1
NOCAC F_NOCACHE read              |      0   4/4         0 |      0      3    0 |    0    1    0 | 0
== tamper_12k apfs
BUFRD F_NOCACHE read              |      1   4/4         1 |      3      0    0 |    1    0    0 | 1
BUFRD msync(INVALIDATE)+NOCACHE   |      1   4/4         1 |      0      3    0 |    0    1    0 | 0
NOCAC plain read                  |      0   4/4         0 |      0      3    0 |    0    1    0 | 1
NOCAC F_NOCACHE read              |      0   4/4         0 |      0      3    0 |    0    1    0 | 0
== tamper_12k hfs
BUFRD F_NOCACHE read              |      1   4/4         1 |      3      0    0 |    1    0    0 | 1
BUFRD msync(INVALIDATE)+NOCACHE   |      1   4/4         1 |      0      3    0 |    0    1    0 | 0
NOCAC plain read                  |      0   4/4         0 |      0      3    0 |    0    1    0 | 1
NOCAC F_NOCACHE read              |      0   4/4         0 |      0      3    0 |    0    1    0 | 0
```

### A6. F_NOCACHE writes in small chunks

```text
wc=1000 exfat
NOCAC F_NOCACHE read              |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 0
wc=1000 hfs
NOCAC F_NOCACHE read              |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 0
wc=4096 exfat
NOCAC F_NOCACHE read              |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 0
wc=4096 hfs
NOCAC F_NOCACHE read              |      0 2050/2050       0 |      0   2048    0 |    0    2    0 | 0
```

### A7. F_NOCACHE write residency matrix

```text
== /tmp/ingest-research/mnt/exfat
  size=1000      chunk=1048576  bufoff=0     fileoff=0     full=0 resident=0/1
  size=4096      chunk=1048576  bufoff=0     fileoff=0     full=0 resident=0/1
  size=15000     chunk=1048576  bufoff=0     fileoff=0     full=0 resident=0/1
  size=16384     chunk=1048576  bufoff=0     fileoff=0     full=0 resident=0/1
  size=17000     chunk=1048576  bufoff=0     fileoff=0     full=0 resident=0/2
  size=65536     chunk=1048576  bufoff=0     fileoff=0     full=0 resident=0/4
  size=100000    chunk=1048576  bufoff=0     fileoff=0     full=0 resident=0/7
  size=1048576   chunk=1048576  bufoff=0     fileoff=0     full=0 resident=0/64
  size=1048577   chunk=1048576  bufoff=0     fileoff=0     full=0 resident=0/65
  size=8393608   chunk=1048576  bufoff=0     fileoff=0     full=0 resident=0/513
  -- small chunks
  size=8388608   chunk=4096     bufoff=0     fileoff=0     full=0 resident=0/512
  size=8388608   chunk=1000     bufoff=0     fileoff=0     full=0 resident=0/512
  size=8388608   chunk=16384    bufoff=0     fileoff=0     full=0 resident=0/512
  size=8388608   chunk=65536    bufoff=0     fileoff=0     full=0 resident=0/512
  -- misaligned memory buffer
  size=8388608   chunk=1048576  bufoff=7     fileoff=0     full=0 resident=0/512
  size=8388608   chunk=1048576  bufoff=512   fileoff=0     full=0 resident=0/512
  size=8388608   chunk=1048576  bufoff=4096  fileoff=0     full=0 resident=0/512
  -- misaligned file offset
  size=8388608   chunk=1048576  bufoff=0     fileoff=512   full=0 resident=0/513
  size=8388608   chunk=1048576  bufoff=0     fileoff=4096  full=0 resident=0/513
  dirty buffered write then msync(MS_INVALIDATE) w/o sync: rc=0 errno=0 data_intact=1
== /tmp/ingest-research/mnt/apfs
  size=1000      chunk=1048576  bufoff=0     fileoff=0     full=0 resident=0/1
  size=4096      chunk=1048576  bufoff=0     fileoff=0     full=0 resident=0/1
  size=15000     chunk=1048576  bufoff=0     fileoff=0     full=0 resident=0/1
  size=16384     chunk=1048576  bufoff=0     fileoff=0     full=0 resident=0/1
  size=17000     chunk=1048576  bufoff=0     fileoff=0     full=0 resident=0/2
  size=65536     chunk=1048576  bufoff=0     fileoff=0     full=0 resident=0/4
  size=100000    chunk=1048576  bufoff=0     fileoff=0     full=0 resident=0/7
  size=1048576   chunk=1048576  bufoff=0     fileoff=0     full=0 resident=0/64
  size=1048577   chunk=1048576  bufoff=0     fileoff=0     full=0 resident=0/65
  size=8393608   chunk=1048576  bufoff=0     fileoff=0     full=0 resident=0/513
  -- small chunks
  size=8388608   chunk=4096     bufoff=0     fileoff=0     full=0 resident=0/512
  size=8388608   chunk=1000     bufoff=0     fileoff=0     full=0 resident=0/512
  size=8388608   chunk=16384    bufoff=0     fileoff=0     full=0 resident=0/512
  size=8388608   chunk=65536    bufoff=0     fileoff=0     full=0 resident=0/512
  -- misaligned memory buffer
  size=8388608   chunk=1048576  bufoff=7     fileoff=0     full=0 resident=0/512
  size=8388608   chunk=1048576  bufoff=512   fileoff=0     full=0 resident=0/512
  size=8388608   chunk=1048576  bufoff=4096  fileoff=0     full=0 resident=0/512
  -- misaligned file offset
  size=8388608   chunk=1048576  bufoff=0     fileoff=512   full=0 resident=0/513
  size=8388608   chunk=1048576  bufoff=0     fileoff=4096  full=0 resident=0/513
  dirty buffered write then msync(MS_INVALIDATE) w/o sync: rc=0 errno=0 data_intact=1
== /tmp/ingest-research/mnt/hfs
  size=1000      chunk=1048576  bufoff=0     fileoff=0     full=0 resident=0/1
  size=4096      chunk=1048576  bufoff=0     fileoff=0     full=0 resident=0/1
  size=15000     chunk=1048576  bufoff=0     fileoff=0     full=0 resident=0/1
  size=16384     chunk=1048576  bufoff=0     fileoff=0     full=0 resident=0/1
  size=17000     chunk=1048576  bufoff=0     fileoff=0     full=0 resident=0/2
  size=65536     chunk=1048576  bufoff=0     fileoff=0     full=0 resident=0/4
  size=100000    chunk=1048576  bufoff=0     fileoff=0     full=0 resident=0/7
  size=1048576   chunk=1048576  bufoff=0     fileoff=0     full=0 resident=0/64
  size=1048577   chunk=1048576  bufoff=0     fileoff=0     full=0 resident=0/65
  size=8393608   chunk=1048576  bufoff=0     fileoff=0     full=0 resident=0/513
  -- small chunks
  size=8388608   chunk=4096     bufoff=0     fileoff=0     full=0 resident=0/512
  size=8388608   chunk=1000     bufoff=0     fileoff=0     full=0 resident=0/512
  size=8388608   chunk=16384    bufoff=0     fileoff=0     full=0 resident=0/512
  size=8388608   chunk=65536    bufoff=0     fileoff=0     full=0 resident=0/512
  -- misaligned memory buffer
  size=8388608   chunk=1048576  bufoff=7     fileoff=0     full=0 resident=0/512
  size=8388608   chunk=1048576  bufoff=512   fileoff=0     full=0 resident=0/512
  size=8388608   chunk=1048576  bufoff=4096  fileoff=0     full=0 resident=0/512
  -- misaligned file offset
  size=8388608   chunk=1048576  bufoff=0     fileoff=512   full=0 resident=0/513
  size=8388608   chunk=1048576  bufoff=0     fileoff=4096  full=0 resident=0/513
  dirty buffered write then msync(MS_INVALIDATE) w/o sync: rc=0 errno=0 data_intact=1
```

### A8. fcntl, rename and capability probes

```text
== /tmp/ingest-research/mnt/exfat fstype=exfat fsubtype=0 iosize=1048576 bsize=4096
  F_PREALLOCATE contig|all 64MiB rc=0  bytesalloc=67108864 0.09ms
    after prealloc st_size=0 st_blocks=0
  ftruncate to 64MiB                             rc=0
    after ftruncate st_size=67108864 st_blocks=131072
    pread hole n=4096 nonzero=0
  ftruncate down rc=0 0.09ms
  F_PREALLOCATE all 8MiB rc=0  alloc=8388608
  F_PREALLOCATE 1TiB (over free) rc=-1 Invalid argument alloc=0
  fsync(file) rc=0 2.82ms
  F_BARRIERFSYNC(file) rc=0  4.16ms
  F_FULLFSYNC(file) rc=0  0.06ms
  F_LOG2PHYS_EXT rc=-1 Operation not supported contig=1048576 devoff=0
  F_RDADVISE                                     rc=0
  fsync(dir) rc=0  0.36ms
  F_FULLFSYNC(dir) rc=0  3.21ms
  F_BARRIERFSYNC(dir) rc=0  3.15ms
  F_FULLFSYNC(read-only fd) rc=0  0.06ms
  renamex_np(RENAME_EXCL) onto existing rc=-1 File exists
  RENAME_SWAP rc=-1 Operation not supported
  rename over existing                           rc=0
  clonefile rc=-1 Operation not supported
  caps CASE_SENSITIVE=0 CASE_PRESERVING=1 2TB_FILESIZE=1 NO_ROOT_TIMES=1 SPARSE=0 FAST_STATFS=1 SYMBOLIC=1 HARDLINKS=0 JOURNAL=0 HIDDEN=1
  ifaces NAMEDSTREAMS=0 EXTENDED_ATTR=0 BULKATTR=0 RENAME_EXCL=0 RENAME_SWAP=0 EXCHANGEDATA=0 CLONE=0 ALLOCATE=1 FLOCK=1
  pathconf NAME_MAX=255 PATH_MAX=-1 CASE_SENS=0 CASE_PRES=1 NAME_CHARS_MAX=-1 FILESIZEBITS=64
== /tmp/ingest-research/mnt/fat fstype=msdos fsubtype=1 iosize=1048576 bsize=4096
  F_PREALLOCATE contig|all 64MiB rc=0  bytesalloc=67108864 3.11ms
    after prealloc st_size=0 st_blocks=131072
  ftruncate to 64MiB                             rc=0
    after ftruncate st_size=67108864 st_blocks=131072
    pread hole n=4096 nonzero=0
  ftruncate down rc=0 1.88ms
  F_PREALLOCATE all 8MiB rc=0  alloc=8388608
  F_PREALLOCATE 1TiB (over free) rc=-1 File too large alloc=0
  fsync(file) rc=0 0.73ms
  F_BARRIERFSYNC(file) rc=0  3.97ms
  F_FULLFSYNC(file) rc=0  3.27ms
  F_LOG2PHYS_EXT rc=-1 Operation not supported contig=1048576 devoff=0
  F_RDADVISE                                     rc=0
  fsync(dir) rc=0  0.34ms
  F_FULLFSYNC(dir) rc=0  3.17ms
  F_BARRIERFSYNC(dir) rc=0  3.16ms
  F_FULLFSYNC(read-only fd) rc=0  2.85ms
  renamex_np(RENAME_EXCL) onto existing rc=-1 File exists
  RENAME_SWAP rc=-1 Operation not supported
  rename over existing                           rc=0
  clonefile rc=-1 Operation not supported
  caps CASE_SENSITIVE=0 CASE_PRESERVING=1 2TB_FILESIZE=0 NO_ROOT_TIMES=1 SPARSE=0 FAST_STATFS=0 SYMBOLIC=1 HARDLINKS=0 JOURNAL=0 HIDDEN=1
  ifaces NAMEDSTREAMS=0 EXTENDED_ATTR=0 BULKATTR=0 RENAME_EXCL=0 RENAME_SWAP=0 EXCHANGEDATA=0 CLONE=0 ALLOCATE=1 FLOCK=1
  pathconf NAME_MAX=255 PATH_MAX=-1 CASE_SENS=0 CASE_PRES=1 NAME_CHARS_MAX=-1 FILESIZEBITS=33
== /tmp/ingest-research/mnt/apfs fstype=apfs fsubtype=1 iosize=2097152 bsize=4096
  F_PREALLOCATE contig|all 64MiB rc=0  bytesalloc=67108864 0.09ms
    after prealloc st_size=0 st_blocks=131072
  ftruncate to 64MiB                             rc=0
    after ftruncate st_size=67108864 st_blocks=131072
    pread hole n=4096 nonzero=0
  ftruncate down rc=0 0.01ms
  F_PREALLOCATE all 8MiB rc=0  alloc=8388608
  F_PREALLOCATE 1TiB (over free) rc=-1 No space left on device alloc=0
  fsync(file) rc=0 13.16ms
  F_BARRIERFSYNC(file) rc=0  11.44ms
  F_FULLFSYNC(file) rc=0  0.00ms
  F_LOG2PHYS_EXT rc=0  contig=1048576 devoff=2940928
  F_RDADVISE                                     rc=0
  fsync(dir) rc=0  0.00ms
  F_FULLFSYNC(dir) rc=0  0.00ms
  F_BARRIERFSYNC(dir) rc=0  0.00ms
  F_FULLFSYNC(read-only fd) rc=0  0.00ms
  renamex_np(RENAME_EXCL) onto existing rc=-1 File exists
  RENAME_SWAP rc=0 
  rename over existing                           rc=0
  clonefile rc=0 
  caps CASE_SENSITIVE=0 CASE_PRESERVING=1 2TB_FILESIZE=1 NO_ROOT_TIMES=0 SPARSE=1 FAST_STATFS=1 SYMBOLIC=1 HARDLINKS=1 JOURNAL=1 HIDDEN=1
  ifaces NAMEDSTREAMS=1 EXTENDED_ATTR=1 BULKATTR=0 RENAME_EXCL=1 RENAME_SWAP=1 EXCHANGEDATA=0 CLONE=1 ALLOCATE=1 FLOCK=1
  pathconf NAME_MAX=255 PATH_MAX=1024 CASE_SENS=0 CASE_PRES=1 NAME_CHARS_MAX=255 FILESIZEBITS=56
== /tmp/ingest-research/mnt/hfs fstype=hfs fsubtype=0 iosize=2097152 bsize=4096
  F_PREALLOCATE contig|all 64MiB rc=0  bytesalloc=67108864 0.10ms
    after prealloc st_size=0 st_blocks=131072
  ftruncate to 64MiB                             rc=0
    after ftruncate st_size=67108864 st_blocks=131072
    pread hole n=4096 nonzero=0
  ftruncate down rc=0 0.01ms
  F_PREALLOCATE all 8MiB rc=0  alloc=8388608
  F_PREALLOCATE 1TiB (over free) rc=-1 No space left on device alloc=0
  fsync(file) rc=0 0.21ms
  F_BARRIERFSYNC(file) rc=0  7.21ms
  F_FULLFSYNC(file) rc=0  0.01ms
  F_LOG2PHYS_EXT rc=0  contig=1048576 devoff=37556224
  F_RDADVISE                                     rc=0
  fsync(dir) rc=0  0.26ms
  F_FULLFSYNC(dir) rc=0  3.80ms
  F_BARRIERFSYNC(dir) rc=0  0.01ms
  F_FULLFSYNC(read-only fd) rc=0  0.01ms
  renamex_np(RENAME_EXCL) onto existing rc=-1 File exists
  RENAME_SWAP rc=-1 Operation not supported
  rename over existing                           rc=0
  clonefile rc=-1 Operation not supported
  caps CASE_SENSITIVE=0 CASE_PRESERVING=1 2TB_FILESIZE=1 NO_ROOT_TIMES=0 SPARSE=0 FAST_STATFS=1 SYMBOLIC=1 HARDLINKS=1 JOURNAL=1 HIDDEN=1
  ifaces NAMEDSTREAMS=1 EXTENDED_ATTR=1 BULKATTR=1 RENAME_EXCL=1 RENAME_SWAP=0 EXCHANGEDATA=1 CLONE=0 ALLOCATE=1 FLOCK=1
  pathconf NAME_MAX=255 PATH_MAX=1024 CASE_SENS=0 CASE_PRES=1 NAME_CHARS_MAX=255 FILESIZEBITS=64
```
