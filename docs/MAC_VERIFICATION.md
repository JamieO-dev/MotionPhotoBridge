# MotionPhotoBridge 2: Mac and device verification

The user reported that version 1 worked on their Mac. Version 2 adds new input
and output paths. The delivery workspace has no Swift compiler, macOS SDK,
Photos app, or real iPhone/Samsung/Google originals, so native compilation,
runtime behavior, and device recognition still require the checks below.

## Build and automated checks

Use macOS 13 or newer and Swift 5.9 or newer with a macOS SDK. Quit the old app
before opening the newly built version.

```sh
xcrun swift test
bash scripts/build-app.sh --universal
codesign --verify --strict --verbose=2 dist/MotionPhotoBridge.app
xcrun lipo -archs dist/MotionPhotoBridge.app/Contents/MacOS/MotionPhotoBridge
open dist/MotionPhotoBridge.app
```

The universal executable should contain `arm64` and `x86_64`. About MotionPhotoBridge
should report version 2.0.1. The automated tests use generated media, do not
request Photos permission, and do not import into a personal library. The HEIC
case skips if that runner cannot encode its fixture.

The included GitHub Actions workflow runs native tests and builds on macOS when
placed in your own repository. It has not been executed for this delivery and
does not publish a release or notarize the app.

The app uses the bundle identifier `com.motionphotobridge.app`. Confirm
Photos permission when prompted; this identity may need a new grant.

## Automatic detection and dropdown

1. Add one Google and one Samsung original. Each should receive the appropriate
   source badge and remain a single queue item.
2. Export an iPhone Live Photo from Photos using **File > Export > Export
   Unmodified Original**. Add its image and MOV together. They should become
   one Apple Live Photo row.
3. Add only the image with its MOV in the same folder, then only the MOV in a
   fresh queue. Both should resolve to the same pair.
4. Put the two resources in separate folders, rename them without changing
   their contents, and select both. Embedded identifiers should still pair them.
5. Add a lone image with its MOV unavailable. Check the missing-partner error,
   then add the MOV. The error should resolve to one ready row.
6. Select a similarly named image and MOV with different identifiers. They
   must not be combined. Duplicate identifier candidates should be reported as
   ambiguous unless the intended pair is explicitly selected.
7. Confirm all three destinations appear in **Convert To**. Apple-only queues
   initially choose Google; a manual choice must survive adding more files.
8. Change the destination after completing a batch. **Queue for …** and the
   batch queue command should make another export without deleting the first.
9. Check that **Also add to Photos** appears only for Apple output and that
   completed Android rows never offer Photos import.

## Conversion matrix

Use small batches of real originals before a large migration. Retain originals
and compare their bytes before/after each test.

| Source | Apple output | Google output | Samsung output |
| --- | --- | --- | --- |
| iPhone Live Photo, JPEG + MOV | Pair and Photos playback | Single JPEG and Google playback | Single JPEG and Samsung playback |
| iPhone Live Photo, HEIC + MOV | Pair and Photos playback | Single JPEG and Google playback | Single JPEG and Samsung playback |
| Older Google Microvideo JPEG | Pair and Photos playback | Modern Google container | Samsung SEF container |
| Current Google JPEG | Pair and Photos playback | Re-encoded modern container | Samsung SEF container |
| Samsung JPEG/HEIC | Pair and Photos playback | Google container | Samsung SEF container |

Check portrait/landscape orientation, mirroring, sound, capture date, GPS,
brightness, and the key moment in every relevant case. Include a silent clip,
a clip longer than three seconds, and an HDR example. SDR conversion is expected;
HDR and gain-map preservation are not implemented.

### Apple output

A completed folder contains a JPEG, MOV, and `conversion.json`. The JPEG's
MakerApple field 17 must match the MOV's
`com.apple.quicktime.content.identifier`. A metadata track must contain the
`com.apple.quicktime.still-image-time` marker.

Play the MOV in QuickTime. Then explicitly use **Add to Photos**, allow add-only
access, and confirm one Live Photo with moving playback and sound. A successful
standalone export validates resources; PhotoKit acceptance is confirmed only
after the import transaction succeeds.

If iCloud Photos is enabled for the test library, check normal iPhone playback
after sync. MotionPhotoBridge does not configure or perform that synchronization.

### Google output

A completed folder contains `name_MP.jpg` and `conversion.json`, with no
separate movie. The image should contain modern Camera/Container XMP and an
MP4 as the final resource. The timestamp is relative to the output clip.
The exported JPEG must not retain an Apple pairing identifier.

Transfer the full JPEG to a Google Photos environment that supports Motion
Photos. Verify the motion indicator, playback, sound, orientation, and key
frame. Record the Google Photos version and transfer method. Sending a file
through a service that recompresses it can remove appended motion data.

### Samsung output

A completed folder contains `name_MP.jpg` and `conversion.json`. The embedded
MP4 is indexed by Samsung SEF `MotionPhoto_Data`; the version block contains
`mpv3`. Unlike the strict Google container, Samsung's vendor layout includes
SEF information after the movie.

Transfer the unchanged file to the Samsung device and verify it in Samsung
Gallery. Record the phone model, One UI/Gallery version, and transfer method.
This layout is implemented from published format/producer references; current
firmware recognition has not been verified in the delivery workspace.

### Round trips and options

- Convert Google → Apple → Google and Samsung → Apple → Samsung. Re-add the
  completed media, avoiding a folder containing multiple old copies with the
  same Apple identifier.
- Verify that the key-photo timestamp remains inside the clip and near the
  same moment. Small frame/timebase rounding is expected.
- Repeat with **3 seconds** and **Full clip**; trimming should preserve the key
  moment, rather than always taking the first three seconds.
- Turn audio off for every destination and verify there is no audio track.
- Preview both the still and motion for each destination; close/reopen previews
  and ensure extracted preview files are cleaned up.
- Verify original source files remain unchanged. Round trips re-encode media,
  so the converted image/video will not be byte-identical to the source.

## Failure and interaction checks

- Deny Photos access. The finished Apple export stays available, with a retry
  action after permission is changed. Google/Samsung export asks for no Photos
  permission.
- Use a missing, read-only, or disconnected destination. The app should report
  failure without publishing a partial result.
- Convert identically named inputs from different folders. Results must remain
  distinct, with no overwrite.
- Cancel during video encoding and during final packaging. Partial staging
  data should be removed and completed exports kept.
- Quit while work is active. Safe cancellation should finish before exit.
- Include an ordinary still, a stripped Motion Photo, a normal MOV, and a
  truncated file. Specific failures should leave the batch able to continue.
- Test a folder with supported originals, unrelated files, and subfolders.
- Check keyboard actions, VoiceOver labels, light/dark appearance, minimum
  window size, long filenames, long error messages, and sidebar scrolling.
- Disable network access and repeat local conversion and Photos import.
  Existing iCloud synchronization is separate and requires its own network.

## Signing for distribution

The build script uses an ad hoc signature by default. For public distribution,
set `MOTIONPHOTOBRIDGE_SIGN_IDENTITY` to your Developer ID identity; the script applies
the hardened runtime and Photos resource entitlement. Notarization and
stapling are separate Apple tool steps. The build script does not upload app
bytes or credentials.

References:

- [Apple: exporting originals from Photos](https://support.apple.com/en-gb/guide/photos/pht6e157c5f/12.0/mac/27)
- [Android Motion Photo specification](https://developer.android.com/media/platform/motion-photo-format)
- [MotionPhoto2 Samsung JPEG producer](https://github.com/PetrVys/MotionPhoto2/blob/main/SamsungTags.py)
- [Swift on macOS](https://www.swift.org/install/macos/)
- [Apple: universal macOS binaries](https://developer.apple.com/documentation/apple-silicon/building-a-universal-macos-binary)
- [Apple: hardened runtime](https://developer.apple.com/documentation/xcode/configuring-the-hardened-runtime)
