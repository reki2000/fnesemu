import 'dart:js_interop';
import 'dart:typed_data';

/// Returns [pixels] backed by a JS typed array.
///
/// The Wasm engine copies a JS-backed list in bulk, but copies a byte view of
/// a Wasm list element by element. Cores expose `Uint32List` frames as byte
/// views, so the frame is converted through its 32-bit list in a single copy.
Uint8List hostPixels(Uint8List pixels) {
  if (pixels.offsetInBytes % 4 != 0 || pixels.length % 4 != 0) return pixels;
  return pixels.buffer
      .asUint32List(pixels.offsetInBytes, pixels.length ~/ 4)
      .toJS
      .toDart
      .buffer
      .asUint8List();
}
