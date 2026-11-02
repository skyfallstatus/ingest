# Contributing

Thanks for looking. This app decides when someone can erase footage, so it's run more carefully than most small projects.

## The safety rules aren't negotiable

Read [docs/SAFETY.md](docs/SAFETY.md) first. A change that weakens any rule there won't be accepted, however much faster or simpler it makes things. If you think a rule is wrong, open an issue and argue it with evidence before writing code.

If you find something that could produce a false "Safe to format", say so straight away, even if you have no fix.

## One real sample per format claim

A new camera or format needs at least one real file from that camera. Manuals are a good start, but they've been wrong before. A real file is what makes a rule trustworthy.

- **Keep footage out of the repository.** Turn what the file taught you into a small fixture, byte-accurate where it matters, and say which real file it follows.
- **Keep private data out too.** No real serials, client names, drive names or paths. Use synthetic values of the same shape.
- **Check the terms** of any public sample, and credit it in [NOTICE](NOTICE) if any of it is excerpted.

No real sample? You can still contribute a rule from documents, as long as it's labelled as such.

## Evidence labels

The research in `docs/research/` tags every claim:

| Label | Meaning |
|---|---|
| `[SAMPLE]` | Seen in a real file |
| `[SOURCE]` | Stated in a manual, specification or parser source |
| `[SOURCE-2]` | A secondary source: a third-party parser, blog or forum |
| `[UNVERIFIED]` | Memory or inference. Don't ship a rule on this |

In tests, a name starting `doc-derived:` means the rule comes from documents and no real file has confirmed it. Keep that prefix until one does, then remove it and update the camera table in the README.

Never move a camera up the README table without the evidence for it. "Real card" means the app has run on a whole card, or a whole card folder, as the camera wrote it.

## How to test

```sh
swift build
scripts/test.sh
```

Both must be clean. No Xcode is needed, and `scripts/test.sh` needs no hardware. It wants 150 GB free, runs one test at a time, and stops itself if the disk is filling, the run passes 20 minutes, or the Mac can't start a process: the top of the script says how to change those.

- **Engine or verdict changes** need a test. A bug that could give a false Safe gets a test in `SafetyRegressionTests.swift` first, and that test must fail before your fix.
- **App flow changes:** also run `SAMPLE_CARD=/path/to/card scripts/selftest.sh`. It uses its own throwaway disk images and fences the app in to them, but it does mount them, so don't run it while you're working with real cards.
- **Visual changes:** `.build/debug/IngestApp --render /tmp/ingest-shots` draws every state in light and dark. It touches no volume.
- **Your own media:** tests in `Tests/IngestCoreTests/Local/` stay on your machine. That folder is ignored by git, and is the place for anything that needs a real drive or real footage.

## Style

- No third-party dependencies beyond Sparkle, which installs updates.
- Small and deliberate. Prefer deleting code to adding it. Version 1 stays small on purpose.
- Nothing is added to the main widget lightly. It's about the card in front of you, and everything else goes behind the quiet control.
- Words shown to people are plain and calm, and they never claim more than was checked.

## Reporting a bug

Use Report a Bug in the app, under the `···` control. It fills in the app version, macOS version and Mac family, and it never includes paths, file names, client names, serials or drive names. Please don't paste those in yourself.
