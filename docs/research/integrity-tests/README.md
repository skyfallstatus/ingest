# Integrity tests

The programs behind the TESTED claims in `../integrity-macos.md`. They were used to settle how the app reads a file back from the device rather than from the Mac's cache. Nothing in the app or its tests depends on them.

**Disk images only.** `tamper` writes straight to the raw device it's given, to change bytes behind the filesystem, and it doesn't check what that device is. Pointed at a real drive it destroys data. Follow the guard below every time.

| Program | Shows | Expected result |
|---|---|---|
| `tamper.c` | Whether a read came from the cache or the device | Table A.2, and Appendix A1 to A4 |
| `ncmatrix.c` | Whether `F_NOCACHE` writes stay out of the cache | Appendix A7 |
| `durable.c` | When written bytes reach the device, per sync call | A.4. An image can't show a drive lying about a flush |
| `probe.c` | `F_FULLFSYNC` on file, directory and read-only fd, `RENAME_EXCL`, capabilities | Appendix A8. It's the one to run on a spare USB drive |
| `ts.c` | Timestamps as stored | B.3 |
| `names.py`, `nf.py` | Name limits and Unicode forms | B.4, B.6 |
| `handwriter.py` | The smallest ASC MHL writer. Needs `pip install xxhash` | D.3 |

`tamper`, `ncmatrix`, `durable` and `probe` compile with plain `cc`:

```sh
cc -O2 -o tamper tamper.c
```

## Running the tamper rig

```sh
hdiutil create -size 200m -fs ExFAT -volname TEST t.dmg
mkdir mnt
hdiutil attach -nobrowse -mountpoint ./mnt t.dmg        # note the device, e.g. /dev/disk5s1
diskutil info /dev/disk5s1 | grep -q 'Protocol:.*Disk Image' || exit 1
./tamper ./mnt /dev/rdisk5s1 -
hdiutil detach ./mnt
```

To test the app's own read path as well, add `ci_hash_uncached` and a third-party-reader case to the methods. Every one must read `all device`. The default file takes the in-line path. `-DNBODY=16384`, on a 400 MB image, makes a 64 MiB file, which takes the overlapped one:

```sh
cc -O2 -DWITH_CI -DNBODY=16384 -I../../../Sources/CIngest/include -o tamper tamper.c ../../../Sources/CIngest/*.c
```

The `diskutil` line is the guard: it stops the run unless that device really is a disk image. Note the `r` in `/dev/rdisk5s1`.

For APFS, pass the `.dmg` file itself as the raw path. No device is opened at all.
