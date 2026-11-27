#!/bin/sh
# fetch-python.sh — download the BeeWare Python-Apple-support 3.13
# prebuilt iOS xcframework into vendor/Python.xcframework.
#
# The asset name is resolved at run time from the GitHub API (latest
# NON-prerelease 3.13 release, asset containing "iOS" ending in .tar.gz)
# because the releases page does not publish a stable asset filename or
# SHA-256 in its text. Do NOT hardcode an asset name here: if BeeWare
# renames the asset, this script must fail loudly listing what exists.
#
# Layout: the tarball extracts to a directory containing
# Python.xcframework (multi-arch, device + simulator slices); the stdlib
# lives in the slices under lib/python3.13 (see ApplePython.c).
# Usage: sh Scripts/fetch-python.sh   (CI runs it before xcodegen)
# Env:   YIPLAYER_PYTHON_CACHE  (default ~/Library/Caches/yiplayer-python)
set -eu

REPO="beeware/Python-Apple-support"
CACHE="${YIPLAYER_PYTHON_CACHE:-$HOME/Library/Caches/yiplayer-python}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="$ROOT/vendor"
mkdir -p "$CACHE" "$VENDOR_DIR"

if [ -d "$VENDOR_DIR/Python.xcframework" ]; then
  echo "vendor/Python.xcframework already present — skipping download."
  exit 0
fi

echo "Resolving latest non-prerelease 3.13 release of $REPO ..."
RELEASE_JSON="$(mktemp)"
trap 'rm -f "$RELEASE_JSON"' EXIT
curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=30" -o "$RELEASE_JSON"

ASSET_URL="$(RELEASE_JSON="$RELEASE_JSON" python3 -c '
import json, os
for rel in json.load(open(os.environ["RELEASE_JSON"])):
    if rel.get("prerelease"):
        continue
    if not str(rel.get("tag_name", "")).startswith("3.13"):
        continue
    for a in rel.get("assets", []):
        n = a.get("name", "")
        if "iOS" in n and n.endswith(".tar.gz"):
            print(a["browser_download_url"])
            raise SystemExit(0)
')"

if [ -z "$ASSET_URL" ]; then
  echo "::error::No iOS .tar.gz asset found in the latest non-prerelease 3.13 release of $REPO."
  echo "Available releases/assets (first 5):"
  RELEASE_JSON="$RELEASE_JSON" python3 -c '
import json, os
for rel in json.load(open(os.environ["RELEASE_JSON"]))[:5]:
    print(rel.get("tag_name"), "prerelease=" + str(rel.get("prerelease")))
    for a in rel.get("assets", []):
        print("   ", a.get("name"))
'
  echo "Fix: update the asset matcher in Scripts/fetch-python.sh to the new name."
  exit 1
fi

FILE="$CACHE/$(basename "$ASSET_URL")"
if [ -f "$FILE" ]; then
  echo "Using cached $FILE"
else
  echo "Downloading $ASSET_URL ..."
  curl -fsSL "$ASSET_URL" -o "$FILE"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" "$RELEASE_JSON"' EXIT
tar -xzf "$FILE" -C "$TMP"
XCFW="$(find "$TMP" -maxdepth 3 -name "Python.xcframework" -type d | head -n 1)"
if [ -z "$XCFW" ] || [ ! -f "$XCFW/Info.plist" ]; then
  echo "::error::Downloaded tarball did not contain a usable Python.xcframework."
  echo "Contents of the tarball top level:"
  ls "$TMP"
  exit 1
fi

rm -rf "$VENDOR_DIR/Python.xcframework"
cp -R "$XCFW" "$VENDOR_DIR/Python.xcframework"
echo "Python.xcframework ready at $VENDOR_DIR/Python.xcframework"
ls "$VENDOR_DIR/Python.xcframework"
