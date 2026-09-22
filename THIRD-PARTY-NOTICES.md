# Third-party notices

The source code in this repository is MIT licensed (see [LICENSE](LICENSE)).

The **released application bundle** additionally contains ffmpeg and the libraries it depends on,
in `Contents/MacOS/ffmpeg` and `Contents/Frameworks/`. They are unmodified builds produced by the
[Homebrew](https://brew.sh) `ffmpeg` formula and are covered by their own licenses, listed below.

## ffmpeg 9.0.2 — GPL v3

The bundled ffmpeg is built with `--enable-gpl --enable-version3`, which places it under the
**GNU General Public License v3**. A copy of that license is included at
[docs/ffmpeg-COPYING.GPLv3](docs/ffmpeg-COPYING.GPLv3).

- Project and source code: <https://ffmpeg.org/download.html> and <https://github.com/FFmpeg/FFmpeg>
- Exact source for the bundled build: ffmpeg 9.0.2, <https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz>
- Build recipe used: the Homebrew formula <https://github.com/Homebrew/homebrew-core/blob/master/Formula/f/ffmpeg.rb>

The binary can be reproduced on any Mac with `brew install ffmpeg`. Run
`"File Utilities.app/Contents/MacOS/ffmpeg" -version` to see the exact version and build options
of the copy you received.

File Utilities runs ffmpeg as a separate command-line program; it does not link against it.

## Bundled libraries

| Library | License | Source |
|---|---|---|
| ffmpeg (libavcodec, libavdevice, libavfilter, libavformat, libavutil, libswresample, libswscale) | GPL v3 (as built) | <https://ffmpeg.org> |
| x264 | GPL v2 or later | <https://www.videolan.org/developers/x264.html> |
| x265 | GPL v2 or later | <https://www.videolan.org/developers/x265.html> |
| SVT-AV1 (libSvtAv1Enc) | BSD 3-Clause / AOM Patent License | <https://gitlab.com/AOMediaCodec/SVT-AV1> |
| dav1d | BSD 2-Clause | <https://code.videolan.org/videolan/dav1d> |
| libvpx | BSD 3-Clause | <https://chromium.googlesource.com/webm/libvpx> |
| LAME (libmp3lame) | LGPL v2 or later | <https://lame.sourceforge.io> |
| mpg123 | LGPL v2.1 | <https://www.mpg123.de> |
| Opus | BSD 3-Clause | <https://opus-codec.org> |
| libvmaf | BSD 2-Clause Patent | <https://github.com/Netflix/vmaf> |
| OpenSSL (libssl, libcrypto) | Apache License 2.0 | <https://www.openssl.org> |
| xz (liblzma) | 0BSD / public domain | <https://tukaani.org/xz/> |

Each library's full license text ships inside its own source distribution, linked above.
If you received the app and want the corresponding source for any GPL component, the links above
provide it; you can also open an issue on this repository.
