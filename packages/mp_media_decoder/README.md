# mp_media_decoder

Decodes H.264 video and ATRAC3plus audio for emulators that play the movies and music of their media. H.264 goes through the decoder of the operating system, and ATRAC3plus through a shared libavcodec under the LGPL that the package loads at run time.

`MediaDecoders.open()` finds the decoders of the platform. `openH264()` returns a `VideoDecoder` that takes one access unit at a time as an Annex B byte stream and returns the latest finished picture as RGBA pixels. A decoder may hold pictures back for reordering, so the picture can belong to an earlier unit. `openAtrac3plus()` returns an `AudioDecoder` that takes one frame of the block size at a time and returns interleaved 16-bit samples. A codec without a decoder on the platform returns null, and the caller plays the media without a picture or sound.

## Backends

| Platform | H.264 | ATRAC3plus |
|---|---|---|
| Linux | GStreamer | libavcodec |
| Android | MediaCodec | libavcodec |
| macOS, iOS | VideoToolbox | libavcodec |
| Windows | Media Foundation | libavcodec |
| Web | none yet | none yet |

## GStreamer

Linux has no H.264 decoder of its own, so the package uses GStreamer, the media framework of the desktop. It opens `libgstreamer-1.0.so.0` and `libgstapp-1.0.so.0` (LGPL) at run time and builds the pipeline `appsrc ! <decoder> ! videoconvert ! appsink` with RGBA output. The decoder is the H.264 decoder of the highest rank among the plugins installed on the system, such as `gstreamer1.0-libav` or `gstreamer1.0-plugins-bad` (openh264) on Debian and Ubuntu; without one, H.264 stays unsupported. A decoder with the `max-threads` property gets one thread, so that frame threading holds no pictures back. The package does not ship a plugin, so the license and the patent terms of the decoder are those of the system.

The pipeline decodes on its own threads. `decode()` waits up to 30 ms for the picture of the unit it was given, and counts a wait that runs out as one more unit that the decoder holds back for reordering, so later calls do not wait for it.

## Media Foundation

Windows decodes H.264 with the H.264 decoder transform of Media Foundation (`CLSID_MSH264DecoderMFT`), driven through its COM interfaces from Dart. The transform decodes on the calling thread. It runs in low latency mode, so that each picture comes out as soon as the order of display allows, and gives NV12 pictures, which the package converts to RGBA. The transform does not decode pictures below 48x48. The N editions of Windows have no Media Foundation unless the media feature pack is installed, and H.264 stays unsupported there.

## MediaCodec

Android decodes H.264 with MediaCodec through the C API of the NDK (`libmediandk.so`), in synchronous mode with byte buffers. It prefers the software decoders of the Android Open Source Project (`c2.android.avc.decoder`, then `OMX.google.h264.decoder`), whose byte buffers hold planar YUV 4:2:0, and falls back to the decoder that the device picks for the type. For that decoder, the semi-planar color formats are read as NV12 and the others as planar, which may be wrong for the vendor formats of some devices. The codec decodes on its own threads, and `decode()` waits for the picture as the GStreamer decoder does. This backend has not run on a device yet.

## VideoToolbox

macOS and iOS decode H.264 with a VideoToolbox decompression session behind a small C shim (`src/videotoolbox.c`), which `hook/build.dart` builds for those platforms only. VideoToolbox gives its pictures to a callback that may run on a thread of its own, which Dart code cannot serve, so the shim keeps the latest picture under a lock. It turns the Annex B units into the length-prefixed form of the format description made from the parameter sets, decodes synchronously with temporal processing so that the pictures come in the order of display, and copies the BGRA picture out as RGBA. This backend has not run on a device yet.

## libavcodec

The package does not link libavcodec. It opens the shared library by its file name (`libavcodec.so.61` to `.58` with the libavutil of the same release on Linux, `avcodec-61.dll` and so on on Windows, `libavcodec.61.dylib` and so on on Apple platforms), so the library stays separate and replaceable, as the LGPL asks of a program that uses it. It searches the directory named by `MP_MEDIA_DECODER_LIBAV_DIR`, the directory of the executable, its `lib` and the `Frameworks` of a macOS bundle before the names of the system.

Only a build under the LGPL is used: the package checks `avcodec_license()` and `avutil_license()` and skips any other build. Linux distributions usually ship a GPL build, which the package therefore does not use.

`tool/build_libav_atrac.sh` builds the library that the app ships: a pinned FFmpeg release configured with only the ATRAC3 and ATRAC3plus decoders, without GPL, version 3 or nonfree parts, and without system libraries. It checks the SHA-256 of the source tarball and puts the license text and the tarball beside the libraries, so that the source of the shipped build can be offered with it.

The bindings use only functions, the AVOptions of the codec context (`ar`, `ch_layout` or `ac`, `block_align`) and the leading fields of `AVPacket` and `AVFrame`, which keep their layout across the major versions 58 to 61.

## Example

`example/` is a Flutter app that plays a file given by its path: an H.264 Annex B stream (`.h264`), the video of a PSP movie (`.pmf`), or an ATRAC3plus RIFF WAVE file (`.at3`).

## Tests

`dart test` decodes a small (64x48) H.264 stream of the ffmpeg test pattern and opens an ATRAC3plus decoder. Set `MP_MEDIA_DECODER_LIBAV_DIR` to the output directory of `tool/build_libav_atrac.sh` to test the ATRAC3plus decoder with that build. The tests skip a codec that has no decoder on the machine. `cd example && flutter test` checks the access unit splitting and the PSMF reader of the example.
