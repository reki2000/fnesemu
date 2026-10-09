import 'dart:math';
import 'dart:typed_data';

import 'bus.dart';
import 'cpu.dart';
import 'cpu_bus.dart';

/// SA-1: a cartridge chip with a second 65816 running at three times the
/// main cpu clock. It has 2KB of I-RAM shared by both cpus, maps the rom in
/// 1MB banks and the battery backed BW-RAM (also as a 2/4bpp bitmap), and
/// has a DMA unit with character conversion, an arithmetic unit, a timer and
/// a variable-length bit reader.
///
/// The register behavior follows bsnes.
class Sa1 {
  final Bus mainBus;
  final Uint8List rom;
  final int _romMask;
  final int _bwMask;

  final iram = Uint8List(0x800);

  late final bus = Sa1Bus(this);
  late final Cpu cpu = Cpu(bus);

  /// SA-1 cpu cycles per main cpu cycle
  static const clockRatio = 3;

  // main cpu irq line used by the chip
  static const _mainIrqLine = 2;

  Sa1(this.mainBus, this.rom, int bwramSize)
      : _romMask = _mask(rom.length),
        _bwMask = bwramSize == 0 ? -1 : _mask(bwramSize);

  static int _mask(int length) {
    var size = 1;
    while (size < length) {
      size <<= 1;
    }
    return size - 1;
  }

  // $2200 CCNT
  bool _rdyb = false, _resb = true;
  int _smeg = 0;
  // $2209 SCNT
  bool _ivsw = false, _nvsw = false;
  int _cmeg = 0;
  // vectors: SA-1 reset/nmi/irq, main cpu nmi/irq
  int _crv = 0, _cnv = 0, _civ = 0, _snv = 0, _siv = 0;

  // interrupt enables and flags of the main cpu side
  bool _cpuIrqEn = false, _chdmaIrqEn = false;
  bool _cpuIrqFl = false, _chdmaIrqFl = false;
  // and of the SA-1 side
  bool _sa1IrqEn = false, _timerIrqEn = false, _dmaIrqEn = false;
  bool _nmiEn = false;
  bool _sa1IrqFl = false, _timerIrqFl = false, _dmaIrqFl = false;
  bool _nmiFl = false;

  // timer
  int _tmc = 0, _hcnt = 0, _vcnt = 0;
  int _hClock = 0, _v = 0; // SA-1 cycles in the line, line
  int _hcr = 0, _vcr = 0;

  // rom banks of $00-$1F/$C0-$CF, $20-$3F/$D0-$DF, $80-$9F/$E0-$EF,
  // $A0-$BF/$F0-$FF, and whether the $8000-$FFFF areas use them
  final _romBank = [0, 1, 2, 3];
  final _romBankMode = [false, false, false, false];

  // BW-RAM 8KB blocks at $6000-$7FFF for each cpu
  int _sbm = 0, _cbm = 0;
  bool _sw46 = false; // the SA-1 block is a bitmap view
  bool _bbf = false; // bitmap: false = 4 bits a pixel, true = 2 bits

  // DMA
  bool _dmaEn = false, _cdEn = false, _cdSel = false;
  int _sd = 0, _dd = 0; // source rom/bwram/iram, destination iram/bwram
  int _dmaSize = 0, _dmaCb = 0;
  int _sda = 0, _dda = 0, _dtc = 0;
  bool _cc1Active = false; // the main cpu reads converted characters
  int _cc2Line = 0;
  final _brf = Uint8List(16);

  // arithmetic
  bool _acm = false, _md = false, _overflow = false;
  int _ma = 0, _mb = 0, _mr = 0;

  // variable-length bit reader
  bool _hl = false;
  int _vb = 16, _va = 0, _vbit = 0;

  void reset() {
    iram.fillRange(0, iram.length, 0);
    _rdyb = false;
    _resb = true;
    _smeg = _cmeg = 0;
    _ivsw = _nvsw = false;
    _crv = _cnv = _civ = _snv = _siv = 0;
    _cpuIrqEn = _chdmaIrqEn = _cpuIrqFl = _chdmaIrqFl = false;
    _sa1IrqEn = _timerIrqEn = _dmaIrqEn = _nmiEn = false;
    _sa1IrqFl = _timerIrqFl = _dmaIrqFl = _nmiFl = false;
    _tmc = _hcnt = _vcnt = _hClock = _v = _hcr = _vcr = 0;
    for (var i = 0; i < 4; i++) {
      _romBank[i] = i;
      _romBankMode[i] = false;
    }
    _sbm = _cbm = 0;
    _sw46 = _bbf = false;
    _dmaEn = _cdEn = _cdSel = _cc1Active = false;
    _sd = _dd = _dmaSize = _dmaCb = _sda = _dda = _dtc = _cc2Line = 0;
    _brf.fillRange(0, 16, 0);
    _acm = _md = _overflow = false;
    _ma = _mb = _mr = 0;
    _hl = false;
    _vb = 16;
    _va = _vbit = 0;
    cpu.reset();
    cpu.cycle = 0;
    mainBus.cpu.releaseIrq(_mainIrqLine);
  }

  /// runs the SA-1 cpu until its clock reaches [mainCycle] of the main cpu
  void run(int mainCycle) {
    final target = mainCycle * clockRatio;
    final start = cpu.cycle;
    if (_rdyb || _resb) {
      cpu.cycle = max(cpu.cycle, target);
    } else {
      while (cpu.cycle < target) {
        if (cpu.idle) {
          cpu.cycle = target;
          break;
        }
        cpu.exec();
      }
    }
    _stepTimer(cpu.cycle - start);
  }

  // ------------------------------------------------------------ rom / ram
  int romRead(int addr) {
    final bank = addr >> 16;
    int a;
    bool lo;
    if (bank & 0x40 == 0) {
      // $00-$3F/$80-$BF:$8000-$FFFF, as 32KB per bank
      a = ((bank & 0x80) << 14) | ((bank & 0x3f) << 15) | (addr & 0x7fff);
      lo = true;
    } else {
      a = addr & 0x3fffff; // $C0-$FF
      lo = false;
    }
    final block = a >> 20;
    if (lo && !_romBankMode[block]) return rom[a & _romMask];
    return rom[((_romBank[block] << 20) | (a & 0xfffff)) & _romMask];
  }

  int bwRead(int a) => _bwMask < 0 ? 0 : mainBus.sramRead(a & _bwMask);

  void bwWrite(int a, int data) {
    if (_bwMask >= 0) mainBus.sramWrite(a & _bwMask, data);
  }

  int bitmapRead(int a) {
    a &= 0xfffff;
    if (!_bbf) return (bwRead(a >> 1) >> ((a & 1) << 2)) & 0xf;
    return (bwRead(a >> 2) >> ((a & 3) << 1)) & 3;
  }

  void bitmapWrite(int a, int data) {
    a &= 0xfffff;
    if (!_bbf) {
      final shift = (a & 1) << 2;
      final v = bwRead(a >> 1);
      bwWrite(a >> 1, (v & ~(0xf << shift)) | ((data & 0xf) << shift));
    } else {
      final shift = (a & 3) << 1;
      final v = bwRead(a >> 2);
      bwWrite(a >> 2, (v & ~(3 << shift)) | ((data & 3) << shift));
    }
  }

  // ------------------------------------------------------ main cpu access
  /// a read by the main cpu, or -1 if the address is not on the cartridge
  /// (wram and the system registers)
  int mainRead(int addr) {
    final bank = addr >> 16;
    final page = addr & 0xffff;
    if (bank & 0x40 == 0) {
      if (page >= 0x8000) return romRead(addr);
      if (page >= 0x6000) return _mainBwRead(_sbm << 13 | (page & 0x1fff));
      if (page >= 0x3000 && page < 0x3800) return iram[page & 0x7ff];
      if (page >= 0x2200 && page < 0x2400) return _readRegister(page);
      return -1;
    }
    if (bank >= 0xc0) return romRead(addr);
    if (bank < 0x50) return _mainBwRead(addr & 0xfffff);
    return 0;
  }

  int _mainBwRead(int a) => _cc1Active ? _cc1Read(a) : bwRead(a);

  /// a write by the main cpu: false if the address is not on the cartridge
  bool mainWrite(int addr, int data) {
    final bank = addr >> 16;
    final page = addr & 0xffff;
    if (bank & 0x40 == 0) {
      if (page >= 0x8000) return true;
      if (page >= 0x6000) {
        bwWrite(_sbm << 13 | (page & 0x1fff), data);
      } else if (page >= 0x3000 && page < 0x3800) {
        iram[page & 0x7ff] = data;
      } else if (page >= 0x2200 && page < 0x2400) {
        _writeRegister(page, data);
      } else {
        return false;
      }
      return true;
    }
    if (bank < 0x50) bwWrite(addr & 0xfffff, data);
    return true;
  }

  int mainVector(int addr) {
    if (addr == 0xffea && _nvsw) return _snv;
    if (addr == 0xffee && _ivsw) return _siv;
    return romRead(addr) | romRead(addr + 1) << 8;
  }

  // ------------------------------------------------------------ registers
  int _readRegister(int page) {
    switch (page) {
      case 0x2300: // SFR
        return (_cpuIrqFl ? 0x80 : 0) |
            (_ivsw ? 0x40 : 0) |
            (_chdmaIrqFl ? 0x20 : 0) |
            (_nvsw ? 0x10 : 0) |
            _cmeg;
      case 0x2301: // CFR
        return (_sa1IrqFl ? 0x80 : 0) |
            (_timerIrqFl ? 0x40 : 0) |
            (_dmaIrqFl ? 0x20 : 0) |
            (_nmiFl ? 0x10 : 0) |
            _smeg;
      case 0x2302: // HCR: reading the low byte latches the counters
        _hcr = _hClock >> 1;
        _vcr = _v;
        return _hcr & 0xff;
      case 0x2303:
        return _hcr >> 8;
      case 0x2304: // VCR
        return _vcr & 0xff;
      case 0x2305:
        return _vcr >> 8;
      case >= 0x2306 && <= 0x230a: // MR
        return (_mr >> ((page - 0x2306) << 3)) & 0xff;
      case 0x230b: // OF
        return _overflow ? 0x80 : 0;
      case 0x230c: // VDP
        return _vbrData() & 0xff;
      case 0x230d:
        final v = _vbrData() >> 8;
        if (_hl) _vbrAdvance();
        return v & 0xff;
      case 0x230e: // VC
        return 0x23;
    }
    return 0;
  }

  int _vbrData() {
    final data =
        bus.read(_va) | bus.read(_va + 1) << 8 | bus.read(_va + 2) << 16;
    return data >> _vbit;
  }

  void _vbrAdvance() {
    _vbit += _vb;
    _va = (_va + (_vbit >> 3)) & 0xffffff;
    _vbit &= 7;
  }

  void _writeRegister(int page, int data) {
    switch (page) {
      case 0x2200: // CCNT
        final wasReset = _resb;
        _rdyb = data & 0x40 != 0;
        _resb = data & 0x20 != 0;
        _smeg = data & 0xf;
        if (wasReset && !_resb) {
          final cycle = cpu.cycle;
          cpu.reset();
          cpu.cycle = cycle;
        }
        if (data & 0x80 != 0) {
          _sa1IrqFl = true;
          _updateSa1Irq();
        }
        if (data & 0x10 != 0) {
          _nmiFl = true;
          if (_nmiEn) cpu.onNmi();
        }
      case 0x2201: // SIE
        _cpuIrqEn = data & 0x80 != 0;
        _chdmaIrqEn = data & 0x20 != 0;
        _updateMainIrq();
      case 0x2202: // SIC
        if (data & 0x80 != 0) _cpuIrqFl = false;
        if (data & 0x20 != 0) _chdmaIrqFl = false;
        _updateMainIrq();
      case 0x2203:
        _crv = (_crv & 0xff00) | data;
      case 0x2204:
        _crv = (_crv & 0xff) | data << 8;
      case 0x2205:
        _cnv = (_cnv & 0xff00) | data;
      case 0x2206:
        _cnv = (_cnv & 0xff) | data << 8;
      case 0x2207:
        _civ = (_civ & 0xff00) | data;
      case 0x2208:
        _civ = (_civ & 0xff) | data << 8;
      case 0x2209: // SCNT
        _ivsw = data & 0x40 != 0;
        _nvsw = data & 0x10 != 0;
        _cmeg = data & 0xf;
        if (data & 0x80 != 0) {
          _cpuIrqFl = true;
          _updateMainIrq();
        }
      case 0x220a: // CIE
        final nmiWasEn = _nmiEn;
        _sa1IrqEn = data & 0x80 != 0;
        _timerIrqEn = data & 0x40 != 0;
        _dmaIrqEn = data & 0x20 != 0;
        _nmiEn = data & 0x10 != 0;
        if (!nmiWasEn && _nmiEn && _nmiFl) cpu.onNmi();
        _updateSa1Irq();
      case 0x220b: // CIC
        if (data & 0x80 != 0) _sa1IrqFl = false;
        if (data & 0x40 != 0) _timerIrqFl = false;
        if (data & 0x20 != 0) _dmaIrqFl = false;
        if (data & 0x10 != 0) _nmiFl = false;
        _updateSa1Irq();
      case 0x220c:
        _snv = (_snv & 0xff00) | data;
      case 0x220d:
        _snv = (_snv & 0xff) | data << 8;
      case 0x220e:
        _siv = (_siv & 0xff00) | data;
      case 0x220f:
        _siv = (_siv & 0xff) | data << 8;
      case 0x2210: // TMC
        _tmc = data;
      case 0x2211: // CTR
        _hClock = _v = 0;
      case 0x2212:
        _hcnt = (_hcnt & 0x100) | data;
      case 0x2213:
        _hcnt = (_hcnt & 0xff) | (data & 1) << 8;
      case 0x2214:
        _vcnt = (_vcnt & 0x100) | data;
      case 0x2215:
        _vcnt = (_vcnt & 0xff) | (data & 1) << 8;
      case >= 0x2220 && <= 0x2223: // CXB-FXB
        _romBankMode[page & 3] = data & 0x80 != 0;
        _romBank[page & 3] = data & 7;
      case 0x2224: // BMAPS
        _sbm = data & 0x1f;
      case 0x2225: // BMAP
        _sw46 = data & 0x80 != 0;
        _cbm = data & 0x7f;
      case 0x2230: // DCNT
        _dmaEn = data & 0x80 != 0;
        _cdEn = data & 0x20 != 0;
        _cdSel = data & 0x10 != 0;
        _dd = (data >> 2) & 1;
        _sd = data & 3;
        if (!_dmaEn) _cc2Line = 0;
      case 0x2231: // CDMA
        if (data & 0x80 != 0) _cc1Active = false;
        _dmaSize = min((data >> 2) & 7, 5);
        _dmaCb = min(data & 3, 2);
      case 0x2232:
        _sda = (_sda & 0xffff00) | data;
      case 0x2233:
        _sda = (_sda & 0xff00ff) | data << 8;
      case 0x2234:
        _sda = (_sda & 0x00ffff) | data << 16;
      case 0x2235:
        _dda = (_dda & 0xffff00) | data;
      case 0x2236:
        _dda = (_dda & 0xff00ff) | data << 8;
        if (_dmaEn) {
          if (!_cdEn && _dd == 0) {
            _dmaNormal();
          } else if (_cdEn && _cdSel) {
            _cc1Start();
          }
        }
      case 0x2237:
        _dda = (_dda & 0x00ffff) | data << 16;
        if (_dmaEn && !_cdEn && _dd == 1) _dmaNormal();
      case 0x2238:
        _dtc = (_dtc & 0xff00) | data;
      case 0x2239:
        _dtc = (_dtc & 0xff) | data << 8;
      case 0x223f: // BBF
        _bbf = data & 0x80 != 0;
      case >= 0x2240 && <= 0x224f: // BRF
        _brf[page & 0xf] = data;
        if ((page & 7) == 7 && _dmaEn && _cdEn && !_cdSel) _cc2();
      case 0x2250: // MCNT
        _acm = data & 2 != 0;
        _md = data & 1 != 0;
        if (_acm) _mr = 0;
      case 0x2251:
        _ma = (_ma & 0xff00) | data;
      case 0x2252:
        _ma = (_ma & 0xff) | data << 8;
      case 0x2253:
        _mb = (_mb & 0xff00) | data;
      case 0x2254:
        _mb = (_mb & 0xff) | data << 8;
        _arithmetic();
      case 0x2258: // VBD
        _hl = data & 0x80 != 0;
        _vb = data & 0xf;
        if (_vb == 0) _vb = 16;
        if (!_hl) _vbrAdvance();
      case 0x2259:
        _va = (_va & 0xffff00) | data;
      case 0x225a:
        _va = (_va & 0xff00ff) | data << 8;
      case 0x225b:
        _va = (_va & 0x00ffff) | data << 16;
        _vbit = 0;
    }
  }

  static int _s16(int v) => (v & 0x7fff) - (v & 0x8000);

  void _arithmetic() {
    if (!_acm) {
      if (!_md) {
        _mr = (_s16(_ma) * _s16(_mb)) & 0xffffffff;
        _mb = 0;
      } else {
        if (_mb == 0) {
          _mr = 0;
        } else {
          final dividend = _s16(_ma);
          final remainder = dividend % _mb; // non-negative in dart
          final quotient = (dividend - remainder) ~/ _mb;
          _mr = remainder << 16 | (quotient & 0xffff);
        }
        _ma = _mb = 0;
      }
    } else {
      _mr += _s16(_ma) * _s16(_mb);
      _overflow = _mr < 0 || _mr >= 1 << 40;
      _mr &= (1 << 40) - 1;
      _mb = 0;
    }
  }

  // ----------------------------------------------------------- interrupts
  void _updateMainIrq() {
    if ((_cpuIrqEn && _cpuIrqFl) || (_chdmaIrqEn && _chdmaIrqFl)) {
      mainBus.cpu.holdIrq(_mainIrqLine);
    } else {
      mainBus.cpu.releaseIrq(_mainIrqLine);
    }
  }

  void _updateSa1Irq() {
    if ((_sa1IrqEn && _sa1IrqFl) ||
        (_timerIrqEn && _timerIrqFl) ||
        (_dmaIrqEn && _dmaIrqFl)) {
      cpu.holdIrq();
    } else {
      cpu.releaseIrq();
    }
  }

  // a line has 341 dots of two SA-1 cycles
  static const _cyclesInLine = 682;

  void _stepTimer(int cycles) {
    final hEn = _tmc & 1 != 0, vEn = _tmc & 2 != 0;
    final lines = _tmc & 0x80 != 0 ? 512 : 262; // linear or H/V
    while (cycles > 0) {
      final n = min(cycles, _cyclesInLine - _hClock);
      if (hEn || vEn) {
        final h = hEn ? _hcnt << 1 : 0;
        if ((!vEn || _v == _vcnt) && h >= _hClock && h < _hClock + n) {
          _timerIrqFl = true;
          _updateSa1Irq();
        }
      }
      _hClock += n;
      cycles -= n;
      if (_hClock >= _cyclesInLine) {
        _hClock = 0;
        _v = (_v + 1) % lines;
      }
    }
  }

  // ------------------------------------------------------------------ DMA
  void _dmaNormal() {
    while (_dtc > 0) {
      _dtc = (_dtc - 1) & 0xffff;
      final src = _sda;
      final dst = _dda;
      _sda = (_sda + 1) & 0xffffff;
      _dda = (_dda + 1) & 0xffffff;
      final data = switch (_sd) {
        0 => romRead(src),
        1 => bwRead(src),
        _ => iram[src & 0x7ff],
      };
      if (_dd == 0) {
        iram[dst & 0x7ff] = data;
      } else {
        bwWrite(dst, data);
      }
    }
    _dmaIrqFl = true;
    _updateSa1Irq();
  }

  // character conversion 1: the main cpu's DMA reads a BW-RAM bitmap as
  // characters, which the chip converts a character at a time into I-RAM
  void _cc1Start() {
    _cc1Active = true;
    _chdmaIrqFl = true;
    _updateMainIrq();
  }

  int _cc1Read(int addr) {
    final charMask = (1 << (6 - _dmaCb)) - 1;
    if (addr & charMask == 0) {
      final bpp = 2 << (2 - _dmaCb);
      final bpl = (8 << _dmaSize) >> _dmaCb;
      final bwMask = _bwMask < 0 ? 0 : _bwMask;
      final tile = ((addr - _sda) & bwMask) >> (6 - _dmaCb);
      final ty = tile >> _dmaSize;
      final tx = tile & ((1 << _dmaSize) - 1);
      var bwAddr = _sda + ty * 8 * bpl + tx * bpp;

      final out = Uint8List(8);
      for (var y = 0; y < 8; y++) {
        var data = 0;
        for (var byte = 0; byte < bpp; byte++) {
          data |= bwRead(bwAddr + byte) << (byte << 3);
        }
        bwAddr += bpl;

        out.fillRange(0, 8, 0);
        for (var x = 0; x < 8; x++) {
          for (var p = 0; p < bpp; p++) {
            out[p] |= (data & 1) << (7 - x);
            data >>= 1;
          }
        }
        for (var byte = 0; byte < bpp; byte++) {
          final p = _dda + (y << 1) + ((byte & 6) << 3) + (byte & 1);
          iram[p & 0x7ff] = out[byte];
        }
      }
    }
    return iram[(_dda + (addr & charMask)) & 0x7ff];
  }

  // character conversion 2: the SA-1 writes a line of 8 pixels to BRF,
  // which the chip converts into I-RAM
  void _cc2() {
    final base = (_cc2Line & 1) << 3;
    final bpp = 2 << (2 - _dmaCb);
    var addr = _dda & 0x7ff;
    addr &= ~((1 << (7 - _dmaCb)) - 1);
    addr += (_cc2Line & 8) * bpp;
    addr += (_cc2Line & 7) * 2;
    for (var byte = 0; byte < bpp; byte++) {
      var output = 0;
      for (var bit = 0; bit < 8; bit++) {
        output |= ((_brf[base + bit] >> byte) & 1) << (7 - bit);
      }
      iram[(addr + ((byte & 6) << 3) + (byte & 1)) & 0x7ff] = output;
    }
    _cc2Line = (_cc2Line + 1) & 15;
  }

  // ------------------------------------------------------ SA-1 cpu access
  int sa1Read(int addr) {
    final bank = addr >> 16;
    final page = addr & 0xffff;
    if (bank & 0x40 == 0) {
      if (page >= 0x8000) return romRead(addr);
      if (page >= 0x6000) {
        return _sw46
            ? bitmapRead(_cbm << 13 | (page & 0x1fff))
            : bwRead((_cbm & 0x1f) << 13 | (page & 0x1fff));
      }
      if (page < 0x800 || (page >= 0x3000 && page < 0x3800)) {
        return iram[page & 0x7ff];
      }
      if (page >= 0x2200 && page < 0x2400) return _readRegister(page);
      return 0;
    }
    if (bank >= 0xc0) return romRead(addr);
    if (bank < 0x50) return bwRead(addr & 0xfffff);
    if (bank >= 0x60 && bank < 0x70) return bitmapRead(addr);
    return 0;
  }

  void sa1Write(int addr, int data) {
    final bank = addr >> 16;
    final page = addr & 0xffff;
    if (bank & 0x40 == 0) {
      if (page >= 0x8000) return;
      if (page >= 0x6000) {
        if (_sw46) {
          bitmapWrite(_cbm << 13 | (page & 0x1fff), data);
        } else {
          bwWrite((_cbm & 0x1f) << 13 | (page & 0x1fff), data);
        }
      } else if (page < 0x800 || (page >= 0x3000 && page < 0x3800)) {
        iram[page & 0x7ff] = data;
      } else if (page >= 0x2200 && page < 0x2400) {
        _writeRegister(page, data);
      }
      return;
    }
    if (bank >= 0xc0) return;
    if (bank < 0x50) {
      bwWrite(addr & 0xfffff, data);
    } else if (bank >= 0x60 && bank < 0x70) {
      bitmapWrite(addr, data);
    }
  }

  int sa1Vector(int addr) => switch (addr) {
        0xffea => _cnv,
        0xffee => _civ,
        0xfffc => _crv,
        _ => romRead(addr) | romRead(addr + 1) << 8,
      };
}

/// the SA-1 cpu's view of the cartridge
class Sa1Bus implements CpuBus {
  final Sa1 sa1;
  Sa1Bus(this.sa1);

  @override
  late final Cpu cpu;

  @override
  int read(int addr) => sa1.sa1Read(addr);

  @override
  void write(int addr, int data) => sa1.sa1Write(addr, data);

  @override
  int readVector(int addr) => sa1.sa1Vector(addr);
}
