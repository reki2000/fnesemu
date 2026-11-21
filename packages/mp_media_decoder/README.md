# mp_media_decoder

Decodes H.264 video and ATRAC3plus audio for emulators that play the movies and music of their media. H.264 goes through the decoder of the operating system, and ATRAC3plus through a shared libavcodec under the LGPL that the package bundles and loads at run time.

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

Android decodes H.264 with MediaCodec through the C API of the NDK (`libmediandk.so`), in synchronous mode with byte buffers. It uses the decoder that the device picks for the type, and the software decoders of the Android Open Source Project (`c2.android.avc.decoder`, then `OMX.google.h264.decoder`) on a device that picks none. A software decoder holds several pictures back when the stream does not state its reordering depth, which a hardware decoder does not. The planar color formats and the flexible format of the software decoders are read as I420, and the semi-planar formats and the other formats of the vendors as NV12, which may be wrong for some devices. The codec decodes on its own threads, and `decode()` waits for the picture as the GStreamer decoder does. It has run on a Pixel 7 with its hardware decoder.

## VideoToolbox

macOS and iOS decode H.264 with a VideoToolbox decompression session behind a small C shim (`src/videotoolbox.c`), which `hook/build.dart` builds for those platforms only. VideoToolbox gives its pictures to a callback that may run on a thread of its own, which Dart code cannot serve, so the shim keeps the latest picture under a lock. It turns the Annex B units into the length-prefixed form of the format description made from the parameter sets, decodes synchronously with temporal processing so that the pictures come in the order of display, and copies the BGRA picture out as RGBA. This backend has not run on a device yet.

## libavcodec

The package does not link libavcodec. It loads it at run time, so the library stays separate and replaceable, as the LGPL asks of a program that uses it, and it tries these in order:

1. the libraries in the directory named by `MP_MEDIA_DECODER_LIBAV_DIR`;
2. `mmd_libav`, the library that `hook/build.dart` bundles;
3. the libraries in the directory of the executable, its `lib` and the `Frameworks` of a macOS bundle;
4. the libraries of the system by their file names.

In a directory, the package looks for `mmd_libav` under the file name of the platform (`libmmd_libav.so`, `mmd_libav.dll`, `libmmd_libav.dylib`) or of a release asset (`mmd_libav-linux-x64.so` and so on), then for a libavcodec with the libavutil of the same release (`libavcodec.so.61` to `.58` on Linux, `avcodec-61.dll` and so on on Windows, `libavcodec.61.dylib` and so on on Apple platforms).

Only a build under the LGPL is used: the package checks `avcodec_license()` and `avutil_license()` and skips any other build. Linux distributions usually ship a GPL build, which the package therefore does not use.

`tool/build_libav_atrac.sh TARGET OUT_DIR` builds `mmd_libav` for one target of the app (`linux-x64`, `android-arm64`, `windows-x64`, `macos-arm64`, `ios-arm64`, `iossim-arm64` and so on). It configures a pinned FFmpeg release with only the ATRAC3 and ATRAC3plus decoders, without GPL, version 3 or nonfree parts, without system libraries and without assembly, and checks the SHA-256 of the source tarball. It then links the static libavcodec and libavutil into one shared library that exports only the functions that the package calls and needs only the C library and the threads of the system.

The `Release libav-atrac` workflow (`.github/workflows/libav-atrac.yaml`) runs the script for every target when a `libav-atrac-<FFmpeg version>-<build>` tag is pushed. It publishes the libraries, their SHA-256, the FFmpeg source tarball, the text of the LGPL and the script as a GitHub Release. The build hook downloads the library of the target from the release that `_release` names, checks it against the SHA-256 in `_sha256`, keeps it in the shared output directory of the hooks, and bundles it as a code asset. A new build of the library takes a new tag and an update of both constants. The user-defines of the package change the bundling:

```yaml
hooks:
  user_defines:
    mp_media_decoder:
      libav_file: path/to/mmd_libav-linux-x64.so # bundle this build instead
      bundle_libav: false # bundle no library
```

`dart build cli` does not bundle the native assets of a dev dependency, so a command-line tool of a package that has this one as a dev dependency finds the library through `MP_MEDIA_DECODER_LIBAV_DIR` or the other locations instead.

The bindings use only functions, the AVOptions of the codec context (`ar`, `ch_layout` or `ac`, `block_align`) and the leading fields of `AVPacket` and `AVFrame`, which keep their layout across the major versions 58 to 61.

## Example

`example/` is a Flutter app that plays a file given by its path: an H.264 Annex B stream (`.h264`), the video of a PSP movie (`.pmf`), or an ATRAC3plus RIFF WAVE file (`.at3`).

## Tests

`dart test` decodes a small (64x48) H.264 stream of the ffmpeg test pattern and opens an ATRAC3plus decoder. The build hook bundles `mmd_libav` for the tests too; set `MP_MEDIA_DECODER_LIBAV_DIR` to the output directory of `tool/build_libav_atrac.sh` to test another build. The tests skip a codec that has no decoder on the machine. `cd example && flutter test` checks the access unit splitting and the PSMF reader of the example.
