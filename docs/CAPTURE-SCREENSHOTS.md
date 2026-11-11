# Capture native MotionPhotoBridge screenshots

The three PNGs in this package are interface illustrations based on the SwiftUI
source. To publish screenshots of the running app, capture the same features on
your Mac and replace those PNGs. Keep the illustration disclosure until all
three have been replaced.

## Prepare the app

Build MotionPhotoBridge 2 with `Build MotionPhotoBridge.command` and open the resulting
app. Close any older copy first. Use a consistent window size and appearance
for all captures; the app's default window is 1040 × 720 points.

Choose photos and filenames you are comfortable making public. The project
includes generated sample inputs in `Tests/LivePhotoEngineTests/Fixtures`.
They can be used to demonstrate the workflow without personal photographs.

For an Apple example, export a Live Photo's unmodified originals from Photos,
or convert `google-modern.jpg` to **Apple Live Photo** with MotionPhotoBridge and
then add that result's JPEG and MOV as a new input. The latter is a generated
test example, not proof of compatibility with every iPhone model.

## 1. Choosing the destination

Save as **`assets/01-format-picker.png`**.

1. Add an Apple Live Photo's image and MOV. They should appear as one row with
   an **Apple Live Photo** source badge.
2. Choose **Google Motion Photo** under **Convert To**.
3. Open the dropdown so **Apple Live Photo**, **Google Motion Photo**, and
   **Samsung Motion Photo** are visible.
4. Capture the window with the menu open. Make sure the menu does not hide the
   source badge or obscure the relationship between input and output.

This image explains that iPhone originals can be converted to Android formats.

## 2. Automatic detection and batching

Save as **`assets/02-automatic-detection.png`**.

1. Start a fresh queue containing an Apple pair, a Google Motion Photo, and a
   Samsung Motion Photo. The synthetic Google/Samsung fixtures can be used.
2. Wait for detection to finish. Each row should show its source format.
3. Choose **Apple Live Photo** as the destination and select an export folder.
4. Leave the queue ready to convert. Capture the three rows, the audio and
   clip-length controls, and the **Convert 3 Photos** button.

Apple's two resources should occupy one row. Avoid including unresolved or
unrelated files in this feature image.

## 3. Previewing a completed export

Save as **`assets/03-preview-and-export.png`**.

1. Convert a sample to **Apple Live Photo**, leaving automatic Photos import off.
2. Confirm the row reports an exported result and offers the Photos import action.
3. Open **Preview** on that row.
4. Capture the preview with the **Photo / Motion** tabs and **Show in Finder**
   action visible. A still view is easiest to capture crisply; the tabs show
   that the motion clip can be inspected as well.

The preview should show real exported sample media. Do not add an artificial
success state to a capture.

## Capture and publish

On macOS, press **Shift–Command–4**, then **Space**, then click the app window
to capture it. For the open menu, a selected rectangular area may be easier
to capture than the window alone. Apple's
[screenshot guide](https://support.apple.com/en-gb/102646) explains the capture options.

Use the same crop and a readable scale across all three images. Save in PNG
format, preserving the filenames above. View the README at GitHub's normal
content width to check that controls and source badges remain legible.

After replacing all three illustrations:

- Change the README heading **Interface illustrations** to **Screenshots**.
- Remove the sentence saying that the images are illustrated from source.
- Update each alt text to describe the actual captured state.
- Update the visual-provenance section in `REPOSITORY-SETUP.md`.
- Keep the compatibility/validation notes accurate; screenshots demonstrate
  the visible UI, not every device's playback behavior.

The editable illustration source is included under `visual-src` for reference.
It is documentation artwork and does not replace the native app implementation.
