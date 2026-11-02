# Sony and Canon card formats — research for the rushes-ingest app

Researched 2026-11-01. Scope: Sony and Canon bodies released or widely used 2021–2026.

A mistake here can lose a client's footage, so everything is tagged by how it was established:

- **[SAMPLE]** seen in a real file in the author's archive during this research (read-only).
- **[SOURCE]** stated by a primary or strong source; numbers in brackets point to the list at the end.
- **[UNVERIFIED]** forum-only, memory, or inferred. Do not build a safety rule on it.
- **[INFERRED]** reasoned from verified facts, not directly observed.

## 1. What matters most

1. **The Sony XML serial is a placeholder on mirrorless bodies.** `serialNo="4294967295"` (0xFFFFFFFF) on all 2,140 XAVC MP4s scanned. The real serial is in the `rtmd` track, tag `0x8114`, on most bodies. `[SAMPLE]`
2. **Camera clocks are wrong in practice.** One FX2 reads exactly 279 calendar days behind on four separate shoots, and one FX3 reads 2021-01-02. The filename date, XML, atoms and mtime all share that clock, so no card-side date can correct it. The ingest date is the only independent reference. `[SAMPLE]`
3. **`MEDIAPRO.XML` is not a completeness list.** One FX6 folder holds 129 clips against 119 index entries. "Safe to format" must come from enumerating the card itself. `[SAMPLE]`
4. **`M4ROOT` and `XDROOT` are not fixed names, and their location depends on media.** SD: `/PRIVATE/M4ROOT`. CFexpress: `/M4ROOT`. Some bodies let the user rename the root folder. `[SOURCE]`
5. **Canon has at least three unrelated layouts.** Real content also lives outside the obvious folders (`/PRIVATE/AUDIO`, `CRM/`, `XFVC/`, `CONTENTS/`). `[SOURCE]`
6. **No Canon card tree is in the archive.** The only Canon evidence is loose clips: 8 EOS R6 MP4s and 200 EOS R5 Mark II MP4s. Anything about CRM, XF-AVC, CR3 or Cinema EOS trees below is source-level at best and needs real cards before shipping.

## 2. Sample inventory

| Evidence | Count | Notes |
|---|---|---|
| `M01.XML` sidecars | 992 | 478 FX2, 338 FX3, 176 FX6V |
| XAVC MP4s (`ftyp` major `XAVC`) | 2,140 | FX2 1049, FX3 966, ZV-E1 85, ZV-E10 38, ILCE-7SM3 2 |
| Sony MXF (camera originals) | 176 | All ILME-FX6V |
| `MEDIAPRO.XML` | 17 | 13 M4ROOT (2 of them metadata-only snapshots with no clips alongside), 4 XDROOT-style |
| DCIM folders | 1 | `DCIM/100MSDCF`: 28 ARW + 28 JPG pairs, ILME-FX2 |
| Canon | 8 MP4 | `1O5A91xx.MP4`, EOS R6, flat, not a card tree. 7 have compatible brand `CAEP` and an EXIF serial. `1O5A9148.MP4` has brands `isom mp41 mp42`, model in `udta`, no serial |
| Canon | 200 MP4 | Two folders (137 and 63), EOS R5 Mark II, flat, not a card tree. See 7.3 |
| CRM, HIF, XF-AVC MXF, X-OCN, proxies (`S03`) | 0 | Nothing to test against. No public source found either: see 10 |
| Sony MXF from an AXS-R5 | 1 | Netflix Open Content `sparks/OCF/`, CC BY 4.0, PMW-F55 RAW, in a clip folder with M01 and checksum. MD5 matches the published value |
| Stills, not in the archive | 7 | raw.pixls.us, CC0: CR3 from R3, R5, R5 II, R6; ARW from A1, A7 IV, ZV-E1. All read through ImageIO, serials matching exiftool |

One `MVI_0996.mov` in the archive has no Canon metadata and is not evidence of anything.

## 3. Sony M4ROOT family (XAVC S, XAVC S-I, XAVC HS)

Bodies: FX3, FX3A, FX30, FX2, A7S III, A7 IV, A7C II, A7R V, A1, A1 II, A9 III, ZV-E1, ZV-E10. FR7 is XDROOT, see section 4.

Samples cover FX2, FX3, ZV-E1, ZV-E10 and ILCE-7SM3 only. A7 IV, A7C II, A7R V, A1, A1 II, A9 III, FX30 have Help Guide evidence but no sample, so their `modelName` strings and `rtmd` behaviour are unconfirmed.

### 3.1 Directory tree

Live-card evidence, from an ingest inventory of a mounted card (FX2, card A082) `[SAMPLE]`:

```
/AVF_INFO/AVIN0001.BNP  AVIN0001.INP  AVIN0001.INT
/M4ROOT/MEDIAPRO.XML
/M4ROOT/CLIP/<stem>.MP4  <stem>M01.XML
/M4ROOT/THMBNL/<stem>T01.JPG
/M4ROOT/GENERAL/LUT/          sometimes present; can hold a user .cube
/M4ROOT/SUB/  /M4ROOT/TAKE/   sometimes present, empty on samples
/PRIVATE/DATABASE/DATABASE.BIN
/SONY/SONYCARD.IND            0 bytes, mtime 1980-01-01, lock flag
```

By media, per the FX3 Help Guide diagram p.496 `[SOURCE 1]`:

- **SD:** `/DCIM`, `/PRIVATE/M4ROOT/CLIP`, `/PRIVATE/M4ROOT/SUB`
- **CFexpress Type A:** `/DCIM`, `/M4ROOT/CLIP`, `/M4ROOT/SUB`

Same split on FX5 and Z200/NX800 `[SOURCE 2, 3]`.

**Conflict.** The archive's notes call two root-level `/M4ROOT` cards "SD", but Sony says SD uses `/PRIVATE/M4ROOT`. Those cards were almost certainly CFexpress Type A described loosely. `[INFERRED]` Every M4ROOT card in the archive is at root; the SD form has no sample here. `mediaKind="AffordableMemoryCard"` appears regardless, so it cannot identify media type. `[SAMPLE]`

**Root rename.** FX5 can set `[XAVC S Root Folder Name]` to `[M4ROOT]` or `[Cam ID + Reel#]`, which changes the root folder and the volume label `[SOURCE 2]`. BURANO has the equivalent for XDROOT `[SOURCE 8]`. The FX3A guide does not mention it. Not found in the FX3, FX2, FX30 or A7 guides: they carry no `M4ROOT` text at all except in the diagram image, so absence there proves little. `[INFERRED]`

No AVCHD mention in any scoped Help Guide. `[SOURCE, grep of 10 guides]`

### 3.2 Detection markers

Strongest first:

1. `MEDIAPRO.XML` whose root is `<MediaProfile xmlns="http://xmlns.sony.net/pro/metadata/mediaprofile">`. Look for it at `/<X>/` and `/PRIVATE/<X>/` rather than matching the folder name, because of the rename above. `[SAMPLE]`
2. `/SONY/SONYCARD.IND` and `/PRIVATE/DATABASE/DATABASE.BIN`, present on all native trees checked. `[SAMPLE]` Sony-wide, not family-specific.
3. MP4 `ftyp` major brand `XAVC`. Compatible brands vary (`XAVC mp42 iso6`, `XAVC mp42 nras iso6`, `XAVC mp42 iso2`), so match major brand only. `[SAMPLE]`
4. `/DCIM/100MSDCF`: Sony-style stills folder, one sample only. Not sufficient alone. `[SAMPLE]`

Do not use: the volume name (`Untitled` on these cards), the bare `DCIM` folder, or a `CLIP` folder by itself.

### 3.3 Model and serial

| Value | Location | Form | Status |
|---|---|---|---|
| Model | `MEDIAPRO.XML` `<System systemKind=...>` | `ILME-FX2`. FX6 adds a suffix: `ILME-FX6V ver.6.000`. Strip after first space | `[SAMPLE]` |
| Recorder and body | `M01.XML` on an AXS-R5 | `<Device modelName="AXS-R5" serialNo="00013454">` is the recorder. `<Camera modelName="PMW-F55" serialNo="101982"/>` is the body. **Prefer `Camera`** | `[SAMPLE]` Netflix OCF |
| Model | `M01.XML` `<Device manufacturer="Sony" modelName="ILME-FX2" serialNo="4294967295"/>` at file tail | Self-closed on mirrorless; has child `<Element .../>` on FX6 | `[SAMPLE]` |
| Model + serial | Embedded copy of the same XML in the MP4 | Top-level `meta` box, handler `nrtm`, child `xml ` | `[SAMPLE]` |
| Real serial | `rtmd` timed-metadata track, local tag `0x8114`, first sample | `ILME-FX2 1234567`, NUL-padded to 63 bytes | `[SAMPLE]` `[SOURCE 4]` |
| Stable body ID | `MEDIAPRO.XML` `systemId`; also last 8 bytes of every clip UMID | 16 hex digits, `..FFFE..` in the middle | `[SAMPLE]` |

**`4294967295` must be treated as "absent".** Never display it, never key on it. All mirrorless samples have it. The likely cause is the `Write Serial Number (still image/movie)` menu item, default Off on FX3 `[SOURCE 1]`, present in the FX2, FX30, A7 IV, A7C II, A7R V, A1 II, A9 III, ZV-E1 guides too. Whether turning it On fills `serialNo` is `[UNVERIFIED]`. FX6V XML holds a real serial.

**`rtmd` results across the archive** `[SAMPLE]`: each body's serial maps to exactly one `systemId`, with no contradictions across 2,140 clips.

| Model | Bodies | Clips | Serial from `0x8114` |
|---|---:|---:|---|
| ILME-FX2 | 1 | 1049 | yes |
| ILME-FX3 | 7 | 966 | yes |
| ZV-E1 | 1 | 85 | yes |
| ZV-E10 | 1 | 38 | **no tag** |
| ILCE-7SM3 | 1 | 2 | **no tag** |

Caveats:

- Absent on these ZV-E10 and A7S III files even though ExifTool's source comment shows `"ILCE-7SM3 5072108"` for this tag `[SOURCE 4]`. So presence varies, possibly by firmware. `[INFERRED]` Needs handling as optional.
- Tag name conflict: ExifTool calls `0x8114` `SerialNumber`; telemetry-parser calls it `CameraAttributes` `[SOURCE 4, 5]`. The value decides it, not the name.
- None of these serials was checked against a body. Anyone with the body can confirm one with the `Display Serial Number` menu item.
- The tag offset within the sample varied between 278 and 289 bytes, so scan for it; do not hard-code.

**Fallback order for body identity:** XML `serialNo` if not `4294967295`, then `rtmd` `0x8114`, then `systemId`. `systemId` exists on every card with a `MEDIAPRO.XML` and in every clip UMID. It looks like an EUI-64 built from a hardware MAC (`..FFFE..` in the middle). `[INFERRED]`

### 3.4 Capture date

Primary: `<CreationDate value="2026-01-20T18:01:11+01:00"/>` in `M01.XML` or the embedded XML. It is the clip start, local wall clock with offset. `[SAMPLE]`

Other fields:

- `lastUpdate` on `NonRealTimeMeta`: clip end. `[SAMPLE]`
- Filename `yymmdd`: same clock, local. `[SAMPLE]`
- `mvhd` creation time: UTC, same instant. AVFoundation returns this as `creationDate`, without the offset. `[SAMPLE]`
- `MEDIAPRO.XML createdAt`: changes as clips are added. Card A082's value moved from `2026-01-20T18:34:15` (31 clips) to `2026-01-22T00:35:34` (44 clips). Not a card creation date. `[SAMPLE]`
- XDROOT only: `DISCMETA.XML <InitializedDate>`, the card format time. `[SAMPLE]`

**Group by the wall-clock text, not the UTC instant.** FX6 clip `B001C001_261022FV` starts `2026-10-22T01:48:15+09:00`, which is 2026-10-21 in UTC and in Europe. ffprobe and mtime both show the previous day. `[SAMPLE]`

**The clock is frequently wrong** `[SAMPLE]`:

| Body | Reads | Actual (shoot notes) | Offset |
|---|---|---|---|
| FX2, card A082 | 2026-01-20 | 2026-10-26 | 279 days |
| FX2, card A082 C032+ | 2026-01-21 | 2026-10-27 | 279 days |
| FX2, card A055 | 2025-11-30 | folder 2026-09-05 | 279 days |
| FX2, card A056 | 2025-12-12 | folder 2026-09-17 | 279 days |
| One FX3 | 2021-01-02 | 2026-10-01 | Clock reset |

The shoot notes for A082 record the mismatch independently, and its time of day is off too: 18:01 read against a morning shoot. The folder dates for A055 and A056 are the only evidence for those two cards, though the exact match makes coincidence unlikely. The app should flag a capture date far from the ingest date rather than silently filing under it.

**Filesystem mtime** `[SAMPLE]`:

- On a live card, MP4 mtime equals `lastUpdate` exactly (4 of 4 checked). So it is clip end, not start, and it comes from the camera clock.
- On archived copies, delta against `lastUpdate` is either 0 or exactly −1.0 h, consistently per card. Where the copy date is known: copies from 26–27 October (after the clock change) and one set shot abroad show 0; the 1 October copies show −1 h.
- That fits the card storing wall-clock with the reading Mac applying its current UTC offset. `[INFERRED]`

So mtime is a weak cross-check at best. Never use it as the date source.

### 3.5 Spanning and file relationships

- **`offset="0"` on all 864 parsed `Material` entries.** No spanned Material seen on any card. MEDIAPRO uses only `Material` and `RelevantInfo`. `[SAMPLE]`
- **Large files stay single.** 5.3 GB MP4, 52.9 GB MXF. `[SAMPLE]`
- **SDHC splits.** "the recorded movies will be divided into files 4 GB in size" on FX3, A7 IV, FX2, A9 III `[SOURCE 1]`. Part naming is `[UNVERIFIED]`, and no sample exists. On SDHC, `[File Name Format]` is locked to `[Standard]` `[SOURCE 1]`.
- **Relay across two slots produces separate clips**, not one spanned clip. FX6: "The new clip appears as a separate clip", and combining needs Catalyst Browse `[SOURCE 6]`.
- **Simultaneous recording.** FX6: same clip name on both media `[SOURCE 6]`. FX5: same name for `[Title]`, identical except the last two characters for `[Cam ID + Reel#]` `[SOURCE 2]`. Merging two dual-recorded cards into one folder risks overwrite.
- **Sidecar pairing is by stem.** `<stem>.MP4`, `<stem>M01.XML`, `<stem>T01.JPG`, `<stem>S03.MP4` proxy `[SOURCE 2]`, `<stem>W01` WAV on FX5 `[SOURCE 2]`. Chunked proxy: original name + chunk number + `S03` `[SOURCE 3, 6]`.
- **Do not link MXF to XML by UMID.** On FX6 clip B001C001 the MXF `file_package_umid` differs by one byte from M01 `umidRef` (`28993EB3` vs `27993EB3`). `[SAMPLE, one clip]`
- **MEDIAPRO paths are case-exact relative URIs.** `./CLIP/` on M4ROOT, `./Clip/` on XDROOT. `[SAMPLE]`

### 3.6 Tree or flat

Clips are self-contained for essence and metadata: the MP4 embeds the full XML, byte-identical to the sidecar apart from one trailing NUL byte. Also lens profile data in `idat` (`LPIF`) and, on some clips, look data (`ELUT`/`SONYBCUB`). `[SAMPLE]` Flat folders do exist in the archive.

Even so, **preserve the full tree**:

- Sony warns: "Do not edit or otherwise process movie files/folders from the connected computer" `[SOURCE 1]`.
- BURANO troubleshooting says changing folder or file names on a computer can prevent playback `[SOURCE 8]`.
- Adobe says Premiere imports spanned clips within a shot as a single clip `[SOURCE 16, search excerpt only; page returned 403]`, which depends on the camera structure being intact. `[INFERRED]`
- A preserved tree is the only form that can be restored to a card or re-verified later.

Whether Premiere and Resolve treat a flat XAVC MP4 identically to a tree was **not** tested here. `[UNVERIFIED]`

### 3.7 What each file is

| Path | Class | Basis |
|---|---|---|
| `CLIP/*.MP4` | Content | `[SAMPLE]` |
| `CLIP/*M01.XML` | Metadata, duplicated in MP4 | `[SAMPLE]` |
| `SUB/*S03.MP4`, proxies | Content; regenerable but copy anyway | `[SOURCE 1, 2]`. No sample |
| `WAV/*W01*` | **Real content** | `[SOURCE 2]` FX5 |
| `GENERAL/LUT/*.cube` | User content; one real LUT seen | `[SAMPLE]` |
| `THMBNL/*T01.JPG` | Regenerable | `[SAMPLE]` |
| `MEDIAPRO.XML`, `CUEUP.XML` | Index | `[SAMPLE]` |
| `DISCMETA.XML` | Index plus format date | `[SAMPLE]` |
| `PRIVATE/DATABASE/DATABASE.BIN`, `AVF_INFO/*` | Camera DB. Sony: the camera creates a missing DB, and `Recover Image DB` repairs it | `[SOURCE 1]` |
| `SONY/SONYCARD.IND` | Marker; 0 bytes. Its lock flag could not be preserved on the archive drive, per one ingest receipt | `[SAMPLE]` |
| `._*`, `.Spotlight-V100`, `.Trashes`, `.fseventsd`, `.TemporaryItems`, `.DS_Store` | Junk from macOS, never camera content | `[SAMPLE]` |

The `AVF_INFO` role itself is `[INFERRED]` from the database notes; no document names that folder.

### 3.8 Naming

| Mode | Example | Parse |
|---|---|---|
| Standard | `C0283.MP4` | `C` + 4 digits. Reused across cards and bodies |
| Cam ID + Reel# | `A082C001_260120DB.MP4` | Camera ID A, reel 082, position C, file 001, date, 2 random |
| Cam ID + Reel#, position L | `C001L001_261022ZT.MP4` | Camera ID **C**, reel 001, position **L**. Not "clip 1" |
| Title + Date + Number | `A20261024_0005.MP4`, `FX3B_20261020_1760.MP4` | Title is free text |
| Custom on FX6 | `FX6_1020_0001.MXF` | Free text |

All `[SAMPLE]`; rules from `[SOURCE 1, 7]`:

- Camera ID A–Z, reel 001–999, position C/L/R. At file 999 the recorded position changes though the setting does not.
- Titles allow 37 characters on FX3 including `. - _ @ ! # $ % + = ^ ~ ( ) , ; [ ]`, so a name regex can never be complete. Use `Material uri` as the name source, and treat embedded dates in names as hints.
- Reel resets when Camera ID changes.

**Collisions are real.** 40 standard names occur under more than one client folder, for example `C0042.MP4`. `[SAMPLE]`

**A reel is not a shoot.** Card A082 holds two shoots a day apart: C001–C031 and C032–C044. `mediaId` is unchanged and the index grew from 31 to 44. `[SAMPLE]` Re-inserting a card must diff against previous ingests.

**`mediaId` is a weak card identity.** FX6 values change per format and contain UMID-like time bytes. M4ROOT cards commonly start `00000000957296xx`, then the rotated `systemId`, so only about one byte varies. `[SAMPLE]`

## 4. Sony XDROOT family (XAVC-I, XAVC-L in MXF)

Bodies: FX6 sampled; FR7, Z200 documented; FX9 undocumented here; BURANO and VENICE in XAVC per section 5.

```
/XDROOT/MEDIAPRO.XML  CUEUP.XML  DISCMETA.XML
/XDROOT/Clip/<stem>.MXF  <stem>M01.XML
/XDROOT/Thmbnl/<stem>T01.JPG
/PRIVATE/DATABASE/DATABASE.BIN
/SONY/SONYCARD.IND
```

`[SAMPLE]` Note `Clip`, `Thmbnl` in mixed case versus M4ROOT's upper case.

- CFexpress Type A: `/XDROOT/...`; SDXC: `/PRIVATE/XDROOT/...`, `Sub` for proxies `[SOURCE 3, 7]`. One FX6 sample has `private/XDROOT` + `private/SONY` in lowercase; another has root `XDROOT`. Whether the lowercase came from the camera or a copy tool is `[UNVERIFIED]`.
- Proxy: `Sub/<stem>S03.mp4` `[SOURCE 7]`. Chunked: `/XDROOT/GENERAL/PXTMP` on FX6 `[SOURCE 6]`, `/PRIVATE/XDROOT/GENERAL/SONY/PXTMP` on Z200 `[SOURCE 3]`. Paths differ by model.
- FX9: no manual retrieved. XDROOT assumed by family, `[UNVERIFIED]`.

**Marker:** as section 3.2, plus `DISCMETA.XML` root `urn:schemas-professionalDisc:discMeta`, `mediaKind="ProfessionalDisc"`. `[SAMPLE]`

**Model and serial:** real on FX6V. `<Device manufacturer="Sony" modelName="ILME-FX6V" serialNo="7654321">`. Two bodies seen, each with its own serial and `systemId`. `[SAMPLE]`

**Inside the MXF** `[SAMPLE, all 176 files]`:

- The same XML is embedded in the header, start byte 20,480–24,575 in all files, in KLV with key `060e2b34025301010d01040104020200`. Sidecar and embedded XML are identical apart from a trailing line break; both CRLF.
- Per-frame metadata carries `ILME-FX6V 7654321 Version6.00` under local tag `0x8114`, with firmware.
- MXF Identification says only `Sony` / `Mem` / `2.00`. No model there.
- AVFoundation cannot open MXF (error −11828). ImageIO irrelevant. Parsing must be manual.

**Date:** same `CreationDate` rule. FX6 XML also adds `BodyUmid*` tables and `TypicalUbit`. `[SAMPLE]`

**Completeness trap** `[SAMPLE]`: one FX6 folder has 129 MXF + 129 M01 but only 119 `Material` entries and 119 thumbnails. `MEDIAPRO.XML createdAt` is 19:26:36, and clips 0120–0129 run 19:38–19:51 that evening. `CUEUP.XML` stops at 0119. Cause unknown: an interrupted index update or a merged second copy both fit. An ingest driven by MEDIAPRO would silently drop 10 real clips.

## 5. Sony cine: VENICE, VENICE 2, BURANO, FX5 (X-OCN, ProRes)

No samples. Weakest Sony area.

- **FX5 X-OCN:** `/CINEROOT/` on CFexpress A, `/PRIVATE/CINEROOT/` on SDXC, `Sub` and `Wav` subfolders; root renameable to `Cam ID + Reel#` `[SOURCE 2]`. X-OCN proxies use lowercase `.mp4` `[SOURCE 2]`.
- **BURANO:** root setting offers `XDROOT` or `Cam ID + Reel#`, sets volume label too; proxies on the Utility SD at `/PRIVATE/PXROOT/Clip` as clip name + `S03` `[SOURCE 8]`.
- **BURANO X-OCN:** "record each X-OCN file in their own folder", while XAVC is in one folder `[SOURCE 9]`. Exact path is `[UNVERIFIED]`. `CINEROOT` by analogy only.
- **X-OCN container:** OP1a MXF, one file with picture, sound, metadata `[SOURCE 10]`.
- **AXS clip folder:** real F55 RAW from an AXS-R5 sits as `A005C006_160510N2/A005C006_160510N2.mxf` with `...M01.xml` in a clip folder of its own, lower-case extensions, no XML inside the MXF. Identification says company `Sony`, product `AXS `. It ends in a RIP and a footer, header closed-complete. `[SAMPLE, one clip]` X-OCN itself remains unsampled.
- **VENICE naming:** Camera ID + Reel + Shot + date + random; `B002C004_XXXXXXXX` inheritance, new card increments reel `[SOURCE 11]`. VENICE 2 offers two formats: Camera ID `A`–`Z` + Reel + Position `C/L/R`, or Camera ID `AA`–`ZZ` + Reel + Shot `001`–`600` `[SOURCE 12]`.
- **VENICE 2 model marker:** string `MPC-3628` (8K) in MXF, used by telemetry-parser to identify it `[SOURCE 5]`. The 6K body is `MPC-3626`, also VENICE 2 (independent review, 2026-11-01). `[UNVERIFIED, no sample of either]`
- **VENICE SxS:** clips land in `XDROOT`, per AbelCine `[SOURCE 13]`.
- **AXS X-OCN tree, ProRes `.mov` tree, M01 presence on X-OCN, serial location:** `[UNVERIFIED]`. The VENICE manuals fetched do not describe them.

Default for these: keep the whole tree, treat any unknown layout as "unknown Sony", never "safe to format" on partial understanding.

## 6. Sony stills (DCIM)

`DCIM/100MSDCF/DSC02465.ARW` + `.JPG`, 28 of each, FX2. `[SAMPLE]`

- Model: ImageIO `{TIFF}.Model` = `ILME-FX2`, Make `SONY`.
- Serial: ImageIO `{Exif}.BodySerialNumber` is **nil** in both ARW and JPG. ExifTool shows an `InternalSerialNumber` with no visible relation to the body serial, and its source marks the tag as unconfirmed `(NC)`. Do not use it. Stills give no serial here; use a movie clip's `rtmd` or `systemId` from the same card. Write Serial Number presumably changes this. `[UNVERIFIED]`
- Date: `{Exif}.DateTimeOriginal` + `SubsecTimeOriginal`. `OffsetTimeOriginal` is `+01:00` in the JPG but **nil via ImageIO in the ARW**, though ExifTool reads it. `[SAMPLE]`
- These dates are 279 days off too, same clock.
- RAW + JPEG pairs share a stem, so a flat merge keyed by stem loses one.

## 7. Canon

### 7.1 Layout generations

| Generation | Bodies | Layout | Status |
|---|---|---|---|
| A | R5, R6, R3, R6 II | `DCIM/100XXXXX/`. Manuals document no other movie folder. `.MP4`, R5 also `.CRM` | Folder pages `[SOURCE 14]`. CRM path `[UNVERIFIED]` |
| B | R5 II, R1, R6 III | `DCIM/`, `XFVC/REEL_****/*.MP4`, `CRM/REEL_****/*.CRM`, 999 files per reel | `[SOURCE 15]` |
| C | C400 | `XFVC/REEL_XXXX`, `DCIM/XXX_mmdd`, `/PRIVATE/AUDIO` | `[SOURCE 17]` |
| D | C70, R5 C, C300 III, C500 II | SD MP4 in `DCIM/XXX_mmdd/`. XF-AVC and RAW tree not stated in manuals found | `[SOURCE 18, 19]` |
| Older XF | C300, C300 II, XF series | `CONTENTS/CLIPS001/<clip>/` with `.MXF .XML .CIF .CPF .THM .SIF`, `INDEX.MIF` | `[SOURCE 20, 21]` plus forums |

For C80, C700: nothing found. `[UNVERIFIED]` Treat C80 as generation C and C700 as older XF only as a guess.

Unconfirmed reports for generation D: a C70 user reports card folders `CONTENTS`, `CRM`, `DCIM`, `MISC`, and `/CRM/REEL_NNN/` for RAW. `[UNVERIFIED, forum]` R5 II also creates `MISC`. `[UNVERIFIED, third-party copy of spec sheet]`

**Search-tool warning:** one web summary attributed the `XFVC`/`CRM` page to the R5 C. Fetching it showed it was the **R5 Mark II** manual. The R5 C layout is not confirmed by it.

### 7.2 Detection markers

Canon has no single marker. `[SOURCE]` Any of:

- `XFVC/REEL_*` or `CRM/REEL_*`: generation B/C.
- `CONTENTS/CLIPS001/`, `INDEX.MIF`, `*.CIF`: Cinema EOS and older XF `[SOURCE 21]`.
- `DCIM/100EOSxx`, or `DCIM/NNN_mmdd` on Cinema EOS.
- Volume label `Canon` or `CanonXY9999` on C400 `[SOURCE 17]`. Helpful only; label is settable.
- MP4 compatible brand `CAEP` `[SAMPLE, SOURCE 4]`. Major brand is `mp42`, so check compatibles. Helpful but not guaranteed: 1 of 8 R6 clips lacks it, see 7.3.
- `ftyp` `crx ` means CR3 or CRM; `CNCV` decides: `CanonCR3_...` or `CanonCRM0001/...` `[SOURCE 4, 22]`.

`DCIM` alone is not a marker: Sony, Canon, iPhone, drones all use it. Canon photo prefixes are editable, and the default 4 characters are camera-specific, so `IMG_` cannot be required. `[SOURCE 14]`

### 7.3 Model and serial

**EOS R6 MP4, verified end to end** `[SAMPLE]`:

| Value | Location | Native route |
|---|---|---|
| Make, model | `moov/udta/manu`, `moov/udta/modl` | AVFoundation `uiso/manu`, `uiso/modl`. Value is `Data`: skip 6 bytes (4 version/flags + 2 language), then NUL-terminated string |
| Model, serial, date, firmware | `moov/uuid{85c0b687-820f-11e0-8111-f4ce462b6a48}/CNTH/CNDA` | CNDA is a JPEG. Hand it to ImageIO |
| Serial | `{Exif}.BodySerialNumber` = `123456789012` | Verified via `CGImageSource` on the extracted JPEG |
| Date | `{Exif}.DateTimeOriginal`, `OffsetTimeOriginal`, `SubsecTimeOriginal` | Verified via ImageIO |
| Internal serial | MakerNote, ExifTool `InternalSerialNumber` `KQ0000000` | Different value; not needed |

Box layout in the sample: `CNCV`, `CNDM`, `CNTH` (wrapping `CNDA`), `CNOP`. ExifTool defines `CNDA` as "the full THM image" `[SOURCE 4]`. On these R6 clips `moov` is at the front, but that is not true of Canon as a whole: every R5 II sample has it at the end.

Exception: `1O5A9148.MP4` still has `udta` model but no `CAEP` brand and no EXIF serial. It looks re-muxed, though the cause is unknown. A clip passing through a tool can lose the serial, so serial must stay optional. `[SAMPLE]`

**EOS R5 Mark II MP4, all 200 samples** `[SAMPLE]`:

- Top-level atoms are `ftyp`, `mdat`, `moov`, in that order. `moov` is at the end, so a cut clip has no index. `mdat` uses a 64-bit size.
- `ftyp` is `mp42` with compatibles `isom mp41 mp42`. No `CAEP`.
- `moov` holds `mvhd`, `trak`s and `udta` only. No Canon `uuid` box, so no `CNTH`/`CNDA`, no EXIF, no serial and no EXIF date.
- `udta/modl` is `Canon EOS R5m2`, `udta/manu` is `Canon`.
- Name: `A_0089C378H261015_190547EJ_ABCDE.MP4`, that is camera index `A_`, reel `0089`, clip `C378`, codec `H`, date `261015`, time `190547`, random `EJ`, user field `ABCDE`. This settles the separators in 7.7 for this body.
- `mvhd` reads 83 to 91 hours later than the name's date and time on all 200, too far for a time zone. Cause unknown, and it could be a copy or re-wrap step. The name is the better date source here.

These match what the R6 `1O5A9148.MP4` exception looked like, so whether a body or a tool wrote them is unsettled. Serial must stay optional.

Not tested on C400 or XF-HEVC S files. `[UNVERIFIED]` Layout may differ.

**CR3** `[SOURCE 22, 4]`: same `moov/uuid` holds `CMT1` (IFD0), `CMT2` (ExifIFD, body serial), `CMT3` (MakerNotes: `0x000c` SerialNumber, `0x0096` InternalSerialNumber), `CMT4` (GPS). ImageIO reads model, serial and date from real R3, R5, R5 II and R6 CR3, matching exiftool. `[SAMPLE]` New bodies may still lag.

**CRM** `[SOURCE 22]`: "very similar to CR3", `crx` codec. Serial location `[UNVERIFIED]`.

**XF-AVC MXF, older XF:** PRONOM says the clip `.CIF` identifies camera type, serial number and version, and is also copied in `INDEX.MIF` `[SOURCE 21]`. Format undocumented. Whether `.XML` carries it, and whether MXF does, is `[UNVERIFIED]`.

Fallback: Canon reel and camera index from the name, then CIF if parseable, then "unknown serial".

### 7.4 Capture date

- R6 MP4: `mvhd` is UTC (14:45:33), EXIF is local 15:45:33 `+01:00`. ImageIO keys above give wall clock plus offset. `[SAMPLE]`
- `mtime`: R6 samples show 3 Sept for a 1 Sept shoot, so copies do not preserve it reliably. `[SAMPLE]`
- Cinema clip names embed the date `[SOURCE 17, 18]`. Set by camera clock, same warning as Sony.
- C70/R5 C photo and MP4 folders use `mmdd`, without a year. `[SOURCE 18, 19]`

### 7.5 Spanning and relationships

Highest-risk Canon area.

- **R-series SDHC / FAT32:** a new file at 4 GB `[SOURCE 23]`. R5 II plays them consecutively; R5, R3, R6 II play them individually. CFexpress and SDXC single-file `[SOURCE 23]`.
- **Cinema MP4, C70, R5 C, C400:** "The video (stream) file in the clip will be split approximately every 4 GB", also on relay. No filesystem qualifier `[SOURCE 17, 18, 19]`. Rejoined with Canon's MP4 Join Tool.
- **C400 names carry a 3-digit stream number on SD/SDHC:** "a stream number (001 to 999) will be added", p.48 `[SOURCE 17]`. Its place in the name is only in the manual's diagram. `[UNVERIFIED]` C500 II and R5 C proxies use `_01P`-style 01–99 `[SOURCE 19, 24]`.
- **Older MXF:** XF200/XF205 split about every 2 GB; rejoined by Canon XF Utility `[SOURCE 25]`. Not confirmed on current bodies.
- **Sub recording:** primary and sub differ only in reel number `[SOURCE 19, 24]`.
- **Double slot:** identical names on both cards `[SOURCE 19, 24]`.
- **Proxy:** `_P` (C70, C500 II, R5 C) or `_Proxy` (R5 II, R6 III, C400) `[SOURCE 15, 17, 19, 24]`.
- **WAV:** slow & fast motion and second-card audio go to `/PRIVATE/AUDIO`, outside every clip folder `[SOURCE 17, 19, 24]`.
- **C70 MP4:** `MVI_nnnn.MP4` primary, `MVIS` sub, `MVIC` continuous `[SOURCE 18]`.
- **CRM relay and any CRM spanning:** `[UNVERIFIED]`.

### 7.6 Tree or flat

**Preserve the tree. Do not flatten Canon.**

- Canon's manuals point users at Canon XF Utility and Cinema RAW Development for saving and developing, not raw copying `[SOURCE 17, 19, 24]`. No manual found states a rule about keeping folders.
- Older XF: CIF is per-clip and duplicated in the card-level `INDEX.MIF`, which Canon apps need to mount a card `[SOURCE 21]`.
- Practitioner reports: missing `CLIPS001` level breaks Final Cut's XF plugin; renaming `CONTENTS` breaks XF Utility; custom names import as `CLIPS001`. `[UNVERIFIED, forums]`
- Keep clip folders whole. Do not rename folders or files.

CRM single-file import into Resolve or Premiere with no sidecar has one anecdotal report each way. `[UNVERIFIED]`

### 7.7 Naming

| Generation | Pattern | Source |
|---|---|---|
| Stills | 4 chars + 4 digits: `IMG_0001.CR3`; `1O5A9147` custom. Fourth char `_` for movies under User setting 2 | `[SOURCE 14]`, `[SAMPLE]` for `1O5A` on movies |
| R5 II, R1, R6 III, C400 | Camera index 2 chars; reel 4 digits; clip `C001`–`D999`; codec `A`/`H`/`X`; date; time; random 2; user 5 (default `CANON`); `_Proxy` | `[SOURCE 15, 17]`. Exact separators are in an image, `[UNVERIFIED]` |
| C70, R5 C, C500 II | `A001C001_yymmddXX_CANON`, `_P`, `_01P` | `[SOURCE 18, 19, 24]` |
| C70 MP4 | `MVI_nnnn.MP4` in `DCIM/XXX_mmdd/` | `[SOURCE 18]` |

- Reel advances at first record on a new card, so it is per card, with the user able to set the start `[SOURCE 17, 19]`.
- `D001` follows `C999`; parsers assuming `C` fail.
- Note `A001C001` is shared with Sony's pattern, so a name alone never identifies a brand.

### 7.8 What each file is

| Item | Class |
|---|---|
| `.CRM`, `.MP4`, `.MXF`, `.CR3`, `.WAV` | Content |
| `.CIF`, `.XML`, `.CPF`, `.SIF`, `INDEX.MIF` | Keep; needed by Canon tools `[SOURCE 21]`, forums otherwise |
| `.THM` | Probably regenerable `[UNVERIFIED]`; keep |
| `_P`, `_Proxy` clips | Keep |

## 8. Native parsing notes (no ExifTool or ffprobe)

Verified with a throwaway Swift and Python test in `/tmp`, not app code.

| Need | Route | Result |
|---|---|---|
| Sony MP4 model, date | Walk top-level boxes to `meta`; child `xml `; skip 4-byte header; XML parse | Works. Box sits after `moov`, at file end |
| Sony MP4 via AVFoundation | `availableMetadataFormats` | **Empty.** Only `.creationDate` works. `rtmd` is hidden: `tracks` lists only `vide`, `soun` |
| Sony MP4 serial | `moov/trak` whose `stsd` entry is `rtmd`; first offset from `co64` or `stco` (both occur); scan first sample of `stsz` size for `81 14`, then 2-byte length, then string | Works |
| Sony MXF | Read first 1 MiB, find `<NonRealTimeMeta` to `</NonRealTimeMeta>` | Works, all 176 camera originals within 25 KB. A re-wrapped FX6 file has it at 445 KB |
| MXF finished or cut | Header partition status byte, then the Random Index Pack at end of file and the footer partition its last entry points to | All 188 MXF in the archive are closed-complete with a valid pack. 3 have header `FooterPartition` 0, so that field can't be required |
| Sony sidecars | Foundation XML parser, default namespace | Straightforward. Namespace versions vary |
| Canon MP4 model | AVFoundation `uiso/modl` | Works, raw `Data` |
| Canon MP4 serial | Find `CNDA`, read length from preceding box, pass JPEG to `CGImageSource` | Works |
| Stills | `CGImageSource` properties | Works; see gaps in section 6 |

Sony and R5 II MP4 `moov` is at the end of the file, at offset 5.3 GB on A082C001. So a truncated recording has no `moov` and no metadata; it must still be copied and reported, never treated as empty. No naturally truncated sample exists in the archive; tests cut real files short. `[INFERRED]`

## 9. Traps

**False "safe to format":**

1. Trusting `MEDIAPRO.XML` for completeness: 10 clips missing from the index in one FX6 folder.
2. Copying only the recognised media folder: `DCIM`, `SUB`, `WAV`, `GENERAL`, `/PRIVATE/AUDIO` and `XFVC` all hold real content. Copy every non-junk file on the card.
3. Treating a renamed root as "not a camera card", or an unknown tree as "nothing to ingest".
4. Filtering Mac dotfiles too broadly. `._*` are junk, but filters should be exact-pattern.
5. A lock flag on `SONYCARD.IND` that cannot be reproduced on the destination: report as a metadata note and verify content, or the ingest either falsely fails or hides errors.
6. Treating a second visit to a card as fresh. A082 needed C001–C031 from one ingest and C032–C044 from another.
7. Assuming a root `M4ROOT` only: SD cards use `/PRIVATE/M4ROOT`, and a naive root check would skip all their video.
8. Calling a card safe on unparsed families (X-OCN, CRM, XF-AVC). Checksums do not depend on parsing, but "this is all of it" does.

**Wrong camera identification:**

9. Showing or keying on `4294967295`: every mirrorless body would look identical.
10. Parsing `systemKind` without stripping ` ver.x.xxx`.
11. Reading `C001L001` as clip 1, or `A082` as a camera. Letter is camera ID.
12. Identifying a brand from a name (`A001C001` is both) or from `DCIM`.
13. Using `InternalSerialNumber` on ARW; it has no visible relation to the body serial.
13a. Requiring `CAEP` or a serial on Canon MP4s: one R6 clip has neither.

**Broken clips or wrong dates:**

14. Flattening or merging cards: `C0042.MP4` collides across jobs, dual-slot clips share names, RAW + JPEG share stems.
15. Renaming Canon clip folders, or separating split MP4 streams.
16. Assuming 4 GB splits only happen on FAT32: Canon Cinema manuals state them without that condition.
17. Filing by filename date or mtime with a wrong camera clock, or by UTC date.
18. Assuming file case: `CLIP`/`Clip`, `PRIVATE`/`private`, `.MP4`/`.mp4`.

## 10. Open items

Needs real cards before shipping:

- Any Canon card tree: R5 or R6 CRM, R5 II `XFVC`, C70 XF-AVC and RAW, C400. No public CRM or XF-AVC was found on 2026-11-01. CineD's C500 II CRM Dropbox link is dead, and the FFmpeg tracker's C300 III attachment sits behind a bot check.
- Native SD Sony card showing `/PRIVATE/M4ROOT`.
- SDHC split Sony clip: part naming, MEDIAPRO behaviour.
- Sony proxy `S03` and any `WAV` clips.
- X-OCN and VENICE ProRes card trees.
- FX9, FX30, A7 IV, A7C II, A7R V, A1, A1 II, A9 III: real `modelName` and `0x8114` presence.
- A clip recorded with `Write Serial Number` On, to confirm `serialNo` fills.
- One body-label check of a serial read from `rtmd`.
- Flat-versus-tree import test in Premiere and Resolve.

## 11. Sources

1. Sony ILME-FX3 Help Guide: https://helpguide.sony.net/ilc/2210/v1/en/print.pdf (p.496 folder tree; File Name Format https://helpguide.sony.net/ilc/2210/v1/en/contents/TP1000884355.html). Same-text guides: FX30 `ilc/2220`, FX2 `ilc/2530`, A7S III `ilc/2010` and `2410`, A7 IV `ilc/2110`, A7R V `ilc/2230`, A7C II `ilc/2360`, A9 III `ilc/2380`, A1 `ilc/2040` and `2420`, A1 II `ilc/2440`, ZV-E1 `ilc/2310`, FX3A `ilc/2510`.
2. Sony ILME-FX5 Help Guide: https://helpguide.sony.net/ilc/2630/v1/en/contents/proxy_shooting.html and https://helpguide.sony.net/ilc/2630/v1/en/print.pdf
3. Sony PXW-Z200 / HXR-NX800 Help Guide: https://helpguide.sony.net/pro/z200nx800/v1/en/contents/proxy_shooting.html
4. ExifTool 13.55 source, local copy (`Sony.pm` line 10734 for `0x8114`; `Canon.pm` `%Canon::uuid`, `%Canon::CNTH`; `QuickTime.pm` line 233 `crx `, line 1234 UUID-Canon). Public: https://exiftool.org/TagNames/Canon.html and https://exiftool.org/TagNames/QuickTime.html
5. telemetry-parser: https://raw.githubusercontent.com/AdrianEddy/telemetry-parser/master/src/sony/rtmd_tags.rs and https://raw.githubusercontent.com/AdrianEddy/telemetry-parser/master/src/sony/mod.rs
6. Sony ILME-FX6 Operating Instructions, 5-024-458-18, third-party copy of Sony document: https://ats.emory.edu/_includes/documents/studios/manuals/Sony%20FX6%20Manual.pdf
7. Sony ILME-FR7 Help Guide: https://helpguide.sony.net/ilc/2240/v1/en/contents/TP1000673435.html and https://helpguide.sony.net/ilc/2240/v1/en/contents/TP1000673465.html
8. Sony BURANO MPC-2610 manual (Japanese): https://www.sony.jp/ls-camera/reference/pdf/MPC-2610_OM_5056098051.pdf
9. Sony Cinematography, BURANO in Premiere: https://sony-cinematography.com/articles/5-tips-to-master-the-sony-burano-in-adobe-premiere-pro/
10. Sony X-OCN white paper: https://77snszqv.media.zestyio.com/Sony_X-OCN_WhitePaper_Sep2023.pdf (search excerpt)
11. Sony VENICE user guide, copy: https://www.afcinema.com/IMG/pdf/a/8/f/user_guide_sony_venice_en_.pdf
12. Sony VENICE 2 manual, firmware 3.0, copy: https://www.lensrentals.com/product-assets/ebfd8bc2-cc7d-4a83-9854-96b736d838cd/VENICE%202%20UG.pdf
13. AbelCine X-OCN workflows: https://www.abelcine.com/articles/blog-and-knowledge/tutorials-and-guides/x-ocn-workflows-with-the-sony-venice (search excerpt)
14. Canon manuals, Folder Settings, File Numbering, File Naming: https://cam.start.canon/en/C003/manual/html/UG-07_Set-up_0040.html (R5, also `C004` R6, `C010` R3, `C012` R6 II with `UG-08`)
15. Canon R5 Mark II Folder Settings and File Naming: https://cam.start.canon/en/C017/manual/html/UG-07_Set-up_0040.html and https://cam.start.canon/en/C017/manual/html/UG-07_Set-up_0070.html; R1 `C018`; R6 III https://cam.start.canon/en/C022/manual/html/UG-08_Set-up_0060.html
16. Adobe, importing tapeless formats: https://helpx.adobe.com/premiere-pro/using/importing-assets-tapeless-formats.html (403 on fetch, excerpt only)
17. Canon EOS C400 Instruction Manual, pp.46, 48, 71, 173, 174: https://www.manualslib.com/manual/3628753/Canon-Eos-C400.html (official PDF `eosc400-im7-en.pdf`: https://asia.canon/en/support/0304987201)
18. Canon EOS C70 Instruction Manual, pp.37, 38, 134: https://www.manualslib.com/manual/2096455/Canon-Eos-C70.html
19. Canon EOS R5 C manual, pp.40, 154: https://www.manualslib.com/manual/2618513/Canon-Eos-R5c.html
20. CatDV camera formats: https://catdv-docs.services.quantum.com/technical-notes/player-technologies/Camera-formats,-containers,-and-codecs.html
21. PRONOM Canon MIF and CIF: https://pronom.nationalarchives.gov.uk/fmt/1749 and https://pronom.nationalarchives.gov.uk/fmt/1750
22. Laurent Clévy, canon_cr3: https://github.com/lclevy/canon_cr3
23. Canon Movie Recording Size: https://cam.start.canon/en/C003/manual/html/UG-03_Shooting-2_0040.html (R5), `C010` R3, https://cam.start.canon/en/C012/manual/html/UG-04_Shooting-2_0040.html (R6 II), `C017` R5 II
24. Canon EOS C500 Mark II Instruction Manual, pp.59, 152: https://www.manualslib.com/manual/1739829/Canon-Eos-C500-Mark-Ii.html
25. Canon, joining separated files, XF200/XF205: https://asia.canon/en/support/8202116800

Forum-level, for `[UNVERIFIED]` items only:

- C70 CRM path and card copying: https://community.usa.canon.com/t5/Professional-Video/EOS-C70-Locating-RAW-files-on-SD-card-and-exporting-them-to-XF/td-p/431428 (401 on fetch), https://community.usa.canon.com/t5/Professional-Video/Can-t-Access-CRM-Files-in-Premiere-Pro-PLEASE-HELP-C70/td-p/431650
- Renamed CONTENTS, `CLIPS001` naming: https://community.adobe.com/t5/premiere-pro-discussions/c70-file-names-all-named-clips001/m-p/12868008
- C300 card rebuild: https://creativecow.net/?p=1279758, https://dvinfo.net/forum/archive/index.php/t-517294.html
- Premiere and XDROOT: https://community.adobe.com/t5/premiere-pro-discussions/is-the-xdroot-folder-structure-still-necessary/td-p/9618806
