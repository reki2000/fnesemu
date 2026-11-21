// Bindings of src/videotoolbox.c, built by hook/build.dart for macOS and
// iOS, and the H.264 decoder on top of them.
// ignore_for_file: non_constant_identifier_names
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'types.dart';

final class MmdVt extends Opaque {}

@Native<Pointer<MmdVt> Function()>()
external Pointer<MmdVt> mmd_vt_open();

@Native<Int32 Function(Pointer<MmdVt>, Pointer<Uint8>, Int32)>()
external int mmd_vt_decode(Pointer<MmdVt> vt, Pointer<Uint8> data, int length);

@Native<Int32 Function(Pointer<MmdVt>, Pointer<Int32>, Pointer<Int32>)>(
  isLeaf: true,
)
external int mmd_vt_size(
  Pointer<MmdVt> vt,
  Pointer<Int32> width,
  Pointer<Int32> height,
);

@Native<Int32 Function(Pointer<MmdVt>, Pointer<Uint8>, Int32)>()
external int mmd_vt_take(Pointer<MmdVt> vt, Pointer<Uint8> rgba, int capacity);

@Native<Void Function(Pointer<MmdVt>)>()
external void mmd_vt_flush(Pointer<MmdVt> vt);

@Native<Void Function(Pointer<MmdVt>)>()
external void mmd_vt_close(Pointer<MmdVt> vt);

/// The H.264 decoder of VideoToolbox.
abstract final class VideoToolbox {
  /// An H.264 decoder; null when the shim is missing.
  static VideoDecoder? openH264() {
    try {
      final vt = mmd_vt_open();
      return vt == nullptr ? null : _VtVideoDecoder(vt);
    } on ArgumentError {
      // the shim was not built for this platform
      return null;
    }
  }
}

class _VtVideoDecoder implements VideoDecoder {
  _VtVideoDecoder(this._vt);

  Pointer<MmdVt> _vt;
  final _width = calloc<Int32>();
  final _height = calloc<Int32>();
  Pointer<Uint8> _unit = nullptr;
  int _unitCapacity = 0;
  Pointer<Uint8> _pixels = nullptr;
  int _pixelCapacity = 0;
  DecodedPicture? _latest;

  @override
  DecodedPicture? decode(Uint8List unit) {
    if (_vt == nullptr || unit.isEmpty) return _latest;
    if (unit.length > _unitCapacity) {
      if (_unit != nullptr) calloc.free(_unit);
      _unitCapacity = unit.length;
      _unit = calloc<Uint8>(_unitCapacity);
    }
    _unit.asTypedList(unit.length).setAll(0, unit);
    mmd_vt_decode(_vt, _unit, unit.length);
    if (mmd_vt_size(_vt, _width, _height) == 0) return _latest;
    final width = _width.value, height = _height.value;
    final size = width * height * 4;
    if (size <= 0) return _latest;
    if (size > _pixelCapacity) {
      if (_pixels != nullptr) calloc.free(_pixels);
      _pixelCapacity = size;
      _pixels = calloc<Uint8>(size);
    }
    if (mmd_vt_take(_vt, _pixels, _pixelCapacity) != 0) {
      _latest = DecodedPicture(
        width,
        height,
        Uint32List.fromList(_pixels.cast<Uint32>().asTypedList(width * height)),
      );
    }
    return _latest;
  }

  @override
  void flush() {
    if (_vt != nullptr) mmd_vt_flush(_vt);
  }

  @override
  void close() {
    if (_vt == nullptr) return;
    mmd_vt_close(_vt);
    _vt = nullptr;
    calloc.free(_width);
    calloc.free(_height);
    if (_unit != nullptr) calloc.free(_unit);
    if (_pixels != nullptr) calloc.free(_pixels);
  }
}
