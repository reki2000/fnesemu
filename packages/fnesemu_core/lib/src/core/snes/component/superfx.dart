import 'dart:typed_data';

import '../../../util/int.dart';
import 'bus.dart';

/// Super FX (GSU): a cartridge risc cpu which draws polygons into its own
/// RAM as bitplane characters, for the main cpu to DMA to vram.
///
/// Written after the fullsnes documentation of the GSU ports, opcodes and
/// caches. The clock is counted in master clocks: 2 for an instruction byte
/// from the cache, 6 for other memory accesses.
class SuperFx {
  final Bus mainBus;
  final Uint8List rom;
  final int _romMask;
  final Uint8List ram;
  final int _ramMask;

  // main cpu irq line used by the chip
  static const _mainIrqLine = 4;

  // master clocks per main cpu cycle
  static const _clocksPerMainCycle = 6;

  SuperFx(this.mainBus, this.rom, int ramSize)
      : _romMask = _mask(rom.length),
        ram = Uint8List(ramSize),
        _ramMask = ramSize - 1;

  static int _mask(int length) {
    var size = 1;
    while (size < length) {
      size <<= 1;
    }
    return size - 1;
  }

  final r = Uint16List(16);
  bool _r15Modified = false;
  int _pipeline = 1; // NOP

  // SFR
  bool _z = false, _cy = false, _s = false, _ov = false, _g = false;
  bool _alt1 = false, _alt2 = false, _b = false, _irq = false;
  int _il = 0, _ih = 0; // flags the main cpu may set

  int _sreg = 0, _dreg = 0;

  int _pbr = 0, _rombr = 0, _rambr = 0, _cbr = 0, _scbr = 0;
  int _scmr = 0, _cfgr = 0, _clsr = 0;
  int _colr = 0, _por = 0;
  int _romdr = 0; // the rom buffer, read at R14
  int _ramaddr = 0; // the last ram word address

  final _cache = Uint8List(512);
  final _cacheValid = List<bool>.filled(32, false);

  int _clock = 0; // master clocks run

  void reset() {
    r.fillRange(0, 16, 0);
    ram.fillRange(0, ram.length, 0);
    _r15Modified = false;
    _pipeline = 1;
    _z = _cy = _s = _ov = _g = _alt1 = _alt2 = _b = _irq = false;
    _il = _ih = _sreg = _dreg = 0;
    _pbr = _rombr = _rambr = _cbr = _scbr = 0;
    _scmr = _cfgr = _clsr = _colr = _por = 0;
    _romdr = _ramaddr = 0;
    _cache.fillRange(0, 512, 0);
    _flushCache();
    _clock = 0;
    mainBus.cpu.releaseIrq(_mainIrqLine);
  }

  /// runs the GSU until its clock reaches [mainCycle] of the main cpu
  void run(int mainCycle) {
    final target = mainCycle * _clocksPerMainCycle;
    while (_g && _clock < target) {
      _instruction(_peekPipe());
      if (_r15Modified) {
        _r15Modified = false;
      } else {
        r[15]++;
      }
    }
    if (_clock < target) _clock = target;
  }

  // ------------------------------------------------------------ memory
  int _read(int addr) {
    if (addr & 0xc00000 == 0) {
      return rom[((addr & 0x3f0000).shr1 | addr.mask15) & _romMask];
    }
    if (addr & 0xe00000 == 0x400000) return rom[addr & _romMask];
    return ram[addr & _ramMask];
  }

  // the 512 bytes from CBR are cached in lines of 16 bytes; the slot of an
  // address is its low 9 bits, as the main cpu sees them at $3100-$32FF
  int _readOpcode(int addr) {
    if ((addr - _cbr).mask16 < 512) {
      final slot = addr.mask9;
      if (!_cacheValid[slot.shr4]) {
        final line = addr & 0xfff0;
        for (var n = 0; n < 16; n++) {
          _cache[(slot & 0x1f0) + n] = _read(_pbr.shl16 | line + n);
        }
        _clock += 16 * _memoryClocks;
        _cacheValid[slot.shr4] = true;
      } else {
        _clock += _cacheClocks;
      }
      return _cache[slot];
    }
    _clock += _memoryClocks;
    return _read(_pbr.shl16 | addr);
  }

  int get _cacheClocks => _clsr != 0 ? 1 : 2;
  int get _memoryClocks => _clsr != 0 ? 5 : 6;

  void _flushCache() => _cacheValid.fillRange(0, 32, false);

  int _peekPipe() {
    final v = _pipeline;
    _pipeline = _readOpcode(r[15]);
    _r15Modified = false;
    return v;
  }

  int _pipe() {
    final v = _pipeline;
    r[15]++;
    _pipeline = _readOpcode(r[15]);
    _r15Modified = false;
    return v;
  }

  int _ramRead(int addr) {
    _clock += _memoryClocks;
    return ram[(_rambr.shl16 | addr) & _ramMask];
  }

  void _ramWrite(int addr, int data) {
    _clock += _memoryClocks;
    ram[(_rambr.shl16 | addr) & _ramMask] = data;
  }

  void _updateRomBuffer() => _romdr = _read(_rombr.shl16 | r[14]);

  // ---------------------------------------------------------- registers
  int get _sr => r[_sreg];

  void _setR(int n, int v) {
    r[n] = v;
    if (n == 15) _r15Modified = true;
    if (n == 14) _updateRomBuffer();
  }

  void _setDr(int v) => _setR(_dreg, v);

  void _setSZ(int v) {
    _s = v.bit15;
    _z = v.mask16 == 0;
  }

  void _resetPrefix() {
    _b = _alt1 = _alt2 = false;
    _sreg = _dreg = 0;
  }

  int get _sfr =>
      (_z ? 0x02 : 0) |
      (_cy ? 0x04 : 0) |
      (_s ? 0x08 : 0) |
      (_ov ? 0x10 : 0) |
      (_g ? 0x20 : 0) |
      (_alt1 ? 0x100 : 0) |
      (_alt2 ? 0x200 : 0) |
      _il.shl10 |
      _ih.shl11 |
      (_b ? 0x1000 : 0) |
      (_irq ? 0x8000 : 0);

  set _sfr(int v) {
    _z = v.bit1;
    _cy = v.bit2;
    _s = v.bit3;
    _ov = v.bit4;
    _g = v.bit5;
    _alt1 = v.bit8;
    _alt2 = v.bit9;
    _il = v.shr10.mask1;
    _ih = v.shr11.mask1;
    _b = v.bit12;
    _irq = v.bit15;
  }

  // ------------------------------------------------------ main cpu access
  // the vectors the main cpu reads while the GSU owns the rom: the handlers
  // are in wram at $0100-$010F
  static const _vectors = [
    0x00, 0x01, 0x00, 0x01, 0x04, 0x01, 0x00, 0x01, //
    0x00, 0x01, 0x08, 0x01, 0x00, 0x01, 0x0c, 0x01,
  ];

  bool get _romOwned => _g && _scmr.bit4;

  /// a read by the main cpu, or -1 if the address is not on the cartridge
  int mainRead(int addr) {
    final bank = addr.shr16;
    final page = addr.mask16;
    if (!bank.bit6) {
      if (page >= 0x8000) {
        if (_romOwned) return _vectors[page.mask4];
        return rom[(bank.mask6.shl15 | page.mask15) & _romMask];
      }
      if (page >= 0x6000) return ram[page.mask13 & _ramMask];
      if (page >= 0x3000 && page < 0x3500) return _readRegister(page);
      return -1;
    }
    final b = bank.mask7;
    if (b < 0x60) {
      if (_romOwned) return _vectors[page.mask4];
      return rom[addr & 0x3fffff & _romMask];
    }
    if (b == 0x70 || b == 0x71) return ram[addr & 0x1ffff & _ramMask];
    return 0;
  }

  /// a write by the main cpu: false if the address is not on the cartridge
  bool mainWrite(int addr, int data) {
    final bank = addr.shr16;
    final page = addr.mask16;
    if (!bank.bit6) {
      if (page >= 0x8000) return true;
      if (page >= 0x6000) {
        ram[page.mask13 & _ramMask] = data;
      } else if (page >= 0x3000 && page < 0x3500) {
        _writeRegister(page, data);
      } else {
        return false;
      }
      return true;
    }
    final b = bank.mask7;
    if (b == 0x70 || b == 0x71) ram[addr & 0x1ffff & _ramMask] = data;
    return true;
  }

  int mainVector(int addr) {
    if (_romOwned) {
      return _vectors[addr.mask4] | _vectors[(addr + 1).mask4].shl8;
    }
    return mainRead(addr) | mainRead(addr + 1).shl8;
  }

  int _readRegister(int page) {
    if (page >= 0x3100 && page < 0x3300) {
      return _cache[page - 0x3100];
    }
    if (page < 0x3020) {
      final v = r[page.shr1.mask4];
      return !page.bit0 ? v.mask8 : v.shr8;
    }
    switch (page) {
      case 0x3030:
        return _sfr.mask8;
      case 0x3031:
        final v = _sfr.shr8;
        _irq = false;
        mainBus.cpu.releaseIrq(_mainIrqLine);
        return v;
      case 0x3034:
        return _pbr;
      case 0x3036:
        return _rombr;
      case 0x303b: // VCR: 4 for the GSU-2 of the 2MB games, 1 for the others
        return rom.length > 0x100000 ? 4 : 1;
      case 0x303c:
        return _rambr;
      case 0x303e:
        return _cbr.mask8;
      case 0x303f:
        return _cbr.shr8;
    }
    return 0;
  }

  void _writeRegister(int page, int data) {
    if (page >= 0x3100 && page < 0x3300) {
      final a = page - 0x3100;
      _cache[a] = data;
      if (a.mask4 == 0xf) _cacheValid[a.shr4] = true;
      return;
    }
    if (page < 0x3020) {
      final n = page.shr1.mask4;
      r[n] = !page.bit0 ? (r[n] & 0xff00) | data : data.shl8 | r[n].mask8;
      if (n == 14) _updateRomBuffer();
      if (page == 0x301f) _g = true;
      return;
    }
    switch (page) {
      case 0x3030:
        final g = _g;
        _sfr = (_sfr & 0xff00) | data;
        if (g && !_g) {
          _cbr = 0;
          _flushCache();
        }
      case 0x3031:
        _sfr = _sfr.mask8 | data.shl8;
      case 0x3034:
        _pbr = data.mask7;
        _flushCache();
      case 0x3037:
        _cfgr = data;
      case 0x3038:
        _scbr = data;
      case 0x3039:
        _clsr = data.mask1;
      case 0x303a:
        _scmr = data;
    }
  }

  // ------------------------------------------------------------- plotting
  int get _md => _scmr.mask2;
  int get _ht => _scmr.shr2.mask1 | (_scmr.shr4 & 2);
  int get _bpp => 2 << (_md - _md.shr1);

  // the ram address of the row [y] of the character containing (x, y)
  int _charRow(int x, int y) {
    int cn;
    switch (_por.bit4 ? 3 : _ht) {
      case 0:
        cn = (x & 0xf8).shl1 + (y & 0xf8).shr3;
      case 1:
        cn = (x & 0xf8).shl1 + (x & 0xf8).shr1 + (y & 0xf8).shr3;
      case 2:
        cn = (x & 0xf8).shl1 + (x & 0xf8) + (y & 0xf8).shr3;
      default:
        cn = (y & 0x80).shl2 +
            (x & 0x80).shl1 +
            (y & 0x78).shl1 +
            (x & 0x78).shr3;
    }
    return cn * _bpp.shl3 + _scbr.shl10 + y.mask3.shl1;
  }

  void _plot(int x, int y) {
    var color = _colr;
    if (!_por.bit0) {
      final freezeHigh = _por.bit3;
      if (_md == 3 && !freezeHigh) {
        if (color == 0) return;
      } else if (color.mask4 == 0) {
        return;
      }
    }
    if (_por.bit1 && _md != 3) {
      if ((x ^ y).bit0) color >>= 4;
      color &= 0xf;
    }
    final addr = _charRow(x, y);
    final mask = 0x80 >> x.mask3;
    final bpp = _bpp;
    for (var n = 0; n < bpp; n++) {
      final a = (addr + n.shr1.shl4 + n.mask1) & _ramMask;
      ram[a] = (color >> n).bit0 ? ram[a] | mask : ram[a] & ~mask;
    }
    _clock += bpp * _memoryClocks;
  }

  int _rpix(int x, int y) {
    final addr = _charRow(x, y);
    final shift = 7 - x.mask3;
    var data = 0;
    final bpp = _bpp;
    for (var n = 0; n < bpp; n++) {
      final a = (addr + n.shr1.shl4 + n.mask1) & _ramMask;
      data |= (ram[a] >> shift).mask1 << n;
    }
    _clock += bpp * _memoryClocks;
    return data;
  }

  int _color(int source) {
    if (_por.bit2) return (_colr & 0xf0) | source.shr4;
    if (_por.bit3) return (_colr & 0xf0) | source.mask4;
    return source;
  }


  // ---------------------------------------------------------- instructions
  void _instruction(int op) {
    final n = op.mask4;
    switch (op.shr4) {
      case 0x0:
        _op0(op);
      case 0x1: // TO / MOVE
        if (!_b) {
          _dreg = n;
          return;
        }
        _setR(n, _sr);
        _resetPrefix();
      case 0x2: // WITH
        _sreg = _dreg = n;
        _b = true;
      case 0x3:
        if (n < 0xc) {
          // STW / STB
          _ramaddr = r[n];
          _ramWrite(_ramaddr, _sr.mask8);
          if (!_alt1) _ramWrite(_ramaddr ^ 1, _sr.shr8);
          _resetPrefix();
        } else if (n == 0xc) {
          // LOOP
          r[12]--;
          _setSZ(r[12]);
          if (!_z) _setR(15, r[13]);
          _resetPrefix();
        } else {
          // ALT1 / ALT2 / ALT3
          _b = false;
          if (n.bit0) _alt1 = true;
          if (n.bit1) _alt2 = true;
        }
      case 0x4:
        _op4(op);
      case 0x5: // ADD / ADC
        final operand = _alt2 ? n : r[n];
        final sr = _sr;
        final v = sr + operand + (_alt1 && _cy ? 1 : 0);
        _ov = (~(sr ^ operand) & (operand ^ v)).bit15;
        _s = v.bit15;
        _cy = v >= 0x10000;
        _z = v.mask16 == 0;
        _setDr(v.mask16);
        _resetPrefix();
      case 0x6: // SUB / SBC / CMP
        final operand = _alt2 && !_alt1 ? n : r[n];
        final sr = _sr;
        final v = sr - operand - (!_alt2 && _alt1 && !_cy ? 1 : 0);
        _ov = ((sr ^ operand) & (sr ^ v)).bit15;
        _s = v.bit15;
        _cy = v >= 0;
        _z = v.mask16 == 0;
        if (!_alt2 || !_alt1) _setDr(v.mask16);
        _resetPrefix();
      case 0x7:
        if (n == 0) {
          // MERGE
          final v = (r[7] & 0xff00) | r[8].shr8;
          _ov = v & 0xc0c0 != 0;
          _s = v & 0x8080 != 0;
          _cy = v & 0xe0e0 != 0;
          _z = v & 0xf0f0 != 0;
          _setDr(v);
        } else {
          // AND / BIC
          final operand = _alt2 ? n : r[n];
          final v = (_sr & (_alt1 ? ~operand : operand)).mask16;
          _setSZ(v);
          _setDr(v);
        }
        _resetPrefix();
      case 0x8: // MULT / UMULT
        final operand = _alt2 ? n : r[n];
        final v = (!_alt1
                ? _sr.rel8 * operand.rel8
                : _sr.mask8 * operand.mask8).mask16;
        _setSZ(v);
        _setDr(v);
        if (!_cfgr.bit5) _clock += _cacheClocks;
        _resetPrefix();
      case 0x9:
        _op9(op);
      case 0xa: // IBT / LMS / SMS
        if (_alt1) {
          _ramaddr = _pipe().shl1;
          final lo = _ramRead(_ramaddr);
          _setR(n, _ramRead(_ramaddr ^ 1).shl8 | lo);
        } else if (_alt2) {
          _ramaddr = _pipe().shl1;
          _ramWrite(_ramaddr, r[n].mask8);
          _ramWrite(_ramaddr ^ 1, r[n].shr8);
        } else {
          _setR(n, _pipe().rel8.mask16);
        }
        _resetPrefix();
      case 0xb: // FROM / MOVES
        if (!_b) {
          _sreg = n;
          return;
        }
        final v = r[n];
        _ov = v.bit7;
        _setSZ(v);
        _setDr(v);
        _resetPrefix();
      case 0xc:
        if (n == 0) {
          // HIB
          final v = _sr.shr8;
          _s = v.bit7;
          _z = v == 0;
          _setDr(v);
        } else {
          // OR / XOR
          final operand = _alt2 ? n : r[n];
          final v = _alt1 ? _sr ^ operand : _sr | operand;
          _setSZ(v);
          _setDr(v);
        }
        _resetPrefix();
      case 0xd:
        if (n < 0xf) {
          // INC
          _setR(n, (r[n] + 1).mask16);
          _setSZ(r[n]);
        } else if (!_alt2) {
          // GETC
          _colr = _color(_romdr);
        } else if (!_alt1) {
          // RAMB
          _rambr = _sr.mask1;
        } else {
          // ROMB: the rom buffer keeps the byte of the old bank
          _rombr = _sr.mask8;
        }
        _resetPrefix();
      case 0xe:
        if (n < 0xf) {
          // DEC
          _setR(n, (r[n] - 1).mask16);
          _setSZ(r[n]);
        } else {
          // GETB / GETBH / GETBL / GETBS
          final v = _romdr;
          _clock += _memoryClocks;
          if (_alt1 && _alt2) {
            _setDr(v.rel8.mask16);
          } else if (_alt1) {
            _setDr(v.shl8 | _sr.mask8);
          } else if (_alt2) {
            _setDr((_sr & 0xff00) | v);
          } else {
            _setDr(v);
          }
        }
        _resetPrefix();
      case 0xf: // IWT / LM / SM
        if (_alt1) {
          _ramaddr = _pipe() | _pipe().shl8;
          final lo = _ramRead(_ramaddr);
          _setR(n, _ramRead(_ramaddr ^ 1).shl8 | lo);
        } else if (_alt2) {
          _ramaddr = _pipe() | _pipe().shl8;
          _ramWrite(_ramaddr, r[n].mask8);
          _ramWrite(_ramaddr ^ 1, r[n].shr8);
        } else {
          _setR(n, _pipe() | _pipe().shl8);
        }
        _resetPrefix();
    }
  }

  void _op0(int op) {
    switch (op) {
      case 0x00: // STOP
        // the flag is set even when CFGR masks the IRQ
        _irq = true;
        if (!_cfgr.bit7) mainBus.cpu.holdIrq(_mainIrqLine);
        _g = false;
        _pipeline = 1;
        _resetPrefix();
      case 0x01: // NOP
        _resetPrefix();
      case 0x02: // CACHE
        if (_cbr != r[15] & 0xfff0) {
          _cbr = r[15] & 0xfff0;
          _flushCache();
        }
        _resetPrefix();
      case 0x03: // LSR
        final sr = _sr;
        _cy = sr.bit0;
        final v = sr.shr1;
        _setSZ(v);
        _setDr(v);
        _resetPrefix();
      case 0x04: // ROL
        final sr = _sr;
        final v = (sr.shl1 | (_cy ? 1 : 0)).mask16;
        _cy = sr.bit15;
        _setSZ(v);
        _setDr(v);
        _resetPrefix();
      default: // branches
        final e = _pipe().rel8;
        final take = switch (op) {
          0x05 => true,
          0x06 => _s == _ov,
          0x07 => _s != _ov,
          0x08 => !_z,
          0x09 => _z,
          0x0a => !_s,
          0x0b => _s,
          0x0c => !_cy,
          0x0d => _cy,
          0x0e => !_ov,
          _ => _ov,
        };
        if (take) _setR(15, (r[15] + e).mask16);
    }
  }

  void _op4(int op) {
    final n = op.mask4;
    switch (n) {
      case < 0xc: // LDW / LDB
        _ramaddr = r[n];
        var v = _ramRead(_ramaddr);
        if (!_alt1) v |= _ramRead(_ramaddr ^ 1).shl8;
        _setDr(v);
      case 0xc:
        if (!_alt1) {
          // PLOT
          _plot(r[1].mask8, r[2].mask8);
          r[1]++;
        } else {
          // RPIX
          final v = _rpix(r[1].mask8, r[2].mask8);
          _setSZ(v);
          _setDr(v);
        }
      case 0xd: // SWAP
        final sr = _sr;
        final v = sr.shr8 | sr.shl8 & 0xff00;
        _setSZ(v);
        _setDr(v);
      case 0xe: // COLOR / CMODE
        if (!_alt1) {
          _colr = _color(_sr.mask8);
        } else {
          _por = _sr.mask5;
        }
      default: // NOT
        final v = (~_sr).mask16;
        _setSZ(v);
        _setDr(v);
    }
    _resetPrefix();
  }

  void _op9(int op) {
    final n = op.mask4;
    switch (n) {
      case 0x0: // SBK
        _ramWrite(_ramaddr, _sr.mask8);
        _ramWrite(_ramaddr ^ 1, _sr.shr8);
      case <= 0x4: // LINK
        _setR(11, (r[15] + n).mask16);
      case 0x5: // SEX
        final v = _sr.rel8.mask16;
        _setSZ(v);
        _setDr(v);
      case 0x6: // ASR / DIV2
        final sr = _sr;
        _cy = sr.bit0;
        final v = (sr.rel16.shr1 + (_alt1 ? (sr + 1).shr16 : 0)).mask16;
        _setSZ(v);
        _setDr(v);
      case 0x7: // ROR
        final sr = _sr;
        final v = (_cy ? 0x8000 : 0) | sr.shr1;
        _cy = sr.bit0;
        _setSZ(v);
        _setDr(v);
      case <= 0xd: // JMP / LJMP
        if (!_alt1) {
          _setR(15, r[n]);
        } else {
          _pbr = r[n].mask7;
          _setR(15, _sr);
          _cbr = r[15] & 0xfff0;
          _flushCache();
        }
      case 0xe: // LOB
        final v = _sr.mask8;
        _s = v.bit7;
        _z = v == 0;
        _setDr(v);
      default: // FMULT / LMULT
        final v = _sr.rel16 * r[6].rel16;
        if (_alt1) {
          _setR(4, v.mask16);
          _setDr(v.shr16.mask16);
        } else if (_dreg != 4) {
          _setDr(v.shr16.mask16); // FMULT leaves R4 as it is
        }
        _s = v.bit31;
        _cy = v.bit15;
        _z = v & 0xffff0000 == 0;
        if (!_cfgr.bit5) _clock += 4 * _cacheClocks;
    }
    _resetPrefix();
  }
}
