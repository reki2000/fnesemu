import 'dart:typed_data';

import '../../../util/int.dart';

import 'mapper.dart';
import 'mirror.dart';
import 'mmc5_apu.dart';

// MMC5 (iNES mapper 5)
// https://www.nesdev.org/wiki/MMC5
//
// implemented: 4 PRG modes with PRG RAM mapping, 4 CHR modes with separate
// sprite/background sets (8x16 sprites), 4 way nametable mapping (CIRAM,
// ExRAM, fill mode), ExRAM modes 0-3 including the extended attributes,
// scanline IRQ, multiplier, vertical split screen and expansion audio.
//
// the scanline detection watches the nametable fetches of the ppu (3 reads of
// the same address in a row), the ppu model adds the 2 dummy reads at dots
// 337-340 for it.
class MapperMmc5 extends Mapper {
  // chr 1k banks / prg 8k banks
  @override
  int get chrRomSizeK => 1;
  @override
  int get prgRomSizeK => 8;

  @override
  bool get hasExpansionArea => true;

  // up to 64k of prg ram
  @override
  Uint8List defaultSram() => Uint8List(64 * 1024);

  final _apu = Mmc5Apu();

  // $5100-$5107
  int _prgMode = 3;
  int _chrMode = 3;
  int _ramProtect1 = 0;
  int _ramProtect2 = 0;
  int _exMode = 0;
  int _ntMap = 0;
  int _fillTile = 0;
  int _fillColor = 0;

  // $5113-$5117: prg bank registers (index 0 is the ram at $6000)
  final _prgReg = [0, 0xff, 0xff, 0xff, 0xff];

  // $5120-$5127 (set A), $5128-$512b (set B), $5130
  final _chrA = List<int>.filled(8, 0);
  final _chrB = List<int>.filled(4, 0);
  int _chrHi = 0;
  bool _lastChrIsB = false;

  // $5200-$5202
  int _splitCtl = 0;
  int _splitScrollY = 0;
  int _splitBank = 0;

  // $5203-$5206
  int _irqCompare = 0;
  bool _irqEnabled = false;
  bool _irqPending = false;
  int _mulA = 0xff;
  int _mulB = 0xff;

  final _ciram = Uint8List(0x800);
  final _exram = Uint8List(0x400);

  // scanline detection
  bool _inFrame = false;
  bool _detectedInLine = false;
  int _scanline = 0;
  int _lastNtAddr = -1;
  int _sameNtCount = 0;

  // tile column of the current background fetch
  int _tileCol = 0;
  int _curCol = 0;
  // extended attribute / split screen state of the current tile
  int _exByte = 0;
  bool _splitTile = false;

  @override
  void init() {
    _prgMode = 3;
    _chrMode = 3;
    _ramProtect1 = 0;
    _ramProtect2 = 0;
    _exMode = 0;
    _ntMap = 0;
    _fillTile = 0;
    _fillColor = 0;
    for (int i = 0; i < 5; i++) {
      _prgReg[i] = 0xff;
    }
    _prgReg[0] = 0;
    _chrA.fillRange(0, 8, 0);
    _chrB.fillRange(0, 4, 0);
    _chrHi = 0;
    _lastChrIsB = false;
    _splitCtl = 0;
    _splitScrollY = 0;
    _splitBank = 0;
    _irqCompare = 0;
    _irqEnabled = false;
    _irqPending = false;
    _inFrame = false;
    _detectedInLine = false;
    _scanline = 0;
    _lastNtAddr = -1;
    _sameNtCount = 0;
    _tileCol = 0;
    mirror(Mirror.external);
    holdIrq(false);
  }

  // ---- cpu side ----------------------------------------------------------

  bool get _ramWritable => _ramProtect1 == 2 && _ramProtect2 == 1;

  // resolves the prg bank of the cpu slot (0:$8000 1:$a000 2:$c000 3:$e000)
  // returns (8k bank number, isRam)
  (int, bool) _prgBank(int slot) {
    switch (_prgMode) {
      case 0:
        return ((_prgReg[4] & 0x7c) + slot, false);
      case 1:
        if (slot < 2) {
          final r = _prgReg[2];
          return r.bit7
              ? ((r & 0x7e) + (slot & 1), false)
              : ((r & 0x06) + (slot & 1), true);
        }
        return ((_prgReg[4] & 0x7e) + (slot & 1), false);
      case 2:
        if (slot < 2) {
          final r = _prgReg[2];
          return r.bit7
              ? ((r & 0x7e) + (slot & 1), false)
              : ((r & 0x06) + (slot & 1), true);
        }
        if (slot == 2) {
          final r = _prgReg[3];
          return r.bit7 ? (r & 0x7f, false) : (r & 0x07, true);
        }
        return (_prgReg[4] & 0x7f, false);
      default:
        final r = _prgReg[slot + 1];
        if (slot == 3) {
          return (r & 0x7f, false);
        }
        return r.bit7 ? (r & 0x7f, false) : (r & 0x07, true);
    }
  }

  int _ramAddr(int bank, int addr) => (bank & 0x07) * 0x2000 + (addr & 0x1fff);

  @override
  int read(int addr) {
    if (addr >= 0x8000) {
      final (bank, isRam) = _prgBank((addr - 0x8000).shr13);
      if (isRam) {
        return readSram(_ramAddr(bank, addr));
      }
      return prgRoms[bank % prgRoms.length][addr & 0x1fff];
    }

    if (addr >= 0x6000) {
      return readSram(_ramAddr(_prgReg[0], addr));
    }

    if (addr >= 0x5c00) {
      // exram: readable only in the mode 2 (ram) and 3 (read only ram)
      return _exMode >= 2 ? _exram[addr & 0x3ff] : 0xff;
    }

    switch (addr) {
      case 0x5010:
        return 0; // pcm irq is not supported
      case 0x5015:
        return _apu.readStatus();
      case 0x5204:
        final v = (_irqPending ? 0x80 : 0) | (_inFrame ? 0x40 : 0);
        _irqPending = false;
        holdIrq(false);
        return v;
      case 0x5205:
        return (_mulA * _mulB) & 0xff;
      case 0x5206:
        return ((_mulA * _mulB) >> 8) & 0xff;
    }
    return 0xff;
  }

  @override
  void write(int addr, int data) {
    if (addr >= 0x8000) {
      final (bank, isRam) = _prgBank((addr - 0x8000).shr13);
      if (isRam && _ramWritable) {
        writeSram(_ramAddr(bank, addr), data);
      }
      return;
    }

    if (addr >= 0x6000) {
      if (_ramWritable) {
        writeSram(_ramAddr(_prgReg[0], addr), data);
      }
      return;
    }

    if (addr >= 0x5c00) {
      switch (_exMode) {
        case 0:
        case 1:
          // used as a nametable: written only while the ppu is rendering
          _exram[addr & 0x3ff] = _inFrame ? data : 0;
        case 2:
          _exram[addr & 0x3ff] = data;
      }
      return;
    }

    if (addr >= 0x5000 && addr <= 0x5015) {
      _apu.write(addr, data);
      return;
    }

    switch (addr) {
      case 0x5100:
        _prgMode = data & 3;
      case 0x5101:
        _chrMode = data & 3;
      case 0x5102:
        _ramProtect1 = data & 3;
      case 0x5103:
        _ramProtect2 = data & 3;
      case 0x5104:
        _exMode = data & 3;
      case 0x5105:
        _ntMap = data;
      case 0x5106:
        _fillTile = data;
      case 0x5107:
        _fillColor = data & 3;
      case >= 0x5113 && <= 0x5117:
        _prgReg[addr - 0x5113] = data;
      case >= 0x5120 && <= 0x5127:
        _chrA[addr - 0x5120] = data | _chrHi.shl8;
        _lastChrIsB = false;
      case >= 0x5128 && <= 0x512b:
        _chrB[addr - 0x5128] = data | _chrHi.shl8;
        _lastChrIsB = true;
      case 0x5130:
        _chrHi = data & 3;
      case 0x5200:
        _splitCtl = data;
      case 0x5201:
        _splitScrollY = data;
      case 0x5202:
        _splitBank = data;
      case 0x5203:
        _irqCompare = data;
      case 0x5204:
        _irqEnabled = data.bit7;
        holdIrq(_irqPending && _irqEnabled);
      case 0x5205:
        _mulA = data;
      case 0x5206:
        _mulB = data;
    }
  }

  // ---- ppu side ----------------------------------------------------------

  // 1k chr bank number of the ppu slot (0-7) for the chr register set
  int _chrBank(int slot, bool setB) {
    if (setB) {
      return switch (_chrMode) {
        0 => _chrB[3] * 8 + (slot & 3),
        1 => _chrB[3] * 4 + (slot & 3),
        2 => _chrB[(slot & 2) | 1] * 2 + (slot & 1),
        _ => _chrB[slot & 3],
      };
    }
    return switch (_chrMode) {
      0 => _chrA[7] * 8 + slot,
      1 => _chrA[(slot & 4) | 3] * 4 + (slot & 3),
      2 => _chrA[(slot & 6) | 1] * 2 + (slot & 1),
      _ => _chrA[slot],
    };
  }

  int _readChr(int bank1k, int addr) {
    if (chrRoms.isEmpty) return 0;
    return chrRoms[bank1k % chrRoms.length][addr & 0x3ff];
  }

  bool get _sprite16 => ppuCtl.bit5;

  bool get _splitEnabled => _splitCtl.bit7 && _exMode < 2;

  bool _inSplit(int col) {
    final threshold = _splitCtl & 0x1f;
    return _splitCtl.bit6 ? col >= threshold : col < threshold;
  }

  // vertical position inside the split area
  int get _splitY => (_scanline + _splitScrollY) % 240;

  @override
  int readVram(int addr) {
    if (addr < 0x2000) {
      return _readPattern(addr);
    }
    return _readNametable(addr);
  }

  int _readPattern(int addr) {
    final slot = (addr >> 10) & 7;

    if (fetchPhase == Mapper.fetchBg) {
      if (_splitTile) {
        // split area: 4k bank of $5202, the fine y follows the split scroll
        final a = (addr & 0xff8) | (_splitY & 7);
        return _readChr(_splitBank * 4 + ((a >> 10) & 3), a);
      }
      if (_exMode == 1) {
        // extended attribute: the tile has its own 4k bank in the exram byte
        final bank = (_exByte & 0x3f) | _chrHi.shl6;
        return _readChr(bank * 4 + ((addr >> 10) & 3), addr);
      }
      return _readChr(_chrBank(slot, _sprite16), addr);
    }

    if (fetchPhase == Mapper.fetchSprite) {
      return _readChr(_chrBank(slot, false), addr);
    }

    // cpu access ($2007): the set written last is used in 8x16 mode
    return _readChr(_chrBank(slot, _sprite16 && _lastChrIsB), addr);
  }

  int _readNametable(int addr) {
    final offset = addr & 0x3ff;
    final isAttr = offset >= 0x3c0;

    if (fetchPhase == Mapper.fetchBg) {
      _scanlineDetect(addr, isAttr);

      if (!isAttr) {
        _curCol = _nextTileCol(addr);
        _splitTile = _inFrame && _splitEnabled && _inSplit(_curCol);
        if (_splitTile) {
          return _exram[(_splitY ~/ 8) * 32 + _curCol];
        }
        final v = _ntByte(addr);
        if (_exMode == 1) {
          _exByte = _exram[offset];
        }
        return v;
      }

      if (_splitTile) {
        final row = _splitY ~/ 8;
        final attr = _exram[0x3c0 + (row >> 2) * 8 + (_curCol >> 2)];
        return attr;
      }
      if (_exMode == 1) {
        // palette bits of the exram byte, replicated to the 4 quadrants
        return (_exByte >> 6) * 0x55;
      }
    }

    return _ntByte(addr);
  }

  // reads the nametable byte through the $5105 mapping
  int _ntByte(int addr) {
    final offset = addr & 0x3ff;
    final src = (_ntMap >> (((addr >> 10) & 3) * 2)) & 3;
    switch (src) {
      case 0:
        return _ciram[offset];
      case 1:
        return _ciram[0x400 + offset];
      case 2:
        return _exMode < 2 ? _exram[offset] : 0;
      default:
        return offset >= 0x3c0 ? _fillColor * 0x55 : _fillTile;
    }
  }

  @override
  void writeVram(int addr, int data) {
    if (addr < 0x2000) {
      return; // chr rom
    }

    final offset = addr & 0x3ff;
    final src = (_ntMap >> (((addr >> 10) & 3) * 2)) & 3;
    switch (src) {
      case 0:
        _ciram[offset] = data;
      case 1:
        _ciram[0x400 + offset] = data;
      case 2:
        if (_exMode < 2) {
          _exram[offset] = data;
        }
    }
  }

  // counts the tile columns of the background fetches: repeated reads of the
  // same address (the dummy fetches) are not new tiles
  int _nextTileCol(int addr) {
    if (addr == _lastNtAddr && _sameNtCount > 1) {
      return _tileCol - 1;
    }
    final col = _tileCol > 32 ? 0 : _tileCol;
    _tileCol = col + 1;
    return col;
  }

  // 3 reads of the same nametable address in a row are the start of a scanline
  void _scanlineDetect(int addr, bool isAttr) {
    if (addr == _lastNtAddr) {
      _sameNtCount++;
    } else {
      _lastNtAddr = addr;
      _sameNtCount = 1;
    }

    if (_sameNtCount != 3 || isAttr) {
      return;
    }

    _detectedInLine = true;
    _tileCol = 2;
    if (!_inFrame) {
      _inFrame = true;
      _scanline = 0;
      _irqPending = false;
      holdIrq(false);
      return;
    }

    _scanline++;
    if (_scanline == _irqCompare) {
      _irqPending = true;
      if (_irqEnabled) {
        holdIrq(true);
      }
    }
  }

  // called once per scanline: no detection in a line means the ppu is not
  // rendering (vblank or rendering disabled)
  @override
  void handleClock(int cycles) {
    if (!_detectedInLine) {
      _inFrame = false;
      _lastNtAddr = -1;
    }
    _detectedInLine = false;
  }

  @override
  Float32List handleApu(int cycles) => _apu.exec(cycles);

  @override
  String dump() {
    return "rom: prg:$_prgMode chr:$_chrMode ex:$_exMode nt:${_ntMap.x2} "
        "irq:${_irqEnabled ? '*' : '-'}${_irqPending ? 'p' : '-'}"
        "${_inFrame ? 'f' : '-'} @$_scanline/$_irqCompare "
        "prg:${_prgReg.map((v) => v.x2).join(" ")} "
        "chrA:${_chrA.map((v) => v.x2).join(" ")} "
        "chrB:${_chrB.map((v) => v.x2).join(" ")} "
        "split:${_splitCtl.x2}\n"
        "apu: ${_apu.dump()}\n";
  }
}
