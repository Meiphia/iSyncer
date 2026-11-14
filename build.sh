#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p .build/module-cache build
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$PWD/.build/module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$PWD/.build/module-cache}"
swift build -c release "$@"
bin_dir=$(swift build -c release "$@" --show-bin-path)

staging=$(mktemp -d "$PWD/build/.bundle.XXXXXX")
trap 'rm -rf "$staging"' EXIT
app="$staging/iSyncer.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
install -m 755 "$bin_dir/iSyncer" "$app/Contents/MacOS/iSyncer"
install -m 644 Resources/Info.plist "$app/Contents/Info.plist"
install -m 644 Resources/iSyncer.icns "$app/Contents/Resources/iSyncer.icns"
install -m 644 Resources/Player.png "$app/Contents/Resources/Player.png"
install -m 644 Resources/TMDB.svg "$app/Contents/Resources/TMDB.svg"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
rm -rf build/iSyncer.app
mv "$app" build/iSyncer.app
echo "$PWD/build/iSyncer.app"
