import 'dart:typed_data';

/// Returns the bytes of [pixels] without copying. Native decoders read Dart
/// lists directly.
Uint8List pixelBytes(Uint32List pixels) =>
    pixels.buffer.asUint8List(pixels.offsetInBytes, pixels.lengthInBytes);
