#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output_directory="${1:-build}"
mkdir -p .build "$output_directory"
stage=$(mktemp -d "$PWD/.build/package.XXXXXX")
trap 'rm -rf "$stage"' EXIT
bundle="$stage/AirPlay Input.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp Resources/Info.plist "$bundle/Contents/Info.plist"
cp -R Resources/*.lproj "$bundle/Contents/Resources/"
for arch in arm64 x86_64; do
    xcrun swiftc -O -swift-version 5 -target "${arch}-apple-macos13.0" \
        -module-cache-path "$PWD/.build/ModuleCache" Sources/*.swift -o "$stage/$arch"
done
xcrun lipo -create "$stage/arm64" "$stage/x86_64" -output "$bundle/Contents/MacOS/AirPlayInput"
/usr/bin/codesign --force --options runtime --timestamp=none --sign "${SIGN_IDENTITY:--}" "$bundle"
/usr/bin/codesign --verify --strict --all-architectures "$bundle"
dest="$(cd "$output_directory" && pwd)/AirPlay Input.app"
if [[ -e "$dest" && "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$dest/Contents/Info.plist")" != local.airplay-input.receiver ]]; then
    echo "Another app already exists at the output path." >&2
    exit 1
fi
/usr/bin/ditto "$bundle" "$dest"
/usr/bin/codesign --verify --strict --all-architectures "$dest"
echo "$dest"
