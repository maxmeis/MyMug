#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

rm -rf build/MyMug.app
mkdir -p build/MyMug.app/Contents/MacOS

swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos14 \
  main.swift -o build/MyMug.app/Contents/MacOS/MyMug \
  -framework IOKit -framework Carbon

cp Info.plist build/MyMug.app/Contents/

SIGN_ID="${SIGN_ID:-0210FF5FC1EF0F6117B1D80CD509BB37D5B6B051}"
if security find-identity -v -p codesigning | grep -q "$SIGN_ID"; then
  codesign --force --sign "$SIGN_ID" build/MyMug.app
else
  echo "warning: identity $SIGN_ID not found; signing ad-hoc (-)"
  codesign --force --sign - build/MyMug.app
fi

echo "Built: $(pwd)/build/MyMug.app"
