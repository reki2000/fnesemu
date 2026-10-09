import 'dart:typed_data';

/// S-DD1: a cartridge chip which maps 1MB rom banks into $C0-$FF and
/// decompresses graphics while a DMA channel reads them.
///
/// Written after the fullsnes documentation of the ports and of the
/// decompression algorithm (a context model over Golomb coded runs).
class Sdd1 {
  final Uint8List rom;
  final int _romMask;

  Sdd1(this.rom) : _romMask = _mask(rom.length);

  static int _mask(int length) {
    var size = 1;
    while (size < length) {
      size <<= 1;
    }
    return size - 1;
  }

  int _dmaEnable = 0; // $4800: channels that may decompress
  int _dmaReady = 0; // $4801: channels that decompress on their next DMA
  final _mmc = List<int>.filled(4, 0); // $4804-$4807: 1MB bank of $C0-$FF

  late final _decompressor = _Decompressor(this);

  void reset() {
    _dmaEnable = _dmaReady = 0;
    for (var i = 0; i < 4; i++) {
      _mmc[i] = i;
    }
  }

  /// true if [addr] ($00-$3F/$80-$BF:$4800-$480F) is a register
  static bool isRegister(int bank, int page) =>
      (bank & 0x7f) < 0x40 && page >= 0x4800 && page < 0x4810;

  int readRegister(int page) => switch (page & 0xf) {
        0 => _dmaEnable,
        1 => _dmaReady,
        4 || 5 || 6 || 7 => _mmc[page & 3],
        _ => 0,
      };

  void writeRegister(int page, int data) {
    switch (page & 0xf) {
      case 0:
        _dmaEnable = data;
      case 1:
        _dmaReady = data;
      case 4 || 5 || 6 || 7:
        _mmc[page & 3] = data & 0xf;
    }
  }

  /// rom read through the bank registers ($C0-$FF and the decompressor)
  int mmcRead(int addr) =>
      rom[((_mmc[(addr >> 20) & 3] << 20) | (addr & 0xfffff)) & _romMask];

  /// called when DMA channel [channel] starts from [addr]: returns true if
  /// the channel reads decompressed data, through [dmaRead]
  bool dmaBegin(int channel, int addr) {
    if ((_dmaEnable & _dmaReady & (1 << channel)) == 0) return false;
    _decompressor.init(addr);
    return true;
  }

  int dmaRead() => _decompressor.read();

  /// a channel decompresses only for the one DMA after $4801 is written
  void dmaEnd(int channel) => _dmaReady &= ~(1 << channel);
}

/// the decompressor of the fullsnes description: bitplanes of 2/4/8 bits
/// per pixel (or bytes of 8 planes), each bit predicted from the bits before
/// it in its plane, and coded as runs of the more probable bit
class _Decompressor {
  final Sdd1 chip;
  _Decompressor(this.chip);

  static const _codeSize = [
    0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, //
    4, 4, 5, 5, 6, 6, 7, 7, 0, 1, 2, 3, 4, 5, 6, 7,
  ];
  static const _mpsNext = [
    25, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, //
    18, 19, 20, 21, 22, 23, 24, 24, 26, 27, 28, 29, 30, 31, 32, 24,
  ];
  static const _lpsNext = [
    25, 1, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, //
    16, 17, 18, 19, 20, 21, 22, 23, 1, 2, 4, 8, 12, 16, 18, 22,
  ];

  // 128, 64, 96, 32, ...: the run lengths of the code words, which are the
  // bit-reversed indexes
  static final _runTable = List<int>.generate(128, (i) {
    var r = 0;
    for (var b = 0; b < 7; b++) {
      r |= ((i >> b) & 1) << (6 - b);
    }
    return 128 - r;
  });

  int _src = 0, _input = 0, _validBits = 0;
  int _planes = 0, _highContext = 0, _lowContext = 0;
  int _plane = 0, _yloc = 0, _raw = 0;
  final _bitCtr = List<int>.filled(8, 0);
  final _prevBits = List<int>.filled(8, 0);
  final _states = List<int>.filled(32, 0);
  final _mps = List<int>.filled(32, 0);

  int _byte() => chip.mmcRead(_src++);

  void init(int src) {
    _src = src;
    final head = _byte();
    _planes = const [2, 8, 4, 0][head >> 6];
    _highContext = const [0x1c0, 0x180, 0x0c0, 0x180][(head >> 4) & 3];
    _lowContext = (head & 0x30) == 0x30 ? 3 : 1;
    _input = (head << 11 | _byte() << 3) & 0xffff;
    _validBits = 5;
    _bitCtr.fillRange(0, 8, 0);
    _prevBits.fillRange(0, 8, 0);
    _states.fillRange(0, 32, 0);
    _mps.fillRange(0, 32, 0);
    _plane = _yloc = _raw = 0;
  }

  int read() {
    if (_planes == 0) {
      for (var plane = 0; plane < 8; plane++) {
        _getBit(plane);
      }
      return _raw;
    }
    if (_plane & 1 == 0) {
      for (var i = 0; i < 8; i++) {
        _getBit(_plane);
        _getBit(_plane + 1);
      }
      return _prevBits[_plane++] & 0xff;
    }
    final v = _prevBits[_plane--] & 0xff;
    if (++_yloc == 8) {
      _yloc = 0;
      _plane = (_plane + 2) & (_planes - 1);
    }
    return v;
  }

  void _getBit(int plane) {
    final prev = _prevBits[plane];
    final context = (plane & 1) << 4 |
        (prev & _highContext) >> 5 |
        (prev & _lowContext);
    final bit = _probGetBit(context);
    _prevBits[plane] = ((prev << 1) + bit) & 0xffff;
    if (_planes == 0) _raw = (_raw >> 1) + (bit << 7);
  }

  int _probGetBit(int context) {
    final state = _states[context];
    final size = _codeSize[state];
    if (_bitCtr[size] & 0x7f == 0) _bitCtr[size] = _codeword(size);
    var bit = _mps[context];
    _bitCtr[size]--;
    if (_bitCtr[size] == 0) {
      _states[context] = _lpsNext[state];
      bit ^= 1;
      if (state < 2) _mps[context] = bit;
    } else if (_bitCtr[size] == 0x80) {
      _states[context] = _mpsNext[state];
    }
    return bit;
  }

  int _codeword(int size) {
    if (_validBits == 0) {
      _input |= _byte();
      _validBits = 8;
    }
    _input = (_input << 1) & 0xffff;
    _validBits--;
    if (_input & 0x8000 == 0) return 0x80 + (1 << size);
    final tmp = ((_input >> 8) & 0x7f) | (0x7f >> size);
    _input = (_input << size) & 0xffff;
    _validBits -= size;
    if (_validBits < 0) {
      _input |= _byte() << -_validBits;
      _validBits += 8;
    }
    return _runTable[tmp];
  }
}
