#!/usr/bin/env python3
"""Preserve XCTest screenshots and convert marked simulator recordings into tutorial WebP.

Usage: python3 scripts/tutorial-media.py /path/to/tutorial-capture-English-v3
Input: .xcresult, .log, .mp4 and .json (startedAt Unix timestamp).
Requires Xcode, ffmpeg, cwebp and img2webp. Source captures remain unannotated; presentation adds decorations.
"""
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def run(*args):
    subprocess.run([str(a) for a in args], check=True, stdout=subprocess.DEVNULL)

def export(base):
    base = Path(base)
    with tempfile.TemporaryDirectory(prefix='tutorial-export-') as tmp:
        run('xcrun', 'xcresulttool', 'export', 'attachments', '--path', base.with_suffix('.xcresult'), '--output-path', tmp)
        manifest = json.loads((Path(tmp) / 'manifest.json').read_text())
        count = 0
        for test in manifest:
            for item in test['attachments']:
                match = re.match(r'tutorial__(en|zh-CN|zh-HK)__([a-z-]+)_', item['suggestedHumanReadableName'])
                if not match:
                    continue
                locale, name = match.groups()
                source = ROOT / 'docs/tutorial/source' / locale / (name + '.png')
                output = ROOT / 'server/public/tutorial/media' / locale / (name + '.webp')
                source.parent.mkdir(parents=True, exist_ok=True)
                output.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(Path(tmp) / item['exportedFileName'], source)
                run('cwebp', '-quiet', '-q', '84', '-resize', '804', '0', source, '-o', output)
                count += 1
    meta = json.loads(base.with_suffix('.json').read_text())
    markers = {}
    for locale, name, edge, when in re.findall(r'TUTORIAL_VIDEO (\S+) (\S+) (start|end) ([\d.]+)', base.with_suffix('.log').read_text()):
        markers.setdefault((locale, name), {})[edge] = float(when)
    for (locale, name), times in markers.items():
        if not {'start', 'end'} <= times.keys():
            continue
        start = max(0, times['start'] - meta['startedAt'])
        duration = times['end'] - times['start']
        source = ROOT / 'docs/tutorial/source' / locale / (name + '.mp4')
        output = ROOT / 'server/public/tutorial/media' / locale / (name + '.animated.webp')
        run('ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-ss', start, '-i', base.with_suffix('.mp4'), '-t', duration,
            '-vf', 'fps=12,scale=804:-2', '-an', '-c:v', 'libx264', '-crf', '19', '-pix_fmt', 'yuv420p', source)
        with tempfile.TemporaryDirectory(prefix='tutorial-frames-') as frames:
            run('ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-i', source,
                '-vf', 'fps=8,scale=640:-2', str(Path(frames) / '%04d.png'))
            run('img2webp', '-loop', '0', '-lossy', '-q', '74', '-m', '6', '-d', '125',
                *sorted(Path(frames).glob('*.png')), '-o', output)
    provenance = ROOT / 'docs/tutorial/source' / locale / 'capture.json'
    provenance.write_text(json.dumps({'capturedAt': meta['startedAt'], 'simulator': 'iPhone 17 / iOS 26.5',
        'source': 'TutorialCaptureTests with --ui-tutorial-capture; mock service, actual app UI',
        'screenshots': count, 'demonstrations': len(markers), 'presentation': 'Original pixels; decorations applied separately in SwiftUI and CSS'}, indent=2) + '\n')
    print(f'{locale}: {count} screenshots, {len(markers)} demonstrations')

if __name__ == '__main__':
    for value in sys.argv[1:]:
        export(value)
