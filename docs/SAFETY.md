# The safety contract

A false "Safe to format" destroys footage that exists nowhere else. Everything else in this project can be traded away. This can't.

These rules hold for every change. Speed, tidiness and new features all come second. A rule here is only changed by a deliberate decision from the project's owner, written down here with the reason.

## The verdict

1. **One place decides.** `Verdict.evaluate` is the only code that can say a card is safe. Nothing else may produce or imitate that result.
2. **Green needs all of it.** The listing finished with no errors, every listed file opened, every file was proved identical by reading both sides, nothing is a blocker, and the card still lists exactly what was proved.
3. **Green is about this drive.** A proof belongs to one drive. Change the working drive and it's gone. No drive means no green.
4. **The last look is real.** Before green, the drive must still hold every file at its listed size, and the card must be listed and fingerprinted again and match.
5. **Doubt is never green.** A blocker stops the verdict. A hold means "Have a look". Only a note leaves a card green. A rule that can't reach a conclusion must not read as a pass.
6. **An unreadable volume isn't an empty one.** A denied permission or a failed listing is never "empty" and never "safe".
7. **Green is earned on screen too.** The green foot and the word "format" in the menu bar appear only on a proved card, and "Don't format" never appears on green.

## The copy

8. **Read everything, twice.** Every file is read in full from the card a second time, separately from the copy, and in full from the drive. The hash taken during the copy can't catch a bad read, because the same wrong bytes reach both sides. This second card read costs about half the time of a job, and it stays.
9. **Read from the device.** Read-back has to reach the device, not the macOS cache: `F_NOCACHE` writes, `F_FULLFSYNC`, `msync(MS_INVALIDATE)`, then an `F_NOCACHE` read. `F_NOCACHE` alone isn't enough. The evidence is in `docs/research/integrity-macos.md`.
10. **A real name is earned.** A file is written under a temporary name and takes its real name only after the copy, the drive and the second card read agree. Temp, read-back, then rename: that order doesn't change.
11. **Never overwrite.** An existing file must prove itself identical, or the job refuses.
12. **The app never writes to a card.** Not a marker, not a manifest, not a timestamp.
13. **The source must still be the source.** If the file at a path no longer matches what was read, it isn't copied. A different card with the same names and sizes is caught by fingerprints.
14. **Nothing on a card is left behind.** Every file is copied, including ones the app doesn't recognise, and empty folders survive. Only the system files macOS and Windows leave on a volume are skipped. A card's own index is never treated as a list of what's there: the card itself is listed.
15. **The strict listing stays.** Cards are walked with the strict C walker, which reports every failure. `FileManager` silently hides entries on exFAT and must never list a card.

## Proof

16. **The ledger is a hint.** Nothing read from a drive can create a proof. The record on the drive may suggest where a file is. Only reading both sides in full proves it.
17. **Proof is in memory only.** It's never written down, and it ends when the app quits. It can survive a remount for up to 12 hours within one run, only for a volume with a UUID, and only per file while size, modified time and fingerprint all match.
18. **Proof is tied to the file it proved.** A file changed in place loses its proof.
19. **Weak stays weak.** If a drive wouldn't confirm a flush, or the cache couldn't be cleared, that copy is a hold. It stays a hold on every later visit, and a later good read doesn't clear it.
20. **Time is never evidence.** Modified times are recorded and compared for convenience. They never prove anything.

## Honesty

21. **Nothing claims a clip was played.** No clip is played. Every check reads structure, and the wording says so. A format with no check says "Clips were not checked or played."
22. **Claims follow evidence.** A rule built from documents is labelled that way until a real file confirms it. See `CONTRIBUTING.md`.
23. **A camera's name is never proof.** Identification is best effort and never changes what gets copied.

## Known limits, stated plainly

These are accepted, and they must stay written down:

- **A drive can lie about its cache.** Software can't see past it. A drive that refuses to confirm goes to a hold, but a drive that confirms falsely can't be detected. Only a power cycle clears such a cache, and software can't see one.
- **The remount window in rule 17.** A card changed while out of the reader, only in the middle of a file, keeping its UUID, size, modified time and first and last 64 KiB, would keep its proof for up to 12 hours. The same blind spot applies while a card stays mounted.
- **One drive is one copy.**

## If you change the engine

Run `scripts/test.sh`, and `scripts/selftest.sh` if the app's flow was touched. `Tests/IngestCoreTests/SafetyRegressionTests.swift` holds one test per attack that once produced, or could have produced, a false Safe. Never weaken or delete one of those to make a change pass. A bug that could produce a false Safe gets a test there before it gets a fix.
