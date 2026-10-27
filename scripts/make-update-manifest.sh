#!/bin/bash
# Writes the update manifest (update.json) for a release to stdout.
# Usage: scripts/make-update-manifest.sh <version> <Duhcord.zip> <notes-file>
set -euo pipefail
VERSION="$1" ZIP="$2" NOTES="$3"
python3 - "$VERSION" "$ZIP" "$NOTES" <<'PY'
import hashlib, json, sys
version, archive, notes = sys.argv[1:4]
data = open(archive, "rb").read()
json.dump({
    "version": version,
    "url": f"https://github.com/C4BRA/duhcord/releases/download/v{version}/Duhcord.zip",
    "sha256": hashlib.sha256(data).hexdigest(),
    "size": len(data),
    "minimumSystemVersion": "13.0",
    "notes": open(notes, encoding="utf-8").read().strip(),
}, sys.stdout, sort_keys=True, ensure_ascii=False)
PY
