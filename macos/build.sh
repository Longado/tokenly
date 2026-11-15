#!/bin/bash
# Build Tokenly.app (universal, ad-hoc signed) with the Xcode command line tools.
set -euo pipefail
cd "$(dirname "$0")"
APP=build/Tokenly.app
rm -rf build
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/"
for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos13" main.swift -o "build/Tokenly-$arch"
done
lipo -create build/Tokenly-arm64 build/Tokenly-x86_64 -output "$APP/Contents/MacOS/Tokenly"
rm build/Tokenly-arm64 build/Tokenly-x86_64
codesign --force --sign - "$APP"
ditto -c -k --keepParent "$APP" build/Tokenly.zip
echo "Built $APP and build/Tokenly.zip"
