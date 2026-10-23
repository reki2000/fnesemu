import 'dart:convert';
import 'dart:typed_data';

/// A saved core state does not match the running core, its media or its
/// format version.
class StateMismatch implements Exception {
  final String message;
  const StateMismatch(this.message);
  @override
  String toString() => 'StateMismatch: $message';
}

/// Writes the logical state of a core as typed little-endian values.
///
/// A state starts with a header naming the core, its format version and an
/// identity of the loaded media. Sections are tagged so that a reader detects
/// a component order or format mismatch instead of loading shifted data.
/// 64-bit integers use [ByteData.setInt64], which dart2js does not support.
class StateWriter {
  final _out = BytesBuilder(copy: false);
  final _scratch = ByteData(8);

  StateWriter(String core, int version, int media) {
    string('fnesemu-state');
    string(core);
    int32(version);
    int64(media);
  }

  void _put(int bytes) =>
      _out.add(Uint8List.fromList(_scratch.buffer.asUint8List(0, bytes)));

  void section(String tag) => string(tag);

  void boolean(bool value) => int32(value ? 1 : 0);

  void int32(int value) {
    _scratch.setInt32(0, value.toSigned(32), Endian.little);
    _put(4);
  }

  void int64(int value) {
    _scratch.setInt64(0, value, Endian.little);
    _put(8);
  }

  void float64(double value) {
    _scratch.setFloat64(0, value, Endian.little);
    _put(8);
  }

  void string(String value) => bytes(utf8.encode(value));

  void bytes(List<int> value) {
    int32(value.length);
    _out.add(Uint8List.fromList(value));
  }

  void ints(List<int> values) {
    int32(values.length);
    values.forEach(int64);
  }

  void floats(List<double> values) {
    int32(values.length);
    values.forEach(float64);
  }

  Uint8List take() => _out.takeBytes();
}

/// Reads a state written by [StateWriter], checking its header and tags.
class StateReader {
  final ByteData _data;
  int _at = 0;

  /// Reads and validates the header; throws [StateMismatch] when the core,
  /// version or media identity differs.
  StateReader(Uint8List state, String core, int version, int media)
      : _data = ByteData.sublistView(state) {
    if (_tryString() != 'fnesemu-state') {
      throw const StateMismatch('not a fnesemu state');
    }
    final savedCore = string();
    if (savedCore != core) {
      throw StateMismatch('state of $savedCore, not $core');
    }
    final savedVersion = int32();
    if (savedVersion != version) {
      throw StateMismatch('format version $savedVersion, expected $version');
    }
    if (int64() != media) throw const StateMismatch('different media');
  }

  String? _tryString() {
    try {
      return string();
    } on StateMismatch {
      return null;
    } on FormatException {
      return null;
    }
  }

  void _need(int bytes) {
    if (_at + bytes > _data.lengthInBytes) {
      throw const StateMismatch('truncated state');
    }
  }

  void section(String tag) {
    final saved = string();
    if (saved != tag) throw StateMismatch('section $saved, expected $tag');
  }

  bool boolean() => int32() != 0;

  int int32() {
    _need(4);
    final v = _data.getInt32(_at, Endian.little);
    _at += 4;
    return v;
  }

  int int64() {
    _need(8);
    final v = _data.getInt64(_at, Endian.little);
    _at += 8;
    return v;
  }

  double float64() {
    _need(8);
    final v = _data.getFloat64(_at, Endian.little);
    _at += 8;
    return v;
  }

  String string() => utf8.decode(bytes());

  Uint8List bytes() {
    final length = int32();
    _need(length);
    final v = Uint8List.sublistView(_data, _at, _at + length);
    _at += length;
    return v;
  }

  /// Copies a byte array of exactly the length of [into].
  void bytesInto(List<int> into) {
    final v = bytes();
    if (v.length != into.length) {
      throw StateMismatch(
          'array of ${v.length} bytes, expected ${into.length}');
    }
    into.setAll(0, v);
  }

  List<int> ints() => List.generate(int32(), (_) => int64());

  /// Copies an integer array of exactly the length of [into].
  void intsInto(List<int> into) {
    final v = ints();
    if (v.length != into.length) {
      throw StateMismatch(
          'array of ${v.length} values, expected ${into.length}');
    }
    into.setAll(0, v);
  }

  List<double> floats() => List.generate(int32(), (_) => float64());

  /// Throws unless the whole state was read.
  void end() {
    if (_at != _data.lengthInBytes) {
      throw const StateMismatch('trailing data in state');
    }
  }
}

/// FNV-1a over [bytes], used as the media identity of a state.
int stateMediaHash(List<int> bytes) {
  var h = 0xcbf29ce484222325;
  for (final b in bytes) {
    h = (h ^ b) * 0x100000001b3;
  }
  return h;
}
