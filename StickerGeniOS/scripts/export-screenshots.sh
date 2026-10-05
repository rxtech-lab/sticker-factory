#!/bin/zsh
# Copies the `screenshot__<name>` attachments from a ScreenshotTests result bundle into a flat
# directory as <name>.png, for the PR screenshot comment.
#
#   export-screenshots.sh <result.xcresult> <output-dir>
#
# With -retry-tests-on-failure a screen can be captured more than once; the latest capture wins.
set -euo pipefail

RESULT_BUNDLE=$1
OUTPUT_DIR=$2
RAW_DIR=$(mktemp -d)
trap 'rm -rf "${RAW_DIR}"' EXIT

mkdir -p "${OUTPUT_DIR}"
xcrun xcresulttool export attachments --path "${RESULT_BUNDLE}" --output-path "${RAW_DIR}"

python3 - "${RAW_DIR}" "${OUTPUT_DIR}" <<'PY'
import json, re, shutil, sys
from pathlib import Path

raw, out = Path(sys.argv[1]), Path(sys.argv[2])
latest = {}
for test in json.loads((raw / "manifest.json").read_text()):
    for attachment in test["attachments"]:
        match = re.search(r"screenshot__([A-Za-z0-9-]+)", attachment["suggestedHumanReadableName"])
        if not match:
            continue
        name, stamp = match.group(1), attachment.get("timestamp", 0)
        if name not in latest or stamp >= latest[name][0]:
            latest[name] = (stamp, raw / attachment["exportedFileName"])
for name, (_, source) in sorted(latest.items()):
    shutil.copy(source, out / f"{name}.png")
    print(f"exported {name}")
if not latest:
    print("no screenshot attachments found", file=sys.stderr)
PY
