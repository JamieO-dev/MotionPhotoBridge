# MotionPhotoBridge 2 validation status

Prepared 11 November 2026 for version 2.0.1.

The user reported that the previous version worked on their Mac. This update
adds automatic Apple pair detection, Google/Samsung writers, and a destination
dropdown. It has been prepared in a Linux workspace without Swift, Apple's
SDKs, or a macOS runtime.

## Completed checks

| Check | Result |
| --- | --- |
| Launcher and build-script shell syntax | Passed `bash -n` |
| Build help and non-Mac platform guard | Help is correct; the build exits with a Mac requirement before creating a bundle |
| Info.plist and Photos entitlement | Parsed successfully; version 2.0.1/build 3 and movie document types confirmed |
| macOS CI workflow | YAML parsed successfully; workflow has not run |
| Fixture-generation and verification scripts | Python syntax parsed successfully |
| Four bundled still images | Independently decoded at 320 × 240; EXIF date, time-zone offset, and orientation checked |
| Four bundled videos | Independently extracted from manifest bounds and fully decoded with FFmpeg |
| Fixture media details | H.264 + AAC, four seconds; portrait example has −90° display rotation |
| Fixture binary layout | XMP directory/legacy offsets and Samsung SEF boundaries independently inspected |
| New code review | Writer bounds/layout, Apple identifiers and timing, output branches, cleanup, queue state, preview lifetimes, and Photos import guards reviewed |
| Android filename rule | Exact uppercase `MP` suffix retained or appended, including a regression case for `lamp.jpg` |

Repeat fixture checks with:

```sh
python3 tools/verify-fixtures.py
```

That script verifies the test inputs, not execution of the Swift parser,
writer, converter, or app.

## Authored automated tests: 100, not executed here

| Suite | XCTest methods | Main coverage |
| --- | ---: | --- |
| MotionPhotoParserTests | 37 | JPEG/XMP/SEF/ISO parsing, malformed bounds, extended XMP, timestamps |
| MotionPhotoWriterTests | 23 | Google/Samsung binary layouts, independent offset/XML checks, metadata retention, parser round trips, size bounds |
| ClipTimingTests | 7 | Shared timeline, trimming, fallback timestamps, clip bounds |
| ConversionIntegrationTests | 8 | Original Apple output path, generated encoded fixtures, audio, orientation, HEIC, source preservation, cancellation |
| SourceDetectionTests | 19 | Embedded formats, identifier pairing, renamed resources, siblings, missing/ambiguous partners, marker conventions, physical-file deduplication |
| BidirectionalConversionTests | 6 | Google/Samsung exports, Apple-to-Android conversion, metadata removal, audio options, portrait frames, filename rules, late cancellation, Photos guard |
| **Total** | **100** | **Authored; no Swift tests were run in this workspace** |

The new detector tests create JPEG/MOV resources with native identifiers and
timed metadata. Conversion tests inspect actual output resources using ImageIO
and AVFoundation. They never add assets to Photos. The HEIC fixture case skips
if the test Mac cannot encode HEIC.

Run `xcrun swift test` on a Mac, or
`bash scripts/build-app.sh --test --universal --dmg` to test and build.

## Runtime validation implemented in the app

Before publishing Apple output, the validator checks JPEG and H.264 decoding,
matching pairing identifiers, and the signed-byte still-image-time track.
Before publishing Google/Samsung output, it checks the selected container
format, timestamp, exact embedded MP4 bytes, image/video decoding, H.264,
and removal of Apple-specific metadata.

These are implemented checks, not reported test results from this environment.
They cannot prove that every destination photo application will recognize an
export. Apple acceptance is reported only after a successful, user-requested
PhotoKit import transaction.

The app previews stills using ImageIO/AppKit and motion using AVKit. It does
not depend on `PHLivePhoto.request` for standalone export validation:
Apple's [macOS Live Photo display documentation](https://developer.apple.com/documentation/photokit/displaying-live-photos)
limits those display objects to Photos editing extensions.

## Remaining verification

- Compile, run the 100 Swift tests, and launch version 2 on macOS.
- Check the dropdown, detected source badges, drag-and-drop pairing, previews,
  queue actions, and minimum window size in the actual native UI.
- Test original iPhone JPEG/HEIC + MOV pairs and real Google/Samsung variants.
- Verify Google Photos and Samsung Gallery recognize and play generated JPEGs
  on the intended phone/app versions.
- Verify Apple Photos imports each exported pair as one playable Live Photo.
- Compare timing, dates, GPS, orientation, sound, and SDR brightness across
  both conversion directions and round trips.
- For public binary distribution, complete Developer ID signing and
  notarization separately.

The [Mac verification guide](MAC_VERIFICATION.md) provides concrete cases.
This source package does not contain a compiled or notarized application.
