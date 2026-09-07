# VP9Encoder

Transparent VP9/WebM encoding for Telegram video stickers, done on the phone.

- `libvpx.xcframework` — libvpx built for iOS devices and the simulator by
  `scripts/build-libvpx.sh` from a pinned upstream tag. VP9 encoder and decoder only; VP8, the
  examples, tools, docs, unit tests, libwebm and libyuv are switched off. libvpx is BSD-licensed
  (see `ThirdPartyNotices/libvpx/`). Nothing GPL or "nonfree" is built, and FFmpeg is not used at
  all: the WebM container is written by `WebMWriter.swift`, a few hundred lines of EBML.
- `Sources/CVPX` — a C shim over the parts of the libvpx API Swift cannot call directly, plus the
  public headers the shim compiles against (copied from the same source tree the binary came from).
- `Sources/VP9Encoder` — the Swift API. `VP9WebMEncoder` takes RGBA frames and returns a WebM
  whose track carries alpha the way FFmpeg's `yuva420p` output does: a second VP9 stream in each
  block's `BlockAdditional`. `WebMReader` and `VP9Decoder` read one back so tests can check the
  encoder against something other than itself.

## Reproducing the binary

```sh
scripts/build-libvpx.sh
```

Clones `libvpx` at the tag in the script, builds three static slices (device arm64, simulator
arm64, simulator x86_64) and assembles the xcframework. `ThirdPartyNotices/libvpx/BUILD-INFO.txt`
records the commit, the toolchain and every configure flag of the last build. Requires Xcode and
`perl`; no assembler is needed (the x86_64 slice disables its SIMD paths rather than depend on
yasm).
