import 'dart:typed_data';
import '../../../util/int.dart';

/// SPC7110: a cartridge chip which decompresses graphics from the data rom
/// (the rom after the first 1MB of program), maps 1MB data rom banks into
/// $D0-$FF, reads the data rom by pointer, multiplies and divides, and
/// connects an RTC-4513 real time clock in one game.
///
/// Written after the fullsnes documentation, including its description of
/// the decompression algorithm.
class Spc7110 {
  final Uint8List rom;
  final int Function(int) sramRead;
  final void Function(int, int) sramWrite;

  Spc7110(this.rom, this.sramRead, this.sramWrite);

  final _reg = Uint8List(0x50); // $4800-$484F
  final _dataBank = [0, 1, 2]; // $4831-$4833

  late final _decoder = Spc7110Decoder(dataRead);
  final _rtc = _Rtc4513();

  void reset() {
    _reg.fillRange(0, _reg.length, 0);
    _dataBank
      ..[0] = 0
      ..[1] = 1
      ..[2] = 2;
    _reg[0x32] = 1;
    _reg[0x33] = 2;
    _offsetWritten = 0;
    _decompressing = false;
    _directActive = false;
    _rtc.reset();
  }

  /// advances the real time clock by a second of emulated time
  void tickSecond() => _rtc.tick();

  /// a byte of the data rom, which follows the 1MB program rom
  int dataRead(int addr) {
    final a = 0x100000 + addr.mask24;
    return a < rom.length ? rom[a] : 0;
  }

  // ------------------------------------------------------------- mapping
  /// a read by the main cpu, or -1 if the address is not the chip's
  int mainRead(int addr) {
    final bank = addr.shr16;
    final page = addr.mask16;
    if (!bank.bit6) {
      if (page >= 0x8000) return _programRead(bank, page);
      if (page >= 0x4800 && page < 0x4850) return _readRegister(page);
      if (page >= 0x6000) {
        return _reg[0x30].bit7 ? sramRead(page.mask13) : 0;
      }
      return -1;
    }
    if (bank >= 0xd0) {
      final b = _dataBank[(bank - 0xd0).shr4];
      return dataRead(b.shl20 | (addr & 0xfffff));
    }
    if (bank >= 0x7e && bank < 0x80) return -1; // wram
    return _programRead(bank, page);
  }

  /// a write by the main cpu: false if the address is not the chip's
  bool mainWrite(int addr, int data) {
    final bank = addr.shr16;
    final page = addr.mask16;
    if (bank.bit6) return false;
    if (page >= 0x4800 && page < 0x4850) {
      _writeRegister(page, data);
      return true;
    }
    if (page >= 0x6000 && page < 0x8000) {
      if (_reg[0x30].bit7) sramWrite(page.mask13, data);
      return true;
    }
    return false;
  }

  // the 1MB program rom in HiROM banks, mirrored
  int _programRead(int bank, int page) =>
      rom[(bank.mask4.shl16 | page) % rom.length];

  // ----------------------------------------------------------- registers
  int _get(int i, int bytes) {
    var v = 0;
    for (var b = 0; b < bytes; b++) {
      v |= _reg[i + b] << (b * 8);
    }
    return v;
  }

  void _set(int i, int bytes, int v) {
    for (var b = 0; b < bytes; b++) {
      _reg[i + b] = (v >> (b * 8)).mask8;
    }
  }

  int _readRegister(int page) {
    final i = page - 0x4800;
    switch (i) {
      case 0x00: // decompressed data
        if (!_decompressing) return 0;
        final counter = (_get(0x09, 2) - 1).mask16;
        _set(0x09, 2, counter);
        return _decoder.next();
      case 0x0c: // decompression status
        return _decompressing ? 0x80 : 0;
      case 0x10: // data rom read, then the pointer moves
        return _directActive ? _directRead() : 0;
      case 0x1a: // data rom read at base+offset
        if (!_directActive) return 0;
        final v = dataRead(_get(0x11, 3) + _offset());
        if (_reg[0x18].shr5.mask2 == 3) _addToBase(_offset());
        return v;
      case 0x2f: // multiply/divide status: always ready
        return 0;
      case 0x41:
        return _rtc.read();
      case 0x42: // rtc ready
        return 0x80;
    }
    return _reg[i];
  }

  int _offsetWritten = 0; // bit0: $4814, bit1: $4815
  bool _decompressing = false;
  bool _directActive = false; // after the pointer is written

  void _writeRegister(int page, int data) {
    final i = page - 0x4800;
    _reg[i] = data;
    switch (i) {
      case 0x06: // starts decompression
        _decompressing = true;
        final base = _get(0x01, 3);
        final entry = base + _reg[0x04] * 4;
        _decoder.start(
            dataRead(entry),
            dataRead(entry + 1).shl16 |
                dataRead(entry + 2).shl8 |
                dataRead(entry + 3));
        for (var n = _get(0x05, 2); n > 0; n--) {
          _decoder.next();
        }
      case 0x11 || 0x12 || 0x13:
        _directActive = true;
      case 0x14 || 0x15:
        _offsetWritten |= i == 0x14 ? 1 : 2;
        if (_offsetWritten == 3) {
          _offsetWritten = 0;
          final action = _reg[0x18].shr5.mask2;
          if (action == 1) _addToBase(_sign(_reg[0x14], 8, _reg[0x18] & 8));
          if (action == 2) _addToBase(_offset());
        }
      case 0x25: // multiply
        final a = _get(0x20, 2), b = _get(0x24, 2);
        final r = _signed ? _sign(a, 16, 1) * _sign(b, 16, 1) : a * b;
        _set(0x28, 4, r.mask32);
      case 0x27: // divide
        final dividend = _get(0x20, 4), divisor = _get(0x26, 2);
        if (divisor == 0) {
          _set(0x28, 4, 0);
          _set(0x2c, 2, dividend.mask16);
        } else if (_signed) {
          final x = _sign(dividend, 32, 1), y = _sign(divisor, 16, 1);
          _set(0x28, 4, (x ~/ y).mask32);
          _set(0x2c, 2, x.remainder(y).mask16);
        } else {
          _set(0x28, 4, dividend ~/ divisor);
          _set(0x2c, 2, dividend % divisor);
        }
      case 0x31 || 0x32 || 0x33:
        _dataBank[i - 0x31] = data.mask3;
      case 0x40:
        _rtc.select(data.bit0);
      case 0x41:
        _rtc.write(data.mask4);
    }
  }

  bool get _signed => _reg[0x2e].bit0;

  static int _sign(int v, int bits, int signed) {
    if (signed == 0) return v;
    final m = 1 << (bits - 1);
    return (v & (m - 1)) - (v & m);
  }

  int _offset() => _sign(_get(0x14, 2), 16, _reg[0x18] & 8);

  void _addToBase(int v) => _set(0x11, 3, (_get(0x11, 3) + v).mask24);

  int _directRead() {
    final mode = _reg[0x18];
    final base = _get(0x11, 3);
    final v = dataRead(base + (mode.bit1 ? _offset() : 0));
    final step = mode.bit0 ? _sign(_get(0x16, 2), 16, mode & 4) : 1;
    if (mode.bit4) {
      _set(0x14, 2, (_get(0x14, 2) + step).mask16);
    } else {
      _addToBase(step);
    }
    return v;
  }
}

/// the SPC7110 decompressor: an adaptive binary arithmetic decoder over
/// context models for 1, 2 and 4 bits per pixel data
class Spc7110Decoder {
  final int Function(int) read;
  Spc7110Decoder(this.read);

  static const _prob = [
    90, 37, 17, 8, 3, 1, 90, 63, 44, 32, 23, 17, 12, 9, 7, 5, 4, 3, 2, //
    90, 72, 58, 46, 38, 31, 25, 21, 17, 14, 11, 9, 8, 7, 5, 4, 4, 3, 2,
    2, 88, 77, 67, 59, 52, 46, 41, 37, 86, 79, 71, 65, 60, 55,
  ];
  static const _nextLps = [
    1, 6, 8, 10, 12, 15, 7, 19, 21, 22, 23, 25, 26, 28, 29, 31, 32, 34, 35, //
    20, 39, 40, 42, 44, 45, 46, 25, 26, 26, 27, 28, 29, 30, 31, 33, 33, 34,
    35, 36, 39, 47, 48, 49, 50, 51, 44, 45, 47, 47, 48, 49, 50, 51,
  ];
  static const _nextMps = [
    1, 2, 3, 4, 5, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 5, //
    20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37,
    38, 5, 40, 41, 42, 43, 44, 45, 46, 24, 48, 49, 50, 51, 52, 43,
  ];
  static const _mode2Context = [
    0, 0, 0, 15, 17, 19, 21, 23, 25, 25, 25, 25, 25, 27, 29, //
  ];

  int _mode = 0, _src = 0;
  int _bufIndex = 0, _out = 0, _c = 0, _top = 0, _val = 0, _inCount = 0;
  int _decoded = 0;
  final _pixelOrder = List<int>.filled(16, 0);
  final _realOrder = List<int>.filled(16, 0);
  final _contextIndex = List<int>.filled(32, 0);
  final _contextInvert = List<int>.filled(32, 0);
  final _planes = List<int>.filled(16, 0);
  int _plane1 = 0;

  void start(int mode, int src) {
    _mode = mode;
    _src = src;
    _bufIndex = 0;
    _out = 0;
    _c = 0;
    _top = 255;
    _val = read(_src++).shl8;
    _inCount = 0;
    for (var i = 0; i < 16; i++) {
      _pixelOrder[i] = i;
    }
    _contextIndex.fillRange(0, 32, 0);
    _contextInvert.fillRange(0, 32, 0);
  }

  void _core(int con) {
    _decoded = _decoded.shl1 ^ _contextInvert[con];
    final evl = _contextIndex[con];
    _top -= _prob[evl];
    if (_val.shr8 > _top) {
      _val -= (_top + 1).shl8;
      _top = _prob[evl] - 1;
      if (_top > 79) _contextInvert[con] ^= 1;
      _decoded ^= 1;
      _contextIndex[con] = _nextLps[evl];
    } else if (_top <= 126) {
      _contextIndex[con] = _nextMps[evl];
    }
    while (_top <= 126) {
      if (_inCount == 0) {
        _val = (_val & 0xff00) | read(_src++);
        _inCount = 8;
      }
      _top = _top.shl1 + 1;
      _val = _val.shl1.mask16;
      _inCount--;
    }
  }

  static int _getCon(int a, int b, int c) {
    if (a == b && b == c) return 0;
    if (a == b) return 1;
    if (b == c) return 2;
    if (a == c) return 3;
    return 4;
  }

  static void _moveToFront(List<int> order, int x) {
    final v = x;
    var m = 0;
    do {
      final t = order[m];
      order[m] = x;
      x = t;
      m++;
    } while (x != v);
  }

  void _pixelOrderStep(int a, int b, int shift) {
    _moveToFront(_pixelOrder, a);
    for (var m = 0; m < 1 << shift; m++) {
      _realOrder[m] = _pixelOrder[m];
    }
    _moveToFront(_realOrder, _c);
    _moveToFront(_realOrder, b);
    _moveToFront(_realOrder, a);
    _out = ((_out << shift) + _realOrder[_decoded]).mask32;
    _c = b;
  }

  /// the next decompressed byte
  int next() => switch (_mode) {
        0 => _mode0(),
        1 => _mode1(),
        _ => _mode2(),
      };

  int _nibble(int base) {
    _decoded = 0;
    _core(base);
    _core(base + 1 + _decoded);
    _core(base + 3 + _decoded);
    _core(base + 7 + _decoded);
    return _decoded;
  }

  int _mode0() {
    for (final base in const [0, 15]) {
      final d = _nibble(base);
      _out = (_out.shl4 ^ (_out.shr12 ^ d).mask4).mask32;
    }
    return _out.mask8;
  }

  int _mode1() {
    int v;
    if (!_bufIndex.bit0) {
      for (var pixel = 0; pixel < 8; pixel++) {
        final a = _out.shr2.mask2, b = _out.shr14.mask2;
        _decoded = 0;
        final con = _getCon(a, b, _c);
        _core(con);
        _core(con * 2 + 5 + _decoded);
        _pixelOrderStep(a, b, 2);
      }
      v = _bits(_out, 15, 2);
      _plane1 = _bits(_out, 14, 2);
    } else {
      v = _plane1;
    }
    _bufIndex++;
    return v;
  }

  int _mode2() {
    int v;
    if (_bufIndex & 0x11 == 0) {
      for (var pixel = 0; pixel < 8; pixel++) {
        final a = _out.mask4, b = _out.shr28.mask4;
        _decoded = 0;
        _core(0);
        var con = _decoded + 1;
        _core(con);
        con = con == 2 ? _decoded + 11 : _getCon(a, b, _c) + 3 + _decoded * 5;
        _core(con);
        _core(_mode2Context[con] + _decoded.mask1);
        _pixelOrderStep(a, b, 4);
      }
      v = _bits(_out, 31, 4);
      _plane1 = _bits(_out, 30, 4);
      _planes[_bufIndex.mask4] = _bits(_out, 29, 4);
      _planes[(_bufIndex + 1).mask4] = _bits(_out, 28, 4);
    } else if (!_bufIndex.bit4) {
      v = _plane1;
    } else {
      v = _planes[_bufIndex.mask4];
    }
    _bufIndex++;
    return v;
  }

  // 8 bits of [v] from bit [top] down, every [step] bits
  static int _bits(int v, int top, int step) {
    var r = 0;
    for (var i = 0; i < 8; i++) {
      r = r.shl1 | (v >> (top - i * step)).mask1;
    }
    return r;
  }
}

/// Epson RTC-4513: a real time clock read and written by 4-bit units
class _Rtc4513 {
  bool _selected = false;
  int _state = 0; // 0: command, 1: index, 2: data
  bool _reading = false;
  bool _timeWritten = false;
  int _index = 0;
  final _regs = Uint8List(16);

  // the clock, which counts emulated seconds from the host time at reset
  DateTime _time = DateTime.utc(2000);
  int _week = 0;

  void reset() {
    _selected = false;
    _state = 0;
    _regs.fillRange(0, 16, 0);
    _regs[0xf] = 0x4; // 24 hour mode, running
    final now = DateTime.now();
    _time = DateTime.utc(
        now.year, now.month, now.day, now.hour, now.minute, now.second);
    _week = now.weekday % 7;
  }

  bool get _running => _regs[0xf].mask2 == 0 && !_regs[0xd].bit0;

  /// advances the clock by a second of emulated time
  void tick() {
    if (!_running) return;
    final next = _time.add(const Duration(seconds: 1));
    if (next.day != _time.day) _week = (_week + 1) % 7;
    _time = next;
  }

  void select(bool on) {
    if (on && !_selected) {
      _state = 0;
      _timeWritten = false;
      _latchTime();
    } else if (!on && _selected) {
      if (_timeWritten) _setTime();
      _regs[0xf] &= ~1; // RESET clears with CE low
    }
    _selected = on;
  }

  static int _bcd(int v) => (v ~/ 10).shl4 | v % 10;
  static int _bin(int v) => v.shr4 * 10 + v.mask4;

  int _pair(int i, int highMask) =>
      _bin(_regs[i] | (_regs[i + 1] & highMask).shl4);

  void _latchTime() {
    final t = _time;
    void put(int i, int v, int highMask) {
      _regs[i] = v.mask4;
      _regs[i + 1] = (_regs[i + 1] & ~highMask).mask4 | (v.shr4 & highMask);
    }

    put(0, _bcd(t.second), 0x7);
    put(2, _bcd(t.minute), 0x7);
    put(4, _bcd(t.hour), 0x3);
    put(6, _bcd(t.day), 0x3);
    put(8, _bcd(t.month), 0x1);
    put(10, _bcd(t.year % 100), 0xf);
    _regs[12] = _week;
  }

  // the game set the clock
  void _setTime() {
    final year = 1900 + _pair(10, 0xf);
    _time = DateTime.utc(
        year < 1990 ? year + 100 : year,
        _pair(8, 0x1).clamp(1, 12),
        _pair(6, 0x3).clamp(1, 31),
        _pair(4, 0x3),
        _pair(2, 0x7),
        _pair(0, 0x7));
    _week = _regs[12].mask3;
  }

  void write(int nibble) {
    if (!_selected) return;
    switch (_state) {
      case 0:
        _reading = nibble == 0x0c;
        _state = 1;
      case 1:
        _index = nibble;
        _state = 2;
      default:
        if (!_reading) {
          _regs[_index] = nibble;
          if (_index <= 12) _timeWritten = true;
        }
        _index = (_index + 1).mask4;
    }
  }

  int read() {
    if (!_selected || !_reading || _state != 2) return 0;
    final v = _regs[_index];
    _index = (_index + 1).mask4;
    return v;
  }
}
