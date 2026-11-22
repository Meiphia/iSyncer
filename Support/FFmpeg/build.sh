#!/bin/bash
# Build a standalone FFmpeg helper from an official source archive.
set -euo pipefail
if [[ $# != 2 ]]; then
  echo "Usage: $0 ffmpeg-VERSION.tar.xz output-directory" >&2
  exit 2
fi
archive="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
mkdir -p "$2"
destination="$(cd "$2" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
tar -xJf "$archive" --strip-components=1 -C "$work"
cd "$work"
export MACOSX_DEPLOYMENT_TARGET=14.0
flags=(--disable-autodetect --disable-gpl --disable-nonfree --disable-version3
       --disable-shared --enable-static --disable-doc --disable-debug
       --disable-ffplay --disable-ffprobe --disable-network)
./configure "${flags[@]}"
make -j "${FFMPEG_BUILD_JOBS:-8}" ffmpeg
install -m 755 ffmpeg "$destination/ffmpeg"
install -m 644 COPYING.LGPLv2.1 LICENSE.md "$destination/"
install -m 644 "$archive" "$destination/ffmpeg-source.tar.xz"
printf '%s\n' "${flags[*]}" > "$destination/configure-flags.txt"
