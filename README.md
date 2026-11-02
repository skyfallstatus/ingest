# Ingest

A small menu bar app for macOS. It copies a camera card to your working drive, reads both sides back in full, and tells you when the card is safe to format.

It lives in the menu bar as a card icon and a word: `Reading`, `96 left`, `Checking`, `Safe to format`. Click it for a small widget that shows the same numbers line by line, with the verdict at the bottom. There's no main window and no Dock icon.

**Status:** private beta. Please read [what not to rely on yet](#what-not-to-rely-on-yet).

## What "Safe to format" promises

The app says it only when all of this is true for the card in front of you, on the drive you're using, with both of them plugged in since they were read:

- The card was listed completely, with no errors, and every listed file opened.
- Every file was copied to a temporary name, written out to the drive, then read back from the drive itself rather than from memory.
- Every file was read from the card a second time, separately from the copy. Both reads and the copy agree, by XXH64 hash and by size, and match the size the card listed.
- Only then did the file get its real name.
- A file that was already on the drive wasn't taken on trust. It was read in full on both sides too.
- At the very end every file on the drive is still the file that was proved, and the card still lists exactly what was proved.
- Nothing on the card raised a problem that stops the verdict.

**A proof doesn't outlive the plug.** Take the card or the drive out, even for a moment, and the proof ends. Put the card back in and it's recognised at once, then read in full on both sides before it can say Safe again: about 92 seconds on the 86 GB test card, from a card that reads at 939 MB/s. A file on the drive that changes loses its proof too, and is read again. As long as nothing changes and nothing comes out, opening the widget doesn't read anything in full.

If a file doesn't match, the app tries once more and then says so. A file that fails never gets its real name on the drive. An ASC MHL manifest is written beside the footage, so other tools can check the copy without this app. A card that keeps its own ASC MHL history is left as it was, and stills sent to their own folder aren't in the manifest.

## What it doesn't promise

**Clips aren't played. It proves bytes.** A clip that was already broken when the camera wrote it will copy perfectly and match perfectly. For many formats the app also runs a structural check, such as whether an MP4 has an index or a RED clip has all its parts, and the verdict's sentence says which one ran. If there's no check for your format, it says "Clips were not checked or played."

**One copy is one copy.** "Safe to format" means this drive holds what the card held at that moment. It says nothing about what happens to that drive tomorrow.

**A drive's own cache can't be seen past.** The app asks the drive to finish writing and reads back from the device, not from macOS. No software can force a drive to tell the truth about its own internal cache. If a drive won't confirm a flush at all, the card goes to "Have a look", never to green.

The full list of rules is in [docs/SAFETY.md](docs/SAFETY.md).

## What not to rely on yet

This is a beta, and it hasn't seen every camera. Until told otherwise, **don't format a card on this beta's word alone without keeping another copy.** The table below shows how little evidence some formats have.

## Cameras, by evidence

Copying and proving bytes works the same for any card. What changes by camera is whether the app recognises the card, names the camera, and can check that clips are whole. This table is about those three things.

- **Real card:** the app has run on a whole card, or a whole card folder, as the camera wrote it.
- **Real files:** real clips from that camera were tested, but loose, not as a card as the camera wrote it.
- **Documents only:** built from manuals and specifications. No real file has been through it. Expect surprises.

| Maker | Camera or format | Evidence | Notes |
|---|---|---|---|
| Sony | FX2 | Real card | Mounted, copied and proved end to end |
| Sony | FX3, FX6 | Real card | Whole card folders from a drive, not mounted cards |
| Sony | ZV-E1, ZV-E10, A7S III | Real files | |
| Sony | F55 RAW on an AXS-R5 | Real files | One public clip |
| Sony | A7 IV, A7C II, A7R V, A1, A1 II, A9 III, FX30 | Documents only | Same family as the FX3. Model names unconfirmed |
| Sony | VENICE, BURANO, X-OCN | **Documents only** | No real file. The clip check stays unconfirmed |
| Canon | EOS R6, R5 Mark II | Real files | Loose clips only, no card tree |
| Canon | Cinema EOS and R5 C: CRM, XF-AVC | **Documents only** | No real card and no real file |
| Blackmagic | URSA Cine, PYXIS, Cinema Camera 6K, Pocket 6K, URSA Mini Pro | Real files | Public clips, some re-saved after shooting |
| Blackmagic | Pocket 4K CinemaDNG | Real files | Public clips |
| Blackmagic | Striped BRAW, `.braw` with `.braw2` | **Documents only** | No real pair. Always a hold until both halves are together, each proved by this app |
| RED | DSMC, 2015 firmware | Real files | One public clip |
| RED | KOMODO, KOMODO-X, V-RAPTOR | **Documents only** | No real file |
| ARRI | ALEXA 35, Mini LF, ALEXA LF, ALEXA 65 | Real files | Public samples, reels rebuilt from real file names |
| ARRI | Compact Drive through Codex | Documents only | HDE volumes never go green |
| GoPro | HERO5 to HERO8, MAX | Real files | Public clips with no chapters, so the chapter check is documents only |
| DJI | Osmo Pocket 3 | Real files | |
| Insta360 | X3 | Real files | |
| Apple | iPhone | Real files | |
| Sound Devices | MixPre-10 II | Real files | |
| Nikon | NEV, R3D NE | Documents only | Stills tested from public files |
| Panasonic | P2, GH7, EVA1 | Documents only | Stills tested from public files |
| Fujifilm | Movies | Documents only | Stills tested from public files |
| Zoom, Tascam | Recorders | Documents only | |

## Requirements

macOS 14 or later, on Apple silicon or Intel. Only macOS 27 has been tested so far: macOS 14 and 15 are untested. A working drive formatted exFAT, APFS or HFS+. FAT32 works but refuses files of 4 GB or more.

## Installing a beta

Beta builds aren't notarised yet, because the project has no Apple Developer ID. macOS will refuse the first launch, and you only have to get past that once per build.

The same steps are in `Read Me First` on the disk image, and in [BETA.md](BETA.md).

1. Open `Ingest.dmg` and drag Ingest to Applications.
2. Open Ingest from Applications. macOS says it can't be opened. Click **Done**.
3. Open **System Settings › Privacy & Security** and scroll down to **Security**.
4. Beside the message about Ingest, click **Open Anyway**, then enter your login password. The button stays there for about an hour after you tried to open the app.
5. Click **Open**.

On macOS 14 you can skip all that: Control-click the app and choose **Open**.

Ingest then shows in the menu bar. The first time it reads a card or drive, macOS asks whether it may read removable volumes. Say yes. Each new beta build asks again.

If the menu bar is full, macOS can hide the card icon. Open Ingest from Applications again and the widget appears.

**Open at login** is in Settings. It works with beta builds and doesn't need the app to be in Applications, but macOS remembers where the app was when you turned it on, so move it to Applications first. Whether it stays on across a real log out, or a new beta build, isn't tested yet. If it looks off, turn it on again.

## Network

The app makes one network call: asking GitHub for the latest release, when you click Check for Updates or if you turn on the automatic check in Settings, which is off by default. There's no tracking.

Report a Bug and Suggest a Feature put your report on the clipboard and open a blank GitHub page in your browser. Nothing you typed goes to GitHub unless you paste it there and send it. The report adds the app version, macOS version, Mac family and the camera maker if a card is in. It never adds paths, file names, client names, serials or drive names.

## What it leaves on your drive

- `.ingest/`, a hidden folder holding your folder setup, a record of what was copied, and any temporary file from a copy that was cut off, which the next job clears. The record is only a hint: it's never accepted as proof. It can only take confidence away: a drive that refused to confirm a copy stays on "Have a look". A copy cut off by a pulled cable or a crash doesn't: the next check reads it in full and carries on.
- `ascmhl/`, beside each card's footage: the checksum manifest.

Your cards are never written to.

## Building and testing

You need Swift 6.2 or later. Command Line Tools are enough, and Xcode isn't needed. There are no third-party dependencies.

```sh
swift build                       # everything
scripts/test.sh                   # the test suite, no hardware needed. Mounts small throwaway images under /tmp
scripts/build-app.sh              # universal, ad-hoc signed dist/Ingest.app
scripts/build-dmg.sh              # dist/Ingest.dmg from that app
```

Two more ways to see it work:

```sh
# The real app flow against throwaway disk images, including pulled cards and drives.
# Needs a folder holding a Sony card. Mounts images, so don't run it during other work.
SAMPLE_CARD=/path/to/card scripts/selftest.sh

# Every state of the widget as PNGs, light and dark, with staged data. Touches no volume.
swift build --product IngestApp && .build/debug/IngestApp --render /tmp/ingest-shots
```

Tests for a few public sample files skip cleanly if the files aren't there. Point `INGEST_SAMPLES` at a folder holding them, by default `/tmp/ingest-samples`.

`ingestctl` is a small command line tool over the same engine. `ingestctl match <card> <drive> --confirm` proves a card against a drive without writing to either, and exits 0 only on Safe.

```
Sources/IngestCore   the engine: listing, copying, proving, the verdict, camera formats, drive layouts
Sources/CIngest      the C layer: uncached reads and writes, XXH64
Sources/IngestApp    the menu bar app
Sources/ingestctl    the command line tool
docs/research        how the rules were arrived at, with evidence
```

Before contributing, read [CONTRIBUTING.md](CONTRIBUTING.md).

## License

All rights reserved during private beta. There's no open source licence yet.

Third-party credits are in [NOTICE](NOTICE).
