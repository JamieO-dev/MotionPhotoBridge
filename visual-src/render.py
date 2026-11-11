#!/usr/bin/env python3
"""Regenerate all three source-based interface illustrations.

Requires Python 3, Node.js, and Inkscape on PATH. This file-only renderer
does not launch a browser or make network requests. These are illustrations,
not captures of a native macOS app.
"""
from pathlib import Path
import runpy

runpy.run_path(str(Path(__file__).with_name("render-svg.py")), run_name="__main__")
