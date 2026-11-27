#!/bin/sh
# fetch-python.sh — download the BeeWare Python-Apple-support 3.13
# prebuilt iOS xcframework into vendor/Python.xcframework, and stage
# its standard library into vendor/python-stdlib/ for the app bundle.
#
# The asset name is resolved at run time from the GitHub API (latest
# NON-prerelease 3.13 release, asset containing "iOS" ending in .tar.gz)
# because the releases page does not publish a stable asset filename or
# SHA-256 in its text. Do NOT hardcode an asset name here: if BeeWare
# renames the asset, this script must fail loudly listing what exists.
#
# LAYOUT — verified 2026-11-27 against the real 3.13-b18 tarball
# (Python-3.13-iOS-support.b18.tar.gz), NOT guessed:
#   Python.xcframework/ios-arm64/Python.framework/   — binary + Info.plist ONLY
#   Python.xcframework/lib/python3.13/                — pure-Python stdlib
#                                                        (os.py, encodings/, ...)
#   Python.xcframework/ios-arm64/lib-arm64/python3.13/lib-dynload/
#                                                      — device .so extension
#                                                        modules (_socket, _ssl,
#                                                        _hashlib, ...)
#   There is NO <Python.framework>/lib/python3.13 — v2.0.0 assumed that
#   path in ApplePython.c, and Xcode only copies the .framework into
#   the .app, so the stdlib never made it into the build and
#   Py_InitializeFromConfig failed (error code 4, "No module named
#   'encodings'"). v2.1 stages the stdlib here instead:
#   vendor/python-stdlib/python3.13/ (+ lib-dynload/ inside it), and
#   project.yml adds vendor/python-stdlib as a folder-reference
#   resource, so the bundle contains python-stdlib/python3.13/os.py.
#   BeeWare ships the extension modules as plain .so files in
#   lib-dynload (no .fwork files anywhere in the package); they load
#   from inside the signed app bundle. (Yingxia converts each module
#   into its own framework instead — heavier; only revisit if a .so
#   ever fails to load on device. See BUILD_NOTES.md.)
#
# The staging step runs EVERY time, even when the xcframework is
# already present (e.g. restored from the CI cache): the staged copy
# may be absent or stale while the framework is fine.
#
# Usage: sh Scripts/fetch-python.sh   (CI runs it before xcodegen)
# Env:   YIPLAYER_PYTHON_CACHE  (default ~/Library/Caches/yiplayer-python)
set -eu

REPO="beeware/Python-Apple-support"
CACHE="${YIPLAYER_PYTHON_CACHE:-$HOME/Library/Caches/yiplayer-python}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="$ROOT/vendor"
mkdir -p "$CACHE" "$VENDOR_DIR"

if [ -d "$VENDOR_DIR/Python.xcframework" ]; then
  echo "vendor/Python.xcframework already present — using it."
else
  echo "Resolving latest non-prerelease 3.13 release of $REPO ..."
  RELEASE_JSON="$(mktemp)"
  trap 'rm -f "$RELEASE_JSON"' EXIT
  # GitHub's unauthenticated API limit (60 req/hour per IP) is routinely
  # exhausted on shared Actions runners -> 403. Actions provides a token
  # (GITHUB_TOKEN) in every run; use it when present so the call is
  # authenticated (5,000 req/hour). The token is never printed or stored.
  # (Plain if/else, not an empty array: /bin/sh here is bash 3.2, where an
  # empty "${ARR[@]}" under set -u is an unbound-variable error.)
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" \
      "https://api.github.com/repos/$REPO/releases?per_page=30" -o "$RELEASE_JSON"
  else
    curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=30" -o "$RELEASE_JSON"
  fi

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
  XCFW_DL="$(find "$TMP" -maxdepth 3 -name "Python.xcframework" -type d | head -n 1)"
  if [ -z "$XCFW_DL" ] || [ ! -f "$XCFW_DL/Info.plist" ]; then
    echo "::error::Downloaded tarball did not contain a usable Python.xcframework."
    echo "Contents of the tarball top level:"
    ls "$TMP"
    exit 1
  fi

  rm -rf "$VENDOR_DIR/Python.xcframework"
  cp -R "$XCFW_DL" "$VENDOR_DIR/Python.xcframework"
  echo "Python.xcframework ready at $VENDOR_DIR/Python.xcframework"
  ls "$VENDOR_DIR/Python.xcframework"
fi

# ---- Stage the stdlib for the app bundle (v2.1) ----------------------
# Device slice only: the build is -sdk iphoneos (arm64). The simulator
# slice (ios-arm64_x86_64-simulator) is never used by this target.
XCFW="$VENDOR_DIR/Python.xcframework"
STDLIB_SRC="$XCFW/lib/python3.13"
DYNLOAD_SRC="$XCFW/ios-arm64/lib-arm64/python3.13/lib-dynload"
STAGED="$VENDOR_DIR/python-stdlib/python3.13"

if [ ! -f "$STDLIB_SRC/os.py" ] || [ ! -f "$STDLIB_SRC/encodings/__init__.py" ]; then
  echo "::error::BeeWare layout changed: no stdlib at $STDLIB_SRC (expected os.py + encodings/)."
  echo "Contents of $XCFW/lib:"
  ls "$XCFW/lib" 2>/dev/null || echo "(no lib/ at all)"
  exit 1
fi
if [ ! -f "$DYNLOAD_SRC/_socket.cpython-313-iphoneos.so" ] \
    || [ ! -f "$DYNLOAD_SRC/_ssl.cpython-313-iphoneos.so" ]; then
  echo "::error::BeeWare layout changed: no device lib-dynload at $DYNLOAD_SRC (expected _socket/_ssl .so)."
  ls "$DYNLOAD_SRC" 2>/dev/null | head -10 || echo "(no lib-dynload at all)"
  exit 1
fi

rm -rf "$VENDOR_DIR/python-stdlib"
mkdir -p "$STAGED/lib-dynload"
cp -R "$STDLIB_SRC/." "$STAGED/"
cp "$DYNLOAD_SRC/"*.so "$STAGED/lib-dynload/"
# Trim dead weight (same list Yingxia's python-runtime-plan.md trims:
# no tests, idlelib, tkinter, ensurepip — none of it can run on iOS,
# and none of it is imported by a spider or by requests).
rm -rf "$STAGED/test" "$STAGED/idlelib" "$STAGED/tkinter" \
       "$STAGED/turtledemo" "$STAGED/ensurepip" "$STAGED/lib2to3"
# Sanity: the interpreter bootstrap needs exactly these.
test -f "$STAGED/os.py" || { echo "::error::staged stdlib lost os.py"; exit 1; }
test -f "$STAGED/encodings/__init__.py" || { echo "::error::staged stdlib lost encodings/"; exit 1; }
test -n "$(ls "$STAGED/lib-dynload/"*.so 2>/dev/null)" || { echo "::error::staged lib-dynload is empty"; exit 1; }
echo "python-stdlib staged at $VENDOR_DIR/python-stdlib ($(find "$STAGED" -type f | wc -l | tr -d ' ') files, $(du -sh "$VENDOR_DIR/python-stdlib" | cut -f1))"
