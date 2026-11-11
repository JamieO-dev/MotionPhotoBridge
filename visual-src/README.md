# Interface illustration sources

The three PNGs in `../assets/` are drawings based on the MotionPhotoBridge 2 SwiftUI
source. They are not screenshots of a running macOS build. Each PNG includes
that disclosure in its footer. Names, sizes, and media are illustrative sample
data. All landscape artwork is original SVG; no personal photographs or
third-party stock images are used.

`features.html` is a self-contained browser-editable counterpart. Open it with
`?scene=1`, `?scene=2`, or `?scene=3` to select a feature scene. It does not run the
native app or perform conversion.

The delivered PNGs were rendered from the three matching SVG files with
Inkscape. To regenerate them, install Python 3, Node.js, and Inkscape, then run:

```sh
python3 visual-src/render.py
```

The renderer uses only local files and writes all three SVGs and PNGs. Its
dependencies are for editing these illustrations only; MotionPhotoBridge itself
does not require them. Native screenshots can replace the PNGs under the same
filenames after the Mac app is built and the corresponding states are captured.
