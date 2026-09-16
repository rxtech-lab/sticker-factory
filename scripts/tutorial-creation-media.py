#!/usr/bin/env python3
"""Export creation-only XCTest screenshots. Usage: tutorial-creation-media.py results.xcresult.

Run TutorialCaptureTests/testCaptureCreation{English,SimplifiedChinese,TraditionalChinese}
against a fresh build first. Requires Xcode and cwebp. Preserves original PNG pixels.
"""
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NAMES = {"create-prompt", "create-references", "create-static", "create-animated", "create-controllable", "create-overview"}

def export(result):
    with tempfile.TemporaryDirectory(prefix="creation-captures-") as temp:
        subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", result, "--output-path", temp], check=True)
        manifest = json.loads((Path(temp) / "manifest.json").read_text())
        captures = {}
        for test in manifest:
            for item in test["attachments"]:
                match = re.match(r"tutorial__(en|zh-CN|zh-HK)__([a-z-]+)_", item["suggestedHumanReadableName"])
                if match and match[2] in NAMES:
                    captures[(match[1], match[2])] = item
        expected = {(locale, name) for locale in ("en", "zh-CN", "zh-HK") for name in NAMES}
        if captures.keys() != expected:
            raise ValueError(f"Incomplete creation capture: missing {expected - captures.keys()}")
        for (locale, name), item in captures.items():
            source = ROOT / "docs/tutorial/source" / locale / f"{name}-wizard.png"
            output = ROOT / "server/public/tutorial/media" / locale / f"{name}-wizard.webp"
            shutil.copy2(Path(temp) / item["exportedFileName"], source)
            subprocess.run(["cwebp", "-quiet", "-q", "84", "-resize", "804", "0", str(source), "-o", str(output)], check=True)
        for locale in ("en", "zh-CN", "zh-HK"):
            items = [item for (language, _), item in captures.items() if language == locale]
            provenance = {"capturedAt": max(item["timestamp"] for item in items), "device": items[0]["deviceName"], "source": "TutorialCaptureTests/testCaptureCreation; latest local app, mock service, real app views", "screenshots": sorted(f"{name}-wizard.png" for name in NAMES), "presentation": "Original PNG pixels; WebP resized to 804 pixels wide. Creation chapters use still screenshots instead of the older wizard recording."}
            (ROOT / "docs/tutorial/source" / locale / "creation-capture.json").write_text(json.dumps(provenance, indent=2) + "\n")

if __name__ == "__main__":
    export(sys.argv[1])
