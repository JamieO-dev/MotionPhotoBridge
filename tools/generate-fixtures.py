#!/usr/bin/env python3
"""Reproduce the synthetic test images; development only (needs Pillow + ffmpeg).

No real people's photos are used. The app itself has no Python/ffmpeg dependency.
"""
from __future__ import annotations
import io
import json
import pathlib
import struct
import subprocess
import tempfile
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parents[1]
DEST = ROOT / 'Tests' / 'LivePhotoEngineTests' / 'Fixtures'


def run(*args: str) -> None:
    subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', *args], check=True)


def xmp_jpeg(image: Image.Image, xml: str, orientation: int = 1) -> bytes:
    exif = Image.Exif()
    exif[0x010F] = 'MotionPhotoBridge synthetic fixture'
    exif[0x0110] = 'Generated pattern, not a phone photograph'
    exif[0x0112] = orientation
    exif[0x8769] = {0x9003: '2024:02:29 12:34:56', 0x9011: '+00:00'}
    output = io.BytesIO()
    image.save(output, format='JPEG', quality=95, subsampling=0, exif=exif)
    jpeg = output.getvalue()
    if not xml:
        return jpeg
    packet = b'http://ns.adobe.com/xap/1.0/\0' + xml.encode('utf-8')
    assert len(packet) + 2 <= 65535
    return jpeg[:2] + b'\xff\xe1' + struct.pack('>H', len(packet) + 2) + packet + jpeg[2:]


def xml(attributes: str, body: str = '') -> str:
    return ('<x:xmpmeta xmlns:x="adobe:ns:meta/">'
            '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
            '<rdf:Description xmlns:GCamera="http://ns.google.com/photos/1.0/camera/" '
            'xmlns:Container="http://ns.google.com/photos/1.0/container/" '
            'xmlns:Item="http://ns.google.com/photos/1.0/container/item/" '
            f'{attributes}>{body}</rdf:Description></rdf:RDF></x:xmpmeta>')


def modern(movie: bytes) -> str:
    directory = ('<Container:Directory><rdf:Seq>'
                 '<rdf:li rdf:parseType="Resource"><Container:Item Item:Mime="image/jpeg" '
                 'Item:Semantic="Primary" Item:Length="0" Item:Padding="0"/></rdf:li>'
                 '<rdf:li rdf:parseType="Resource"><Container:Item Item:Mime="video/mp4" '
                 f'Item:Semantic="MotionPhoto" Item:Length="{len(movie)}"/></rdf:li>'
                 '</rdf:Seq></Container:Directory>')
    return xml('GCamera:MotionPhoto="1" GCamera:MotionPhotoVersion="1" '
               'GCamera:MotionPhotoPresentationTimestampUs="2000000"', directory)


def main() -> None:
    DEST.mkdir(parents=True, exist_ok=True)
    manifest = {}
    with tempfile.TemporaryDirectory(prefix='motionphotobridge-fixtures-') as temporary:
        work = pathlib.Path(temporary)
        movie_path, still_path, rotated_path = (work / n for n in ('motion.mp4', 'still.png', 'rotated.mp4'))
        run('-f', 'lavfi', '-i', 'testsrc2=size=320x240:rate=30:duration=4',
            '-f', 'lavfi', '-i', 'sine=frequency=523.25:sample_rate=48000:duration=4',
            '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '23', '-pix_fmt', 'yuv420p',
            '-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709',
            '-c:a', 'aac', '-b:a', '96k', '-movflags', '+faststart', '-shortest', '-y', str(movie_path))
        run('-i', str(movie_path), '-ss', '2', '-frames:v', '1', '-y', str(still_path))
        run('-display_rotation:v:0', '-90', '-i', str(movie_path), '-c', 'copy', '-y', str(rotated_path))
        movie, rotated = movie_path.read_bytes(), rotated_path.read_bytes()
        image = Image.open(still_path).convert('RGB')
        for name, clip, metadata, orientation in [
            ('google-modern', movie, modern(movie), 1),
            ('google-legacy', movie, xml(f'GCamera:MicroVideo="1" GCamera:MicroVideoVersion="1" '
                                       f'GCamera:MicroVideoOffset="{len(movie)}" '
                                       'GCamera:MicroVideoPresentationTimestampUs="2000000"'), 1),
            ('rotated-google', rotated, modern(rotated), 6),
        ]:
            still = xmp_jpeg(image, metadata, orientation)
            (DEST / f'{name}.jpg').write_bytes(still + clip)
            manifest[f'{name}.jpg'] = {'video_start': len(still), 'video_length': len(clip), 'timestamp_us': 2000000}
        still = xmp_jpeg(image, '')
        identifier = b'\x00\x00\x30\x0a'
        field_name = b'MotionPhoto_Data'
        prefix = identifier + struct.pack('<I', len(field_name)) + field_name
        block = prefix + movie
        directory = b'SEFH' + struct.pack('<II', 107, 1) + identifier + struct.pack('<II', len(block), len(block))
        trailer = block + directory + struct.pack('<I', len(directory)) + b'SEFT'
        (DEST / 'samsung-sef.jpg').write_bytes(still + trailer)
        manifest['samsung-sef.jpg'] = {'video_start': len(still) + len(prefix), 'video_length': len(movie), 'timestamp_us': None}
    (DEST / 'fixture-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'Created {len(manifest)} synthetic fixtures in {DEST}')


if __name__ == '__main__':
    main()
