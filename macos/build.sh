#!/bin/bash
# Build TokenMeter.app (universal, ad-hoc signed) with the Xcode command line tools.
set -euo pipefail
cd "$(dirname "$0")"
APP=build/TokenMeter.app
rm -rf build
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/"
for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos13" main.swift -o "build/TokenMeter-$arch"
done
lipo -create build/TokenMeter-arm64 build/TokenMeter-x86_64 -output "$APP/Contents/MacOS/TokenMeter"
rm build/TokenMeter-arm64 build/TokenMeter-x86_64
codesign --force --sign - "$APP"
ditto -c -k --keepParent "$APP" build/TokenMeter.zip
echo "Built $APP and build/TokenMeter.zip"
