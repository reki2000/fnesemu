import 'dart:typed_data';

/// A decoded picture: [width] by [height] pixels, one RGBA pixel per element
/// (R in the low byte), rows [width] elements apart.
class DecodedPicture {
  const DecodedPicture(this.width, this.height, this.pixels);

  final int width;
  final int height;
  final Uint32List pixels;
}

/// A video stream being decoded.
abstract interface class VideoDecoder {
  /// Passes one access unit and returns the latest finished picture, which
  /// may belong to an earlier unit; null while there is none.
  DecodedPicture? decode(Uint8List unit);

  /// Drops the units in flight.
  void flush();

  void close();
}

/// An audio stream being decoded.
abstract interface class AudioDecoder {
  /// Decodes one frame into interleaved 16-bit samples; null when the
  /// frame gives none.
  Int16List? decode(Uint8List frame);

  /// Drops the state of the frames so far.
  void flush();

  void close();
}
