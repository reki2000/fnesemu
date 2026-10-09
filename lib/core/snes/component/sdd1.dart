import 'dart:typed_data';

/// S-DD1: a cartridge chip which maps 1MB rom banks into $C0-$FF and
/// decompresses graphics while a DMA channel reads them.
///
/// The decompressor (context model + Golomb codes) follows the description
/// by Andreas Naive used by bsnes and snes9x.
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

class _Decompressor {
  final Sdd1 chip;
  _Decompressor(this.chip);

  // input manager
  int _offset = 0, _bitCount = 0;

  // bit generators for code numbers 0-7
  final _mpsCount = List<int>.filled(8, 0);
  final _lpsIndex = List<bool>.filled(8, false);

  // probability estimation
  final _status = List<int>.filled(32, 0);
  final _mps = List<int>.filled(32, 0);

  // context model
  int _bitplanesInfo = 0, _contextBitsInfo = 0, _bitNumber = 0;
  int _currentBitplane = 0;
  final _prevBitplaneBits = List<int>.filled(8, 0);

  // output logic
  int _r0 = 0, _r1 = 0, _r2 = 0;

  void init(int offset) {
    _offset = offset;
    _bitCount = 4;
    _mpsCount.fillRange(0, 8, 0);
    _lpsIndex.fillRange(0, 8, false);
    _status.fillRange(0, 32, 0);
    _mps.fillRange(0, 32, 0);

    final header = chip.mmcRead(offset);
    _bitplanesInfo = header & 0xc0;
    _contextBitsInfo = header & 0x30;
    _bitNumber = 0;
    _prevBitplaneBits.fillRange(0, 8, 0);
    _currentBitplane = switch (_bitplanesInfo) {
      0x00 => 1,
      0x40 => 7,
      0x80 => 3,
      _ => 0,
    };
    _r0 = 1;
  }

  int _codeWord(int codeLength) {
    var codeWord = (chip.mmcRead(_offset) << _bitCount) & 0xff;
    _bitCount++;
    if ((codeWord & 0x80) != 0) {
      codeWord |= chip.mmcRead(_offset + 1) >> (9 - _bitCount);
      _bitCount += codeLength;
    }
    if ((_bitCount & 8) != 0) {
      _offset++;
      _bitCount &= 7;
    }
    return codeWord & 0xff;
  }

  // the run length of the MPS before an LPS, for a code word of [n] bits
  static final _runCount = Uint8List.fromList(List.generate(256, (i) {
    if (i == 0) return 0;
    final k = i.bitLength - 1;
    var low = i - (1 << k), reversed = 0;
    for (var b = 0; b < k; b++) {
      reversed = (reversed << 1) | (low & 1);
      low >>= 1;
    }
    return ~reversed & ((1 << k) - 1);
  }));

  // returns (bit, endOfRun) packed as bit | endOfRun << 1
  int _generatorBit(int codeNumber) {
    if (_mpsCount[codeNumber] == 0 && !_lpsIndex[codeNumber]) {
      final codeWord = _codeWord(codeNumber);
      if ((codeWord & 0x80) != 0) {
        _lpsIndex[codeNumber] = true;
        _mpsCount[codeNumber] = _runCount[codeWord >> (codeNumber ^ 7)];
      } else {
        _mpsCount[codeNumber] = 1 << codeNumber;
      }
    }
    int bit;
    if (_mpsCount[codeNumber] != 0) {
      bit = 0;
      _mpsCount[codeNumber]--;
    } else {
      bit = 1;
      _lpsIndex[codeNumber] = false;
    }
    final end = _mpsCount[codeNumber] == 0 && !_lpsIndex[codeNumber];
    return bit | (end ? 2 : 0);
  }

  // (code number, next status if MPS, next status if LPS)
  static const _evolution = [
    [0, 25, 25], [0, 2, 1], [0, 3, 1], [0, 4, 2], [0, 5, 3], [1, 6, 4], //
    [1, 7, 5], [1, 8, 6], [1, 9, 7], [2, 10, 8], [2, 11, 9], [2, 12, 10],
    [2, 13, 11], [3, 14, 12], [3, 15, 13], [3, 16, 14], [3, 17, 15],
    [4, 18, 16], [4, 19, 17], [5, 20, 18], [5, 21, 19], [6, 22, 20],
    [6, 23, 21], [7, 24, 22], [7, 24, 23], [0, 26, 1], [1, 27, 2],
    [2, 28, 4], [3, 29, 8], [4, 30, 12], [5, 31, 16], [6, 32, 18],
    [7, 24, 22],
  ];

  int _estimatedBit(int context) {
    final status = _status[context], mps = _mps[context];
    final state = _evolution[status];
    final result = _generatorBit(state[0]);
    final bit = result & 1;
    if ((result & 2) != 0) {
      if (bit != 0) {
        if ((status & 0xfe) == 0) _mps[context] ^= 1;
        _status[context] = state[2];
      } else {
        _status[context] = state[1];
      }
    }
    return bit ^ mps;
  }

  int _contextBit() {
    switch (_bitplanesInfo) {
      case 0x00:
        _currentBitplane ^= 1;
      case 0x40:
        _currentBitplane ^= 1;
        if ((_bitNumber & 0x7f) == 0) {
          _currentBitplane = (_currentBitplane + 2) & 7;
        }
      case 0x80:
        _currentBitplane ^= 1;
        if ((_bitNumber & 0x7f) == 0) _currentBitplane ^= 2;
      case 0xc0:
        _currentBitplane = _bitNumber & 7;
    }
    final bits = _prevBitplaneBits[_currentBitplane];
    var context = (_currentBitplane & 1) << 4;
    context |= switch (_contextBitsInfo) {
      0x00 => ((bits & 0x01c0) >> 5) | (bits & 1),
      0x10 => ((bits & 0x0180) >> 5) | (bits & 1),
      0x20 => ((bits & 0x00c0) >> 5) | (bits & 1),
      _ => ((bits & 0x0180) >> 5) | (bits & 3),
    };
    final bit = _estimatedBit(context);
    _prevBitplaneBits[_currentBitplane] = ((bits << 1) | bit) & 0xffff;
    _bitNumber++;
    return bit;
  }

  int read() {
    if (_bitplanesInfo == 0xc0) {
      _r1 = 0;
      for (var r0 = 1; r0 < 0x100; r0 <<= 1) {
        if (_contextBit() != 0) _r1 |= r0;
      }
      return _r1;
    }
    if (_r0 == 0) {
      _r0 = 0xff;
      return _r2;
    }
    _r1 = _r2 = 0;
    for (_r0 = 0x80; _r0 != 0; _r0 >>= 1) {
      if (_contextBit() != 0) _r1 |= _r0;
      if (_contextBit() != 0) _r2 |= _r0;
    }
    return _r1;
  }
}
