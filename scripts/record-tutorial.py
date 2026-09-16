#!/usr/bin/env python3
"""Capture one localization on an explicit, isolated, booted simulator.

Build-for-testing first. Usage:
python3 scripts/record-tutorial.py DEVICE_UDID English /tmp/tutorial-build /tmp/capture-en
The language is English, SimplifiedChinese or TraditionalChinese.
"""
import json
import signal
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
device, language, build, prefix = sys.argv[1:]
assert language in ['English', 'SimplifiedChinese', 'TraditionalChinese']
base = Path(prefix)
with open(str(base) + '-video.log', 'w') as video_log:
    started = time.time()
    recorder = subprocess.Popen(['xcrun', 'simctl', 'io', device, 'recordVideo', '--codec=h264', '--force', str(base.with_suffix('.mp4'))], stdout=video_log, stderr=subprocess.STDOUT)
    base.with_suffix('.json').write_text(json.dumps({'startedAt': started}))
    try:
        with open(base.with_suffix('.log'), 'w') as log:
            code = subprocess.call(['xcodebuild', '-project', 'StickerGeniOS.xcodeproj', '-scheme', 'StickerGeniOS', '-destination', f'platform=iOS Simulator,id={device}', '-derivedDataPath', build, '-disableAutomaticPackageResolution', 'CODE_SIGNING_ALLOWED=NO', '-parallel-testing-enabled', 'NO', '-resultBundlePath', str(base.with_suffix('.xcresult')), '-only-testing:StickerGeniOSUITests/TutorialCaptureTests/testCapture' + language, 'test-without-building'], cwd=ROOT / 'StickerGeniOS', stdout=log, stderr=subprocess.STDOUT)
    finally:
        recorder.send_signal(signal.SIGINT)
        try:
            recorder.wait(timeout=20)
        except subprocess.TimeoutExpired:
            recorder.terminate()
sys.exit(code)
