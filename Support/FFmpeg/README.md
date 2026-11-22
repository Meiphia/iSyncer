# Bundled FFmpeg

iSyncer launches FFmpeg as a separate executable. It prefers the signed helper in the app bundle and can also use a system installation when the helper is absent.

To reproduce the Apple silicon helper, download the unmodified [FFmpeg 8.0.1 release archive](https://ffmpeg.org/releases/ffmpeg-8.0.1.tar.xz) and run these commands from the project root on an Apple silicon Mac with Xcode command-line tools:

```sh
Support/FFmpeg/build.sh ffmpeg-8.0.1.tar.xz build/ffmpeg
./build.sh
```

The archive used for the helper has SHA-256 digest `05ee0b03119b45c0bdb4df654b96802e909e0a752f72e4fe3794f487229e5a41`.

The helper uses FFmpeg under LGPL 2.1 or later. Its configure options, build script, license notices, and corresponding upstream source archive are included in `iSyncer.app/Contents/Resources/FFmpeg`. See [FFmpeg’s license page](https://ffmpeg.org/legal.html).
