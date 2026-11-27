#!/bin/sh
# fetch-node-mobile.sh — download jo32/nodejs-mobile Node.js 26 LTS
# (no JIT) for iOS into vendor/NodeMobile.xcframework.
#
# Facts below are from tvbox-silicon's Scripts/fetch-node-mobile.sh,
# read in full and verified 2026-11-27 (version, release tag, asset
# name, both SHA-256 values, base URL). This script is YiPlayer's own
# wording of the same download; it does not copy tvbox-silicon code.
# The archive unzips NodeMobile.xcframework/* and a LICENSE file.
#
# Usage: sh Scripts/fetch-node-mobile.sh   (CI runs it before xcodegen)
# Env:   NODE_MOBILE_DIR   (folder holding NodeMobile.xcframework +
#          LICENSE.node: used as-is, no download)
#        YIPLAYER_NODE_CACHE (default ~/Library/Caches/yiplayer-nodejs-mobile)
set -eu

VERSION="26.13.0"
RELEASE="v26.13.0-tvbox.1"
ARCHIVE_SHA256="a84ac23e389f186dc64a78e2350b747b6e3f6cf56db12c9e1c3561db156b6440"
LICENSE_SHA256="12d632aa78f637d8c899f19d4549538c477b6df3836fe86731cd821f750abac8"
BASE="https://github.com/jo32/nodejs-mobile/releases/download/$RELEASE"
ASSET="nodejs-mobile-v$VERSION-apple.zip"

CACHE="${YIPLAYER_NODE_CACHE:-$HOME/Library/Caches/yiplayer-nodejs-mobile}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="$ROOT/vendor"
mkdir -p "$CACHE" "$VENDOR_DIR"

if [ -d "$VENDOR_DIR/NodeMobile.xcframework" ]; then
  echo "vendor/NodeMobile.xcframework already present — skipping download."
  exit 0
fi

if [ -n "${NODE_MOBILE_DIR:-}" ] && [ -d "$NODE_MOBILE_DIR/NodeMobile.xcframework" ]; then
  echo "Using NODE_MOBILE_DIR=$NODE_MOBILE_DIR"
  cp -R "$NODE_MOBILE_DIR/NodeMobile.xcframework" "$VENDOR_DIR/NodeMobile.xcframework"
  if [ -f "$NODE_MOBILE_DIR/LICENSE.node" ]; then
    cp "$NODE_MOBILE_DIR/LICENSE.node" "$VENDOR_DIR/LICENSE.node"
  fi
  exit 0
fi

FILE="$CACHE/$ASSET"
if [ -f "$FILE" ]; then
  echo "Using cached $FILE"
else
  echo "Downloading $BASE/$ASSET ..."
  curl -fsSL "$BASE/$ASSET" -o "$FILE"
fi

# SHA-256 check (shasum on macOS, sha256sum on Linux).
ACTUAL="$(shasum -a 256 "$FILE" 2>/dev/null | cut -d' ' -f1 || sha256sum "$FILE" | cut -d' ' -f1)"
if [ "$ACTUAL" != "$ARCHIVE_SHA256" ]; then
  echo "::error::SHA-256 mismatch for $ASSET (got $ACTUAL, expected $ARCHIVE_SHA256)."
  echo "The release asset changed — update VERSION/RELEASE/ARCHIVE_SHA256 in Scripts/fetch-node-mobile.sh."
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unzip -q "$FILE" "NodeMobile.xcframework/*" -d "$TMP"
XCFW="$TMP/NodeMobile.xcframework"
if [ ! -d "$XCFW" ] || [ ! -f "$XCFW/Info.plist" ]; then
  echo "::error::Archive did not contain a usable NodeMobile.xcframework."
  unzip -l "$FILE" | head -20
  exit 1
fi

rm -rf "$VENDOR_DIR/NodeMobile.xcframework"
cp -R "$XCFW" "$VENDOR_DIR/NodeMobile.xcframework"

# LICENSE -> vendor/LICENSE.node (kept for attribution; not a build input).
if unzip -p "$FILE" LICENSE > "$VENDOR_DIR/LICENSE.node" 2>/dev/null; then
  LICENSE_ACTUAL="$(shasum -a 256 "$VENDOR_DIR/LICENSE.node" 2>/dev/null | cut -d' ' -f1 || sha256sum "$VENDOR_DIR/LICENSE.node" | cut -d' ' -f1)"
  if [ "$LICENSE_ACTUAL" != "$LICENSE_SHA256" ]; then
    echo "::warning::LICENSE SHA-256 differs from the expected value (license text changed?) — continuing."
  fi
else
  echo "::warning::No LICENSE file in the archive; LICENSE.node not written."
fi

echo "NodeMobile.xcframework ready at $VENDOR_DIR/NodeMobile.xcframework"
ls "$VENDOR_DIR/NodeMobile.xcframework"
