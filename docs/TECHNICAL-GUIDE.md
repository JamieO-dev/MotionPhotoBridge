# MotionPhotoBridge 2

A native Mac app that converts between **Apple Live Photos**, **Google Motion
Photos**, and **Samsung Motion Photos**. Add originals, let the app detect their
format, and choose the destination in **Convert To**.

## What is new in 2.0

- Apple Live Photo input: automatically match the image and MOV by their embedded
  pairing identifiers, including renamed pairs.
- Google and Samsung output: create one JPEG containing the motion video.
- A three-format output dropdown and a detected-format badge on every valid row.
- Mixed-format batches, missing-partner errors, and rechecking when another
  Live Photo resource is added.
- Previews for all three outputs, with Photos import offered for Apple output.
- Queue an already converted source for another format while keeping its
  previous export on disk.

| Detected input | Apple Live Photo output | Google Motion Photo output | Samsung Motion Photo output |
| --- | --- | --- | --- |
| Apple image + MOV | Yes | Yes | Yes |
| Google Motion Photo or legacy Microvideo | Yes | Yes | Yes |
| Samsung Motion Photo | Yes | Yes | Yes |

Choosing the input's own format creates a fresh export with the selected audio
and duration options. All choices remain available for mixed batches. When a
new queue contains only Apple inputs, Google is selected automatically until
you choose a destination yourself.

## Build and open on your Mac

Requirements: **macOS 13 Ventura or later** and **Swift 5.9 or later** with the
macOS SDK. Xcode 15 or later, or compatible Apple Command Line Tools, provides
the compiler. There are no third-party Swift packages.

1. Quit the previous MotionPhotoBridge app.
2. Unzip the updated source into a new folder.
3. Open **Build MotionPhotoBridge.command**. It builds for your Mac, creates
   **dist/MotionPhotoBridge.app**, and opens the new app.
4. Move the completed app to Applications if desired. Replace your previous
   installed copy after closing it.

The app uses the bundle identifier `com.motionphotobridge.app`. macOS may
ask you to grant Photos permission again after building this version.

If the developer tools are missing, run `xcode-select --install` in Terminal
and complete Apple's installer first. To run the launcher from Terminal:

```sh
bash "Build MotionPhotoBridge.command"
```

The launcher explains missing compiler/SDK requirements. It performs no
dependency downloads, uploads, or administrator commands. The app is locally
signed; public distribution with Developer ID and notarization requires your
own Apple credentials.

**Delivery status:** the earlier version was reported working by the user.
This updated download contains source and the Mac build launcher, not a
precompiled app. Version 2 has not been compiled, launched, or tested on macOS
in the Linux delivery workspace. See [Validation status](VALIDATION.md).

## Convert your photos

1. Drop original photos into the window, use **Add Photos**, or use **Add Folder**
   to include subfolders. Formats are detected before conversion.
2. Check the source badge on each row and select **Apple Live Photo**,
   **Google Motion Photo**, or **Samsung Motion Photo** under **Convert To**.
3. Choose an export folder. Keep **3 seconds** for a short clip around the key
   photo, or choose **Full clip**. Audio is kept when enabled and present.
4. For Apple output, optionally enable **Also add to Photos**.
5. Choose **Convert**. Completed rows offer a still/motion preview and
   **Show in Finder**.

One dropdown sets the destination for the current batch. To export the same
sources again in another format, change it and choose **Queue for …** on a
completed row, or **Queue Completed for …** in the queue menu. Previous files
remain in their export folders.

### Bringing in iPhone Live Photos

In Photos on your Mac, select the Live Photos and choose **File > Export >
Export Unmodified Original**. Apple exports a still image and a video as two
separate files. Keep those originals together and add both, or their folder,
to MotionPhotoBridge. See [Apple's export instructions](https://support.apple.com/en-gb/guide/photos/pht6e157c5f/12.0/mac/27).

A Live Photo normally supplies a JPEG or HEIC image plus a MOV. Selecting one
half also works when its partner can be found in the same folder. Both embedded
identifiers must match; filenames only help find candidates. Renamed files
selected together can match across folders. Missing, mismatched, or ambiguous
partners get a specific error. Adding the missing half rechecks the queue.

A standalone still, an ordinary video, or two unrelated files cannot supply
a Live Photo pair. Photos edits, Loop/Bounce effects, and separately exported
XMP sidecars are not imported; use unmodified originals.

### Exported files

Each conversion gets a new, uniquely named folder:

| Destination | Photo files | Details |
| --- | --- | --- |
| Apple Live Photo | `name.jpg` and `name.mov` | Linked image/video identifiers and a timed key-photo marker |
| Google Motion Photo | `name_MP.jpg` | JPEG with modern Camera/Container XMP and an embedded MP4 |
| Samsung Motion Photo | `name_MP.jpg` | JPEG with Samsung SEF motion data and an embedded MP4 |

Each folder also contains `conversion.json`: source and destination formats,
resource names, clip timing, audio status, capture date, and conversion notes.
An existing name ending in `MP` does not receive a second suffix.

Keep both Apple resources together. The app's **Add to Photos** action attaches
the JPEG and MOV to one creation request; importing only the JPEG loses motion.
Export alone does not require Photos access. If import fails, the completed
pair stays available and can be imported again without reconverting. A
submitted Photos transaction reports its real outcome before cancellation
finishes, avoiding an accidental duplicate.

For Google or Samsung output, transfer the complete exported JPEG to the target
device without passing it through an image editor or service that strips the
appended data. Recognition by current Google Photos and Samsung Gallery versions
still needs device verification. In particular, Samsung output implements the
established SEF JPEG layout; this is not a claim of testing every Gallery or
firmware version.

## Input and output formats

| Input layout | Implemented handling |
| --- | --- |
| Apple JPEG/HEIC image + MOV | MakerApple pairing identifier, QuickTime content identifier, timed still-image marker |
| Older Google/Pixel JPEG | Legacy `MicroVideoOffset` and presentation timestamp |
| Current Google-compatible JPEG | XMP Container Directory, video length, padding, preceding gain-map resources |
| Samsung JPEG | Indexed SEF `MotionPhoto_Data`, direct-video payloads, supported `mpv2` references |
| Samsung HEIC/HEIF | `mpvd` video boxes, supported `sefd` layouts, indexed pointers |
| HEIC/AVIF Motion Photo containers | ISO box extraction; macOS must support the image and video codecs |
| Some damaged location metadata | Conservative recovery outside the image when motion metadata or a Samsung signature provides evidence |

Google output follows the [Android Motion Photo specification](https://developer.android.com/media/platform/motion-photo-format):
a modern XMP directory, the key-photo timestamp in microseconds, and an MP4 as
the final resource. Legacy Microvideo is an input format, not a separate output
choice.

Samsung output writes a JPEG with SEF version 107, a `MotionPhoto_Data` block
containing the MP4, and a `MotionPhoto_Version` block containing `mpv3`.
The original Swift implementation was checked against the published
[MotionPhoto2 JPEG producer](https://github.com/PetrVys/MotionPhoto2/blob/main/SamsungTags.py)
and [SEF constants](https://github.com/PetrVys/MotionPhoto2/blob/main/constants.py).
Input parsing was also checked against
[ExifTool's Samsung parser](https://github.com/exiftool/exiftool/blob/master/lib/Image/ExifTool/Samsung.pm).
Neither project is bundled or required at runtime.

PNG, RAW, ordinary stills, stripped motion data, and arbitrary unlinked sidecars
are not supported. Motion cannot be reconstructed after the video is removed.

## Quality, timing, and metadata

- **Still photo:** the original full-resolution image is rendered as an 8-bit
  sRGB JPEG at 0.98 quality. Dimensions and orientation are retained. It is a
  lossy re-encode; the still is never substituted with a video frame.
- **Video:** H.264 in MOV for Apple, or in a real MP4 container for Google and
  Samsung. Up to a 3840-pixel long edge, a 2160-pixel short edge, and 60 fps.
  Higher dimensions/rates are reduced with a conversion note. Rotation and
  mirroring are retained.
- **HDR:** output is standard dynamic range. Video is converted to BT.709.
  HDR gain maps, depth maps, auxiliary images, and auxiliary video tracks are
  not retained. See Apple's [HDR conversion guidance](https://developer.apple.com/av-foundation/Incorporating-HDR-video-with-Dolby-Vision-into-your-apps.pdf).
- **Audio:** optional AAC at 48 kHz, retaining mono or stereo when source audio
  overlaps the exported interval.
- **Key-photo timing:** source XMP timing or the Apple timed marker sets the key
  moment. The three-second option centers a clip around it within the source
  bounds. An absent or out-of-range timestamp uses a noted midpoint fallback.
  Malformed/conflicting Apple timing metadata is rejected.
- **Dates and location:** supported EXIF/TIFF/IPTC and GPS fields are copied.
  Apple import explicitly supplies capture date and GPS. An EXIF date without
  a time-zone offset uses your Mac's time zone and gets a note.
- **Manufacturer metadata:** obsolete maker notes and motion offsets are removed.
  Apple output receives a new pairing identifier. Google and Samsung output
  receive their new container metadata without an Apple pairing identifier.

## Reliability and privacy

The app reads source files without modifying them. It stages each conversion
in a private hidden directory, validates the encoded resources, then publishes
a complete folder under a unique name. Ordinary failures and cancellation
remove partial exports; completed folders are kept.

For Apple output, validation checks image/video decoding, linked identifiers,
and the timed still-image marker. For Google and Samsung, it checks that the
embedded bytes exactly match the encoded MP4, the format and timestamp are
readable, the JPEG and H.264 decode, and Apple-specific metadata is absent.
Validation does not substitute for playback in the destination photo app.

If the app or Mac is forcibly terminated, an incomplete hidden
`.motionphotobridge-*` folder can remain in the output folder. It can be removed
while MotionPhotoBridge is closed.

Conversions run one at a time off the main UI thread. The app does not make
network requests or use analytics, a server, a shell, Python, FFmpeg, or ExifTool
at runtime. Existing iCloud Photos settings may sync a user-requested Apple
import independently of this app.

Resource bounds: 2,000 queue rows; 4,000 explicitly scanned image/video resources;
50,000 entries per folder scan; 1 GiB per input file; 250 megapixels and 32,768
pixels per still-image side; up to two minutes of motion video. Sibling pairing
searches one directory, up to 2,048 entries and 512 supported resources. Adding
both halves explicitly avoids relying on that search. Folder scans skip hidden
files, packages, and symbolic links.

## Developer builds and tests

```sh
# Run all Swift tests on a Mac.
xcrun swift test

# Build for this Mac and open the app.
bash scripts/build-app.sh --open

# Test, build for both Apple silicon and Intel, and create a DMG.
bash scripts/build-app.sh --test --universal --dmg
```

The script accepts `--output DIR`. Set `MOTIONPHOTOBRIDGE_SIGN_IDENTITY` for Developer
ID signing; notarization is separate. Use the bundled app for Photos permission
testing, rather than `swift run MotionPhotoBridge`.

Open `Package.swift` in Xcode to edit the source. The included GitHub Actions
workflow tests and builds on a macOS runner when used in your repository; it
has not been run for this delivery.

Tests cover binary parsing/writing and bounds, source detection and pair
matching, timing, real encoded synthetic fixtures, conversion among formats,
audio options, orientation, metadata, source preservation, and cleanup. They
never add test assets to Photos. Four synthetic originals are bundled under
`Tests/LivePhotoEngineTests/Fixtures` for tests and manual app trials. The
developer fixture scripts under `tools/` require Pillow and FFmpeg; the app
does not.

| Location | Responsibility |
| --- | --- |
| `Sources/MotionPhotoCore` | JPEG/XMP/SEF/ISO parsing and Google/Samsung container writing |
| `Sources/LivePhotoEngine` | Detection, Apple pairing, media encoding, validation, export, Photos import |
| `Sources/MotionPhotoBridgeApp` | Native window, destination picker, queue, preview, progress, cancellation |
| `Tests` | XCTest suites and generated media fixtures |
| `Resources` and `scripts` | App metadata, signing, bundling, icon generation, optional DMG |
| `docs/MAC_VERIFICATION.md` | Mac and real-device verification procedure |
| `docs/VALIDATION.md` | Checks completed here and remaining verification |

For an unsupported original, retain the phone model, camera/Gallery version,
macOS version, chosen destination/options, and full error. A representative
original is needed to add reliable support for a device-specific variant.
