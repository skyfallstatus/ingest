# Camera card formats: Blackmagic, RED, ARRI and other common sources

Research date: 2026-11-01. Scope: cameras from the past 5 years. Purpose: rules for a native macOS rushes-ingest app that must never say "Safe to format" wrongly.

No app code here. Sony and Canon are out of scope, except where they collide with these families.

## Evidence labels

- **[SAMPLE]**: seen in a real file on this machine, read-only.
- **[SOURCE]**: stated in a manual, spec or parser source. Reference IDs are listed at the end.
- **[SOURCE-2]**: secondary source, such as a third-party parser, blog or forum, or a search summary of a page I could not read directly. Weaker than [SOURCE].
- **[UNVERIFIED]**: from memory or inference. Do not ship a rule on this without a real sample.

How sources were read: PDFs were downloaded and searched as exact text, and quoted lines come from that text. HTML pages (docs.red.com, help.codex.online, Nikon and Panasonic online manuals) went through a web-fetch summariser, so short quotes are reliable but treat wording around them with care. The raw CODEX developer guide was read directly.

## Real samples available

The author's archive holds **no .braw, .R3D, .ari, .NEV, P2, GoPro or field-recorder files**. Real data used:

| Sample | Location | Value |
|---|---|---|
| Insta360 X3 pairs, LRV, Thumb folder | The archive, folder `Camera01` | Full clip set, the closest thing to a real card |
| Insta360 X3 single-file set | The archive | Different body, different layout |
| DJI Osmo Pocket 3 `_D.MP4` (49 files) | The archive | Serial, model, date behaviour |
| Blackmagic Cam app `.mov` (4 files) | The archive | Real `com.blackmagic-design.*` keys, filename trap |
| iPhone MOV and HEVC | Several archive folders | Key layout, date disagreement |
| One real BRAW | `/Applications/Blackmagic RAW/Blackmagic RAW Speed Test.app/Contents/Resources/profile.braw` | Vendor test clip: real container, fabricated metadata values |
| BRAW API strings | `/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Frameworks/BlackmagicRawAPI.framework` | Key names only |
| Real R3D (DSMC, 2015, firmware 5.3.33) | Public ffmpeg sample `https://samples.ffmpeg.org/r3d/F099_C001_0317IH.R3D`, downloaded to `/tmp` | Header tags and footer. Older than the 5-year scope, used for structure only |
| ARRI originals, public Frame.io shares linked from `arri.com/samplefootage` (2026-11-01) | ALEXA 35 ARRIRAW, ARRICORE, ProRes, HDE; Mini LF ARRIRAW, ProRes, `.arx`; ALEXA LF `.ari`; ALEXA 65 `.mov` | Reel contents with `.ale` and `.bin`, real frame trees. Listed flat, so reel folders were rebuilt from the real names |
| Blackmagic originals, `downloads.blackmagicdesign.com` gallery zips (2026-11-01) | URSA Cine 12K LF, URSA Cine 17K 65, PYXIS 6K and 12K, Cinema Camera 6K, Pocket 6K, Pocket 4K CinemaDNG, URSA Mini Pro 12K and 4.6K G2 | Loose clips, some renamed. `mvhd` is later than `date_recorded` on all nine, so trimmed or re-saved in Blackmagic software, with camera keys intact. The `.mov` files in those zips are HEVC from Resolve, not originals |
| GoPro test clips, `github.com/gopro/gpmf-parser/samples` | HERO5 to HERO8, MAX, Fusion | Unmodified, low resolution. Loose files, no chapters |

**Biggest gap:** still no real KOMODO or V-RAPTOR file, no Nikon NEV or R3D NE, no Panasonic or Fujifilm movie, no Zoom file and no striped BRAW pair. Sections on those rest on documents. Stills from Nikon, Panasonic and Fujifilm bodies were tested from raw.pixls.us (CC0). See "Samples to collect before shipping".

---

## 1. Corrections to the working assumptions in the brief

1. **ALEXA 35, 35 Xtreme and 265 do not use `A001C001_260120_R1AB`.** They use `A_0001C001_240504_104800_a12NR.mxf` in reel folder `A_0001_12NR`. A strict old-style regex would miss these cameras. [SOURCE: ARRI-HDE, ARRI-A35]
2. **`R1AB` is not a random suffix.** It is a one-letter user prefix plus the camera serial in Base36. [SOURCE: ARRI-MLF]
3. **Mini LF ProRes is `.mxf`, not `.mov`.** "All files are written as .mxf files". QuickTime `.mov` ProRes belongs to ALEXA Mini and AMIRA era files. [SOURCE: ARRI-MLF, CODEX-DEV, ARRI-SAMPLE]
4. **"Codex Device Manager" is now "CODEX Platform"**, renamed from version 8.0.0. [SOURCE: CODEX-DM]
5. **Compact Drive is UDF, not a Codex proprietary format.** ARRI says it is readable without special software. CODEX Platform is needed for HDE. [SOURCE: ARRI-A35, CODEX-DM]
6. **`.R3D` no longer means RED.** Nikon ZR writes R3D NE as `DSC_nnnn.R3D`. [SOURCE: NIKON-ZR]
7. **`multicard_volume_count` is real, but not everywhere.** It is a big-endian u32, type 77, with value 1 on Pocket 6K firmware 7.3 and URSA Mini Pro 12K firmware 7.2.1. It is absent on URSA Cine 12K LF 9.0, URSA Cine 17K 65 9.3, PYXIS 6K 9.1, PYXIS 12K 9.8 and Cinema Camera 6K 8.3. So on current firmware a normal clip has no key, and one card cannot show a striped clip unless the key appears only then. [SAMPLE]
7a. **BRAW has a two-file format.** Striped recording produces `.BRAW` plus `.BRAW2` on different cards. [SOURCE: BM-CINE p.116, BM-UMP p.103]
8. **BRAW is not necessarily at the card root.** Blackmagic manuals say cards show "folders that contain your Blackmagic RAW files". I have no real card to settle this. Scan recursively. [SOURCE: BM-PYX p.212, BM-POCKET p.150]

---

## 2. Blackmagic Design

### Tree and names

Example from every manual: `A001_08151512_C001.braw` = camera index `A`, reel `001`, month `08`, day `15`, hour `15`, minute `12`, clip `C001`. **No year.** [SOURCE: BM-CINE p.117, BM-PYX p.89, BM-CC6K p.83, BM-MICRO p.44]

- ProRes `.mov` uses the same pattern on URSA Mini and Pocket. [SOURCE: BM-UMP p.105, BM-POCKET p.18]
- Stills end in `S001` in place of the clip number, in a `stills` folder at the media root. [SOURCE: BM-CINE p.75, BM-PYX p.45]
- URSA Cine proxies: same filename, `.mp4`, in a `Proxy` folder. [SOURCE: BM-CINE p.117]
- Pyxis and Cinema Camera 6K: same stem, `.MP4` suffix. The manuals do not state the folder. [SOURCE: BM-PYX p.89, BM-CC6K p.83]
- `Presets` and `3DLUTs` folders can exist at media root. [SOURCE: BM-PYX p.129-132, BM-CINE p.163-166]
- Filesystems: HFS+ or exFAT. [SOURCE: BM-POCKET p.11, BM-PYX p.13] Micro Studio Camera 4K G2 formats USB-C disks as HFS+. [SOURCE: BM-MICRO p.51]
- Blackmagic Media Module mount behaviour and folder layout: [UNVERIFIED], the manual says nothing useful.

Whether `.braw` files sit at the root or in folders is **unresolved**. [UNVERIFIED either way]

### Detection markers

There is **no reliable folder marker.** The camera writes no `DCIM` or equivalent. Blackmagic is identified by content, not by path:

1. File is `.braw` or `.braw2`, case-insensitive.
2. First atoms are `wide` then `mdat`, with **no `ftyp`**, and `moov` is at the end. [SAMPLE: profile.braw] An independent changelog agrees. [SOURCE-2: SWIFTMM]
3. Video `stsd` format is `brhq` in the sample. Other quality variants will have other four-character codes, so do not whitelist one. [SAMPLE]
4. `moov/meta` with `mdta` handler has `manufacturer` = `Blackmagic Design` and `camera_type`. [SAMPLE, SOURCE: TP-BMD] telemetry-parser detects on `Blackmagic Design` plus `braw_compression_ratio` or `braw_codec_bitrate`, noting not every firmware writes the second. [SOURCE: TP-BMD]

**ProRes `.mov` from Blackmagic:** on the app sample, keys are `com.blackmagic-design.camera.*` and `com.apple.proapps.*`. [SAMPLE] A Resolve render of Cinema Camera 6K footage carries `com.apple.proapps.manufacturer` = `Blackmagic Design`, `com.blackmagic-design.cameraType` and `com.blackmagic-design.cinemacamera.uuid`. [SAMPLE, passed through Resolve] Keys on a file straight from a camera are [UNVERIFIED]. Note `com.blackmagic-design.*` also appears on iPhone footage from the Blackmagic Cam app, where `com.apple.quicktime.model` is `Apple iPhone 17 Pro Max 24mm` and `com.apple.proapps.manufacturer` is `Apple Inc.` [SAMPLE] So those keys alone do not mean a Blackmagic camera.

**Telling a Blackmagic SSD from a working drive:** see section 11. Do not auto-start on markerless media.

### Model and serial

Readable **without the SDK.** BRAW is a QuickTime-style file; parse `moov/meta`, `keys`, `ilst` by walking atoms. [SAMPLE, SOURCE: TP-BMD]

Keys in the real sample: `manufacturer`, `camera_id`, `camera_type`, `firmware_version`, `braw_compression_ratio`, `braw_codec_bitrate`, `clip_number`, `reel_name`, `scene`, `angle`, `take`, `camera_number`, `camera_operator`, `lens_type`, `date_recorded`, `production_name`, `director`, and more. [SAMPLE]

- **Model:** `camera_type`, e.g. `Blackmagic URSA Mini Pro 4.6K`. [SAMPLE] telemetry-parser strips the `Blackmagic ` prefix and matches `Pocket Cinema Camera 6K Pro`, `Pocket Cinema Camera 6K G2`, `Pocket Cinema Camera 6K`, `Pocket Cinema Camera 4K`, `Micro Studio Camera 4K G2`, and has seen `URSA Cine 12K LF`. [SOURCE: TP-BMD]
- **Serial: no confirmed serial field.** `camera_id` exists, as a UUID. In `profile.braw` it is `123e4567-e89b-12d3-a456-426655440000`, the textbook example UUID, so treat that sample value as fake. Nine real bodies have real, different UUIDs. [SAMPLE] Whether `camera_id` is fixed per body or changes is still [UNVERIFIED]: no two clips from one body were compared. Do not label it "serial".
- CinemaDNG from a Pocket 4K has no TIFF Make or Model. The body is in `UniqueCameraModel`, and `CameraSerialNumber` holds a UUID. [SAMPLE]
- `encoder_device_serial` and `encoder_device_manufacturer` strings exist in BlackmagicRawAPI. [SAMPLE: strings only] Whether cameras populate them is [UNVERIFIED].
- `.mov` ProRes from a real camera: model and serial source [UNVERIFIED].

### Capture date

- `date_recorded` is `YYYY:MM:DD` on nine real bodies. [SAMPLE] It holds the text `Monday` in the vendor test clip, so keep treating it as free text. `reel_name` is a bare number, `4`, not `A004`.
- `mvhd` creation date is real in the sample (2019-06-11). Whether UTC or local is [UNVERIFIED].
- On the Blackmagic Cam app, `com.blackmagic-design.camera.dateRecorded` is `2025-11-03T15:51:50+0900` and `com.apple.quicktime.creationdate` agrees, while `mvhd` holds the UTC time `06:51:50`. [SAMPLE] This is the app, not necessarily a camera.
- Filename gives month, day, hour, minute with no year. [SOURCE]

### Spanned and striped clips (critical)

**Striped recording, URSA Cine and URSA Mini Pro 12K:** "Record RAW on 2 cards" splits one clip across two cards. [SOURCE: BM-CINE p.116, BM-UMP p.103]

- Card one holds `.BRAW`, card two holds `.BRAW2`.
- URSA Mini Pro 12K can stripe a CFast card with a **USB-C disk**, so the pair may be a card and an SSD. [SOURCE: BM-UMP p.50]
- "Copy the .BRAW and .BRAW2 files from both memory cards into the same folder on your computer and DaVinci Resolve will bring them in as a single, merged clip." [SOURCE: BM-CINE p.116]
- "If the .BRAW and .BRAW2 files are separated, the clips can play independently at half the frame rate." [SOURCE: BM-CINE p.116]
- SDK: `GetMulticardFileCount` and `IsMulticardFilePresent`. "If files are missing the movie will still play back, just at a lower framerate." [SOURCE: BM-SDK]
- **A missing half gives no error, just a clip with half the frames.**
- Strings `multicard_volume_count`, `multicard_volume_number`, `multicard_volume_` and `.multicard_timecode` exist in BlackmagicRawAPI. [SAMPLE: strings only] They are probably per-clip keys, which would let the app know a partner exists from either half. This needs a real striped clip. [UNVERIFIED]
- The option is disabled on non-12K URSA Mini cameras. [SOURCE: BM-UMP p.100] I found no striping text in the Pyxis, Cinema Camera 6K or Pocket manuals, which is not proof of absence.

**Consequence:** the common "one folder per card" destination **breaks** the merge. For a striped pair, both files must end in one folder.

**Rollover:** Cinema Camera 6K continues "on the alternate" media when the first fills up. [SOURCE: BM-CC6K p.80] Whether a take splits across media is [UNVERIFIED].

**CinemaDNG frame sequences:** I found no CinemaDNG recording in the current manuals I grepped. A real Pocket 4K clip is `A007_07271236_C038/A007_07271236_C038_000000.dng`, 1,135 frames, contiguous from 000000. [SAMPLE]

### Sidecars

- `.sidecar` is JSON written by software such as Resolve, holding non-destructive overrides. Deleting it restores original metadata. It is real grading work once it exists. Must stay beside the `.braw`. [SOURCE: BM-SDK, BM-CINE p.53] Not expected on a fresh card. [UNVERIFIED]
- Proxies are regenerable but used for Blackmagic Cloud. Copy them.
- A LUT may be embedded in the file header. [SOURCE: BM-CINE p.113]

### Keep tree?

Single-file clips survive flat copy, provided `.sidecar` stays beside the `.braw`. [SOURCE] Keep the tree anyway. Striped pairs must share one folder. URSA Cine `Proxy` matching depends on name and folder. [UNVERIFIED how Resolve matches]

---

## 3. RED

### Tree and names

```
A020_0213N4.RDM/                      (magazine, example from a forum post)
  A020_C001_0213N4.RDC/               (clip)
    A020_C001_0213N4_001.R3D
    A020_C001_0213N4_002.R3D
    .RMD  .mov  .rtn  (ASC MHL)
```

- Folder hierarchy `.RDM` > `.RDC` > `.R3D`, `.RMD`, `.mov`. [SOURCE: RED-RCX-STRUCT] `.RDM` name example is forum-level. [SOURCE-2: APPLEINSIDER]
- Clip name: camera letter, reel, `C` + 3 digits, month, day, two random characters, e.g. `A001_C001_12046M.RDC`. **No year.** [SOURCE: RED-KOMODO-NAME]
- KOMODO, KOMODO-X, V-RAPTOR: R3D + ProRes Proxy gives `.RDM` > `.RDC` > `.mov`, `.R3D`, `.rtn` (RED Thumbnail). ProRes only gives `.RDM` > `.RDC` > `.mov`. [SOURCE: RED-KX-FF, RED-VR-FF]
- "The camera creates multiple .mov files, similar to how the camera creates multiple R3D files." **So RED ProRes also spans.** Exact `.mov` part naming is [UNVERIFIED]. [SOURCE: RED-KX-FF]
- V-RAPTOR formats CFexpress as exFAT. [SOURCE: RED-VR-FS] KOMODO CFast and DSMC2 filesystems: [UNVERIFIED].
- MXF exists only on DSMC2 third-party codec recording. [SOURCE: RED-RCX-STRUCT]

### Detection markers

- `.RDM` directory at volume root containing `.RDC` directories: strong marker.
- `.R3D` magic: 4 bytes size, then `RED2` (or `RED1`) at offset 4. [SAMPLE, SOURCE: EXIF-RED]
- **`.R3D` inside `DCIM`, with a `DSC_` name, is Nikon**, see section 7.
- An `.RDC` folder copied to a working drive still looks like a RED card if you scan deep. Require it at root.

### Model and serial: readable without the SDK

Header is atom `RED2`. After the `rdi`, `rda`, `rdx` records comes a metadata block of entries: u16 size, type byte, id byte, value. High nibble of ExifTool's tag is the type. [SOURCE: EXIF-RED, TP-RED, SAMPLE]

| Tag | ExifTool name | telemetry-parser name | Real value | Use |
|---|---|---|---|---|
| 0x1006 | SerialNumber | camera_pin | `102-57C-F9A` | Stable body ID. Call it PIN |
| 0x1019 | CameraType | camera_id | `F` | **Camera letter, not a type** |
| 0x1071 | Model | camera_network_name | `DRAGON` | **Sources conflict** |
| 0x10A0 | Brain | camera_model | absent in this file | Likely true model |
| 0x10A1 | Sensor | sensor_name | absent | |
| 0x101A | ReelNumber | reel_id | `099` | |
| 0x1056 | OriginalFileName | file_name | `F099_C001_0317IH_001.R3D` | Rename detection |
| 0x1025 | FirmwareVersion | camera_firmware_version | `5.3.33` | |
| 0x1032, 0x1033 | Storage serial, model | | `61MS10MNTLDZ`, `RED 128GB Rev. T2` | Media ID |

**Conflict:** the sources disagree on model. ExifTool calls 0x1071 `Model`. telemetry-parser's RED parser calls it the user-set network name and uses 0xA0 for model. Its Nikon parser treats 0x1071 as model for R3D NE. The real 2015 file returns `DRAGON`, a sensor-like name, and has no 0x10A0. RED lists "Camera Name, Network, Model, Model ID, Serial Number" as separate metadata. [SOURCE: RED-METADATA] **Rule: prefer 0x10A0, else show 0x1071 flagged as uncertain, until tested on a real KOMODO and V-RAPTOR.**

`OriginalFileName` is a good check: the public sample was renamed without `_001`, and the header still says `_001`. [SAMPLE]

### Capture date

- 0x1023 and 0x1024 are local date and time, e.g. `20150317`, `121327`. [SAMPLE, SOURCE: TP-RED]
- 0x1030 and 0x1031: **conflict.** ExifTool says StorageFormatDate/Time; telemetry-parser says gmt_date/gmt_time. Equal to local time in the sample, so it cannot settle it. [SAMPLE]
- Filename has month and day only.

### Multi-part clips (critical)

- DSMC cameras split every clip at **4 GB**, RED ONE at 2 GB, whatever the codec. [SOURCE: RED-RCX-STRUCT]
- Names: `<clip>_<NNN>.R3D`, `A001_C001_1231XY_001...999.R3D`. [SOURCE: TP-RED quoting R3DSDK.h]

**Footer type, the key finding.** A part's last 4 KB are a footer. Type at offset 4: [SOURCE: TP-RED, established on 124 R3D files from RAVEN, DSMC2 DRAGON-X, KOMODO 6K, KOMODO-X, V-RAPTOR 8K VV, V-RAPTOR [X], V-RAPTOR XE]

| Footer | Meaning |
|---|---|
| `REOB` | Clip of one file |
| `REOF` | Another part follows |
| `REOC` | Last part of the clip |

Also at offset 0x40: file size as u64. At 0x4C: stream counts. From 0x50: stream descriptors with frame counts. [SOURCE: TP-RED] On the real sample: footer `REOB`, size field 6619136 equals the actual file size, one video stream. [SAMPLE]

**Native completeness rule:** a clip is whole only when parts are contiguous from `_001`, the highest part ends in `REOC` (or the single file in `REOB`), and each footer's size field equals its file size. A last present part with `REOF` means later parts are missing. No footer means a part cut short. Camera numbers frames from 1 through all parts, so frame numbers can cross-check. [SOURCE: TP-RED]

**What happens when `_002` is missing:** the R3D SDK walks part numbers from the file it was given, **stopping at the first gap.** [SOURCE: TP-RED, tested with R3D SDK 9.2 and REDline on clips with parts missing, added, renamed and copied] So the clip appears **shorter, with no failure** from `_001`, and parts after the gap are ignored. A Resolve forum thread reports an R3D not importing its full duration, with spanned clips the suspected cause. [SOURCE-2: RESOLVE-R3D-THREAD]

**Renaming and flattening:** the SDK derives other parts from the given file's name, with the number changed. Anything else, e.g. `<clip>_001 - Copy.R3D`, is its own clip. The sidecar is `<clip>.RMD`. All must sit in one folder. [SOURCE: TP-RED]

**Phantom Track:** on V-RAPTOR [X], "the camera records two instances of the same clip within the .RDC folder", labelled by Camera Position letter and `X`. So one `.RDC` can hold two stems; group parts by stem, not by folder. [SOURCE: RED-PHANTOM]

### Sidecars

- `.RMD`: created when a clip is changed in REDCINE-X. Real grading work. Keep. [SOURCE: RED-RCX-STRUCT]
- `.rtn`: RED thumbnail, regenerable but keep. [SOURCE: RED-KX-FF]
- `.mov` proxy or ProRes: keep.
- **ASC MHL:** when enabled, V-RAPTOR [X] writes a hash list inside each `.RDC`. Hashing runs only while not recording. Cloud Upload forces it on. The page does not name the hash algorithm or default state. [SOURCE: RED-MHL] Use as an extra check when present. Note the media may be partly hashed. [UNVERIFIED]

### Keep tree?

**Yes, keep `.RDM/.RDC`.** RED recommends importing through Premiere's Media Browser so portions load as one clip. [SOURCE-2: RED-PREMIERE, the page returned 403, read via search result] Adobe staff say the R3D filter shows spanned files as one clip. [SOURCE-2: ADOBE-R3D] Users report it failing in Premiere 2025. [SOURCE-2: ADOBE-R3D-2025]

---

## 4. ARRI

### Two naming generations

| | ALEXA 35, 35 Xtreme, 265 | ALEXA Mini LF |
|---|---|---|
| Example | `A_0001C001_240504_104800_a12NR.mxf` | `A004C010_210421_RN9O.mxf` |
| Camera index | 2 chars, A-Z + `_`, 704 options. `DW` on real files | 1 char, A-Z |
| Reel | 4 digits | 3 digits |
| Clip | `C` + 3 digits. Manual says 001-400, workflow guide says 999 clips | `C` + 3 digits, 001-999 |
| Date | YYMMDD | YYMMDD |
| Time | HHMMSS | none |
| Codec ID | `a` ARRIRAW, `p` ProRes, `h` after HDE, `c` ARRICORE [SAMPLE] | none |
| Camera ID | 4 chars Base36 | 1-char user prefix + 3 chars Base36 |
| Container | "All clips are written as MXF files" | `.mxf` |

[SOURCE: ARRI-A35 12.6, ARRI-WF, ARRI-HDE, ARRI-MLF 16.7]

- **Serial is in the filename.** Proven on four bodies against the camera's own metadata: `1I7H` = 70253 (MXF JSON), `N99` = 30141 (ALE `Camera_sn` 0030141), `1ZA` = 2566 (Codex XML `SourceSerial`), `0D0` = 468 (QuickTime key). For Mini LF and older, drop the prefix letter before decoding. [SAMPLE]
- ALEXA 35 Xtreme files say `cameraModel` = `ARRI ALEXA 35` and SUP 5.01.00, so Xtreme cannot be told from ALEXA 35 by that field. [SAMPLE]
- HDE output: `a` becomes `h`, e.g. `A_0001C001_240504_104800_h12NR.mxf`. [SOURCE: ARRI-HDE] Legacy option appends `_hde`.
- Older cameras: `A001C001_140711_R0Z3`, frames `.0027301.ari`. [SOURCE: CODEX-DEV] Frame numbers **do not start at 1** in this example.

### Trees

```
Compact Drive, ALEXA 35:     /Volumes/A_0001_12NR/A_0001_12NR/A_0001C001_240504_104800_a12NR.mxf
Compact Drive, Mini LF:      /Volumes/A001R0Z3/A001R0Z3/*.mxf  + ALE + BIN
HDE enabled, ARX workflow:   /<reel>/<clip folder>/*.arx + *.wav, plus ALE, BIN
Capture Drive, CodexFS:      /<reel>/<clip folder>/*.arx or *.ari + *.wav + Codex Shot XML
Capture Drive ProRes:        /<reel>/*.mov + ALE + BIN
```
[SOURCE: ARRI-HDE, CODEX-DEV]

- Volume name: `{CameraId}{ReelNumber}{CameraSerial}`, e.g. `A001R0Z3`. [SOURCE: CODEX-DEV]
- A drive is named `ARRI_UDF` until the first clip is recorded. [SOURCE: ARRI-A35, ARRI-MLF]
- **More than one reel on one medium:** loaded in another camera, media "keeps its name, but a new folder with the according camera ID and reel number is created in the root folder". [SOURCE: ARRI-A35, ARRI-MLF] Volume name does not describe all contents.
- ALEXA Mini CFast 2.0 is UDF. [SOURCE: CODEX-DM] AMIRA CFast filesystem: [UNVERIFIED]. `.mov` ProRes plus MXF ARRIRAW on Mini. [SOURCE: ARRI-SAMPLE]
- CompactDrive Express records ProRes only. [SOURCE: CODEX-A35]

### Formats and frame sequences

- ALEXA XT, SXT, LF and 65: ARRIRAW is a **sequence of `.ari` files**, one per frame. [SOURCE: ARRI-HDE] Real ALEXA LF clip: `B003C002_180327_R1ZA/4448x1856/B003C002_180327_R1ZA.1195823.ari`, with `xml/<clip>.xml` (root `CodexShotMetadata`: `AlexaModel`, `SourceSerial`, `AlexaReel`) and `md5.ada` in each folder. **Frames sit in a resolution folder.** All 482 frames are 12,603,304 bytes. [SAMPLE]
- `.ari` starts `ARRI` and `.arx` starts `CDXA`, each then `12 34 56 78`. The 4 KB header holds the model as plain text: `Alexa LF Plus W`, `ARRI ALEXA Mini LF`. [SAMPLE] `.arx` frames vary in size and their header records no size, so one cut frame cannot be told from a small one.
- Real `.arx` clip: `F004C028_190925_MN99/F004C028_190925_MN99.0328979.arx` with `.12.wav`, `.34.wav`, `.5.wav` beside it. [SAMPLE]
- ALEXA Mini, AMIRA, Mini LF: one MXF per take. [SOURCE: ARRI-HDE]
- ALEXA 35, Xtreme, 265: MXF per SMPTE RDD 54/55; ARRICORE per RDD 61. [SOURCE: ARRI-METADATA, RDD54, RDD61]
- `.arx`: frame-based HDE sequences for cameras up to Mini LF. MXF/HDE is now also available. [SOURCE: ARRI-HDE]
- OP1a MXF: "even incomplete files can be repaired and accessed up to the last recorded frame". [SOURCE: ARRI-A35 12.2] So an interrupted clip may be valid to copy, yet not complete.
- **How a finished ARRI MXF ends:** all 72 MXF in ARRI's public samples end in a Random Index Pack whose last entry is a footer partition. The header's own status is no guide: 43 ALEXA 35 and 10 Mini LF ProRes files say open-incomplete, and their footers are complete. [SAMPLE, read by HTTP range across every file]

For `.ari` and `.arx`, one clip's frames live across thousands of files. A single missing frame is a hole in the clip. Check contiguous numbering from min to max, not from 1.

### macOS mount (critical)

- Compact Drive: **UDF, read-only for computers.** ARRI: "accessible for operating systems without the need for special software"; CODEX: UDF, RAID-0. [SOURCE: ARRI-A35, CODEX-DM] Compact Drive readers are not on CODEX's list of readers that need the software. It does not say outright that they mount without it, and I could not test macOS 27. [UNVERIFIED on this OS]
- Compact Drives need no unmount in-camera. [SOURCE: ARRI-A35]
- CODEX Platform is a macOS-only menu bar app using **macFUSE (5.3.3+ recommended)**, System Extensions and Full Disk Access. [SOURCE: CODEX-DM]
- **VFS volumes:** Get Info format `x2xfuse`; hidden JSON `.codexvfs` at root with `volume_label`, `vfs_type`, `media_id`, `log_file`; capacity equals sum of presented files; available space zero; read-only. [SOURCE: CODEX-DEV]
- **VFS volumes build gradually.** `.codexvfs` modification time keeps changing while files are exposed. Poll at least 2 seconds apart until stable, and compare before and after indexing. **A listing taken too early is incomplete.** [SOURCE: CODEX-DEV]
- **HDE:** a second volume with `_hde` suffix appears; the original stays mounted. [SOURCE: CODEX-DEV, CODEX-DM]
- **`.arx` files report 0 bytes.** "Copy applications should read the data stream from the file until the end is reached." Finder drag gives an error or 0-byte files. `cp` works. [SOURCE: CODEX-DEV, CODEX-TROUBLE]
- xattrs `codex.decodedSize`, `codex.estimatedHDESize` help space planning. Actual size can exceed the 75% estimate. [SOURCE: CODEX-DEV]
- **CRC errors go only to a log**, `/Library/Logs/Codex/vfs/`, path in `.codexvfs`, e.g. `CRC ERROR: A001R0Z3/.../...0027301.ari`. A successful read does not prove clean data. [SOURCE: CODEX-DEV]
- If an HDE transcode fails, the original ARRIRAW is presented in the HDE volume. [SOURCE-2: CODEX-TROUBLE, read through a summary]
- macOS 14+ is required for latest Platform per the Mini LF page; the ALEXA 35 page says 13+. **Sources conflict.** Tahoe 26.1 had a Full Disk Access problem with `drserver`. [SOURCE: CODEX-MLF, CODEX-A35, CODEX-TROUBLE]

**Conflict on HDE naming:** the developer guide (copyright 2021) says the `_hde` volume holds `.arx`. Newer pages say 7.5+ presents MXF/HDE for Mini LF, and 8.0+ presents HDE `.mxf` on Capture Drives. Handle both. [SOURCE: CODEX-DEV, CODEX-MLF, CODEX-DM]

**Recommendation for v1:** copy the original volume, and refuse to treat `_hde` as a separate card. "When not using the HDE features... any copy tool application can be used." [SOURCE: CODEX-A35] Codex lists compatible tools for HDE: Hedge, ShotPut Pro, Silverstack, YoYotta. If HDE is added later, sizes cannot be pre-checked and verification must hash the stream.

Erasing: back up, erase in CODEX Platform, return to camera to format. [SOURCE: CODEX-A35] The app cannot format this media; "Safe to format" means in-camera.

### Model and serial, without proprietary SDKs

ALEXA 35, Xtreme, 265 (MXF):
- "All metadata is stored in each file header". [SOURCE: ARRI-WF]
- Static metadata is JSON with `cameraModel`, `cameraSerialNumber`, `reelName`. RDD 55 says UTF-16; **real files hold plain UTF-8**, as `"cameraModel" : "ARRI ALEXA 35"`, about 8 KB in. [SAMPLE] So the 16 MiB header need not be read for this.
- MXF Identification: company `ARRI`, product `ALEXA 35` or `ALEXA Mini LF`, version `SUP 5.01.00`. [SAMPLE]
- Device sub-descriptor: `DeviceCreatorName`, `DeviceProductName`, `DeviceInstanceIdentifier`. [SOURCE: RDD55]
- Header partition is at least 16 MiB (`HeaderByteCount` >= 2^24), so read more than the first few KB. [SOURCE: RDD55]

ALEXA Mini, Mini LF, AMIRA, older:
- QuickTime keys `com.arri.camera.CameraModel`, `CameraSerialNumber`, `ReelName`, `CameraClipName`, `CameraIndex`, `TimeZone`, `SxsSerialNumber`, `ArriUuid`. [SOURCE: ARRI-META-WP]
- MXF: static metadata as XML under key `06.0e.2b.34.01.01.01.05.03.01.02.20.01.00.00.00`. [SOURCE: ARRI-META-WP]
- `.ari`: 4 KB V3 header. Field layout is in `ArriFileV3.h` on ARRI's partner FTP, **not public**. MXF/ARRIRAW from Mini uses the same header. [SOURCE: ARRI-META-WP]
- Use filename Base36 for `.ari`, or the ALE file.
- ALE sits in the reel folder and holds all static clip metadata. Real names: `F004MN99_AVID.ale`, `F004MN99_BIN.bin`, `DW0001_1I7H_AVID.ale`, with `Camera_model`, `Camera_sn`, `Camera_id`. [SAMPLE]

ProRes `.mov` from ALEXA uses a generic QuickTime key parser: a real ALEXA 65 file gives `com.arri.camera.CameraModel` = `Alexa65  XT`, with two spaces. [SAMPLE]

### Date

ALEXA 35: filename YYMMDD + HHMMSS, from camera system time. Mini LF: date only. `com.arri.camera.TimeZone` holds UTC offset on QuickTime. [SOURCE] RDD 55 has PTP timestamps on data streams. [SOURCE: RDD55] mtime on UDF: [UNVERIFIED].

### Sidecars

`.ale`, `.bin` in the reel folder: keep. `.xml` on older ALEXA. `.wav` per clip in `.arx`/`.ari` workflows are **real audio.** `.codexvfs` is optional. [SOURCE: CODEX-DEV] Purpose of `.bin`: [UNVERIFIED].

### Keep tree?

**Yes.** ARRI: changing names "is not recommended". [SOURCE: ARRI-MLF] For `.ari`/`.arx`, clip folders are required. Reel folder and volume name carry the camera serial.

---

## 5. Panasonic

### Trees

**LUMIX, default DCF:** `DCIM/100xxxxx/`. GH7: "storage destination is within the DCIM folder". [SOURCE: PANA-GH7-FILE] Folder is number 100-999 plus 5 characters, default `_PANA`. [SOURCE: PANA-S1H, SOURCE-2: PANA-UK] Still names like `P1000001`; video names on LUMIX in DCF mode: [UNVERIFIED].

**LUMIX, CINE Style, GH7:** "storage destination is within the PRIVATE folder". Folder has number + `A` + frame-rate code + format code + `A` + setting code. File has camera index, 3-digit card number, clip `C001`-`C999`, YYMMDD, 4-character hash. Needs a card of 48 GB or more. Time-lapse stays in DCIM. [SOURCE: PANA-GH7-FILE] GH7 limits filenames to 8 characters on FAT32. [SOURCE: PANA-GH7-FS]

**EVA1:** SD with `PRIVATE`, MOV folders like `001QAQAM` (number, pixel code, frame rate, scan, fixed, recording setting), clip = CAM INDEX + REEL + `C001` + date + **hashtag "generated from the serial number"**. REEL is stored in the SD card's volume label. AVCHD `00000.MTS` with a management folder. Partial changes risk "the data may not be recognized". [SOURCE: PANA-EVA1] `PANA_GRP`: [SOURCE-2: search summary of EVA1 manual]

**P2:**
```
CONTENTS/AVCLIP AUDIO CLIP ICON PROXY VIDEO VOICE
LASTCLIP.TXT
```
"All these folders are required." [SOURCE: PANA-PX270] One clip is one video MXF plus one per audio track, joined by `CLIP/*.XML`. [SOURCE-2: AVID-P2] Rules: copy `CONTENTS` and `LASTCLIP.TXT` together, use one folder per card to avoid overwriting same-named clips, do not delete from Finder. [SOURCE: PANA-P2COPY]

**VariCam:** EVA1 uses "the same structure as the VARICAM series" for clip names. [SOURCE-2] VariCam LT media layout: [UNVERIFIED]. Codex lists VariCam Pure VRAW on Capture Drive. [SOURCE: CODEX-DEV]

### Detection

- `CONTENTS` + `LASTCLIP.TXT` at root: P2.
- `PRIVATE/PANA_GRP` at root: Panasonic. [SOURCE-2]
- `DCIM/1xx_PANA`: LUMIX, but the suffix is user-changeable. Panasonic warns only the suffix may change. [SOURCE-2: PANA-UK]
- **Filename collides with ARRI:** `A001C001_YYMMDD_XXXX`.

### Model, serial, date

- `PANA` atom in MOV: ExifTool `Panasonic::PANA`, starts with Make. [SOURCE: EXIF-QT] Full MakerNotes may include InternalSerialNumber; on video [UNVERIFIED]. No real file.
- `CLIP/*.XML` for P2: fields [UNVERIFIED].
- EVA1 hash derives from serial, not reversible as far as documented. [SOURCE: PANA-EVA1]
- Date: filename has YYMMDD in CINE Style.

### Multi-file clips

- **GH7 Segmented File Recording:** MOV or ProRes, split at 10, 5, 3 or 1 minutes "to avoid video loss", saved "as one group image". Naming not documented on that page. **One take is many files.** [SOURCE: PANA-GH7-SEG]
- Long recordings continue in new files at limits. [SOURCE-2: search summary]
- P2 spanning across cards: [UNVERIFIED]. I found no document.

### Keep tree?

Yes for `PRIVATE`, `CONTENTS` + `LASTCLIP.TXT`, AVCHD. Flat is fine only for DCF, and keep it anyway.

---

## 6. DJI

Real sample: Osmo Pocket 3.

- Name: `DJI_20261022115458_0143_D.MP4` = local date and time, sequence, `_D`. [SAMPLE]
- `ftyp isom`, `free`, `mdat`, `moov` at end. Tracks: HEVC, AAC, `djmd` ("DJI meta"), `dbgi` ("DJI dbgi"), `tmcd`, MJPEG cover. [SAMPLE]
- **Model:** `moov/udta/meta/ilst/©too` = `DJI OsmoPocket3`. [SAMPLE] Also `Xtra` atom `WM/Category` = `pb_file:dvtm_PP-101.proto;model_name:PP-101;...`. [SAMPLE]
- **Serial:** in the `djmd` track's protobuf, first sample. ExifTool field `dvtm_PP-101_1-1-5` = SerialNumber, `1-1-10` = Model. [SOURCE: EXIF-DJI, SAMPLE, a 14-character value] Parsing needs a small protobuf reader and a per-model schema name from the `Xtra` atom. Known list includes Osmo Action 4-6, Avata 2, Mavic 3, Mavic 3 Pro, Mavic 4, Air 3, Air 3s, Mini 4, Mini 5, Neo, Osmo 360, Matrice 4E. **Ronin 4D and Inspire 3 are not listed.** [SOURCE: EXIF-DJI]
- **Date trap:** `mvhd` is **UTC** (`09:54:58`), the filename is **local** (`11:54:58`, UTC+2). tmcd is `17:45:02:01`, unrelated. mtime in the sample is 20:32, over 8 hours after capture, which points to a later transfer. [SAMPLE]
- 49 Pocket 3 files in the archive show only `_D`, none with chapter parts. One file is 4.05 GiB, so no 4 GiB split there. [SAMPLE, limited]
- `.LRF`: low-resolution preview. `.SRT`: location, altitude, camera settings. Files under `DCIM/DJI_001` or `DCIM/100MEDIA`, varying by model. [SOURCE-2: DJIUTIL, MAVICPILOTS] Suffix meanings beyond `_D`, e.g. `_V`, `_S`, `_T`: [UNVERIFIED]. Do not assume `_T` etc. are duplicates.
- Same stem, different extension, e.g. `.LRF` renamed to `.MP4`, collides with the real file. [SOURCE-2]
- Ronin 4D records ProRes RAW, ProRes 422 HQ, H.264 to PROSSD, CFexpress or USB-C SSD. Its manual has no file layout. [SOURCE: DJI-R4D] Inspire 3 CinemaDNG: frame sequences likely, layout [UNVERIFIED].
- Treat `.SRT` as real: once the card is formatted, it cannot be regenerated. [UNVERIFIED that no other copy exists]

---

## 7. Nikon

- Files: `DSC_nnnn.xxx`; `_DSCnnnn.xxx` with Adobe RGB. Types NEV, R3D, MOV as RAW video, MP4 proxy. "RAW and proxy videos recorded at the same time have the same file names but different extensions." [SOURCE: NIKON-ZR]
- ZR default folder name `NC-ZR`, 5 characters, user-changeable. [SOURCE-2: NIKON-ZR-FOLDER] Z8/Z9 default folder: [UNVERIFIED]. Path `DCIM/`: DCF standard, [UNVERIFIED] for each model.
- Z9 NEV also records H.264 8-bit MP4 proxy at 1920×1080. [SOURCE: NIKON-Z9-VIDEO]
- **Z9 splitting:** on cards of 32 GB or less, a video is saved across up to 8 files of up to 4 GB each. ProRes 422 HQ stops at 4 GB instead. N-RAW and ProRes RAW cannot record to XQD of 32 GB or less. [SOURCE: NIKON-Z9-NOTES] FAT32 cannot record N-RAW. [SOURCE: NIKON-NRAW] Part naming: [UNVERIFIED].
- `.NEV` structure: `moov/udta/NCDT`, with `NCHD`, `NCTG`, `NCTH`, `NCVW`. [SOURCE: TP-NIKON, EXIF-NIKON]
- `NCTG` tags: 0x01 Make, 0x02 Model, 0x110a431 SerialNumber. [SOURCE: EXIF-NIKON] Nikon parser treats 0x1071 as model and 0x1006 as PIN for R3D NE. [SOURCE: TP-NIKON]
- **R3D NE:** telemetry-parser detects Nikon by finding `Nikon` + `NCTG`, and its RED parser needs `RED2` at offset 4. Implied: R3D NE differs from true RED structure. Needs a real file. [UNVERIFIED structure]
- **`.NEV` renamed to `.R3D`** can open in RED software, but RED states "these files technically remain N-RAW". [SOURCE: DPREVIEW-NEV] Parse the bytes, never the extension.
- Date: `NCTG` date tags. Proxy with a capture of same stem: pair it.

---

## 8. Fujifilm

- Stills conform to DCF 2.0. [SOURCE: FUJI-SPEC] File patterns `DSCF` and folder `100_FUJI`: my text search of the X-H2S manual found neither. [UNVERIFIED]
- X-H2S: ProRes must go to CFexpress. Slot options include slot 1, slot 2, both (each movie recorded twice) and HDMI only. [SOURCE: FUJI-XH2S]
- Proxy: ON (H.264), ON (ProRes Proxy), OFF. "When deleting movies from camera memory cards using a computer, be sure to delete both the originals and the proxies." [SOURCE: FUJI-XH2S] Proxy location and naming: [UNVERIFIED].
- Metadata: `FFMV`, `MVTG`, `TAGS` atoms. [SOURCE: EXIF-QT] Serial in video: [UNVERIFIED].
- GFX: not researched separately.
- A dual-slot duplicate is a valid second copy, not new footage, and could double-count. [UNVERIFIED how to detect]

---

## 9. GoPro

- **Chapters:** `GXYYZZZZ.mp4`, X = encoding type (`X` HEVC, `H` AVC), YY chapter, ZZZZ video number. Sibling `GL` prefix `.LRV`, plus `.THM`. Examples `GH011234`, `GH021234`. [SOURCE-2: GOPRO-CHAPTERED, GOPRO-BLOG] GoPro's official article is JavaScript-only, I could not read it.
- **Sorting trap:** "chapters of different videos are intertwined", so sort by video number then chapter. [SOURCE-2: GOPRO-GIST]
- Chapter size: varies by model, 4 GB in older reports. [SOURCE-2]
- Each chapter is a standalone MP4, so a missing chapter creates a silent gap. No footer gives total count. Check chapters are contiguous from `01`. The final chapter cannot be proven final from names alone. Size just below the camera's cap on the last chapter is suspicious. [UNVERIFIED]
- **Model and serial:** `MINF` (model, e.g. `HERO6 Black`), `CASN` (serial) in `moov/udta/GPMF` on HERO6, 7, 8 and MAX, matching exiftool. HERO5 and Fusion have no `MINF`. `FIRM`, `LENS`, `CAME` sit in `udta` too. [SAMPLE] `MISC/version.txt` holds serial at end of file. [SOURCE-2: HAVECAMERA] Exact format: [UNVERIFIED].
- `DCIM/100GOPRO`: [UNVERIFIED], from memory.
- `.LRV` and `.THM` are regenerable. Copy anyway.
- Keep tree: flat works if stems stay intact.

---

## 10. Insta360, iPhone, audio recorders

### Insta360

Real X3 set: [SAMPLE]

```
Camera01/
  VID_20260531_010338_00_001.insv     lens 0, Insta360 trailer
  VID_20260531_010338_10_001.insv     lens 1, NO trailer
  LRV_20260531_010338_11_001.lrv      low-res proxy, trailer
  Thumb/VID_20260531_010338_00_001.bmp
```

- **A clip is two `.insv` files.** Lose `_10_` and half the sphere is gone. Yet the `_00_` file plays alone. [SAMPLE]
- **Single-file clips exist too:** the second X3 has only `_00_` at 3840×1920, with no `_10_`. [SAMPLE] So "`_00_` without `_10_`" is not automatically an error. Decide by frame size or trailer contents, which needs more samples. [UNVERIFIED]
- Trailer ends in ASCII magic `8db42d694ccc418790edff439fe026bf`, last 32 bytes. [SAMPLE, SOURCE: EXIF-INSTA] ExifTool's `INSV_MakerNotes` record holds `SerialNumber`, `Model`, `Firmware` at field IDs 0x0a, 0x12, 0x1a. [SOURCE: EXIF-INSTA, SAMPLE: `Insta360 X3`, a 14-character serial]
- Serial only in `_00_` and `.lrv`, never `_10_`. [SAMPLE]
- **Date:** filename is camera local. `mvhd` disagrees: 10 seconds off in one set, 1 hour 10 seconds off in another. `_00_` and `_10_` differ by 1 second. [SAMPLE] Use the filename, and do not pair files by `mvhd`.
- Pair key: timestamp + counter, ignoring the lens digit.
- `DCIM/Camera01` is the likely card path. Only `Camera01` confirmed. [SAMPLE for `Camera01`, UNVERIFIED for `DCIM`]
- Keep tree: Insta360 Studio's pairing needs both in one folder. [UNVERIFIED]

### iPhone over SSD

- iPhone 15 Pro, 16 Pro, 17 Pro can record ProRes to USB-C storage. ProRes RAW through Final Cut Camera on 17 Pro. Drive format exFAT or APFS. [SOURCE-2: search summaries of APPLE-PRORES and APPLE-FCC]
- **On-drive folder layout: not found.** [UNVERIFIED] An iPhone itself does not mount as a volume. [UNVERIFIED for this app; ImageCaptureCore would be a different path.]
- Metadata: `moov/meta` keys `com.apple.quicktime.make`, `.model`, `.software`, `.creationdate` (ISO 8601 with offset), `.camera.lens_model`. [SAMPLE]
- **No serial** in the keys seen. [SAMPLE]
- **Date trap:** an iPhone 15 Pro Max ProRes MOV has `creationdate` 2025-08-29 12:08:34+02:00 but `mvhd` 2025-09-02 11:12:33. [SAMPLE] Trust `creationdate`.
- Blackmagic Cam app files: `A001_1103351<U+202F>PM_C001.mov`. The name contains a **narrow no-break space** before `PM`, bytes `e2 80 af`. An ASCII-typed path fails with "file not found". [SAMPLE] Timestamp is `MMDD` + `HMM` + AM/PM, unlike camera pattern `MMDDHHMM`.

### Audio recorders

**Zoom F6:** [SOURCE: ZOOM-F6 p.43-44]
- Poly: `Scene001_001.WAV`, or date-based `190101_001.WAV`, in the root or a scene folder.
- Mono/stereo: one folder per take, `Scene001_003.TAKE/` holding `_Tr1.WAV`…`_Tr4.WAV`, `_Tr5_6.WAV`, `_TL_R.WAV`.
- MP3 sidecars possible.
- Above **2 GB**, "a new take will be created automatically and recording will continue without interruption". One performance can be several takes with no gap.
- `FALSE TAKE` folder: failed takes. **Keep; a false take is often a real take.**

**Sound Devices 8-Series, 888:** [SOURCE: SD-888]
- BWF auto-splits at 4 GB with suffix A, B, C. RF64 does not split, and some NLEs cannot read it.
- Arming or disarming channels mid-take also splits, with the same suffix.
- Poly suffix `ISO`, `LR`, `B1B2`.
- `FALSETAKES` folder at root of each drive.
- Record folders on all of SSD, SD1, SD2, so the same take may exist on three media. Treat as duplicates, not new content.
- CSV sound report in the record folder.

**MixPre:** [SOURCE: SD-MIXPRE]
- Media: the guide says "All media will be formatted as exFAT", while its spec tables say FAT32 for 32 GB or less and exFAT above. **The guide conflicts with itself.** Accept both. 4 GB BWF split, seamless in post.
- Projects as folders. `TRASH` folder keeps trashed projects until formatted. CSV sound report in the project.

**Tascam:** no primary source obtained. [UNVERIFIED] Treat as generic BWF.

**Metadata:**
- `bext` and `iXML` RIFF chunks are easy to parse natively. [SOURCE: EXIF-RIFF]
- `bext.Originator` values in the archive: `Adobe Premiere Pro 2026.0 (Macin`, `Pro Tools`. [SAMPLE] **Originator or a `bext` chunk alone does not prove a recorder.** The archive has no real recorder file.
- Recorder model and serial fields: [UNVERIFIED].
- `bext` date/time and TimeReference are the expected capture sources. [UNVERIFIED on real files]

**Poly vs split:** mono/stereo keeps a take in many files; losing one loses a channel. Treat all `Scene_Take_*` files as one take.

---

## 11. Detection rules across families

**Markers must be at the volume root.** The archive holds `M4ROOT`, `PRIVATE`, `DCIM`, `XDROOT` deep inside client folders, e.g. `<client>/.../CARD A055/PRIVATE`. It also holds lowercase `private`. [SAMPLE] Compare case-insensitively.

**Filename patterns cannot identify a camera alone.** These collide: [SOURCE, SAMPLE]

| Pattern | Could be |
|---|---|
| `A001C001_YYMMDD_XXXX` | ARRI Mini/LF, Panasonic CINE Style, EVA1 |
| `A053C192_251120SO.MP4` | Canon, seen in the archive |
| `A001_08151512_C001` | Blackmagic |
| `DW0001C001_251020_111956_c1I7H.mxf` | ALEXA 35 Xtreme, real: two-letter index, `c` for ARRICORE |
| `A001_1103351 PM_C001` | Blackmagic Cam app on an iPhone |
| `A001_C001_0101XY` | RED |
| `.R3D` | RED, Nikon ZR, or renamed NEV |
| `.mov` | Everything |

**Markerless media (BRAW or ProRes on an SSD, audio cards, iPhone SSD).** Treat as a suggestion, and ask the user. Suggested signals, none proven on real cards: [UNVERIFIED]

- Files parse as camera originals by content, not name.
- Single reel prefix and contiguous clip numbers.
- Absence of `.prproj`, `.drp`, `.aep`, nested client folders.
- Reasonable file count; the archive drive has about 147,000.
- Volume label of a camera style.

**Junk vs real:**

| Class | Items |
|---|---|
| macOS junk | `._*`, `.Spotlight-V100`, `.Trashes`, `.fseventsd`, `.TemporaryItems`, `.DS_Store`. All seen in the archive [SAMPLE] |
| Real, keep | `FALSE TAKE`, `FALSETAKES`, `TRASH`, `.SRT`, `.wav` beside `.ari`, `.sidecar`, `.RMD`, `.ale`, `.mhl` |
| Regenerable, copy anyway | `.LRF`, `.LRV`, `.THM`, `.rtn`, proxies, `Thumb/*.bmp`, P2 `ICON`, `PROXY` |

Default: copy everything except the macOS row.

**mtime:** cannot be trusted as capture date. DJI sample: mtime is over 8 hours after capture, from a later transfer. [SAMPLE] FAT/exFAT time zones can shift it. [UNVERIFIED] Preference order is in the summary table; mtime is last resort.

**Native parsing, by need:** a single QuickTime atom walker covers BRAW, MOV, MP4, INSV, LRV, NEV. Add: R3D 4 KB atoms and tag walker; MXF KLV for header; RIFF chunks; small protobuf reader for DJI; fixed trailer reader for Insta360; Base36 for ARRI.

---

## 12. Summary table

| Family | Date preference | Keep tree | Completeness rule |
|---|---|---|---|
| Blackmagic | `date_recorded` if real, `mvhd`, filename | Yes; striped pair in one folder | `.braw` and `.braw2` both present |
| RED | 0x1023/0x1024 | Yes, required | Footer chain to `REOC` or `REOB` |
| ARRI | Filename, then metadata | Yes | `.ari`/`.arx` contiguous, `.codexvfs` stable, no CRC in log |
| Panasonic | Filename in CINE Style, metadata | Yes, required | `LASTCLIP.TXT`, XML to MXF links |
| DJI | Filename local, `mvhd` UTC | Preferred | Unknown beyond stems |
| Nikon | `NCTG` dates | Preferred | Proxy pair |
| GoPro | GPMF, `mvhd` | Preferred | Chapters contiguous |
| Insta360 | Filename | Yes | `_00_` + `_10_` where a pair is expected |
| iPhone | `creationdate` | Preferred | None |
| Audio | `bext` | Yes, `.TAKE` folders | Split suffix or next take |

---

## 13. Samples to collect before shipping

1. Real KOMODO and V-RAPTOR clip with a multi-part take, full `.RDM` tree. RED's sample pages show a login element and a terms box. Nikon's page gates ZR, KOMODO-X and V-RAPTOR [X] samples behind a form.
2. BRAW card as written by a camera, for root vs folder. Two clips from one body, to see if `camera_id` is stable.
3. A striped `.braw`/`.braw2` pair, to see whether `multicard_volume_count` appears on firmware 9. None of Blackmagic's 164 public zips holds a `.braw2`.
4. Compact Drive mounted on this Mac, with and without CODEX Platform, for `statfs` type name and mount events. Check whether the FUSE mount raises normal volume notifications.
6. Nikon NEV and R3D NE, for structure. P2 card. GH7 segmented recording. GoPro chaptered recording. Real Zoom, Sound Devices and Tascam cards.

### Where samples can and can't be had (checked 2026-11-01)

Public, no sign-in: ARRI's Frame.io shares from `arri.com/samplefootage`; Blackmagic gallery pages at `blackmagicdesign.com/products/<camera>/gallery`, which link `downloads.blackmagicdesign.com`; Netflix Open Content `sparks/OCF/`; `gopro/gpmf-parser` samples; raw.pixls.us stills.

Gated, not used:

| Source | Offers | What a person must do |
|---|---|---|
| RED `reddigitalcinema.com/download/sample-r3d-file-*` | KOMODO, KOMODO-X, V-RAPTOR R3D | Log in and tick the terms box |
| Nikon `nikonusa.com/content/Zcinema-raw-file-downloads` | ZR R3D NE, KOMODO-X, V-RAPTOR [X] zips | Fill in the form at `nikon.tfaforms.net/771` |
| Sony `pro.sony` X-OCN download form | VENICE 2 X-OCN and ProRes | Register, then receive a link |
| Sony BURANO test files | X-OCN LT, about 50 GB | Register by email |
| Visual Park `visualpark-shop.com` | FX5 X-OCN, 13 GB | Create a free account |
| ARRI `ftp2.arri.de` | ALEXA SXT and XT, other ALEXA material | Log in with the shared password ARRI publishes |
| FFmpeg tracker #9556 | Real C300 III MXF | Pass a proof-of-work browser check |

Dead: RawFilm's `objects-us-east-1.dream.io` R3D links fail TLS on every client tried. CineD's C500 II CRM Dropbox link returns an error page. RED's support article sits behind Cloudflare, and CVP's page was down.

---

## References

### Blackmagic
- BM-CINE: https://documents.blackmagicdesign.com/UserManuals/BlackmagicURSACineManual.pdf (September 2026)
- BM-UMP: https://documents.blackmagicdesign.com/UserManuals/BlackmagicURSAMiniManual.pdf
- BM-PYX: https://documents.blackmagicdesign.com/UserManuals/BlackmagicPYXISManual.pdf
- BM-CC6K: https://documents.blackmagicdesign.com/UserManuals/BlackmagicCinemaCameraManual.pdf
- BM-POCKET: https://documents.blackmagicdesign.com/UserManuals/BlackmagicPocketCinemaCameraManual.pdf
- BM-MICRO: https://documents.blackmagicdesign.com/UserManuals/BlackmagicMicroStudioCamera4KG2Manual.pdf
- BM-SDK: https://documents.blackmagicdesign.com/DeveloperManuals/BlackmagicRAW-SDK.pdf (September 2026)
- TP-BMD: https://github.com/AdrianEddy/telemetry-parser/blob/master/src/blackmagic/mod.rs
- BM-FORUM-META: https://forum.blackmagicdesign.com/viewtopic.php?f=2&t=107838 and https://github.com/c0deous/python-metabraw
- SWIFTMM: https://github.com/aagedal/SwiftMediaMetadata/releases/tag/1.5.0

### RED
- RED-RCX-STRUCT: https://docs.red.com/955-0004_v50/REDCINE-XProOperationGuide/Content/4_LoadOrganize/R3D_Structure.htm
- RED-RCX-MULTI: https://docs.red.com/955-0004_v42/REV-A/HTML/955-0004_V42%20Rev-A%20%20%20RED%20PS,%20REDCINE-X%20PRO%20Operation%20Guide/Content/8_Troubleshoot/MultipleR3D.htm
- RED-KOMODO-NAME: https://docs.red.com/955-0190_v1.3/955-0190_v1.3_REV-1.1_1_RED_PS_KOMODO_Operation_Guide/Content/5_How_To/Media/ClipName.htm
- RED-KX-FF: https://docs.red.com/955-0219/955-0219_V1.0%20Rev-A%20RED%20PS,%20KOMODO-X%20Operation%20Guide/Content/4_Menus/02_ProjSet/FileFormat.htm
- RED-VR-FF: https://docs.red.com/955-0199/955-0199_V1.2_Rev_A_RED_PS_V-RAPTOR_Operation_Guide/Content/4_Menus/b_ProjSet/FileFormat.htm
- RED-VR-FS: https://docs.red.com/955-0199/955-0199_V1.2_Rev_A_RED_PS_V-RAPTOR_Operation_Guide/Content/5_How_To/Media/File_System.htm
- RED-MHL: https://docs.red.com/955-0225/955-0225_V2.0+Rev-A+RED+PS,+V-RAPTOR+[X]+8K+VV+Operation+Guide/Content/4_Menus/e_Media/ASC_MHL.htm
- RED-PHANTOM: https://docs.red.com/955-0225/955-0225_V1.7+Rev-A+RED+PS,+V-RAPTOR+%5BX%5D+8K+VV+Operation+Guide+HTML/Content/4_Menus/b_ProjSet/Recording_Mode.htm
- RED-METADATA: https://docs.red.com/955-0225/955-0225_V2.0+Rev-A+RED+PS,+V-RAPTOR+%5BX%5D+8K+VV+Operation+Guide/Content/5_How_To/Media/ClipMetadata.htm
- RED-PREMIERE: https://support.red.com/hc/en-us/articles/360059576833-Recommended-R3D-Workflow-for-Adobe-Premiere-Pro
- TP-RED: https://github.com/AdrianEddy/telemetry-parser/blob/master/src/red/mod.rs
- EXIF-RED: ExifTool 13.55 `Image/ExifTool/Red.pm`, https://exiftool.org/TagNames/Red.html
- APPLEINSIDER: https://forums.appleinsider.com/discussion/107129
- ADOBE-R3D: https://community.adobe.com/t5/premiere-pro-discussions/importing-red-footage-into-premiere-pro-cc-multiple-files-appear-but-which-one-do-i-use/m-p/11482748
- ADOBE-R3D-2025: https://community.adobe.com/t5/premiere-pro-discussions/red-spanned-clips-not-automatically-combining-in-media-browser/td-p/15188055
- RESOLVE-R3D-THREAD: https://forum.blackmagicdesign.com/viewtopic.php?p=734983

### ARRI and CODEX
- ARRI-A35: https://www.arri.com/resource/blob/282238/84d1df5e5269a799515446d37d10876a/user-manual-alexa-35-sup-1-0-data.pdf (SUP 1.0/1.1, sections 12.2, 12.6)
- ARRI-MLF: https://www.arrirental.com/resource/blob/239012/b6bb13229cb64206391f85fb088e0ff8/user-manual-sup-7-0-data.pdf (section 16.7)
- ARRI-WF: https://www.arri.com/resource/blob/277396/5a14858a5279638c1e0756d67e94a7d7/2022-05-alexa-35-workflow-post-guide-launch-data.pdf
- ARRI-HDE: https://www.arri.com/resource/blob/401788/bf76cfa57682372ff82336ce13088d40/arriraw-hde-transcoder-quick-guide-1-6-4-data.pdf
- ARRI-META-WP: https://www.arri.com/resource/blob/31912/e30dd1a324dbecbced88fa146d3f88a9/2022-08-arri-metadata-white-paper-en-data.pdf
- ARRI-METADATA: https://www.arri.com/en/learn-help/learn-help-camera-system/pre-postproduction/metadata
- ARRI-FAQ: https://www.arri.com/en/learn-help/learn-help-camera-system/pre-postproduction/file-formats-data-handling/arriraw-faq
- ARRI-SAMPLE: https://www.arri.com/resource/blob/31926/74ff21f71c10d8e4e39314893eea7f42/2025-03-arri-sample-footage-technical-information-data.pdf
- RDD54: https://pub.smpte.org/latest/rdd54/rdd54-2022.pdf
- RDD55: https://pub.smpte.org/latest/rdd55/rdd55-2022.pdf
- RDD61: https://pub.smpte.org/pub/rdd61/rdd61-2025.pdf
- CODEX-DEV: https://help.codex.online/content/developer-guides
- CODEX-DM: https://help.codex.online/content/device-manager
- CODEX-TROUBLE: https://help.codex.online/content/troubleshooting
- CODEX-A35: https://help.codex.online/content/Workflows/ALEXA_35_Workflow
- CODEX-MLF: https://help.codex.online/content/Workflows/ALEXA_Mini_LF_Workflow

### Panasonic
- PANA-GH7-FILE: https://eww.pavc.panasonic.co.jp/dscoi/DC-GH7/html/DC-GH7_DVQP3109_eng/0129.html
- PANA-GH7-FS: https://eww.pavc.panasonic.co.jp/dscoi/DC-GH7/html/DC-GH7_DVQP3109_eng/0075.html
- PANA-GH7-SEG: https://eww.pavc.panasonic.co.jp/dscoi/DC-GH7/html/DC-GH7_DVQP3109_eng/0102.html
- PANA-EVA1: https://pro-av.panasonic.net/manual/html/AU-EVA1P_PJ_EN_ED_AN_PX(DVQP1561VA)_E/chapter03_06_07.htm
- PANA-PX270: https://eu.connect.panasonic.com/sites/default/files/media//2024-04/AJ-PX270%20Operating%20Manual_8.pdf
- PANA-P2COPY: https://eww.pass.panasonic.co.jp/pro-av/support/content/faq/guidance/handlingp2.pdf
- PANA-S1H: https://www.manualslib.com/manual/1995519/Panasonic-Lumix-S1h.html?page=66
- PANA-UK: https://www.panasonic.com/uk/consumer/cameras-camcorders/lumix-expert-advice-learn/lumix-expert-advice/creating-custom-folders-and-file-names.html
- AVID-P2: https://resources.avid.com/SupportFiles/attach/73513_P2_User_Manual_6761.pdf

### Nikon
- NIKON-ZR: https://onlinemanual.nikonimglib.com/zr/en/09-03-03.html
- NIKON-ZR-FOLDER: https://onlinemanual.nikonimglib.com/zr/en/09-03-02.html
- NIKON-Z9-VIDEO: https://onlinemanual.nikonimglib.com/z9/en/06_video_recording_01.html
- NIKON-Z9-NOTES: https://onlinemanual.nikonimglib.com/z9/en/06_video_recording_04.html
- NIKON-NRAW: https://download.nikonimglib.com/archive5/5eguQ00nQ3UB05evbcQ56aZjlO90/Z9_TG_NRAW_(En)02.pdf
- TP-NIKON: https://github.com/AdrianEddy/telemetry-parser/blob/master/src/nikon/mod.rs
- EXIF-NIKON: ExifTool 13.55 `Image/ExifTool/Nikon.pm`, https://exiftool.org/TagNames/Nikon.html
- DPREVIEW-NEV: https://www.dpreview.com/news/1333334312/red-gives-clue-to-red-code-n-raw-puzzle/

### Others
- FUJI-XH2S: https://fujifilm-dsc.com/en/manual/x-h2s/x-h2s_manual_en_s_f.pdf
- FUJI-SPEC: https://fujifilm-x.com/global/products/cameras/x-h2s/specifications/
- EXIF-QT: ExifTool 13.55 `Image/ExifTool/QuickTime.pm`, https://exiftool.org/TagNames/QuickTime.html
- EXIF-DJI: ExifTool 13.55 `Image/ExifTool/DJI.pm`, https://exiftool.org/TagNames/DJI.html
- EXIF-GOPRO: ExifTool 13.55 `Image/ExifTool/GoPro.pm`, https://exiftool.org/TagNames/GoPro.html
- EXIF-INSTA: ExifTool 13.55 `Image/ExifTool/QuickTimeStream.pl`
- EXIF-RIFF: ExifTool 13.55 `Image/ExifTool/RIFF.pm`
- DJI-R4D: https://www.adorama.com/col/productManuals/DJIRONIN48K.pdf
- DJIUTIL: https://pypi.org/project/djiutil
- MAVICPILOTS: https://mavicpilots.com/threads/lrf-and-srt-files.118171/post-1333525
- GOPRO-CHAPTERED: https://docs.rs/crate/gopro-chaptered-video-assembler/latest/source/src/gopro.rs
- GOPRO-GIST: https://gist.github.com/danielm/6c012e3b9a74636b4a2be0a56b19cf57
- GOPRO-BLOG: https://blogs.callutheran.edu/jpdillon/?p=181
- HAVECAMERA: https://havecamerawilltravel.com/action/gopro-serial-number/
- APPLE-PRORES: https://support.apple.com/109041
- APPLE-FCC: https://support.apple.com/guide/final-cut-camera/dev6b8c9521d/ios
- ZOOM-F6: https://zoomcorp.com/media/documents/E_F6.pdf
- SD-888: https://cdn.sounddevices.com/wp-content/uploads/2022/04/888-User-Guide_041122.pdf
- SD-MIXPRE: https://cdn.sounddevices.com/wp-content/uploads/2022/01/MixPre-I-User-Guide_01.04.22.pdf
