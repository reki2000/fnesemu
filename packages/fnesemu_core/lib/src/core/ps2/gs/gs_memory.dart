import 'dart:typed_data';

/// Pixel storage formats of the GS (PSM values).
class GsPsm {
  static const ct32 = 0x00, ct24 = 0x01, ct16 = 0x02, ct16s = 0x0a;
  static const t8 = 0x13, t4 = 0x14, t8h = 0x1b, t4hl = 0x24, t4hh = 0x2c;
  static const z32 = 0x30, z24 = 0x31, z16 = 0x32, z16s = 0x3a;

  /// bits per pixel in local memory (8H and 4H formats occupy a 32-bit word)
  static int bits(int psm) => switch (psm) {
        ct32 || ct24 || z32 || z24 || t8h || t4hl || t4hh => 32,
        ct16 || ct16s || z16 || z16s => 16,
        t8 => 8,
        _ => 4,
      };

  /// bits carried by one pixel of the format
  static int pixelBits(int psm) => switch (psm) {
        ct32 || z32 => 32,
        ct24 || z24 => 24,
        ct16 || ct16s || z16 || z16s => 16,
        t8 || t8h => 8,
        _ => 4,
      };

  static bool isValid(int psm) =>
      psm == ct32 ||
      psm == ct24 ||
      psm == ct16 ||
      psm == ct16s ||
      psm == t8 ||
      psm == t4 ||
      psm == t8h ||
      psm == t4hl ||
      psm == t4hh ||
      psm == z32 ||
      psm == z24 ||
      psm == z16 ||
      psm == z16s;
}

/// The 4 MiB of GS local memory with the page, block and column layout of
/// each pixel format.
///
/// Memory is organised in 8 KiB pages of 32 blocks of 256 bytes, and a block
/// in four columns of 64 bytes. `bp` is a block pointer (256 byte units) and
/// `bw` a buffer width in units of 64 pixels.
///
/// The column layouts of the 8-bit and 4-bit formats, and the odd-column
/// handling of them, are written from memory of the layout diagrams and are
/// not yet checked against hardware captures. The tests only verify that
/// every pixel of a page maps to its own storage unit.
class GsMemory {
  static const size = 4 * 1024 * 1024;
  static const _wordMask = size ~/ 4 - 1;

  final Uint8List bytes;
  final ByteData _view;

  GsMemory() : this._(Uint8List(size));

  GsMemory._(this.bytes) : _view = ByteData.sublistView(bytes);

  static const _col32 = [0, 1, 4, 5, 8, 9, 12, 13, 2, 3, 6, 7, 10, 11, 14, 15];
  static const _blk32 = [
    0, 1, 4, 5, 16, 17, 20, 21, //
    2, 3, 6, 7, 18, 19, 22, 23,
    8, 9, 12, 13, 24, 25, 28, 29,
    10, 11, 14, 15, 26, 27, 30, 31,
  ];
  static const _col16 = [
    0, 2, 8, 10, 16, 18, 24, 26, 1, 3, 9, 11, 17, 19, 25, 27, //
    4, 6, 12, 14, 20, 22, 28, 30, 5, 7, 13, 15, 21, 23, 29, 31,
  ];
  static const _blk16 = [
    0, 2, 4, 6, //
    1, 3, 5, 7,
    8, 10, 12, 14,
    9, 11, 13, 15,
    16, 18, 20, 22,
    17, 19, 21, 23,
    24, 26, 28, 30,
    25, 27, 29, 31,
  ];
  static const _blk16s = [
    0, 2, 16, 18, //
    1, 3, 17, 19,
    8, 10, 24, 26,
    9, 11, 25, 27,
    4, 6, 20, 22,
    5, 7, 21, 23,
    12, 14, 28, 30,
    13, 15, 29, 31,
  ];
  static const _col8 = [
    0, 4, 16, 20, 32, 36, 48, 52, 2, 6, 18, 22, 34, 38, 50, 54, //
    8, 12, 24, 28, 40, 44, 56, 60, 10, 14, 26, 30, 42, 46, 58, 62,
    33, 37, 49, 53, 1, 5, 17, 21, 35, 39, 51, 55, 3, 7, 19, 23,
    41, 45, 57, 61, 9, 13, 25, 29, 43, 47, 59, 63, 11, 15, 27, 31,
  ];
  static const _col4 = [
    0, 8, 32, 40, 64, 72, 96, 104, 2, 10, 34, 42, 66, 74, 98, 106, //
    4, 12, 36, 44, 68, 76, 100, 108, 6, 14, 38, 46, 70, 78, 102, 110,
    16, 24, 48, 56, 80, 88, 112, 120, 18, 26, 50, 58, 82, 90, 114, 122,
    20, 28, 52, 60, 84, 92, 116, 124, 22, 30, 54, 62, 86, 94, 118, 126,
    65, 73, 97, 105, 1, 9, 33, 41, 67, 75, 99, 107, 3, 11, 35, 43,
    69, 77, 101, 109, 5, 13, 37, 45, 71, 79, 103, 111, 7, 15, 39, 47,
    81, 89, 113, 121, 17, 25, 49, 57, 83, 91, 115, 123, 19, 27, 51, 59,
    85, 93, 117, 125, 21, 29, 53, 61, 87, 95, 119, 127, 23, 31, 55, 63,
  ];
  static const _blk4 = [
    0, 2, 8, 10, //
    1, 3, 9, 11,
    4, 6, 12, 14,
    5, 7, 13, 15,
    16, 18, 24, 26,
    17, 19, 25, 27,
    20, 22, 28, 30,
    21, 23, 29, 31,
  ];

  static bool _isZ(int psm) => psm >= 0x30;

  /// Index of the storage unit of pixel (x, y): a 32-bit word for the 32-bit
  /// formats (including 8H and 4H), a halfword, a byte or a nibble.
  static int unitIndex(int psm, int bp, int bw, int x, int y) {
    switch (psm) {
      case GsPsm.ct16 || GsPsm.ct16s || GsPsm.z16 || GsPsm.z16s:
        final page = (y >> 6) * bw + (x >> 6);
        var block = (psm == GsPsm.ct16s || psm == GsPsm.z16s
            ? _blk16s
            : _blk16)[((y >> 3) & 7) * 4 + ((x >> 4) & 3)];
        if (_isZ(psm)) block ^= 24;
        final word = bp * 64 + page * 2048 + block * 64;
        return word * 2 + ((y >> 1) & 3) * 32 + _col16[(y & 1) * 16 + (x & 15)];
      case GsPsm.t8:
        final page = (y >> 6) * ((bw + 1) >> 1) + (x >> 7);
        final block = _blk32[((y >> 4) & 3) * 8 + ((x >> 4) & 7)];
        final column = (y >> 2) & 3;
        final cx = column & 1 == 0 ? x & 15 : (x & 15) ^ 4;
        final word = bp * 64 + page * 2048 + block * 64;
        return word * 4 + column * 64 + _col8[(y & 3) * 16 + cx];
      case GsPsm.t4:
        final page = (y >> 7) * ((bw + 1) >> 1) + (x >> 7);
        final block = _blk4[((y >> 4) & 7) * 4 + ((x >> 5) & 3)];
        final column = (y >> 2) & 3;
        final cx = column & 1 == 0 ? x & 31 : (x & 31) ^ 8;
        final word = bp * 64 + page * 2048 + block * 64;
        return word * 8 + column * 128 + _col4[(y & 3) * 32 + cx];
      default:
        final page = (y >> 5) * bw + (x >> 6);
        var block = _blk32[((y >> 3) & 3) * 8 + ((x >> 3) & 7)];
        if (_isZ(psm)) block ^= 24;
        return bp * 64 +
            page * 2048 +
            block * 64 +
            ((y >> 1) & 3) * 16 +
            _col32[(y & 1) * 8 + (x & 7)];
    }
  }

  int word(int index) =>
      _view.getUint32((index & _wordMask) * 4, Endian.little);

  void setWord(int index, int value) => _view.setUint32(
      (index & _wordMask) * 4, value & 0xffffffff, Endian.little);

  int _half(int index) => _view.getUint16(
      ((index >> 1) & _wordMask) * 4 + (index & 1) * 2, Endian.little);

  void _setHalf(int index, int value) => _view.setUint16(
      ((index >> 1) & _wordMask) * 4 + (index & 1) * 2, value, Endian.little);

  /// the raw pixel value of the format at (x, y)
  int read(int psm, int bp, int bw, int x, int y) {
    final i = unitIndex(psm, bp, bw, x, y);
    switch (psm) {
      case GsPsm.ct32 || GsPsm.z32:
        return word(i);
      case GsPsm.ct24 || GsPsm.z24:
        return word(i) & 0xffffff;
      case GsPsm.t8h:
        return word(i) >>> 24;
      case GsPsm.t4hl:
        return (word(i) >>> 24) & 15;
      case GsPsm.t4hh:
        return word(i) >>> 28;
      case GsPsm.t8:
        return bytes[i & (size - 1)];
      case GsPsm.t4:
        final b = bytes[(i >> 1) & (size - 1)];
        return i & 1 == 0 ? b & 15 : b >> 4;
      default:
        return _half(i);
    }
  }

  void write(int psm, int bp, int bw, int x, int y, int value) {
    final i = unitIndex(psm, bp, bw, x, y);
    switch (psm) {
      case GsPsm.ct32 || GsPsm.z32:
        setWord(i, value);
      case GsPsm.ct24 || GsPsm.z24:
        setWord(i, (word(i) & 0xff000000) | (value & 0xffffff));
      case GsPsm.t8h:
        setWord(i, (word(i) & 0xffffff) | ((value & 0xff) << 24));
      case GsPsm.t4hl:
        setWord(i, (word(i) & 0xf0ffffff) | ((value & 15) << 24));
      case GsPsm.t4hh:
        setWord(i, (word(i) & 0x0fffffff) | ((value & 15) << 28));
      case GsPsm.t8:
        bytes[i & (size - 1)] = value;
      case GsPsm.t4:
        final a = (i >> 1) & (size - 1), b = bytes[a];
        bytes[a] = i & 1 == 0
            ? (b & 0xf0) | (value & 15)
            : (b & 15) | ((value & 15) << 4);
      default:
        _setHalf(i, value);
    }
  }
}
