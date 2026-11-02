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

  /// The color format with the bits of [psm]. A Z format used as a frame
  /// buffer or a texture holds its value in the bits of the color format of
  /// the same size; only the page layout differs.
  static int colorFormat(int psm) => psm >= z32 ? psm & 0xf : psm;

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

/// The page layout of a group of pixel formats. The storage unit of a pixel
/// is the base of its page plus an entry of [table], which holds the unit
/// index inside the page of every pixel of a page, by row.
final class GsLayout {
  final Int32List table;

  /// log2 of the page width and height in pixels
  final int xBits, yBits;

  /// log2 of the storage units in a 32-bit word
  final int unitShift;

  /// pages of the 8-bit and 4-bit formats are 128 pixels wide, so a row of
  /// the buffer holds half as many of them
  final bool wide;

  final int _xMask, _yMask;

  GsLayout._(int psm, this.xBits, this.yBits, this.unitShift)
      : table = Int32List(1 << (xBits + yBits)),
        wide = xBits == 7,
        _xMask = (1 << xBits) - 1,
        _yMask = (1 << yBits) - 1 {
    for (var y = 0; y <= _yMask; y++) {
      for (var x = 0; x <= _xMask; x++) {
        table[y << xBits | x] = GsMemory.unitIndex(psm, 0, 1, x, y);
      }
    }
  }

  /// the pages in a row of a buffer [bw] units of 64 pixels wide
  int pagesInRow(int bw) => wide ? (bw + 1) >> 1 : bw;

  /// [GsMemory.unitIndex] for a buffer of [pagesInRow] pages per row
  @pragma('vm:prefer-inline')
  int index(int bp, int pages, int x, int y) =>
      ((bp * 64 + ((y >> yBits) * pages + (x >> xBits)) * 2048) << unitShift) +
      table[(y & _yMask) << xBits | (x & _xMask)];
}

/// The 4 MiB of GS local memory with the page, block and column layout of
/// each pixel format.
///
/// Memory is organised in 8 KiB pages of 32 blocks of 256 bytes, and a block
/// in four columns of 64 bytes. `bp` is a block pointer (256 byte units) and
/// `bw` a buffer width in units of 64 pixels.
///
/// The 8-bit and 4-bit layouts are checked against the conversion from
/// 8-bit and 4-bit textures to 32-bit uploads that PS2 Linux developers
/// published ("Sparky's swizzle code"): a texture written in one format reads
/// back in the other.
class GsMemory {
  static const size = 4 * 1024 * 1024;
  static const _wordMask = size ~/ 4 - 1;
  static const _halfMask = size ~/ 2 - 1;

  final Uint8List bytes;
  final Uint32List _words;
  final Uint16List _halves;

  /// the layout of every PSM value; the invalid ones use the 32-bit layout
  final List<GsLayout> _layouts;

  GsMemory() : this._(Uint8List(size));

  GsMemory._(this.bytes)
      : _words = Uint32List.view(bytes.buffer, bytes.offsetInBytes),
        _halves = Uint16List.view(bytes.buffer, bytes.offsetInBytes),
        _layouts = _buildLayouts();

  static List<GsLayout> _buildLayouts() {
    final ct32 = GsLayout._(GsPsm.ct32, 6, 5, 0);
    final z32 = GsLayout._(GsPsm.z32, 6, 5, 0);
    final layouts = List.filled(64, ct32);
    for (final psm in [GsPsm.z32, GsPsm.z24]) {
      layouts[psm] = z32;
    }
    for (final psm in [GsPsm.ct16, GsPsm.ct16s, GsPsm.z16, GsPsm.z16s]) {
      layouts[psm] = GsLayout._(psm, 6, 6, 1);
    }
    layouts[GsPsm.t8] = GsLayout._(GsPsm.t8, 7, 6, 2);
    layouts[GsPsm.t4] = GsLayout._(GsPsm.t4, 7, 7, 3);
    return layouts;
  }

  /// the layout of format [psm]
  GsLayout layout(int psm) => _layouts[psm & 63];

  /// [unitIndex] through the page tables
  int index(int psm, int bp, int bw, int x, int y) {
    final layout = _layouts[psm & 63];
    return layout.index(bp, layout.pagesInRow(bw), x, y);
  }

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
        // a 128x128 page of 4-bit pixels covers a 64x32 page of 32-bit
        // pixels: a block of 32x16 pixels takes the 8x8 block of the 32-bit
        // page with its x and y swapped, and a pixel takes a nibble of a
        // byte of a 32-bit pixel of that block
        final page = (y >> 7) * ((bw + 1) >> 1) + (x >> 7);
        final lx = x & 127, ly = y & 127;
        final swap = ((ly + 2) >> 2) & 1 == 0 ? 0 : 4;
        final cx = (ly & ~15) >> 1 | ((lx + swap) & 7);
        final cy = (lx & ~31) >> 2 | ((((ly & ~3) >> 1) + (ly & 1)) & 7);
        final word =
            bp * 64 + page * 2048 + unitIndex(GsPsm.ct32, 0, 1, cx, cy);
        return (word * 4 + ((lx >> 3) & 3)) * 2 + ((ly >> 1) & 1);
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

  // the word and halfword views assume a little-endian host
  int word(int index) => _words[index & _wordMask];

  void setWord(int index, int value) => _words[index & _wordMask] = value;

  int _half(int index) => _halves[index & _halfMask];

  void _setHalf(int index, int value) => _halves[index & _halfMask] = value;

  /// the raw pixel value of the format at (x, y)
  int read(int psm, int bp, int bw, int x, int y) =>
      readAt(psm, index(psm, bp, bw, x, y));

  /// the raw pixel value of the format at unit [i] from [index]
  int readAt(int psm, int i) {
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

  void write(int psm, int bp, int bw, int x, int y, int value) =>
      writeAt(psm, index(psm, bp, bw, x, y), value);

  /// writes the pixel at unit [i] from [index]
  void writeAt(int psm, int i, int value) {
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
