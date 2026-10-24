import 'dart:js_interop';
import 'dart:typed_data';

/// Returns the bytes of [pixels] backed by a JS typed array.
///
/// The Wasm engine copies a JS-backed list in bulk, but copies a byte view of
/// a Wasm list element by element. A `Uint32List` converts to JS in a single
/// copy, and is used as is when it is already backed by JS.
Uint8List pixelBytes(Uint32List pixels) {
  final js = pixels.toJS.toDart;
  return js.buffer.asUint8List(js.offsetInBytes, js.lengthInBytes);
}
