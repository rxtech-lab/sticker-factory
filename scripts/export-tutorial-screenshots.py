#!/usr/bin/env python3
"""Export a complete localized tutorial screenshot set from fresh XCTest result bundles.

Usage: python3 scripts/export-tutorial-screenshots.py REVISION results.xcresult [...]
After visual review, update MDX media IDs to NAME-REVISION and compile the content.
"""
import hashlib
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOCALES = ("en", "zh-CN", "zh-HK")
NAMES = {"create-prompt", "create-references", "create-static", "create-animated", "create-controllable", "plan", "sticker", "controls", "export", "packs", "pack-picker", "new-pack", "pack-detail", "whatsapp", "telegram"}

def export(revision, results):
    if not re.fullmatch(r"[a-z0-9-]+", revision):
        raise ValueError("Revision must contain lowercase letters, digits or hyphens")
    with tempfile.TemporaryDirectory(prefix="tutorial-refresh-") as temp:
        captures = {}
        for index, result in enumerate(results):
            directory = Path(temp) / str(index)
            subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", result, "--output-path", str(directory)], check=True, stdout=subprocess.DEVNULL)
            for test in json.loads((directory / "manifest.json").read_text()):
                for item in test["attachments"]:
                    match = re.match(r"tutorial__(en|zh-CN|zh-HK)__([a-z-]+)_", item["suggestedHumanReadableName"])
                    if match and match[2] in NAMES:
                        captures[(match[1], match[2])] = (directory / item["exportedFileName"], item, test["testIdentifier"])
        expected = {(locale, name) for locale in LOCALES for name in NAMES}
        if captures.keys() != expected:
            raise ValueError(f"Incomplete capture: missing {sorted(expected - captures.keys())}")
        for locale in LOCALES:
            provenance = {"revision": revision, "source": "Fresh simulator screenshots of actual app views with mock service and curated demo stickers", "screenshots": []}
            for name in sorted(NAMES):
                path, item, test = captures[(locale, name)]
                filename = f"{name}-{revision}"
                source = ROOT / "docs/tutorial/source" / locale / f"{filename}.png"
                output = ROOT / "server/public/tutorial/media" / locale / f"{filename}.webp"
                shutil.copy2(path, source)
                subprocess.run(["cwebp", "-quiet", "-q", "84", "-resize", "804", "0", str(source), "-o", str(output)], check=True)
                provenance["screenshots"].append({"id": filename, "capturedAt": item["timestamp"], "device": item["deviceName"], "test": test, "sha256": hashlib.sha256(source.read_bytes()).hexdigest()})
            (ROOT / "docs/tutorial/source" / locale / f"capture-{revision}.json").write_text(json.dumps(provenance, indent=2) + "\n")
        print(f"Exported {len(captures)} current screenshots, revision {revision}")

if __name__ == "__main__":
    export(sys.argv[1], sys.argv[2:])
