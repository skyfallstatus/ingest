# Speed: what the time goes on

Measured 2026-11-01 on one real card, on an M5 Max (18 cores, 128 GB) with both devices on their own 10 Gb/s USB links.

- **Card:** 138 files, 86.67 GB, in a USB reader. Read-only.
- **Working drive:** a 4 TB USB SSD, exFAT, read-only for these tests.
- **Destination:** throwaway exFAT sparse images on the internal SSD. **This is not a real external drive.** See [Limits](#limits-of-these-numbers).

Tools: `scripts/bench/` (`iotrace.c` times every system call of the unmodified binary, `iotrace.py` attributes the wall clock, `speedbench.c` does the raw tests), and `ingestctl timings`. Every read test purged the file first, and confirmed zero pages resident.

## Result

| Job | Before | After | Floor | Gain |
|---|---|---|---|---|
| Copy and proof, runs (s) | 202.45, 202.02, 201.74 | 187.44, 186.98, 186.98 | 184.6 | 7.4% |
| Same, final build, untraced (s) | | 187.21 | | |
| Re-check against an image (s) | 100.60, 100.73 | 92.53, 92.52, 92.51 | 92.3 | 8.1% |
| Same, final build, untraced (s) | | 92.50 | | |
| Re-check against the drive, with an 11 s index scan (s) | 113.47 | 103.80, 104.16 | | 8.4% |
| 2,500 tiny files (s, mean of 6 and 3, noisy) | 29.1 | 26.6 | | 9% |
| Same card again, this run of the app | a full re-check | fingerprints only | | all of it |

The floor is the whole answer: both jobs are limited by the card, whose ceiling is 939 MB/s. Copy and proof reads every byte from it twice, so it can't beat 2 × 86.67 GB ÷ 939 MB/s = 184.6 s. The app is now at 98.7% of that, and the re-check at 99.8%.

## Where the time really went

Full `ingest`, before and after. Every instant is shared equally between the system calls running then, so the columns sum to the wall clock (100% attributed). "User space" is whatever ran with no system call anywhere: hashing, Swift, thread start.

| Stage | Before, s | % | After, s | % |
|---|---|---|---|---|
| Read card | 179.06 | 88.4 | 163.21 | 87.3 |
| Write drive | 9.69 | 4.8 | 12.66 | 6.8 |
| User space, mostly hashing | 6.33 | 3.1 | 0.08 | 0.0 |
| Read drive | 5.35 | 2.6 | 9.13 | 4.9 |
| Flush, `F_FULLFSYNC` | 0.72 | 0.4 | 0.62 | 0.3 |
| Rename | 0.42 | 0.2 | 0.39 | 0.2 |
| Open, unlink, truncate | 0.56 | 0.3 | 0.61 | 0.3 |
| Journal, `fsync` | 0.11 | 0.1 | 0.05 | 0.0 |
| Invalidate, `msync` | 0.00 | 0.0 | 0.00 | 0.0 |
| Everything else | 0.21 | 0.1 | 0.23 | 0.1 |
| Total | 202.45 | | 186.98 | |

The "read" rows shrink less than the wall clock suggests because the card is the bottleneck in both builds. What changed is how often it sat idle between reads.

Full `confirm` against an image:

| Stage | Before, s | % | After, s | % |
|---|---|---|---|---|
| Read card | 92.27 | 91.6 | 81.51 | 88.1 |
| Read drive | 5.47 | 5.4 | 10.94 | 11.8 |
| User space, mostly hashing | 2.94 | 2.9 | 0.02 | 0.0 |
| Total | 100.73 | | 92.51 | |

### The suspects

| Suspect | Finding |
|---|---|
| `msync(MS_INVALIDATE)` | Innocent: 1 µs per file, whatever the size, with nothing cached. The whole card costs 1 ms |
| One read at a time, QD1 | **Guilty: this was the loss.** A fixed gap between reads costs 5% to 30% |
| Hashing inline | Small on its own, 3%, but it adds to that gap |
| Per-file overhead | Under 1.5 s on this card. It only matters for thousands of tiny files |
| Concurrency between the two sides | None: card and drive read at once did 937 and 1,014 MB/s |
| Swift per file, UI path | Nothing measurable |
| The sparse image | Not a limit: writes at 4.5 GB/s |
| The card and its reader | Together they're the ceiling, 939 MB/s. The drive does 1,015 on the same kind of link. These tests can't separate the card from the reader |

### The 195 s re-check

It doesn't reproduce with one reader: 100.6 s against an image, 113 s against the drive from the command line, 101 s by the app's own ledger timestamps. A debug build gives 130.7 s, because XXH64 at `-O0` runs at 4 GB/s. **Two re-checks at once give 184.81 s each**, the same device shared between two readers.

The likely cause, inferred and not proved: the app was running, and it starts a re-check on launch. It did so again during this work: it was running when measuring began, despite the brief, and reading card and drive at full speed. Check for it before benchmarking.

## Measurements

### Stages before any full read, ms, 3 runs

| Stage | Device | Runs |
|---|---|---|
| `listCard` | card | 5.6, 12.9, 15.6 |
| Quick fingerprints, one at a time | card | 66.8, 58.4, 66.8 (0.43 per file) |
| `CardReader.read`, listing and fingerprints | card | 17.9, 17.1, 18.4 |
| Ledger load | Drive | 221.6 cold, then 1.9, 2.7 |
| Drive index scan, 267,895 entries | Drive | 11,143, 11,114, 11,209 |
| Index save / load from cache | SSD | 33 to 35 / 149 to 159 |
| `CardMatcher.match` | Drive | 28.7 cold, then 1.5, 1.5 |
| `CardProber.probe`, everything / nothing in focus | card | 5.3 to 6.1 / 2.7 to 2.8 |

The app scans in the background and starts from the cached index, so the 11 s isn't waited on.

### Raw read, card, MB/s, no hash

Tested with 2 GiB per cell. QD is threads in `pread`.

| `F_NOCACHE` on, `F_RDAHEAD` off | QD1 | QD2 | QD4 | QD8 |
|---|---|---|---|---|
| 1 MiB | 664 | 939 | 939 | 939 |
| 4 MiB | 860 | 939 | 939 | 939 |
| 8 MiB (the old read) | 893 | 939 | 939 | 939 |
| 16 MiB | 912 | 939 | 939 | 939 |
| 64 MiB | 927 | 939 | 938 | 938 |

`F_RDAHEAD` on gave the same within 5 MB/s, because read-ahead does nothing under `F_NOCACHE`. With the cache and read-ahead both on, QD1 reaches 938 at every size, but that reads through RAM, which the proof can't do. At QD2 and above every cell of all four tables is 937 to 939. Repeats at QD2 and QD3 for 2, 4 and 8 MiB were 939 three times each. 1 MiB at QD2 once gave 870, so it isn't quite as steady.

### Raw read, working drive, MB/s, same conditions

| Chunk | QD1 | QD2 | QD4 |
|---|---|---|---|
| 1 MiB | 701 | 1,017 | 1,014 |
| 8 MiB | 957 | 1,015 | 1,012 |
| 64 MiB | 999 | 1,013 | 991 |

2 MiB wasn't tested on the drive. 1 MiB and 8 MiB at QD2 repeated at 1,018 and 1,017, three runs each.

### XXH64

28 GB/s inline, 27.4 GB/s on its own thread, three runs each: 0.3 ms per 8 MiB. A separate thread adds nothing by itself. The gain comes from reads staying in flight while it hashes.

### `msync(MS_INVALIDATE)`, ms, 3 runs

| Mapped | exFAT, nothing cached | exFAT, all cached | APFS, nothing cached | APFS, all cached |
|---|---|---|---|---|
| 1 MiB | 0.001 | 0.009 | 0.001 | 0.008 |
| 16 MiB | 0.001 | 0.11 to 0.15 | 0.001 | 0.13 to 0.17 |
| 256 MiB | 0.001 | 1.5 | 0.001 | 2.7 to 3.0 |
| 1 GiB | 0.001 | 4.7 to 5.0 | 0.001 | 5.7 to 5.9 |
| 4 GiB | 0.001 | 18.1 to 18.9 | 0.001 | 18.4 to 19.8 |

It scales with what's cached, not with mapped size. On the card, an 8.59 GB file took 0.001 to 0.006 ms. The call is kept unchanged, as the integrity evidence requires.

### Each path alone, 86.67 GB

| Path | Device | Before | After |
|---|---|---|---|
| `ci_hash_uncached` | card | 100.10, 100.61, 100.83 s (860 to 866 MB/s) | whole `confirm`: 92.5 s |
| `ci_hash_uncached` | Drive | 94.65 s (916 MB/s) | 86.34 s (1,004 MB/s) |
| `ci_hash_uncached`, read-back | SSD image | 13.73, 13.75, 13.75 s (6,311 MB/s) | 21.81 s (3,973 MB/s) |
| `ci_copy` | card to SSD image | 101.30, 101.37, 101.28 s (856 MB/s) | 93.59 s (926 MB/s) |

Read-back from the SSD image got slower, through the smaller chunk. It costs nothing, because a proof always waits for the card, and no card is near 4 GB/s.

### Per-file overhead, 2,500 tiny files, image to image

Runs before: 26.32, 29.77, 28.33, then on a fresh image 34.04, 30.51, 25.66. After: 28.47, 27.35, 23.84. Each run on an image tends to beat the last, so compare positions, not single numbers. Breakdown of the 28.32 s run, about 11.3 ms per file:

| Stage | ms per file | % |
|---|---|---|
| `F_FULLFSYNC` on the file | 4.07 | 35.9 |
| Rename: RENAME_EXCL refused 0.44, plain rename 1.35 | 1.73 | 15.3 |
| Journal `fsync` (removed: see Changed) | 1.22 | 10.8 |
| Read card | 1.04 | 9.1 |
| Open and create | 0.98 | 8.6 |
| Unlink, including `._` sidecars | 0.77 | 6.8 |
| Truncate | 0.42 | 3.8 |
| User space | 0.24 | 2.1 |
| Close, stat, times, preallocate, read-back and the rest | 0.86 | 7.6 |

## Changed

1. **Overlapped reads.** One read-ahead primitive in `io.c` now serves copy and proof: two reads in flight, chunks handed over strictly in file order, hashing on the consumer. 8 MiB for copies, 2 MiB for proof. Files under 16 MiB, and any file whose listed size is 0, are read in line with no threads, until end of file as before. This is almost all of the gain.
2. **Journal sync batching.** Tiny files share a sync, at most one each 250 ms. Saves 1.2 ms per file. A long clip still syncs its record, as it takes longer than that.
3. **Proof survives a remount.** In memory only, for 12 hours in one run of the app, only for a volume with a UUID, and only per file while size, modified time and fingerprint all match.
4. **Bytes on screen.** A re-check now shows the same meter, rate and time left as a copy. A copy counts both card reads, so the meter no longer stalls while a file is proved. Time left is the remaining work at the average speed since the start.

### A safety bug found on the way

`CardMatcher.match` took a stored proof without checking the file. A file changed in place on the card, then Recheck, kept its old proof, and the fresh read made the end-of-job comparison pass: a possible false Safe. Found by reading the code. Proofs are now tied to the file they proved, covered by `aProofDoesNotOutliveTheFileItProved`.

## Hard limits, checked

- **Second card read:** untouched. Every file is read in full from the card and the drive in `readBoth`, independently of the copy.
- **Ledger is a hint:** unchanged. `Proof` is in memory only, and nothing read from a drive can create one.
- **Temp, rename, no overwrite, strict listing, weak flush, final fingerprints:** code unchanged. Verdict logic unchanged.
- **A batched journal:** a record still only follows a proved file in place, so any record that survives is true. A pulled drive can lose up to 250 ms of records, and those files are then found and read again. A weak mark syncs at once, as nothing else keeps it.
- **Remount:** this is the one behaviour that changed on purpose. `selftest` used to require a re-read after a remount. It now requires no re-read in the same run, and a full read after proofs are forgotten, as in a new run. What it gives up: a card changed while out of the reader, in the middle of a file only, keeping its volume UUID, size, modified time and first and last 64 KiB, would keep its proof for up to 12 hours. The same blind spot already applies while a card stays mounted.

### Device read path, tamper rig

`docs/research/integrity-tests/tamper.c` now calls `ci_hash_uncached` itself. Disk images only, with the device guard. Every case read `all device`, `invalidated 1`:

| | exFAT, 8 MiB (in line) | APFS, 8 MiB | exFAT, 64 MiB (overlapped) | APFS, 64 MiB |
|---|---|---|---|---|
| Buffered write | device | device | device | device |
| Buffered write, third-party read | device | device | device | device |
| `F_NOCACHE` write | device | device | device | device |
| `F_NOCACHE` write, third-party read | device | device | device | device |

Control from the same runs: `F_NOCACHE` alone on a buffered write still reads the cache, 2,048 of 2,048 blocks, so the rig still tells them apart.

### ThreadSanitizer

0 reports across 880 whole reads and copies, 294 mid-file stops, and 224 files cut short mid-read, and through 11 Swift engine tests. A planted race was caught, so it was really on. Every result was the exact start of the file, in order.

### Suite

`swift build` clean. `scripts/test.sh` 331 pass. `INGEST_LIVE=1 scripts/test.sh` 331 pass with 37 more really run, 9 skipped for missing public samples. `selftest` 123 pass, 0 fail. No file on the drive changed during any of these runs.

## Not changed, and why

| Idea | Why not |
|---|---|
| Replacing `msync` | It costs nothing |
| Overlapping read-back of file N with copy of N+1 | The card has to serve the same bytes regardless, so at most 1.3% is left here |
| Reordering small files | Total work is the same. It would only move when each file finishes |
| Larger buffers, higher QD | 939 is reached at QD2. More memory, no speed |
| A second read in parallel with the first | Same card, same ceiling |

## Gains blocked by a safety rule

| Rule | What it costs | Owner's call |
|---|---|---|
| Full second card read | 92 s, half of a copy and proof. Without it: about 94 s | Decided: it stays |
| `F_FULLFSYNC` per file | 36% of tiny files. 0.3% on this card | Left as it is. Batching would mean a drive-wide weak flush, and a new ordering of flush and rename |
| Trying RENAME_EXCL first | 0.44 ms per file: 4% of tiny files, 0.03% here | Left as it is |

## Limits of these numbers

- **The destination was an SSD image, not a USB drive.** It writes at 4.5 GB/s and its flush takes 4 ms, so it hides the drive entirely. On a real drive, copy and proof takes at least 187 s, and more if the drive can't sustain 939 MB/s through one write at a time.
- **Writes to a real drive were never measured.** The drive is read-only here, and nothing else is attached. Writes are still one at a time, 8 MiB each. Reads lost 5% that way, so writes may too. Worth measuring on a spare drive before changing.
- **The 2 MiB chunk and QD2 weren't tried on a hard drive.** The small chunk was chosen to stay nearly sequential, and that is reasoning, not a measurement.
- **One card and one reader.** A faster card moves the ceiling up, and the method still applies.
