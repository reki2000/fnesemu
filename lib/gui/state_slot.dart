import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:fnesemu_core/app_api.dart';

/// The metadata of one saved state slot, read from the header of its blob
/// without decompressing the state itself.
class StateSlotInfo {
  final int slot;

  /// when the state was saved, in local time
  final DateTime savedAt;

  /// a PNG image of the game screen at the save, if a frame was available
  final Uint8List? thumbnail;

  const StateSlotInfo(
      {required this.slot, required this.savedAt, this.thumbnail});
}

/// The binary form of a saved state in the blob store.
///
/// The layout lets the slot list read the save time and the thumbnail
/// without decompressing the state. Multi-byte values are big endian:
///
///   bytes 0..3   the magic "FNST"
///   byte  4      the format version (1)
///   bytes 5..12  the save time in milliseconds since the epoch
///   bytes 13..16 the length of the thumbnail in bytes (0 if there is none)
///   bytes 17..   the thumbnail as a PNG image, then the state compressed
///                with gzip
class StateSlotBlob {
  static const _magic = [0x46, 0x4e, 0x53, 0x54]; // "FNST"
  static const _version = 1;
  static const headerSize = 17;

  static Uint8List build(Uint8List state,
      {Uint8List? thumbnail, required DateTime savedAt}) {
    final compressed = GZipEncoder().encode(state);
    final thumb = thumbnail ?? Uint8List(0);
    final blob = Uint8List(headerSize + thumb.length + compressed.length);
    final header = ByteData.sublistView(blob, 0, headerSize);
    blob.setAll(0, _magic);
    blob[4] = _version;
    header.setUint64(5, savedAt.millisecondsSinceEpoch);
    header.setUint32(13, thumb.length);
    blob.setAll(headerSize, thumb);
    blob.setAll(headerSize + thumb.length, compressed);
    return blob;
  }

  /// parses and validates the header of [blob], the blob of slot [slot]
  static StateSlotInfo header(Uint8List blob, int slot) {
    final thumbnailLength = _thumbnailLength(blob);
    return StateSlotInfo(
        slot: slot,
        savedAt: DateTime.fromMillisecondsSinceEpoch(
            ByteData.sublistView(blob, 0, headerSize).getUint64(5)),
        thumbnail: thumbnailLength == 0
            ? null
            : Uint8List.sublistView(
                blob, headerSize, headerSize + thumbnailLength));
  }

  /// the state saved in [blob], decompressed.
  /// throws a FormatException if the blob is not a state slot blob or its
  /// compressed state is corrupt.
  static Uint8List state(Uint8List blob) {
    final thumbnailLength = _thumbnailLength(blob);
    try {
      return GZipDecoder().decodeBytes(
          Uint8List.sublistView(blob, headerSize + thumbnailLength),
          verify: true);
    } catch (e) {
      throw FormatException('the saved state is corrupt: $e');
    }
  }

  static int _thumbnailLength(Uint8List blob) {
    if (blob.length < headerSize ||
        blob[0] != _magic[0] ||
        blob[1] != _magic[1] ||
        blob[2] != _magic[2] ||
        blob[3] != _magic[3]) {
      throw const FormatException('not a saved state');
    }
    if (blob[4] != _version) {
      throw FormatException('unsupported saved state version: ${blob[4]}');
    }
    final length = ByteData.sublistView(blob, 0, headerSize).getUint32(13);
    if (headerSize + length > blob.length) {
      throw const FormatException('the saved state is truncated');
    }
    return length;
  }
}

/// Scales [frame] down so that no side exceeds [maxDimension] pixels and
/// encodes it as a PNG image, for the thumbnail of a saved state.
/// Returns null when the frame has no pixels.
Future<Uint8List?> stateThumbnail(ImageBuffer frame,
    {int maxDimension = 160}) async {
  if (frame.width <= 0 || frame.height <= 0 || frame.buffer.isEmpty) {
    return null;
  }
  final scale = maxDimension / max(frame.width, frame.height);
  final width =
      scale >= 1 ? frame.width : max(1, (frame.width * scale).round());
  final height =
      scale >= 1 ? frame.height : max(1, (frame.height * scale).round());
  final pixels = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    final sourceY = y * frame.height ~/ height;
    for (var x = 0; x < width; x++) {
      final source = frame.buffer[sourceY * frame.width +
          (x * frame.width ~/ width)];
      final i = (y * width + x) * 4;
      // the pixels are in the memory order R, G, B, A
      pixels[i] = source & 0xff;
      pixels[i + 1] = (source >> 8) & 0xff;
      pixels[i + 2] = (source >> 16) & 0xff;
      pixels[i + 3] = (source >> 24) & 0xff;
    }
  }
  final completer = Completer<Uint8List?>();
  ui.decodeImageFromPixels(pixels, width, height, ui.PixelFormat.rgba8888,
      (image) async {
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      completer.complete(data?.buffer.asUint8List());
    } catch (e) {
      completer.completeError(e);
    } finally {
      image.dispose();
    }
  });
  return completer.future;
}
