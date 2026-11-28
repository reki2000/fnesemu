import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'types.dart';
import 'yuv.dart';

// The H.264 decoder of Android: MediaCodec through the C API of the NDK
// (libmediandk.so), in synchronous mode with byte buffers. The codec
// decodes on its own threads, so a decode waits a little for the picture of
// the unit it was given. The pictures come out as YUV 4:2:0 and turn into
// RGBA here.
//
// The functions, the structures and the codes follow NdkMediaCodec.h and
// NdkMediaFormat.h of the NDK; the format keys and the color formats are
// those of the public MediaFormat and MediaCodecInfo.CodecCapabilities.

typedef _CreateC = Pointer<Void> Function(Pointer<Utf8>);
typedef _Create = Pointer<Void> Function(Pointer<Utf8>);
typedef _StatusC = Int32 Function(Pointer<Void>);
typedef _Status = int Function(Pointer<Void>);
typedef _ConfigureC =
    Int32 Function(
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Void>,
      Uint32,
    );
typedef _Configure =
    int Function(
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Void>,
      int,
    );
typedef _BufferC = Pointer<Uint8> Function(Pointer<Void>, Size, Pointer<Size>);
typedef _Buffer = Pointer<Uint8> Function(Pointer<Void>, int, Pointer<Size>);
typedef _DequeueInputC = IntPtr Function(Pointer<Void>, Int64);
typedef _DequeueInput = int Function(Pointer<Void>, int);
typedef _QueueInputC =
    Int32 Function(Pointer<Void>, Size, IntPtr, Size, Uint64, Uint32);
typedef _QueueInput = int Function(Pointer<Void>, int, int, int, int, int);
typedef _DequeueOutputC = IntPtr Function(Pointer<Void>, Pointer<Uint8>, Int64);
typedef _DequeueOutput = int Function(Pointer<Void>, Pointer<Uint8>, int);
typedef _FormatC = Pointer<Void> Function(Pointer<Void>);
typedef _Format = Pointer<Void> Function(Pointer<Void>);
typedef _ReleaseOutputC = Int32 Function(Pointer<Void>, Size, Bool);
typedef _ReleaseOutput = int Function(Pointer<Void>, int, bool);
typedef _NewFormatC = Pointer<Void> Function();
typedef _NewFormat = Pointer<Void> Function();
typedef _SetStringC =
    Void Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _SetString = void Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _SetIntC = Void Function(Pointer<Void>, Pointer<Utf8>, Int32);
typedef _SetInt = void Function(Pointer<Void>, Pointer<Utf8>, int);
typedef _GetIntC = Bool Function(Pointer<Void>, Pointer<Utf8>, Pointer<Int32>);
typedef _GetInt = bool Function(Pointer<Void>, Pointer<Utf8>, Pointer<Int32>);

// dequeueOutputBuffer results
const _formatChanged = -2;

// AMediaCodecBufferInfo: offset, size, presentationTimeUs, flags
const _infoSize = 24, _infoOffset = 0, _infoLength = 4;

// color formats of byte buffers: planar (I420) and semi-planar (NV12)
const _yuv420Planar = 19, _yuv420PackedPlanar = 20;
const _yuv420SemiPlanar = 21, _yuv420PackedSemiPlanar = 39;
const _yuv420Flexible = 0x7f420888;

const _mime = 'video/avc';

/// The software decoders of the Android Open Source Project, which every
/// device has and whose byte buffers hold planar YUV 4:2:0, for a device
/// that picks no decoder for the type. The decoder of the device comes
/// first: a software decoder holds several pictures back when the stream
/// does not state its reordering depth.
const _decoderNames = ['c2.android.avc.decoder', 'OMX.google.h264.decoder'];

/// The NDK media library.
class MediaCodecLibrary {
  MediaCodecLibrary._(DynamicLibrary lib)
    : _createByName = lib.lookupFunction<_CreateC, _Create>(
        'AMediaCodec_createCodecByName',
      ),
      _createByType = lib.lookupFunction<_CreateC, _Create>(
        'AMediaCodec_createDecoderByType',
      ),
      _configure = lib.lookupFunction<_ConfigureC, _Configure>(
        'AMediaCodec_configure',
      ),
      _start = lib.lookupFunction<_StatusC, _Status>('AMediaCodec_start'),
      _stop = lib.lookupFunction<_StatusC, _Status>('AMediaCodec_stop'),
      _flush = lib.lookupFunction<_StatusC, _Status>('AMediaCodec_flush'),
      _delete = lib.lookupFunction<_StatusC, _Status>('AMediaCodec_delete'),
      _inputBuffer = lib.lookupFunction<_BufferC, _Buffer>(
        'AMediaCodec_getInputBuffer',
      ),
      _outputBuffer = lib.lookupFunction<_BufferC, _Buffer>(
        'AMediaCodec_getOutputBuffer',
      ),
      _dequeueInput = lib.lookupFunction<_DequeueInputC, _DequeueInput>(
        'AMediaCodec_dequeueInputBuffer',
      ),
      _queueInput = lib.lookupFunction<_QueueInputC, _QueueInput>(
        'AMediaCodec_queueInputBuffer',
      ),
      _dequeueOutput = lib.lookupFunction<_DequeueOutputC, _DequeueOutput>(
        'AMediaCodec_dequeueOutputBuffer',
      ),
      _outputFormat = lib.lookupFunction<_FormatC, _Format>(
        'AMediaCodec_getOutputFormat',
      ),
      _releaseOutput = lib.lookupFunction<_ReleaseOutputC, _ReleaseOutput>(
        'AMediaCodec_releaseOutputBuffer',
      ),
      _newFormat = lib.lookupFunction<_NewFormatC, _NewFormat>(
        'AMediaFormat_new',
      ),
      _deleteFormat = lib.lookupFunction<_StatusC, _Status>(
        'AMediaFormat_delete',
      ),
      _setString = lib.lookupFunction<_SetStringC, _SetString>(
        'AMediaFormat_setString',
      ),
      _setInt = lib.lookupFunction<_SetIntC, _SetInt>('AMediaFormat_setInt32'),
      _getInt = lib.lookupFunction<_GetIntC, _GetInt>('AMediaFormat_getInt32');

  final _Create _createByName;
  final _Create _createByType;
  final _Configure _configure;
  final _Status _start;
  final _Status _stop;
  final _Status _flush;
  final _Status _delete;
  final _Buffer _inputBuffer;
  final _Buffer _outputBuffer;
  final _DequeueInput _dequeueInput;
  final _QueueInput _queueInput;
  final _DequeueOutput _dequeueOutput;
  final _Format _outputFormat;
  final _ReleaseOutput _releaseOutput;
  final _NewFormat _newFormat;
  final _Status _deleteFormat;
  final _SetString _setString;
  final _SetInt _setInt;
  final _GetInt _getInt;

  static MediaCodecLibrary? _loaded;
  static bool _tried = false;

  /// The NDK media library, or null when it is missing.
  static MediaCodecLibrary? load() {
    if (_tried) return _loaded;
    _tried = true;
    try {
      final lib = MediaCodecLibrary._(DynamicLibrary.open('libmediandk.so'));
      // The device can lack an H.264 decoder.
      final probe = lib._create();
      if (probe == null) return null;
      lib._delete(probe.$1);
      return _loaded = lib;
    } on ArgumentError {
      return null;
    }
  }

  /// A new H.264 decoder and whether its byte buffers are known to hold
  /// planar pictures.
  (Pointer<Void>, bool)? _create() => using((arena) {
    final codec = _createByType(_mime.toNativeUtf8(allocator: arena));
    if (codec != nullptr) return (codec, false);
    for (final name in _decoderNames) {
      final codec = _createByName(name.toNativeUtf8(allocator: arena));
      if (codec != nullptr) return (codec, true);
    }
    return null;
  });

  /// An H.264 decoder; null when none starts.
  VideoDecoder? openH264() {
    final created = _create();
    if (created == null) return null;
    final (codec, planar) = created;
    final ok = using((arena) {
      final format = _newFormat();
      Pointer<Utf8> key(String k) => k.toNativeUtf8(allocator: arena);
      _setString(format, key('mime'), _mime.toNativeUtf8(allocator: arena));
      // The size is a guess that the stream corrects; a PSP movie has it.
      _setInt(format, key('width'), 480);
      _setInt(format, key('height'), 272);
      _setInt(format, key('low-latency'), 1);
      final result = _configure(codec, format, nullptr, nullptr, 0);
      _deleteFormat(format);
      return result == 0 && _start(codec) == 0;
    });
    if (!ok) {
      _delete(codec);
      return null;
    }
    return _CodecVideoDecoder(this, codec, planar);
  }
}

class _CodecVideoDecoder implements VideoDecoder {
  _CodecVideoDecoder(this._lib, this._codec, this._knownPlanar);

  final MediaCodecLibrary _lib;
  Pointer<Void> _codec;
  final bool _knownPlanar;
  final _info = calloc<Uint8>(_infoSize);
  final _size = calloc<Size>();
  final _int = calloc<Int32>();

  // the output format: the picture size, the plane layout and the crop
  int _width = 0, _height = 0, _stride = 0, _sliceHeight = 0;
  int _left = 0, _top = 0, _shownWidth = 0, _shownHeight = 0;
  bool _planar = true;

  int _time = 0;
  DecodedPicture? _latest;

  /// The units sent and the pictures taken since the last flush.
  int _sent = 0, _taken = 0;

  /// The number of units the decoder holds back, learned from the waits
  /// that ran out.
  int _delay = 0;

  /// How long a decode waits for the picture of the unit it was given.
  static const _wait = 30000; // microseconds

  @override
  DecodedPicture? decode(Uint8List unit) {
    if (_codec == nullptr || unit.isEmpty) return _latest;
    var index = _lib._dequeueInput(_codec, 0);
    if (index < 0) {
      _drain(0);
      index = _lib._dequeueInput(_codec, _wait);
      if (index < 0) return _latest;
    }
    final buffer = _lib._inputBuffer(_codec, index, _size);
    if (buffer == nullptr || _size.value < unit.length) {
      _lib._queueInput(_codec, index, 0, 0, _time, 0);
      return _latest;
    }
    buffer.asTypedList(unit.length).setAll(0, unit);
    _lib._queueInput(_codec, index, 0, unit.length, _time, 0);
    _time += 33333;
    _sent++;
    // Take the pictures that are ready, and wait for the one of this unit
    // unless the decoder holds that many units back; a wait that runs out
    // means it holds one more.
    if (!_drain(_sent - _taken > _delay ? _wait : 0) &&
        _sent - _taken > _delay) {
      _delay++;
    }
    return _latest;
  }

  /// Takes the finished pictures, waiting up to [wait] microseconds for
  /// the first; whether a picture came.
  bool _drain(int wait) {
    var took = false;
    for (var i = 0; i < 32; i++) {
      final index = _lib._dequeueOutput(_codec, _info, took ? 0 : wait);
      if (index == _formatChanged) {
        _readFormat();
        continue;
      }
      if (index < 0) break; // no picture yet, or the buffers changed
      final offset = (_info + _infoOffset).cast<Int32>().value;
      final length = (_info + _infoLength).cast<Int32>().value;
      final data = _lib._outputBuffer(_codec, index, _size);
      if (data != nullptr && length > 0) {
        _latest = _picture((data + offset).asTypedList(length)) ?? _latest;
      }
      _lib._releaseOutput(_codec, index, false);
      _taken++;
      took = true;
    }
    return took;
  }

  int _get(Pointer<Void> format, String key, int otherwise) => using(
    (arena) => _lib._getInt(format, key.toNativeUtf8(allocator: arena), _int)
        ? _int.value
        : otherwise,
  );

  void _readFormat() {
    final format = _lib._outputFormat(_codec);
    if (format == nullptr) return;
    _width = _get(format, 'width', 0);
    _height = _get(format, 'height', 0);
    _stride = _get(format, 'stride', _width);
    _sliceHeight = _get(format, 'slice-height', _height);
    if (_stride < _width) _stride = _width;
    if (_sliceHeight < _height) _sliceHeight = _height;
    _left = _get(format, 'crop-left', 0);
    _top = _get(format, 'crop-top', 0);
    _shownWidth = _get(format, 'crop-right', _width - 1) - _left + 1;
    _shownHeight = _get(format, 'crop-bottom', _height - 1) - _top + 1;
    final color = _get(format, 'color-format', _yuv420Flexible);
    // The software decoders give planar pictures in byte buffers and say
    // that they are flexible. A hardware decoder names its format, and the
    // formats of the vendors are mostly variants of NV12, so they are taken
    // as semi-planar, which may be wrong for some devices.
    _planar = switch (color) {
      _yuv420SemiPlanar || _yuv420PackedSemiPlanar => false,
      _yuv420Planar || _yuv420PackedPlanar => true,
      _yuv420Flexible => true,
      _ => _knownPlanar,
    };
    _lib._deleteFormat(format);
  }

  DecodedPicture? _picture(Uint8List bytes) {
    final width = _shownWidth, height = _shownHeight;
    if (width <= 0 || height <= 0 || _stride <= 0) return null;
    final lumaSize = _stride * _sliceHeight;
    final step = _planar ? 1 : 2;
    final chromaStride = _planar ? _stride >> 1 : _stride;
    final chromaPlane = chromaStride * (_sliceHeight >> 1);
    final chromaAt =
        lumaSize + (_top >> 1) * chromaStride + (_left >> 1) * step;
    final crAt = chromaAt + (_planar ? chromaPlane : 1);
    // the last byte read, as a decoder may leave the rows after the last
    // one out of the buffer
    final end =
        crAt +
        (((height + 1) >> 1) - 1) * chromaStride +
        (((width + 1) >> 1) - 1) * step +
        1;
    if (end > bytes.length) return null;
    final luma = Uint8List.sublistView(bytes, _top * _stride + _left);
    final cb = Uint8List.sublistView(bytes, chromaAt);
    final cr = Uint8List.sublistView(bytes, crAt);
    return DecodedPicture(
      width,
      height,
      yuv420ToRgba(
        width,
        height,
        luma,
        _stride,
        cb,
        cr,
        chromaStride,
        chromaStep: step,
      ),
    );
  }

  @override
  void flush() {
    if (_codec == nullptr) return;
    _lib._flush(_codec);
    _sent = _taken = 0;
  }

  @override
  void close() {
    if (_codec == nullptr) return;
    _lib._stop(_codec);
    _lib._delete(_codec);
    _codec = nullptr;
    calloc.free(_info);
    calloc.free(_size);
    calloc.free(_int);
  }
}
