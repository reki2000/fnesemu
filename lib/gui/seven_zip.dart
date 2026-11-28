/// Reads 7z archives after the 7z format description of 7-Zip
/// (DOC/7zFormat.txt). It reads the entries packed with Copy, LZMA or
/// LZMA2, in solid or separate folders, with a plain or a packed header.
/// Encrypted archives and other methods throw [SevenZipException].
library;

import 'dart:typed_data';

import 'package:archive/archive.dart';

/// reads [length] bytes of the archive from [offset]
typedef ReadRange = Future<Uint8List> Function(int offset, int length);

class SevenZipException implements Exception {
  final String message;
  const SevenZipException(this.message);
  @override
  String toString() => 'SevenZipException: $message';
}

/// a file or a directory in a 7z archive
class SevenZipEntry {
  /// the path in the archive, with '/' between the directories
  final String name;
  final int size;
  final bool isDirectory;

  /// the CRC-32 of the content, when the archive has it
  final int? crc;

  // the folder holding the content and its offset in the folder's output;
  // -1 for an entry without content
  final int _folder;
  final int _offset;

  const SevenZipEntry._(this.name, this.size, this.isDirectory, this.crc,
      this._folder, this._offset);
}

bool isSevenZip(String name) => name.toLowerCase().endsWith('.7z');

class _Coder {
  final List<int> id;
  final Uint8List properties;
  final int inputs, outputs;
  const _Coder(this.id, this.properties, this.inputs, this.outputs);
}

class _Folder {
  final List<_Coder> coders;
  final List<(int, int)> bindPairs; // (input index, output index)
  final List<int> packedInputs;
  List<int> unpackSizes = const [];
  int? crc;
  // the position of its first packed stream in the archive and the sizes
  int packOffset = 0;
  List<int> packSizes = const [];

  _Folder(this.coders, this.bindPairs, this.packedInputs);

  int get _mainOutput {
    for (var i = 0; i < unpackSizes.length; i++) {
      if (!bindPairs.any((p) => p.$2 == i)) return i;
    }
    throw const SevenZipException('a folder without a main output');
  }

  int get size => unpackSizes[_mainOutput];
}

class _Streams {
  List<_Folder> folders = [];
  // per substream: the folder, the offset in it, the size and the CRC
  final substreams = <(int, int, int, int?)>[];
}

class _Bytes {
  final Uint8List _data;
  int _at = 0;
  _Bytes(this._data);

  int byte() {
    if (_at >= _data.length) {
      throw const SevenZipException('the header is truncated');
    }
    return _data[_at++];
  }

  Uint8List bytes(int length) {
    if (_at + length > _data.length) {
      throw const SevenZipException('the header is truncated');
    }
    final value = Uint8List.sublistView(_data, _at, _at + length);
    _at += length;
    return value;
  }

  void skip(int length) => bytes(length);

  /// a number of 1 to 9 bytes: the leading one bits of the first byte count
  /// the bytes that follow, in little endian, below the rest of its bits
  int number() {
    final first = byte();
    var value = 0;
    var mask = 0x80;
    for (var i = 0; i < 8; i++) {
      if (first & mask == 0) {
        return value | (first & (mask - 1)) << (8 * i);
      }
      value |= byte() << (8 * i);
      mask >>= 1;
    }
    return value;
  }

  int uint32() {
    final b = bytes(4);
    return b[0] | b[1] << 8 | b[2] << 16 | b[3] << 24;
  }

  /// [count] bits, from the top bit of each byte
  List<bool> bits(int count) {
    final result = <bool>[];
    var value = 0;
    for (var i = 0; i < count; i++) {
      if (i % 8 == 0) value = byte();
      result.add(value & (0x80 >> (i % 8)) != 0);
    }
    return result;
  }

  /// [count] bits that may all be set by a leading nonzero byte
  List<bool> definedBits(int count) =>
      byte() != 0 ? List.filled(count, true) : bits(count);

  List<int?> digests(int count) {
    final defined = definedBits(count);
    return [for (final d in defined) d ? uint32() : null];
  }

  void expect(int id) {
    final value = byte();
    if (value != id) {
      throw SevenZipException('property $value where $id is expected');
    }
  }
}

class SevenZip {
  static const _signature = [0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c];

  final ReadRange _read;
  final List<_Folder> _folders;

  /// the files and directories in the order of the archive
  final List<SevenZipEntry> entries;

  SevenZip._(this._read, this._folders, this.entries);

  /// reads the header of the archive of [length] bytes through [read]
  static Future<SevenZip> open(int length, ReadRange read) async {
    if (length < 32) throw const SevenZipException('not a 7z archive');
    final start = await read(0, 32);
    for (var i = 0; i < _signature.length; i++) {
      if (start[i] != _signature[i]) {
        throw const SevenZipException('not a 7z archive');
      }
    }
    final s = ByteData.sublistView(start);
    final nextOffset = s.getUint64(12, Endian.little);
    final nextSize = s.getUint64(20, Endian.little);
    final nextCrc = s.getUint32(28, Endian.little);
    if (getCrc32(Uint8List.sublistView(start, 12, 32)) !=
        s.getUint32(8, Endian.little)) {
      throw const SevenZipException('the start header is corrupt');
    }
    if (nextSize == 0) return SevenZip._(read, const [], const []);
    if (32 + nextOffset + nextSize > length) {
      throw const SevenZipException('the archive is truncated');
    }
    var header = await read(32 + nextOffset, nextSize);
    if (getCrc32(header) != nextCrc) {
      throw const SevenZipException('the header is corrupt');
    }
    for (;;) {
      final b = _Bytes(header);
      final id = b.byte();
      if (id == 0x01) return _header(read, b);
      if (id != 0x17) throw SevenZipException('unknown header $id');
      // a header packed in a folder of its own
      final streams = _streamsInfo(b);
      if (streams.folders.isEmpty) {
        throw const SevenZipException('a packed header without a folder');
      }
      final folder = streams.folders.first;
      header = await _decode(read, folder, 0, folder.size);
      if (folder.crc case final crc? when getCrc32(header) != crc) {
        throw const SevenZipException('the packed header is corrupt');
      }
    }
  }

  /// the content of [entry]
  Future<Uint8List> read(SevenZipEntry entry) async {
    if (entry._folder < 0) return Uint8List(0);
    final data = await _decode(
        _read, _folders[entry._folder], entry._offset, entry.size);
    if (entry.crc case final crc? when getCrc32(data) != crc) {
      throw SevenZipException('${entry.name} is corrupt');
    }
    return data;
  }

  static SevenZip _header(ReadRange read, _Bytes b) {
    var streams = _Streams();
    var entries = <SevenZipEntry>[];
    for (;;) {
      final id = b.byte();
      switch (id) {
        case 0x00:
          return SevenZip._(read, streams.folders, entries);
        case 0x02: // archive properties
          while (b.byte() != 0) {
            b.skip(b.number());
          }
        case 0x03: // additional streams, not used
          _streamsInfo(b);
        case 0x04:
          streams = _streamsInfo(b);
        case 0x05:
          entries = _files(b, streams);
        default:
          throw SevenZipException('unknown header property $id');
      }
    }
  }

  static _Streams _streamsInfo(_Bytes b) {
    final streams = _Streams();
    var packPosition = 0;
    var packSizes = <int>[];
    List<int>? counts;
    List<int>? sizes;
    List<int?>? crcs;
    for (;;) {
      final id = b.byte();
      if (id == 0x00) break;
      switch (id) {
        case 0x06: // pack info
          packPosition = b.number();
          final count = b.number();
          for (var t = b.byte(); t != 0; t = b.byte()) {
            if (t == 0x09) {
              packSizes = [for (var i = 0; i < count; i++) b.number()];
            } else if (t == 0x0a) {
              b.digests(count);
            } else {
              b.skip(b.number());
            }
          }
        case 0x07: // coders info
          b.expect(0x0b);
          final count = b.number();
          if (b.byte() != 0) {
            throw const SevenZipException('external folders are not supported');
          }
          streams.folders = [for (var i = 0; i < count; i++) _folder(b)];
          b.expect(0x0c);
          for (final f in streams.folders) {
            final outputs = f.coders.fold<int>(0, (n, c) => n + c.outputs);
            f.unpackSizes = [for (var i = 0; i < outputs; i++) b.number()];
          }
          for (var t = b.byte(); t != 0; t = b.byte()) {
            if (t == 0x0a) {
              final digests = b.digests(count);
              for (var i = 0; i < count; i++) {
                streams.folders[i].crc = digests[i];
              }
            } else {
              b.skip(b.number());
            }
          }
        case 0x08: // substreams info
          final folders = streams.folders;
          counts = List.filled(folders.length, 1);
          var t = b.byte();
          if (t == 0x0d) {
            counts = [for (var i = 0; i < folders.length; i++) b.number()];
            t = b.byte();
          }
          if (t == 0x09) {
            sizes = [];
            for (var i = 0; i < folders.length; i++) {
              if (counts[i] == 0) continue;
              var sum = 0;
              for (var j = 1; j < counts[i]; j++) {
                final size = b.number();
                sizes.add(size);
                sum += size;
              }
              sizes.add(folders[i].size - sum);
            }
            t = b.byte();
          }
          while (t != 0) {
            if (t == 0x0a) {
              // digests of the substreams whose folder gives none
              var unknown = 0;
              for (var i = 0; i < folders.length; i++) {
                if (counts[i] != 1 || folders[i].crc == null) {
                  unknown += counts[i];
                }
              }
              crcs = b.digests(unknown);
            } else {
              b.skip(b.number());
            }
            t = b.byte();
          }
        default:
          throw SevenZipException('unknown streams property $id');
      }
    }

    // the packed streams of each folder follow each other
    var offset = 32 + packPosition;
    var pack = 0;
    for (final f in streams.folders) {
      f.packOffset = offset;
      f.packSizes = packSizes.sublist(pack, pack + f.packedInputs.length);
      pack += f.packedInputs.length;
      offset += f.packSizes.fold<int>(0, (n, s) => n + s);
    }

    final folders = streams.folders;
    counts ??= List.filled(folders.length, 1);
    var sizeIndex = 0, crcIndex = 0;
    for (var i = 0; i < folders.length; i++) {
      var at = 0;
      for (var j = 0; j < counts[i]; j++) {
        final size = sizes == null ? folders[i].size : sizes[sizeIndex++];
        int? crc;
        if (counts[i] == 1 && folders[i].crc != null) {
          crc = folders[i].crc;
        } else if (crcs != null) {
          crc = crcs[crcIndex++];
        }
        streams.substreams.add((i, at, size, crc));
        at += size;
      }
    }
    return streams;
  }

  static _Folder _folder(_Bytes b) {
    final coders = <_Coder>[];
    final count = b.number();
    for (var i = 0; i < count; i++) {
      final flags = b.byte();
      if (flags & 0x80 != 0) {
        throw const SevenZipException('alternative methods are not supported');
      }
      final id = b.bytes(flags & 0x0f).toList();
      final complex = flags & 0x10 != 0;
      final inputs = complex ? b.number() : 1;
      final outputs = complex ? b.number() : 1;
      final properties = flags & 0x20 != 0
          ? Uint8List.fromList(b.bytes(b.number()))
          : Uint8List(0);
      coders.add(_Coder(id, properties, inputs, outputs));
    }
    final outputs = coders.fold<int>(0, (n, c) => n + c.outputs);
    final inputs = coders.fold<int>(0, (n, c) => n + c.inputs);
    final bindPairs = [
      for (var i = 0; i < outputs - 1; i++) (b.number(), b.number())
    ];
    final packed = inputs - bindPairs.length;
    final packedInputs = packed == 1
        ? [
            for (var i = 0; i < inputs; i++)
              if (!bindPairs.any((p) => p.$1 == i)) i
          ].take(1).toList()
        : [for (var i = 0; i < packed; i++) b.number()];
    return _Folder(coders, bindPairs, packedInputs);
  }

  static List<SevenZipEntry> _files(_Bytes b, _Streams streams) {
    final count = b.number();
    var emptyStream = List.filled(count, false);
    var emptyFile = <bool>[];
    var names = List.filled(count, '');
    List<int?>? attributes;
    for (;;) {
      final id = b.byte();
      if (id == 0x00) break;
      final size = b.number();
      final p = _Bytes(b.bytes(size));
      switch (id) {
        case 0x0e:
          emptyStream = p.bits(count);
        case 0x0f:
          emptyFile = p.bits(emptyStream.where((e) => e).length);
        case 0x11:
          if (p.byte() != 0) {
            throw const SevenZipException('external names are not supported');
          }
          final units = Uint16List(p._data.length ~/ 2 + 1);
          var n = 0, name = 0;
          while (name < count) {
            final unit = p.byte() | p.byte() << 8;
            if (unit == 0) {
              names[name++] = String.fromCharCodes(units, 0, n);
              n = 0;
            } else {
              units[n++] = unit;
            }
          }
        case 0x15:
          final defined = p.definedBits(count);
          if (p.byte() != 0) {
            throw const SevenZipException(
                'external attributes are not supported');
          }
          attributes = [for (final d in defined) d ? p.uint32() : null];
      }
    }
    final entries = <SevenZipEntry>[];
    var stream = 0, empty = 0;
    for (var i = 0; i < count; i++) {
      final name = names[i].replaceAll('\\', '/');
      if (emptyStream[i]) {
        final isFile = empty < emptyFile.length && emptyFile[empty];
        empty++;
        final attribute = attributes?[i];
        final directory = attribute == null ? !isFile : attribute & 0x10 != 0;
        entries.add(SevenZipEntry._(name, 0, directory, null, -1, 0));
        continue;
      }
      if (stream >= streams.substreams.length) {
        throw const SevenZipException('more files than streams');
      }
      final (folder, offset, size, crc) = streams.substreams[stream++];
      entries.add(SevenZipEntry._(name, size, false, crc, folder, offset));
    }
    return entries;
  }

  static String _method(List<int> id) =>
      id.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// [length] bytes from [start] of the output of [folder]
  static Future<Uint8List> _decode(
      ReadRange read, _Folder folder, int start, int length) async {
    if (folder.coders.length != 1 || folder.packSizes.length != 1) {
      throw SevenZipException('the method chain '
          '${folder.coders.map((c) => _method(c.id)).join('+')} '
          'is not supported');
    }
    final coder = folder.coders.single;
    final packed = await read(folder.packOffset, folder.packSizes.single);
    final size = folder.size;
    if (start + length > size) {
      throw const SevenZipException('an entry is past its folder');
    }
    switch (_method(coder.id)) {
      case '00':
        return Uint8List.sublistView(packed, start, start + length);
      case '030101':
        final p = coder.properties;
        if (p.length < 5) {
          throw const SevenZipException('LZMA properties are missing');
        }
        final lzma = LzmaDecoder();
        final (lc, lp, pb) = _lzmaProperties(p[0]);
        lzma.reset(
            literalContextBits: lc,
            literalPositionBits: lp,
            positionBits: pb,
            resetDictionary: true);
        final out = lzma.decode(InputMemoryStream(packed), start + length);
        return Uint8List.sublistView(out, start, start + length);
      case '21':
        if (coder.properties.isEmpty) {
          throw const SevenZipException('LZMA2 properties are missing');
        }
        return _lzma2(packed, coder.properties[0], start, length);
      case '06f10701':
        throw const SevenZipException('encrypted archives are not supported');
      default:
        throw SevenZipException(
            'the method ${_method(coder.id)} is not supported');
    }
  }

  static (int, int, int) _lzmaProperties(int value) {
    if (value >= 9 * 5 * 5) {
      throw const SevenZipException('invalid LZMA properties');
    }
    final lc = value % 9;
    value ~/= 9;
    return (lc, value % 5, value ~/ 5);
  }

  /// decodes the chunks of an LZMA2 stream, keeping the bytes of
  /// [start] .. [start] + [length] of its output
  static Uint8List _lzma2(
      Uint8List packed, int dictionaryProperty, int start, int length) {
    if (dictionaryProperty > 40) {
      throw const SevenZipException('invalid LZMA2 dictionary size');
    }
    final dictionarySize = dictionaryProperty == 40
        ? 0xffffffff
        : (2 | (dictionaryProperty & 1)) << (dictionaryProperty ~/ 2 + 11);
    final lzma = LzmaDecoder();
    final out = BytesBuilder(copy: false);
    final end = start + length;
    var at = 0, position = 0;
    int byte() {
      if (at >= packed.length) {
        throw const SevenZipException('LZMA2 data is truncated');
      }
      return packed[at++];
    }

    Uint8List take(int n) {
      if (at + n > packed.length) {
        throw const SevenZipException('LZMA2 data is truncated');
      }
      final bytes = Uint8List.sublistView(packed, at, at + n);
      at += n;
      return bytes;
    }

    void keep(Uint8List chunk) {
      final from = (start - position).clamp(0, chunk.length);
      final to = (end - position).clamp(0, chunk.length);
      if (to > from) out.add(Uint8List.fromList(chunk.sublist(from, to)));
      position += chunk.length;
    }

    while (position < end) {
      final control = byte();
      if (control == 0) break;
      if (control < 0x80) {
        if (control > 2) {
          throw SevenZipException('unknown LZMA2 control $control');
        }
        if (control == 1) lzma.reset(resetDictionary: true);
        final size = (byte() << 8 | byte()) + 1;
        keep(lzma.decodeUncompressed(InputMemoryStream(take(size)), size));
      } else {
        final size = ((control & 0x1f) << 16 | byte() << 8 | byte()) + 1;
        final packedSize = (byte() << 8 | byte()) + 1;
        final reset = (control >> 5) & 3;
        if (reset >= 2) {
          final (lc, lp, pb) = _lzmaProperties(byte());
          lzma.reset(
              literalContextBits: lc,
              literalPositionBits: lp,
              positionBits: pb,
              resetDictionary: reset == 3);
        } else if (reset == 1) {
          lzma.reset();
        }
        keep(lzma.decode(InputMemoryStream(take(packedSize)), size));
      }
      lzma.trimDictionary(dictionarySize);
    }
    final result = out.takeBytes();
    if (result.length != length) {
      throw const SevenZipException('LZMA2 data ended early');
    }
    return result;
  }
}
