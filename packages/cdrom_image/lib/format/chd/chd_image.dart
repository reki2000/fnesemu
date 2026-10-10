// CD-ROM images in the CHD format (version 5): the TOC from the metadata and
// the sectors from the compressed hunks.
import 'dart:typed_data';

import '../../filesystem_api.dart';
import '../../image_api.dart';
import 'cd_ecc.dart';
import 'codecs.dart';
import 'flac.dart';

/// bytes of a CD frame in a CHD: the sector and the subcode
const _frameBytes = 2448;
const _sectorBytes = 2352;

/// the frames of a track are padded to a multiple of this in a CHD
const _trackPadding = 4;

const _sync = [
  0,
  0xff,
  0xff,
  0xff,
  0xff,
  0xff,
  0xff,
  0xff,
  0xff,
  0xff,
  0xff,
  0
];

int _tag(String s) =>
    s.codeUnitAt(0) << 24 |
    s.codeUnitAt(1) << 16 |
    s.codeUnitAt(2) << 8 |
    s.codeUnitAt(3);

final _cdzl = _tag('cdzl'),
    _cdlz = _tag('cdlz'),
    _cdzs = _tag('cdzs'),
    _cdfl = _tag('cdfl');

// the kinds of the map entries
const _compressed3 = 3; // 0..3: the codec of the header
const _uncompressed = 4;
const _self = 5;
const _parent = 6;
const _rleSmall = 7;
const _rleLarge = 8;
const _self0 = 9;
const _self1 = 10;
const _parentSelf = 11;
const _parent0 = 12;
const _parent1 = 13;

/// reads bits from the most significant bit. reads past the end give zeros.
class _Bits {
  final Uint8List data;
  int pos = 0;

  _Bits(this.data);

  int read(int n) {
    var v = 0;
    for (int i = 0; i < n; i++) {
      final byte = pos >> 3;
      final b = byte < data.length ? (data[byte] >> (7 - (pos & 7))) & 1 : 0;
      v = (v << 1) | b;
      pos++;
    }
    return v;
  }

  int peek(int n) {
    final save = pos;
    final v = read(n);
    pos = save;
    return v;
  }
}

/// the Huffman code of the compressed map: the code lengths are run-length
/// coded, and the codes are assigned from the longest code
class _Huffman {
  final int codes, maxBits;
  final Uint16List _lookup; // (code << 5) | bits
  _Huffman(this.codes, this.maxBits) : _lookup = Uint16List(1 << maxBits);

  void importTreeRle(_Bits bits) {
    final lengthBits = maxBits >= 16 ? 5 : (maxBits >= 8 ? 4 : 3);
    final lengths = Uint8List(codes);
    var code = 0;
    while (code < codes) {
      var n = bits.read(lengthBits);
      if (n != 1) {
        lengths[code++] = n;
        continue;
      }
      n = bits.read(lengthBits);
      if (n == 1) {
        lengths[code++] = 1;
        continue;
      }
      var repeat = bits.read(lengthBits) + 3;
      while (repeat-- > 0 && code < codes) {
        lengths[code++] = n;
      }
    }

    // the first code of each length, from the longest
    final start = List<int>.filled(33, 0);
    for (final l in lengths) {
      if (l > maxBits) throw const FormatException('chd: bad map tree');
      start[l]++;
    }
    var cur = 0;
    for (int len = 32; len > 0; len--) {
      final next = (cur + start[len]) >> 1;
      if (len != 1 && next * 2 != cur + start[len]) {
        throw const FormatException('chd: bad map tree');
      }
      start[len] = cur;
      cur = next;
    }

    for (int c = 0; c < codes; c++) {
      final len = lengths[c];
      if (len == 0) continue;
      final value = start[len]++;
      final shift = maxBits - len;
      final first = value << shift;
      for (int i = 0; i < 1 << shift; i++) {
        _lookup[first + i] = (c << 5) | len;
      }
    }
  }

  int decode(_Bits bits) {
    final entry = _lookup[bits.peek(maxBits)];
    bits.pos += entry & 0x1f;
    return entry >> 5;
  }
}

/// CRC-16-CCITT (polynomial 0x1021, initial value 0xffff)
int _crc16(Uint8List data) {
  var crc = 0xffff;
  for (final b in data) {
    crc ^= b << 8;
    for (int i = 0; i < 8; i++) {
      crc = crc & 0x8000 != 0
          ? ((crc << 1) ^ 0x1021) & 0xffff
          : (crc << 1) & 0xffff;
    }
  }
  return crc;
}

int _be(Uint8List b, int offset, int bytes) {
  var v = 0;
  for (int i = 0; i < bytes; i++) {
    v = (v << 8) | b[offset + i];
  }
  return v;
}

/// a track of the CHD metadata
class _Track {
  final int number;
  final String type;
  final int frames; // in the CHD, with the pregap if it is stored
  final int pregap;
  final bool pregapStored;
  final String pregapType;
  final int postgap;

  _Track(this.number, this.type, this.frames, this.pregap, this.pregapStored,
      this.pregapType, this.postgap);

  bool get isAudio => type == 'AUDIO';

  static int dataSize(String type) => switch (type) {
        'MODE1' || 'MODE2_FORM1' => 2048,
        'MODE1_RAW' || 'MODE2_RAW' || 'AUDIO' => 2352,
        'MODE2' || 'MODE2_FORM_MIX' => 2336,
        'MODE2_FORM2' => 2324,
        _ => throw FormatException('chd: unknown track type $type'),
      };
}

/// sectors from [lba]: stored in the CHD from [frame], or silence if null
class _Span {
  final int lba, count;
  final int? frame;
  final String type;
  _Span(this.lba, this.count, this.frame, this.type);
}

/// a CD-ROM image in a CHD file
class ChdImage implements DiscImage {
  final DiscFile file;
  final int _hunkBytes;
  final List<int> _codecs;
  final Uint8List _kinds; // of the map entries
  final List<int> _offsets;
  final Uint32List _lengths;
  final List<_Span> _spans;
  @override
  final DiscToc toc;

  /// decompressed hunks, the most recently used last
  final _hunks = <int, Future<Uint8List>>{};
  static const _cachedHunks = 32;

  ChdImage._(this.file, this._hunkBytes, this._codecs, this._kinds,
      this._offsets, this._lengths, this._spans, this.toc);

  static bool isChd(String name) => name.toLowerCase().endsWith('.chd');

  static Future<ChdImage> open(DiscFile file) async {
    final header = await file.read(0, 124);
    if (header.length < 16 ||
        String.fromCharCodes(header.sublist(0, 8)) != 'MComprHD') {
      throw const FormatException('chd: not a CHD file');
    }
    final version = _be(header, 12, 4);
    if (version != 5) {
      throw FormatException('chd: version $version is not supported');
    }
    final codecs = [for (int i = 0; i < 4; i++) _be(header, 16 + i * 4, 4)];
    final logicalBytes = _be(header, 32, 8);
    final mapOffset = _be(header, 40, 8);
    final metaOffset = _be(header, 48, 8);
    final hunkBytes = _be(header, 56, 4);
    final unitBytes = _be(header, 60, 4);
    if (header.sublist(104, 124).any((b) => b != 0)) {
      throw const FormatException('chd: a CHD with a parent is not supported');
    }
    if (unitBytes != _frameBytes || hunkBytes % _frameBytes != 0) {
      throw const FormatException('chd: not a CD-ROM image');
    }
    final hunkCount = (logicalBytes + hunkBytes - 1) ~/ hunkBytes;

    final kinds = Uint8List(hunkCount);
    final offsets = List<int>.filled(hunkCount, 0);
    final lengths = Uint32List(hunkCount);
    if (codecs[0] == 0) {
      // uncompressed: the hunk offsets in hunks
      final map = await file.read(mapOffset, hunkCount * 4);
      for (int i = 0; i < hunkCount; i++) {
        kinds[i] = _uncompressed;
        offsets[i] = _be(map, i * 4, 4) * hunkBytes;
        lengths[i] = hunkBytes;
      }
    } else {
      await _readMap(
          file, mapOffset, hunkBytes, unitBytes, kinds, offsets, lengths);
    }

    final tracks = await _readTracks(file, metaOffset);
    final (spans, discTracks, total) = _layout(tracks);
    return ChdImage._(file, hunkBytes, codecs, kinds, offsets, lengths, spans,
        DiscToc(discTracks, total));
  }

  static Future<void> _readMap(
      DiscFile file,
      int mapOffset,
      int hunkBytes,
      int unitBytes,
      Uint8List kinds,
      List<int> offsets,
      Uint32List lengths) async {
    final head = await file.read(mapOffset, 16);
    final mapBytes = _be(head, 0, 4);
    final firstOffset = _be(head, 4, 6);
    final mapCrc = _be(head, 10, 2);
    final lengthBits = head[12], selfBits = head[13], parentBits = head[14];
    final bits = _Bits(await file.read(mapOffset + 16, mapBytes));
    final count = kinds.length;

    // the kinds, run-length coded
    final huffman = _Huffman(16, 8)..importTreeRle(bits);
    var last = 0, repeat = 0;
    for (int i = 0; i < count; i++) {
      if (repeat > 0) {
        kinds[i] = last;
        repeat--;
        continue;
      }
      final v = huffman.decode(bits);
      if (v == _rleSmall) {
        kinds[i] = last;
        repeat = 2 + huffman.decode(bits);
      } else if (v == _rleLarge) {
        kinds[i] = last;
        repeat = 2 + 16 + (huffman.decode(bits) << 4);
        repeat += huffman.decode(bits);
      } else {
        kinds[i] = last = v;
      }
    }

    // the offsets and lengths
    final crcs = Uint16List(count);
    var cur = firstOffset, lastSelf = 0, lastParent = 0;
    for (int i = 0; i < count; i++) {
      var offset = cur, length = 0;
      switch (kinds[i]) {
        case <= _compressed3:
          length = bits.read(lengthBits);
          crcs[i] = bits.read(16);
          cur += length;
        case _uncompressed:
          length = hunkBytes;
          crcs[i] = bits.read(16);
          cur += length;
        case _self:
          lastSelf = offset = bits.read(selfBits);
        case _parent:
          lastParent = offset = bits.read(parentBits);
        case _self1:
          lastSelf++;
          kinds[i] = _self;
          offset = lastSelf;
        case _self0:
          kinds[i] = _self;
          offset = lastSelf;
        case _parentSelf:
          kinds[i] = _parent;
          lastParent = offset = i * hunkBytes ~/ unitBytes;
        case _parent1:
          lastParent += hunkBytes ~/ unitBytes;
          kinds[i] = _parent;
          offset = lastParent;
        case _parent0:
          kinds[i] = _parent;
          offset = lastParent;
        default:
          throw FormatException('chd: bad map entry ${kinds[i]}');
      }
      offsets[i] = offset;
      lengths[i] = length;
    }

    // the CRC of the map in its raw form: kind, length 24, offset 48, crc 16
    final raw = Uint8List(count * 12);
    for (int i = 0; i < count; i++) {
      final o = i * 12;
      raw[o] = kinds[i];
      for (int b = 0; b < 3; b++) {
        raw[o + 1 + b] = lengths[i] >> (16 - b * 8);
      }
      for (int b = 0; b < 6; b++) {
        raw[o + 4 + b] = offsets[i] >> (40 - b * 8);
      }
      raw[o + 10] = crcs[i] >> 8;
      raw[o + 11] = crcs[i];
    }
    if (_crc16(raw) != mapCrc) {
      throw const FormatException('chd: bad map CRC');
    }
  }

  /// the tracks of the CD-ROM metadata
  static Future<List<_Track>> _readTracks(DiscFile file, int offset) async {
    final tracks = <_Track>[];
    final cht2 = _tag('CHT2'), chtr = _tag('CHTR'), chgd = _tag('CHGD');
    while (offset != 0) {
      final head = await file.read(offset, 16);
      final tag = _be(head, 0, 4);
      final length = _be(head, 5, 3);
      final next = _be(head, 8, 8);
      if (tag == cht2 || tag == chtr || tag == chgd) {
        final text = String.fromCharCodes(
            (await file.read(offset + 16, length)).takeWhile((c) => c != 0));
        final f = {
          for (final m in RegExp(r'(\w+):(\S*)').allMatches(text))
            m.group(1)!: m.group(2)!
        };
        final pregapType = f['PGTYPE'] ?? '';
        tracks.add(_Track(
            int.parse(f['TRACK'] ?? '0'),
            f['TYPE'] ?? '',
            int.parse(f['FRAMES'] ?? '0'),
            int.parse(f['PREGAP'] ?? '0'),
            pregapType.startsWith('V'),
            pregapType.startsWith('V') ? pregapType.substring(1) : pregapType,
            int.parse(f['POSTGAP'] ?? '0')));
      }
      offset = next;
    }
    if (tracks.isEmpty) throw const FormatException('chd: no CD-ROM tracks');
    tracks.sort((a, b) => a.number.compareTo(b.number));
    return tracks;
  }

  /// the sectors by LBA, and the TOC
  static (List<_Span>, List<DiscTrack>, int) _layout(List<_Track> tracks) {
    final spans = <_Span>[];
    final starts = <(int, bool, int)>[];
    var lba = 0, frame = 0;
    for (final t in tracks) {
      _Track.dataSize(t.type); // a known type
      var stored = t.frames;
      var trackFrame = frame;
      if (t.pregap > 0) {
        if (t.pregapStored) {
          // the pregap is in the CHD, before the track
          spans.add(_Span(lba, t.pregap, frame,
              t.pregapType.isEmpty ? t.type : t.pregapType));
          trackFrame += t.pregap;
          stored -= t.pregap;
        } else {
          spans.add(_Span(lba, t.pregap, null, t.type));
        }
        lba += t.pregap;
      }
      starts.add((t.number, t.isAudio, lba));
      spans.add(_Span(lba, stored, trackFrame, t.type));
      lba += stored;
      if (t.postgap > 0) {
        spans.add(_Span(lba, t.postgap, null, t.type));
        lba += t.postgap;
      }
      frame +=
          t.frames + (_trackPadding - t.frames % _trackPadding) % _trackPadding;
    }
    final total = lba;
    final discTracks = <DiscTrack>[
      for (int i = 0; i < starts.length; i++)
        DiscTrack(starts[i].$1, starts[i].$2, starts[i].$3,
            (i + 1 < starts.length ? starts[i + 1].$3 : total) - starts[i].$3)
    ];
    return (spans, discTracks, total);
  }

  @override
  int get totalSectors => toc.totalSectors;

  @override
  bool isReadable(int lba) => lba >= 0 && lba < totalSectors;

  @override
  Future<List<Uint8List>> readSectors(int lba, int count) async {
    final result = <Uint8List>[];
    for (int i = 0; i < count; i++) {
      result.add(await _sector(lba + i));
    }
    return result;
  }

  _Span _spanOf(int lba) {
    var lo = 0, hi = _spans.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_spans[mid].lba <= lba) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return _spans[lo];
  }

  Future<Uint8List> _sector(int lba) async {
    if (!isReadable(lba)) throw RangeError.range(lba, 0, totalSectors - 1);
    final span = _spanOf(lba);
    final frame = span.frame;
    if (frame == null) return Uint8List(_sectorBytes);

    final byte = (frame + lba - span.lba) * _frameBytes;
    final hunk = await _hunk(byte ~/ _hunkBytes);
    final at = byte % _hunkBytes;
    final size = _Track.dataSize(span.type);
    final data = Uint8List.sublistView(hunk, at, at + size);

    if (span.type == 'AUDIO') {
      // CD audio is big-endian in a CHD
      final out = Uint8List(_sectorBytes);
      for (int i = 0; i < _sectorBytes; i += 2) {
        out[i] = data[i + 1];
        out[i + 1] = data[i];
      }
      return out;
    }
    if (size == _sectorBytes) return Uint8List.fromList(data);
    return _rawSector(data, lba, span.type);
  }

  /// a raw sector of the user data of a cooked sector
  static Uint8List _rawSector(Uint8List data, int lba, String type) {
    final out = Uint8List(_sectorBytes)..setAll(0, _sync);
    final msf = lba + 150;
    int bcd(int v) => ((v ~/ 10) << 4) | (v % 10);
    out[12] = bcd(msf ~/ (60 * 75));
    out[13] = bcd(msf ~/ 75 % 60);
    out[14] = bcd(msf % 75);
    switch (type) {
      case 'MODE1':
        out[15] = 1;
        out.setAll(16, data);
      case 'MODE2' || 'MODE2_FORM_MIX':
        out[15] = 2;
        out.setAll(16, data);
      default:
        throw FormatException('chd: $type tracks are not supported');
    }
    return out;
  }

  Future<Uint8List> _hunk(int index) {
    final cached = _hunks.remove(index);
    if (cached != null) {
      _hunks[index] = cached; // the most recently used
      return cached;
    }
    final future = _readHunk(index);
    _hunks[index] = future;
    // a failed read is read again next time
    future.catchError((Object _) {
      if (identical(_hunks[index], future)) _hunks.remove(index);
      return Uint8List(0);
    });
    while (_hunks.length > _cachedHunks) {
      _hunks.remove(_hunks.keys.first);
    }
    return future;
  }

  Future<Uint8List> _readHunk(int index) async {
    final kind = _kinds[index];
    final offset = _offsets[index];
    switch (kind) {
      case _uncompressed:
        final data = await file.read(offset, _hunkBytes);
        return data.length == _hunkBytes
            ? data
            : (Uint8List(_hunkBytes)..setAll(0, data));
      case _self:
        return _hunk(offset);
      case _parent:
        throw const FormatException(
            'chd: a CHD with a parent is not supported');
      default:
        final src = await file.read(offset, _lengths[index]);
        return _decompress(_codecs[kind], src);
    }
  }

  /// decompresses a hunk of the CD codecs: the sectors and the subcodes of
  /// the frames compressed separately
  Uint8List _decompress(int codec, Uint8List src) {
    final frames = _hunkBytes ~/ _frameBytes;
    final out = Uint8List(_hunkBytes);
    final sectorBytes = frames * _sectorBytes;

    if (codec == _cdfl) {
      // FLAC of the sectors, then deflate of the subcodes (not used here)
      final (sectors, _) = FlacDecoder.decodeStereo16(src, sectorBytes ~/ 4);
      for (int f = 0; f < frames; f++) {
        out.setRange(f * _frameBytes, f * _frameBytes + _sectorBytes, sectors,
            f * _sectorBytes);
      }
      return out;
    }
    if (codec != _cdzl && codec != _cdlz && codec != _cdzs) {
      throw FormatException('chd: the codec ${String.fromCharCodes([
            codec >> 24,
            (codec >> 16) & 0xff,
            (codec >> 8) & 0xff,
            codec & 0xff
          ])} is not supported');
    }

    // the frames whose sync and ECC are removed, and the length of the
    // compressed sectors
    final eccBytes = (frames + 7) >> 3;
    final lengthBytes = _hunkBytes < 65536 ? 2 : 3;
    final header = eccBytes + lengthBytes;
    final baseLength = _be(src, eccBytes, lengthBytes);
    final base = Uint8List.sublistView(src, header, header + baseLength);
    final sectors = codec == _cdzl
        ? inflate(base, sectorBytes)
        : codec == _cdlz
            ? lzmaDecode(base, sectorBytes)
            : zstdDecode(base, sectorBytes);
    for (int f = 0; f < frames; f++) {
      final at = f * _frameBytes;
      out.setRange(at, at + _sectorBytes, sectors, f * _sectorBytes);
      if (src[f >> 3] & (1 << (f & 7)) != 0) {
        final sector = Uint8List.sublistView(out, at, at + _sectorBytes);
        sector.setAll(0, _sync);
        generateEcc(sector);
      }
    }
    return out;
  }
}
