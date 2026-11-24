import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'libav_bundled.dart';
import 'types.dart';

// The ATRAC3 and ATRAC3plus decoders of a shared libavcodec found at run
// time: the
// mmd_libav that the build hook bundles (libav_bundled.dart), or a
// libavcodec and libavutil opened by their file names. The package does not
// link either, so the library stays separate and replaceable, and only a
// build under the LGPL is used. Only functions and the leading fields of
// AVPacket and AVFrame are used, which keep their layout across the major
// versions 58 to 61; the codec settings go through AVOptions, and the
// codec data, which no option reaches, through mmd_set_extradata, a helper
// of mmd_libav only.

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
typedef _SetExtradataC = Int32 Function(Pointer<Void>, Pointer<Uint8>, Int32);
typedef _SetExtradata = int Function(Pointer<Void>, Pointer<Uint8>, int);
typedef _LicenseC = Pointer<Utf8> Function();
typedef _License = Pointer<Utf8> Function();

// AVPacket: buf, pts, dts, data
const _packetData = 24;

// AVFrame: data[8], linesize[8], extended_data, width, height, nb_samples,
// format
const _frameSamples = 112, _frameFormat = 116;

// AVSampleFormat values
const _s16 = 1, _flt = 3, _s16p = 6, _fltp = 8;

/// The environment variable that names a directory to search for the
/// libraries before the others.
const libavDirVariable = 'MP_MEDIA_DECODER_LIBAV_DIR';

/// A shared libavcodec and its libavutil, both under the LGPL.
class LibAvcodec {
  LibAvcodec._(Pointer<Void> Function(String) symbol, this.name)
      : _findDecoder = symbol('avcodec_find_decoder_by_name')
            .cast<NativeFunction<_FindDecoderC>>()
            .asFunction(),
        _allocContext = symbol('avcodec_alloc_context3')
            .cast<NativeFunction<_PtrOfPtrC>>()
            .asFunction(),
        _open2 =
            symbol('avcodec_open2').cast<NativeFunction<_Open2C>>().asFunction(),
        _sendPacket = symbol('avcodec_send_packet')
            .cast<NativeFunction<_TwoPtrC>>()
            .asFunction(),
        _receiveFrame = symbol('avcodec_receive_frame')
            .cast<NativeFunction<_TwoPtrC>>()
            .asFunction(),
        _flushBuffers = symbol('avcodec_flush_buffers')
            .cast<NativeFunction<_VoidPtrC>>()
            .asFunction(),
        _freeContext = symbol('avcodec_free_context')
            .cast<NativeFunction<_FreePtrC>>()
            .asFunction(),
        _packetAlloc =
            symbol('av_packet_alloc').cast<NativeFunction<_NewPtrC>>().asFunction(),
        _packetFree =
            symbol('av_packet_free').cast<NativeFunction<_FreePtrC>>().asFunction(),
        _newPacket = symbol('av_new_packet')
            .cast<NativeFunction<_NewPacketC>>()
            .asFunction(),
        _packetUnref = symbol('av_packet_unref')
            .cast<NativeFunction<_VoidPtrC>>()
            .asFunction(),
        _frameAlloc =
            symbol('av_frame_alloc').cast<NativeFunction<_NewPtrC>>().asFunction(),
        _frameFree =
            symbol('av_frame_free').cast<NativeFunction<_FreePtrC>>().asFunction(),
        _optSetInt = symbol('av_opt_set_int')
            .cast<NativeFunction<_OptSetIntC>>()
            .asFunction(),
        _optSet =
            symbol('av_opt_set').cast<NativeFunction<_OptSetC>>().asFunction(),
        _setExtradata = _optional(symbol, 'mmd_set_extradata')
            ?.cast<NativeFunction<_SetExtradataC>>()
            .asFunction();

  /// The symbol [name], or null when the library lacks it.
  static Pointer<Void>? _optional(
      Pointer<Void> Function(String) symbol, String name) {
    try {
      return symbol(name);
    } on ArgumentError {
      return null;
    }
  }

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
  final _SetExtradata? _setExtradata;

  /// The library file names to try, newest first, as pairs of libavcodec
  /// and the libavutil of the same release.
  static List<(String, String)> get _names {
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

  /// The directories where the app may keep a libavcodec of its own,
  /// searched after the bundled one and before the names of the system:
  /// beside the executable, its `lib`, and the `Frameworks` of a macOS
  /// bundle.
  static List<String> get _directories {
    final exe = File(Platform.resolvedExecutable).parent.path;
    final sep = Platform.pathSeparator;
    return [
      exe,
      '$exe${sep}lib',
      if (Platform.isMacOS) '$exe$sep..${sep}Frameworks',
    ];
  }

  static LibAvcodec? _loaded;
  static bool _tried = false;

  /// The first libavcodec under the LGPL that loads, or null when none
  /// does: the one in the directory of [libavDirVariable], the one bundled
  /// by the build hook, then the ones in [_directories] and of the system.
  /// A build under the GPL, as Linux distributions ship, is skipped.
  static LibAvcodec? load() {
    if (_tried) return _loaded;
    _tried = true;
    final dir = Platform.environment[libavDirVariable] ?? '';
    return _loaded = (dir.isEmpty ? null : _search([dir], system: false)) ??
        _bundled() ??
        _search(_directories, system: true);
  }

  /// The library that the build hook bundled; null without one.
  static LibAvcodec? _bundled() {
    final symbol = bundledLibavSymbols();
    if (symbol == null) return null;
    bool lgpl(String function) {
      final license = symbol(function)
          .cast<NativeFunction<_LicenseC>>()
          .asFunction<_License>()();
      return license != nullptr && license.toDartString().startsWith('LGPL');
    }

    if (!lgpl('avcodec_license') || !lgpl('avutil_license')) return null;
    return LibAvcodec._(symbol, bundledLibavName);
  }

  /// The first pair of libraries in [directories], or of the system when
  /// [system], that loads and is under the LGPL.
  static LibAvcodec? _search(List<String> directories,
      {required bool system}) {
    final sep = Platform.pathSeparator;
    final paths = [
      for (final dir in directories) ...[
        // mmd_libav, the output of tool/build_libav_atrac.sh, which holds
        // both libraries
        for (final file in _combined(dir)) (file, file),
        for (final (codec, util) in _names)
          ('$dir$sep$codec', '$dir$sep$util'),
      ],
      if (system) ..._names,
    ];
    for (final (codecPath, utilPath) in paths) {
      if (codecPath.contains(sep) && !File(codecPath).existsSync()) continue;
      try {
        final util = DynamicLibrary.open(utilPath);
        final codec = DynamicLibrary.open(codecPath);
        if (!_isLgpl(codec, 'avcodec_license') ||
            !_isLgpl(util, 'avutil_license')) {
          continue;
        }
        return LibAvcodec._(
            (symbol) => (symbol.startsWith('avcodec_') ||
                        symbol.startsWith('av_packet') ||
                        symbol.startsWith('mmd_') ||
                        symbol == 'av_new_packet'
                    ? codec
                    : util)
                .lookup<Void>(symbol),
            codecPath);
      } on ArgumentError {
        // not this version
      }
    }
    return null;
  }

  /// The files of mmd_libav in [dir], under the name of the platform or of
  /// a release asset (mmd_libav-TARGET).
  static List<String> _combined(String dir) {
    final ext = Platform.isWindows
        ? '.dll'
        : (Platform.isMacOS || Platform.isIOS ? '.dylib' : '.so');
    try {
      return [
        for (final entry in Directory(dir).listSync())
          if (entry is File &&
              entry.path.endsWith(ext) &&
              RegExp(r'(^|[/\\])(lib)?mmd_libav[-.]').hasMatch(entry.path))
            entry.path,
      ]..sort();
    } on FileSystemException {
      return const [];
    }
  }

  /// Whether the license string that [function] of [library] returns is
  /// the LGPL, as configure records it.
  static bool _isLgpl(DynamicLibrary library, String function) {
    try {
      final license =
          library.lookupFunction<_LicenseC, _License>(function)();
      return license != nullptr && license.toDartString().startsWith('LGPL');
    } on ArgumentError {
      return false;
    }
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

  /// An ATRAC3plus decoder for frames of [blockAlign] bytes; null when the
  /// library has none or does not take the settings.
  AudioDecoder? openAtrac3plus(
          {required int sampleRate,
          required int channels,
          required int blockAlign}) =>
      _openAudio('atrac3plus', sampleRate, channels, blockAlign, null);

  /// Whether the library can pass codec data to a decoder, which ATRAC3
  /// needs: only mmd_libav can.
  bool get takesCodecData => _setExtradata != null;

  /// An ATRAC3 decoder for frames of [blockAlign] bytes, with the codec
  /// data of the stream, such as the 14-byte format extension of a WAVE
  /// file; null when the library has none or does not take the settings.
  AudioDecoder? openAtrac3(
          {required int sampleRate,
          required int channels,
          required int blockAlign,
          required Uint8List codecData}) =>
      _setExtradata == null
          ? null
          : _openAudio('atrac3', sampleRate, channels, blockAlign, codecData);

  AudioDecoder? _openAudio(String decoder, int sampleRate, int channels,
      int blockAlign, Uint8List? codecData) {
    var ok = true;
    final context = _open(decoder, (c) {
      ok &= _setInt(c, 'ar', sampleRate);
      // ch_layout from release 59 on, the channel count before
      final layout = channels == 1 ? 'mono' : 'stereo';
      ok &= _set(c, 'ch_layout', layout) || _setInt(c, 'ac', channels);
      ok &= _setInt(c, 'block_align', blockAlign);
      if (codecData != null) {
        ok &= using((arena) {
          final data = arena<Uint8>(codecData.isEmpty ? 1 : codecData.length);
          data.asTypedList(codecData.length).setAll(0, codecData);
          return _setExtradata!(c, data, codecData.length) >= 0;
        });
      }
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
