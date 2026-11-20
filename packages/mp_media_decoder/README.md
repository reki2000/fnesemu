# mp_media_decoder

Decodes H.264 video and ATRAC3plus audio for emulators that play the movies and music of their media. H.264 goes through the decoder of the operating system, and ATRAC3plus through a shared libavcodec that the package loads at run time.

`MediaDecoders.open()` finds the decoders of the platform. `openH264()` returns a `VideoDecoder` that takes one access unit at a time as an Annex B byte stream and returns the latest finished picture as RGBA pixels. A decoder may hold pictures back for reordering, so the picture can belong to an earlier unit. `openAtrac3plus()` returns an `AudioDecoder` that takes one frame of the block size at a time and returns interleaved 16-bit samples. A codec without a decoder on the platform returns null, and the caller plays the media without a picture or sound.

## Backends

| Platform | H.264 | ATRAC3plus |
|---|---|---|
| Linux | libavcodec (no decoder of the system) | libavcodec |
| Android | MediaCodec (not yet) | libavcodec |
| macOS, iOS | VideoToolbox (not yet) | libavcodec |
| Windows | Media Foundation (not yet) | libavcodec |
| Web | none yet | none yet |

## libavcodec

The package does not link libavcodec. It opens the shared library by name (`libavcodec.so.61` to `.58` with the libavutil of the same release on Linux, `avcodec-61.dll` and so on on Windows, `libavcodec.61.dylib` and so on on Apple platforms), so the library stays separate and replaceable, as the LGPL asks of a program that uses it. The bindings use only functions, the AVOptions of the codec context (`ar`, `ch_layout` or `ac`, `block_align`, `threads`) and the leading fields of `AVPacket` and `AVFrame`, which keep their layout across the major versions 58 to 61. Linux distributions ship the library; the other platforms need a build of it next to the app, which the package does not provide yet.

H.264 pictures come out as RGBA through the BT.601 matrix, in video range, or full range for the `yuvj420p` format. The decoder runs with one thread, so it adds no frame-threading delay.

## Example

`example/` is a Flutter app that plays a file given by its path: an H.264 Annex B stream (`.h264`), the video of a PSP movie (`.pmf`), or an ATRAC3plus RIFF WAVE file (`.at3`).

## Tests

`dart test` decodes a small H.264 stream of the ffmpeg test pattern and opens an ATRAC3plus decoder. The tests skip a codec that has no decoder on the machine. `cd example && flutter test` checks the access unit splitting and the PSMF reader of the example.
