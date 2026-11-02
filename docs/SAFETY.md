# The safety contract

A false "Safe to format" destroys footage that exists nowhere else. Everything else in this project can be traded away. This can't.

These rules hold for every change. Speed, tidiness and new features all come second. A rule here is only changed by a deliberate decision from the project's owner, written down here with the reason.

## The verdict

1. **One place decides.** `Verdict.evaluate` is the only code that can say a card is safe. Nothing else may produce or imitate that result.
2. **Green needs all of it.** The listing finished with no errors, every listed file opened, every file was proved identical by reading both sides, nothing is a blocker, and the card still lists exactly what was proved.
3. **Green is about this drive.** A proof belongs to one mount of one drive. Change the working drive, or unplug it, and it's gone. Another drive at the same path is another drive, even with the same name and UUID. No drive means no green.
4. **The last look is real.** Before green, every file on the drive must still be the file that was proved: same mount, same file, same size, same modified time. The card must be listed and fingerprinted again and match, modified times included, and any device log is read again after the full reads that can add to it.
5. **Doubt is never green.** A blocker stops the verdict. A hold means "Have a look". Only a note leaves a card green. A rule that can't reach a conclusion must not read as a pass.
6. **An unreadable volume isn't an empty one.** A denied permission or a failed listing is never "empty" and never "safe".
7. **Green is earned on screen too.** The green foot and the word "format" in the menu bar appear only on a proved card, and "Don't format" never appears on green.

## The copy

8. **Read everything, twice.** Every file is read in full from the card a second time, separately from the copy, and in full from the drive. The hash taken during the copy can't catch a bad read, because the same wrong bytes reach both sides. This second card read costs about half the time of a job, and it stays.
9. **Read from the device.** Read-back has to reach the device, not the macOS cache, on both sides: `F_NOCACHE` writes, `F_FULLFSYNC`, `msync(MS_INVALIDATE)`, then an `F_NOCACHE` read. `F_NOCACHE` alone isn't enough. If either side's cache can't be cleared, rule 19 applies. A read counts only if it reached the listed size and the file didn't change during it. The evidence is in `docs/research/integrity-macos.md`.
10. **A real name is earned.** A file is written under a temporary name and takes its real name only after the copy, the drive and the second card read agree. Temp, read-back, then rename: that order doesn't change. Temporary files live only in `.ingest/tmp`, and only files there are ever cleaned up, so nobody else's file can be taken for one. The one other thing a later job may remove is an empty file the journal shows this app reserved and never filled, once the job that reserved it has died.
11. **Never overwrite.** An existing file must prove itself identical, or the job refuses. A real name is taken atomically: `RENAME_EXCL` where the filesystem has it, and on exFAT, which doesn't, an `O_EXCL` reservation of the name, checked as still being that empty file, that the rename then replaces.
12. **The app never writes to a card.** Not a marker, not a manifest, not a timestamp.
13. **The source must still be the source.** If the file at a path no longer matches what was read, it isn't copied. A different card with the same names and sizes is caught by fingerprints.
14. **Nothing on a card is left behind.** Every file is copied, including ones the app doesn't recognise, and empty folders survive: one missing from the drive is a hold. Only the system files macOS and Windows leave on a volume are skipped. A card's own index is never treated as a list of what's there: the card itself is listed.
15. **The strict listing stays.** Cards are walked with the strict C walker, which reports every failure. `FileManager` silently hides entries on exFAT and must never list a card.

## Proof

16. **The ledger is a hint.** Nothing read from a drive can create a proof. The record on the drive may suggest where a file is. Only reading both sides in full proves it.
17. **Proof is in memory only, and ends with the mount.** It's never written down. It ends when the app quits, and when the card or the drive leaves the Mac, however briefly. A card put back in is read in full again, about 92 s on the test card. The owner decided this on 2026-11-02, replacing a 12-hour remount window, after three independent reviews: proof must not survive a card leaving the Mac. Nothing about a card can show it wasn't changed while it was out.
18. **Proof is tied to both files.** It holds only for the card file with the size, modified time and fingerprint it had, and the drive file with the identity, size and modified time it had. Any change means unproved, and it's read again. An empty file has no identity to hold, because exFAT and FAT make one up that macOS changes on its own, and no bytes to prove: its size and time still count. While nothing changes, nothing is read in full again just to redraw the panel. Recheck always reads both sides again.
19. **Weak stays weak, and a job that was cut off isn't weak.** If a drive refuses to confirm a flush, or the cache can't be cleared on either side, that copy is a hold. It stays a hold on every later visit, under any new name, and a later good read doesn't clear it. A weak mark reaches the drive before the file gets its real name. A job's record opens before it writes anything. It's sealed once the drive confirms the job, and marked refused if the drive says no. One with neither was cut off, by a pulled cable or a crash, and its files are unfinished: a hold until the drive confirms a flush and both sides are then read in full, in that order, which closes them on the record for good. A look that doesn't flush leaves them on hold, and so does a refused flush, and nothing is closed by a read from before the flush. A check always asks the drive to flush before it reads. The owner decided this on 2026-11-02, after review: a confirmed flush and then a full read is the same evidence a sealed job has, and a drive that was pulled has usually lost power too, which is all that clears a lying cache.
20. **Time is never evidence.** Modified times are recorded and compared for convenience. They never prove anything.

## The drive

24. **Every path stays on the drive.** Paths from a saved setup, a ledger, an index or a person are refused if they're absolute, hold `.` or `..`, or lead into the app's own folder. Everything on the drive is reached with no symbolic link on the way, on the drive's own volume, and a file that turns out to be the card's own file is never a copy of it.
25. **A job belongs to its drive.** The working drive can't change under a running or queued job, and everything known about a card is dropped before another drive is looked at.

## Honesty

21. **Nothing claims a clip was played.** No clip is played. Every check reads structure, and the wording says so. A format with no check says "Clips were not checked or played."
22. **Claims follow evidence.** A rule built from documents is labelled that way until a real file confirms it. See `CONTRIBUTING.md`.
23. **A camera's name is never proof.** Identification is best effort and never changes what gets copied.
26. **Not safe always says why.** Every file left unproved carries a reason a person can read, and it survives a rescan until something new is known about that file.

## Known limits, stated plainly

These are accepted, and they must stay written down:

- **A drive can lie about its cache.** Software can't see past it. A drive that refuses to confirm goes to a hold, but a drive that confirms falsely can't be detected. Only a power cycle clears such a cache, and software can't see one.
- **A file changed with nothing to show for it.** While a card and a drive stay mounted, proof isn't re-read. A card file changed only in the middle, keeping its size, modified time and first and last 64 KiB, keeps its proof, and so does a drive file changed with its size and modified time put back: in place anywhere, and on FAT32, which reuses a first cluster, rewritten too. Recheck reads both sides again, and leaving the Mac ends the proof.
- **A careless writer on exFAT.** With no atomic exclusive rename there, a program that writes to, or renames onto, a reserved name in the instant between the app's last check and its rename can lose what it wrote. It would write over anything at that name.
- **A refusal that couldn't be recorded.** If a drive refuses the final flush and won't take a record of that either, the job reads as cut off, not refused. On a later visit a look still holds and a refused flush still holds, but a confirmed flush and a full read finish it, and it can go green. That's the evidence any green rests on, and a drive that confirms falsely is the first limit above.
- **Striped BRAW pairs are matched by name, folder and this drive's record.** No real pair has been tested, so whether two halves are the same take isn't checked.
- **One drive is one copy.**

## If you change the engine

Run `scripts/test.sh`, and `scripts/selftest.sh` if the app's flow was touched. `Tests/IngestCoreTests/SafetyRegressionTests.swift` holds one test per attack that once produced, or could have produced, a false Safe, `DiskImageTests.swift` beside it holds the ones that need a real volume, and `Tests/IngestAppTests` the ones that live in the app's own model. Never weaken or delete one of those to make a change pass. A bug that could produce a false Safe gets a test there before it gets a fix.
