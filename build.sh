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
# Include the standalone helper when built from the accompanying upstream sources.
ffmpeg_bundle="${ISYNCER_FFMPEG_BUNDLE:-$PWD/build/ffmpeg}"
if [[ -x "$ffmpeg_bundle/ffmpeg" ]]; then
    install -m 755 "$ffmpeg_bundle/ffmpeg" "$app/Contents/MacOS/ffmpeg"
    notices="$app/Contents/Resources/FFmpeg"
    mkdir -p "$notices"
    install -m 644 "$ffmpeg_bundle"/{COPYING.LGPLv2.1,LICENSE.md,configure-flags.txt,ffmpeg-source.tar.xz} "$notices/"
    install -m 644 Support/FFmpeg/build.sh "$notices/build-ffmpeg.sh"
    codesign --force --sign - "$app/Contents/MacOS/ffmpeg"
fi
codesign --force --sign - "$app"
codesign --verify --strict "$app"
rm -rf build/iSyncer.app
mv "$app" build/iSyncer.app
echo "$PWD/build/iSyncer.app"
