import 'dart:math' as math;
import 'dart:typed_data';

/// Cx4 (manufacturer HG51B169): a cartridge risc cpu which runs 16-bit opcodes
/// from the cartridge rom, with 3KB of ram, a 1024 x 24-bit data rom of math
/// tables and sixteen 24-bit registers shared with the main cpu.
///
/// Written after the fullsnes documentation of the I/O ports, the opcodes
/// and the data rom formulas. A command runs to its end when the main cpu
/// starts it, so the chip never reads as busy.
class Cx4 {
  /// reads the main bus (the cartridge rom) for data
  final int Function(int addr) busRead;

  /// the cartridge rom (LoROM), for the program
  final Uint8List rom;
  final int _romMask;

  Cx4(this.busRead, this.rom) : _romMask = _mask(rom.length);

  static int _mask(int length) {
    var size = 1;
    while (size < length) {
      size <<= 1;
    }
    return size - 1;
  }

  final ram = Uint8List(0xc00);
  final _io = Uint8List(0x80); // $7F40-$7FBF

  // registers
  int _a = 0; // accumulator
  int _mh = 0, _ml = 0; // multiply result
  int _extDta = 0, _extPtr = 0; // a byte of the snes rom and its address
  int _romDta = 0; // a word of the data rom
  int _ramDta = 0, _ramPtr = 0;
  int _page = 0, _pc = 0, _prgPage = 0;
  bool _n = false, _z = false, _c = false;
  final _stack = <int>[];
  final _r = List<int>.filled(16, 0);

  static final dataRom = _buildDataRom();

  static Int32List _buildDataRom() {
    final t = Int32List(1024);
    int clip(double v) => math.min(v.floor(), 0xffffff);
    double rad(int i) => i * math.pi / 2 / 128;
    for (var i = 0; i < 256; i++) {
      t[i] = i == 0 ? 0xffffff : clip(0x800000 / i);
      t[0x100 + i] = clip(0x100000 * math.sqrt(i));
    }
    for (var i = 0; i < 128; i++) {
      t[0x200 + i] = clip(0x1000000 * math.sin(rad(i)));
      t[0x280 + i] = clip(0x800000 / 90 * math.asin(i / 128) * 180 / math.pi);
      t[0x300 + i] = clip(0x10000 * math.tan(rad(i)));
      t[0x380 + i] = clip(0x1000000 * math.cos(rad(i)));
    }
    return t;
  }

  void reset() {
    ram.fillRange(0, ram.length, 0);
    _io.fillRange(0, _io.length, 0);
    _a = _mh = _ml = _extDta = _extPtr = _romDta = _ramDta = _ramPtr = 0;
    _page = _pc = _prgPage = 0;
    _n = _z = _c = false;
    _stack.clear();
    _r.fillRange(0, 16, 0);
  }

  /// true if [page] ($6000-$7FFF in banks $00-$3F/$80-$BF) is the chip's
  static bool isMapped(int bank, int page) =>
      (bank & 0x40) == 0 && page >= 0x6000 && page < 0x8000;

  int read(int page) {
    if (page < 0x6c00) return ram[page - 0x6000];
    if (page >= 0x7f80 && page < 0x7fb0) {
      final n = (page - 0x7f80) ~/ 3;
      return (_r[n] >> ((page - 0x7f80) % 3 * 8)) & 0xff;
    }
    if (page == 0x7f5e) return 0; // never busy
    if (page >= 0x7f40 && page < 0x7fc0) return _io[page - 0x7f40];
    return 0;
  }

  void write(int page, int data) {
    if (page < 0x6c00) {
      ram[page - 0x6000] = data;
      return;
    }
    if (page >= 0x7f80 && page < 0x7fb0) {
      final n = (page - 0x7f80) ~/ 3;
      final shift = (page - 0x7f80) % 3 * 8;
      _r[n] = (_r[n] & ~(0xff << shift)) | data << shift;
      return;
    }
    if (page < 0x7f40 || page >= 0x7fc0) return;
    _io[page - 0x7f40] = data;
    switch (page) {
      case 0x7f47:
        _dma();
      case 0x7f4f:
        final base = _io24(9);
        _programBase = ((base >> 16) & 0x7f) * 0x8000 + (base & 0x7fff);
        _page = _io[0x0d] | _io[0x0e] << 8;
        _pc = data;
        _run();
    }
  }

  int _io24(int i) => _io[i] | _io[i + 1] << 8 | _io[i + 2] << 16;

  void _dma() {
    var src = _io24(0);
    final length = _io[3] | _io[4] << 8;
    var dst = (_io[5] | _io[6] << 8) - 0x6000;
    for (var i = 0; i < length; i++) {
      final d = busRead(src);
      if (dst >= 0 && dst < ram.length) ram[dst] = d;
      src = _nextLoRom(src);
      dst++;
    }
  }

  // the next byte of a LoROM address, skipping the lower half of the banks
  static int _nextLoRom(int addr) {
    addr = (addr + 1) & 0xffffff;
    return addr & 0x8000 == 0 ? (addr | 0x8000) : addr;
  }

  // the program base ($7F49-$7F4B, a LoROM address) as a rom offset
  int _programBase = 0;

  int _fetch() {
    final a = (_programBase + (((_page << 8) | _pc) << 1)) & _romMask;
    final op = rom[a] | rom[(a + 1) & _romMask] << 8;
    _pc++;
    if (_pc == 0x100) {
      _pc = 0;
      _page = (_page + 1) & 0xffff;
    }
    return op;
  }

  static const _constants = [
    0x000000, 0xffffff, 0x00ff00, 0xff0000, 0x00ffff, 0xffff00, //
    0x800000, 0x7fffff, 0x008000, 0x007fff, 0xff7fff, 0xffff7f,
    0x010000, 0xfeffff, 0x000100, 0x00feff,
  ];

  int _readReg(int op) {
    switch (op) {
      case 0x00:
        return _a;
      case 0x01:
        return _mh;
      case 0x02:
        return _ml;
      case 0x03:
        return _extDta;
      case 0x08:
        return _romDta;
      case 0x0c:
        return _ramDta;
      case 0x13:
        return _extPtr;
      case 0x1c:
        return _ramPtr;
      case 0x2e:
        return busRead(_extPtr);
      case >= 0x50 && < 0x60:
        return _constants[op - 0x50];
      case >= 0x60 && < 0x70:
        return _r[op & 0xf];
    }
    return 0;
  }

  void _writeReg(int op, int v) {
    v &= 0xffffff;
    switch (op) {
      case 0x00:
        _a = v;
      case 0x01:
        _mh = v;
      case 0x02:
        _ml = v;
      case 0x03:
        _extDta = v;
      case 0x08:
        _romDta = v;
      case 0x0c:
        _ramDta = v;
      case 0x13:
        _extPtr = v;
      case 0x1c:
        _ramPtr = v;
      case >= 0x60 && < 0x70:
        _r[op & 0xf] = v;
    }
  }

  // A, A*2, A*100h or A*10000h
  int _shiftedA(int ss) => (_a << const [0, 1, 8, 16][ss]) & 0xffffff;

  void _setNZ(int v) {
    _n = v & 0x800000 != 0;
    _z = v & 0xffffff == 0;
  }

  int _add(int x, int y) {
    final r = x + y;
    _c = r > 0xffffff;
    _setNZ(r);
    return r & 0xffffff;
  }

  int _sub(int x, int y) {
    final r = x - y;
    _c = r >= 0;
    _setNZ(r);
    return r & 0xffffff;
  }

  static int _s24(int v) => (v & 0x7fffff) - (v & 0x800000);

  void _jump(int op) {
    if (op & 0x200 != 0) _page = _prgPage;
    _pc = op & 0xff;
  }

  bool _flag(int which) => switch (which) {
        1 => _c,
        2 => _z,
        3 => _n,
        _ => false,
      };

  void _run() {
    _stack.clear();
    for (var steps = 0; steps < 1 << 22; steps++) {
      final op = _fetch();
      final ss = (op >> 8) & 3;
      final operand = op & 0xff;
      int src() => op & 0x400 != 0 ? operand : _readReg(operand);

      switch (op >> 11) {
        case 0x00: // nop
          break;
        case 0x01: // jmp / jz
          if (op & 0x400 == 0 || _z) _jump(op);
        case 0x02: // jc / js
          if (op & 0x400 == 0 ? _c : _n) _jump(op);
        case 0x03: // finish ext_dta: waits for the read, done at once here
          break;
        case 0x04: // skip
          if (op & 0x400 != 0 && _flag(ss) == (op & 1 != 0)) {
            _fetch();
          }
        case 0x05: // call / callz
          if (op & 0x400 == 0 || _z) _call(op);
        case 0x06: // callc / calls
          if (op & 0x400 == 0 ? _c : _n) _call(op);
        case 0x07: // ret
          if (op & 0x400 != 0) {
            if (_stack.isEmpty) return;
            final ret = _stack.removeLast();
            _page = ret >> 8;
            _pc = ret & 0xff;
          }
        case 0x08: // inc ext_ptr
          if (op & 0x400 == 0) _extPtr = _nextLoRom(_extPtr);
        case 0x09: // cmp op,A / cmp imm,A
          _sub(src(), _shiftedA(ss));
        case 0x0a: // cmp A,op / cmp A,imm
          _sub(_shiftedA(ss), src());
        case 0x0b: // sign expand / -
          if (op & 0x400 == 0) {
            if (ss == 1) _a = ((_a & 0xff) ^ 0x80) - 0x80 & 0xffffff;
            if (ss == 2) _a = ((_a & 0xffff) ^ 0x8000) - 0x8000 & 0xffffff;
            _setNZ(_a);
          }
        case 0x0c: // mov
          final v = src();
          switch (ss) {
            case 0:
              _a = v & 0xffffff;
            case 1:
              _extDta = v & 0xffffff;
            case 3:
              _prgPage = v & 0xffff;
          }
        case 0x0d: // movb ram_dta.byte, cx4ram[op] / [ram_ptr + imm]
          final addr = op & 0x400 != 0 ? _ramPtr + operand : _readReg(operand);
          final shift = ss * 8;
          final b = ram[addr % ram.length];
          _ramDta = (_ramDta & ~(0xff << shift) & 0xffffff) | b << shift;
        case 0x0e: // mov rom_dta, cx4rom[op]
          if (op & 0x400 == 0) _romDta = dataRom[_readReg(operand) & 0x3ff];
        case 0x0f: // mov prg_page.lsb/msb
          final v = src() & 0xff;
          _prgPage = ss & 1 == 0
              ? (_prgPage & 0xff00) | v
              : (_prgPage & 0x00ff) | v << 8;
        case 0x10: // add A, A*n + op
          _a = _add(_shiftedA(ss), src());
        case 0x11: // sub A, op - A*n
          _a = _sub(src(), _shiftedA(ss));
        case 0x12: // sub A, A*n - op
          _a = _sub(_shiftedA(ss), src());
        case 0x13: // smul MH:ML, A, op
          final r = _s24(_a) * _s24(src() & 0xffffff);
          _ml = r & 0xffffff;
          _mh = (r >> 24) & 0xffffff;
        case 0x15: // xor
          _a = _shiftedA(ss) ^ (src() & 0xffffff);
          _setNZ(_a);
        case 0x16: // and
          _a = _shiftedA(ss) & src();
          _setNZ(_a);
        case 0x17: // or
          _a = _shiftedA(ss) | (src() & 0xffffff);
          _setNZ(_a);
        case 0x18: // shr
          _a = _a >> (src() & 0x1f);
          _setNZ(_a);
        case 0x19: // sar
          _a = (_s24(_a) >> (src() & 0x1f)) & 0xffffff;
          _setNZ(_a);
        case 0x1a: // ror
          final n = src() % 24;
          _a = ((_a >> n) | (_a << (24 - n))) & 0xffffff;
          _setNZ(_a);
        case 0x1b: // shl
          _a = (_a << (src() & 0x1f)) & 0xffffff;
          _setNZ(_a);
        case 0x1c: // mov op, A
          if (op & 0x400 == 0) _writeReg(operand, _a);
        case 0x1d: // movb cx4ram[op] / [ram_ptr + imm], ram_dta.byte
          final addr = op & 0x400 != 0 ? _ramPtr + operand : _readReg(operand);
          ram[addr % ram.length] = (_ramDta >> (ss * 8)) & 0xff;
        case 0x1e: // xchg op, A
          if (op & 0x400 == 0) {
            final v = _readReg(operand);
            _writeReg(operand, _a);
            _a = v & 0xffffff;
          }
        case 0x1f: // stop
          if (op & 0x400 != 0) return;
      }
    }
  }

  void _call(int op) {
    _stack.add(_page << 8 | _pc);
    _jump(op);
  }
}
