#!/usr/bin/env python3
"""Verify bundled media fixtures with independent tools, not the Swift parser.

Requires Pillow, ffmpeg and ffprobe. It does not claim to compile or test the
macOS app; run `swift test` on a Mac for the application integration suite.
"""
import json
import pathlib
import subprocess
import tempfile
from PIL import Image

root = pathlib.Path(__file__).resolve().parents[1] / 'Tests' / 'LivePhotoEngineTests' / 'Fixtures'
manifest = json.loads((root / 'fixture-manifest.json').read_text())
for name, expected in manifest.items():
    data = (root / name).read_bytes()
    start, length = expected['video_start'], expected['video_length']
    assert 0 <= start < start + length <= len(data), name
    movie = data[start:start + length]
    assert movie[4:8] == b'ftyp', name
    with tempfile.NamedTemporaryFile(suffix='.mp4') as extracted:
        extracted.write(movie)
        extracted.flush()
        result = subprocess.run(['ffprobe', '-v', 'error', '-show_streams', '-show_format', '-of', 'json', extracted.name],
                                check=True, capture_output=True, text=True)
        probe = json.loads(result.stdout)
        streams = probe['streams']
        assert [(s['codec_type'], s['codec_name']) for s in streams] == [('video', 'h264'), ('audio', 'aac')], name
        assert abs(float(probe['format']['duration']) - 4) < 0.1, name
        assert (streams[0]['width'], streams[0]['height']) == (320, 240), name
        rotations = [s.get('rotation') for s in streams[0].get('side_data_list', []) if 'rotation' in s]
        if name == 'rotated-google.jpg':
            assert rotations == [-90], (name, rotations)
        else:
            assert not rotations, (name, rotations)
        subprocess.run(['ffmpeg', '-v', 'error', '-xerror', '-err_detect', 'explode', '-i', extracted.name,
                        '-f', 'null', '-'], check=True, capture_output=True)
    with Image.open(root / name) as image:
        image.load()
        assert image.size == (320, 240), name
        exif = image.getexif()
        assert exif.get(0x010F) == 'MotionPhotoBridge synthetic fixture', name
        assert exif.get(0x112) == (6 if name == 'rotated-google.jpg' else 1), name
        date = exif.get_ifd(0x8769)
        assert date[0x9003] == '2024:02:29 12:34:56', name
        assert date[0x9011] == '+00:00', name
    print(f'PASS {name}: JPEG, fixture branding, capture date, orientation, 4s H.264 + AAC, full decode')
print(f'{len(manifest)} fixtures verified. Swift and macOS application tests were not run by this script.')
