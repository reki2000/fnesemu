import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'types.dart';
import 'yuv.dart';

// The decoders of a shared libavcodec found at run time. The package does
// not link it: the library is loaded by name, so it stays a separate,
// replaceable library. Only functions and the leading fields of AVPacket
// and AVFrame are used, which keep their layout across the major versions
// 58 to 61; the codec settings go through AVOptions.

typedef _FindDecoderC = Pointer<Void> Function(Pointer<Utf8>);
typedef _FindDecoder = Pointer<Void> Function(Pointer<Utf8>);
typedef _PtrOfPtrC = Pointer<Void> Function(Pointer<Void>);
typedef _PtrOfPtr = Pointer<Void> Function(Pointer<Void>);
typedef _NewPtrC = Pointer<Void> Function();
typedef _NewPtr = Pointer<Void> Function();
typedef _Open2C = Int32 Function(Pointer<Void>, Pointer<Void>, Pointer<Void>);
typedef _Open2 = int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>);
typedef _TwoPtrC = Int32 Function(Pointer<Void>, Pointer<Void>);
typedef _TwoPtr = int Function(Pointer<Void>, Pointer<Void>);
typedef _VoidPtrC = Void Function(Pointer<Void>);
typedef _VoidPtr = void Function(Pointer<Void>);
typedef _FreePtrC = Void Function(Pointer<Pointer<Void>>);
typedef _FreePtr = void Function(Pointer<Pointer<Void>>);
typedef _NewPacketC = Int32 Function(Pointer<Void>, Int32);
typedef _NewPacket = int Function(Pointer<Void>, int);
typedef _OptSetIntC = Int32 Function(
    Pointer<Void>, Pointer<Utf8>, Int64, Int32);
typedef _OptSetInt = int Function(Pointer<Void>, Pointer<Utf8>, int, int);
typedef _OptSetC = Int32 Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Int32);
typedef _OptSet = int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, int);

// AVPacket: buf, pts, dts, data
const _packetData = 24;

// AVFrame: data[8], linesize[8], extended_data, width, height, nb_samples,
// format
const _frameLinesize = 64, _frameWidth = 104, _frameHeight = 108;
const _frameSamples = 112, _frameFormat = 116;

// AVPixelFormat and AVSampleFormat values
const _yuv420p = 0, _yuvj420p = 12, _nv12 = 23;
const _s16 = 1, _flt = 3, _s16p = 6, _fltp = 8;

/// A shared libavcodec and its libavutil.
class LibAvcodec {
  LibAvcodec._(DynamicLibrary codec, DynamicLibrary util, this.name)
      : _findDecoder = codec.lookupFunction<_FindDecoderC, _FindDecoder>(
            'avcodec_find_decoder_by_name'),
        _allocContext = codec
            .lookupFunction<_PtrOfPtrC, _PtrOfPtr>('avcodec_alloc_context3'),
        _open2 = codec.lookupFunction<_Open2C, _Open2>('avcodec_open2'),
        _sendPacket =
            codec.lookupFunction<_TwoPtrC, _TwoPtr>('avcodec_send_packet'),
        _receiveFrame =
            codec.lookupFunction<_TwoPtrC, _TwoPtr>('avcodec_receive_frame'),
        _flushBuffers =
            codec.lookupFunction<_VoidPtrC, _VoidPtr>('avcodec_flush_buffers'),
        _freeContext =
            codec.lookupFunction<_FreePtrC, _FreePtr>('avcodec_free_context'),
        _packetAlloc =
            codec.lookupFunction<_NewPtrC, _NewPtr>('av_packet_alloc'),
        _packetFree =
            codec.lookupFunction<_FreePtrC, _FreePtr>('av_packet_free'),
        _newPacket =
            codec.lookupFunction<_NewPacketC, _NewPacket>('av_new_packet'),
        _packetUnref =
            codec.lookupFunction<_VoidPtrC, _VoidPtr>('av_packet_unref'),
        _frameAlloc = util.lookupFunction<_NewPtrC, _NewPtr>('av_frame_alloc'),
        _frameFree = util.lookupFunction<_FreePtrC, _FreePtr>('av_frame_free'),
        _optSetInt =
            util.lookupFunction<_OptSetIntC, _OptSetInt>('av_opt_set_int'),
        _optSet = util.lookupFunction<_OptSetC, _OptSet>('av_opt_set');

  /// the file name of the libavcodec that was loaded
  final String name;

  final _FindDecoder _findDecoder;
  final _PtrOfPtr _allocContext;
  final _Open2 _open2;
  final _TwoPtr _sendPacket;
  final _TwoPtr _receiveFrame;
  final _VoidPtr _flushBuffers;
  final _FreePtr _freeContext;
  final _NewPtr _packetAlloc;
  final _FreePtr _packetFree;
  final _NewPacket _newPacket;
  final _VoidPtr _packetUnref;
  final _NewPtr _frameAlloc;
  final _FreePtr _frameFree;
  final _OptSetInt _optSetInt;
  final _OptSet _optSet;

  /// The library names to try, newest first, as pairs of libavcodec and
  /// the libavutil of the same release.
  static List<(String, String)> get _candidates {
    const versions = [(61, 59), (60, 58), (59, 57), (58, 56)];
    if (Platform.isWindows) {
      return [for (final (c, u) in versions) ('avcodec-$c.dll', 'avutil-$u.dll')];
    }
    if (Platform.isMacOS || Platform.isIOS) {
      return [
        for (final (c, u) in versions)
          ('libavcodec.$c.dylib', 'libavutil.$u.dylib'),
        ('libavcodec.dylib', 'libavutil.dylib'),
      ];
    }
    return [
      for (final (c, u) in versions) ('libavcodec.so.$c', 'libavutil.so.$u'),
      ('libavcodec.so', 'libavutil.so'),
    ];
  }

  static LibAvcodec? _loaded;
  static bool _tried = false;

  /// The first libavcodec that loads, or null when none does.
  static LibAvcodec? load() {
    if (_tried) return _loaded;
    _tried = true;
    for (final (codecName, utilName) in _candidates) {
      try {
        final util = DynamicLibrary.open(utilName);
        final codec = DynamicLibrary.open(codecName);
        return _loaded = LibAvcodec._(codec, util, codecName);
      } on ArgumentError {
        // not this version
      }
    }
    return null;
  }

  /// Whether the library has a decoder called [decoder].
  bool has(String decoder) => using((arena) =>
      _findDecoder(decoder.toNativeUtf8(allocator: arena)) != nullptr);

  /// Opens the decoder [decoder] after [configure] sets its options on the
  /// codec context; null when it cannot be opened.
  Pointer<Void>? _open(
      String decoder, void Function(Pointer<Void> context) configure) {
    final codec = using(
        (arena) => _findDecoder(decoder.toNativeUtf8(allocator: arena)));
    if (codec == nullptr) return null;
    final context = _allocContext(codec);
    if (context == nullptr) return null;
    configure(context);
    if (_open2(context, codec, nullptr) < 0) {
      _freePointer(_freeContext, context);
      return null;
    }
    return context;
  }

  bool _setInt(Pointer<Void> object, String name, int value) =>
      using((arena) =>
          _optSetInt(object, name.toNativeUtf8(allocator: arena), value, 0) >=
          0);

  bool _set(Pointer<Void> object, String name, String value) =>
      using((arena) =>
          _optSet(object, name.toNativeUtf8(allocator: arena),
              value.toNativeUtf8(allocator: arena), 0) >=
          0);

  static void _freePointer(_FreePtr free, Pointer<Void> pointer) {
    final holder = calloc<Pointer<Void>>()..value = pointer;
    free(holder);
    calloc.free(holder);
  }

  /// An H.264 decoder that outputs each picture without frame threading
  /// delay; null when the library has none.
  VideoDecoder? openH264() {
    final context = _open('h264', (c) => _setInt(c, 'threads', 1));
    return context == null ? null : _AvVideoDecoder(this, context);
  }

  /// An ATRAC3plus decoder for frames of [blockAlign] bytes; null when the
  /// library has none or does not take the settings.
  AudioDecoder? openAtrac3plus(
      {required int sampleRate,
      required int channels,
      required int blockAlign}) {
    var ok = true;
    final context = _open('atrac3plus', (c) {
      ok &= _setInt(c, 'ar', sampleRate);
      // ch_layout from release 59 on, the channel count before
      final layout = channels == 1 ? 'mono' : 'stereo';
      ok &= _set(c, 'ch_layout', layout) || _setInt(c, 'ac', channels);
      ok &= _setInt(c, 'block_align', blockAlign);
    });
    if (context == null) return null;
    if (!ok) {
      _freePointer(_freeContext, context);
      return null;
    }
    return _AvAudioDecoder(this, context, channels);
  }
}

/// A decoder context with its packet and frame.
abstract class _AvStream {
  _AvStream(this._lib, this._context)
      : _packet = _lib._packetAlloc(),
        _frame = _lib._frameAlloc();

  final LibAvcodec _lib;
  Pointer<Void> _context;
  final Pointer<Void> _packet;
  final Pointer<Void> _frame;

  /// Sends [bytes] as one packet; false when the decoder rejects it.
  bool _send(Uint8List bytes) {
    if (_context == nullptr) return false;
    if (_lib._newPacket(_packet, bytes.length) < 0) return false;
    final packet = _packet.cast<Uint8>();
    final data = Pointer<Uint8>.fromAddress(
        (packet + _packetData).cast<IntPtr>().value);
    data.asTypedList(bytes.length).setAll(0, bytes);
    final result = _lib._sendPacket(_context, _packet);
    _lib._packetUnref(_packet);
    return result >= 0;
  }

  /// Whether a decoded frame is now in [_frame].
  bool _receive() =>
      _context != nullptr && _lib._receiveFrame(_context, _frame) >= 0;

  int _int(int offset) => (_frame.cast<Uint8>() + offset).cast<Int32>().value;

  Pointer<Uint8> _plane(int index) => Pointer<Uint8>.fromAddress(
      (_frame.cast<Uint8>() + index * 8).cast<IntPtr>().value);

  int _linesize(int index) => _int(_frameLinesize + index * 4);

  void flush() {
    if (_context != nullptr) _lib._flushBuffers(_context);
  }

  void close() {
    if (_context == nullptr) return;
    LibAvcodec._freePointer(_lib._freeContext, _context);
    LibAvcodec._freePointer(_lib._packetFree, _packet);
    LibAvcodec._freePointer(_lib._frameFree, _frame);
    _context = nullptr;
  }
}

class _AvVideoDecoder extends _AvStream implements VideoDecoder {
  _AvVideoDecoder(super.lib, super.context);

  DecodedPicture? _latest;

  @override
  DecodedPicture? decode(Uint8List unit) {
    _send(unit);
    while (_receive()) {
      _latest = _picture() ?? _latest;
    }
    return _latest;
  }

  DecodedPicture? _picture() {
    final width = _int(_frameWidth), height = _int(_frameHeight);
    final format = _int(_frameFormat);
    if (width <= 0 || height <= 0) return null;
    final lumaStride = _linesize(0);
    final luma = _plane(0).asTypedList(lumaStride * height);
    final chromaRows = (height + 1) >> 1;
    switch (format) {
      case _yuv420p || _yuvj420p:
        final chromaStride = _linesize(1);
        return DecodedPicture(
            width,
            height,
            yuv420ToRgba(
                width,
                height,
                luma,
                lumaStride,
                _plane(1).asTypedList(chromaStride * chromaRows),
                _plane(2).asTypedList(_linesize(2) * chromaRows),
                chromaStride,
                fullRange: format == _yuvj420p));
      case _nv12:
        final chromaStride = _linesize(1);
        final chroma = _plane(1).asTypedList(chromaStride * chromaRows);
        return DecodedPicture(
            width,
            height,
            yuv420ToRgba(width, height, luma, lumaStride, chroma,
                Uint8List.sublistView(chroma, 1), chromaStride,
                chromaStep: 2));
      default:
        return null;
    }
  }
}

class _AvAudioDecoder extends _AvStream implements AudioDecoder {
  _AvAudioDecoder(super.lib, super.context, this._channels);

  final int _channels;

  @override
  Int16List? decode(Uint8List frame) {
    if (!_send(frame)) return null;
    final parts = <Int16List>[];
    while (_receive()) {
      final samples = _samples();
      if (samples != null) parts.add(samples);
    }
    if (parts.isEmpty) return null;
    if (parts.length == 1) return parts.first;
    final out = Int16List(parts.fold(0, (n, p) => n + p.length));
    var at = 0;
    for (final p in parts) {
      out.setAll(at, p);
      at += p.length;
    }
    return out;
  }

  Int16List? _samples() {
    final count = _int(_frameSamples);
    final format = _int(_frameFormat);
    final channels = _channels;
    if (count <= 0) return null;
    final out = Int16List(count * channels);
    switch (format) {
      case _fltp:
        for (var c = 0; c < channels; c++) {
          final plane = _plane(c).cast<Float>().asTypedList(count);
          for (var i = 0; i < count; i++) {
            out[i * channels + c] = _fromFloat(plane[i]);
          }
        }
      case _flt:
        final data = _plane(0).cast<Float>().asTypedList(count * channels);
        for (var i = 0; i < out.length; i++) {
          out[i] = _fromFloat(data[i]);
        }
      case _s16p:
        for (var c = 0; c < channels; c++) {
          final plane = _plane(c).cast<Int16>().asTypedList(count);
          for (var i = 0; i < count; i++) {
            out[i * channels + c] = plane[i];
          }
        }
      case _s16:
        out.setAll(0, _plane(0).cast<Int16>().asTypedList(count * channels));
      default:
        return null;
    }
    return out;
  }

  static int _fromFloat(double v) {
    final s = (v * 32768).round();
    return s > 32767 ? 32767 : (s < -32768 ? -32768 : s);
  }
}
