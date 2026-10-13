import 'dart:typed_data';

import '../../../util/int.dart';
import 'mapper.dart';
import 'mirror.dart';
import 'sunsoft5b_apu.dart';

// https://www.nesdev.org/wiki/Sunsoft_FME-7
class MapperFme7 extends Mapper {
  final _apu = Sunsoft5bApu();

  @override
  int get chrRomSizeK => 1;
  @override
  int get prgRomSizeK => 8;

  int _command = 0;
  int _audioReg = 0;

  final _chrBank = List<int>.filled(8, 0);
  final _prgBank = List<int>.filled(4, 0); // $8000, $A000, $C000, $E000

  // $6000-$7FFF: a rom bank, or the ram when bit6 of command 8 is set
  int _bank6000 = 0;
  bool _ram6000 = false, _ramEnabled = false;

  bool _irqEnabled = false, _counterEnabled = false;
  int _irqCounter = 0;
  int _prevCycle = 0;

  @override
  void init() {
    _prgBank[3] = prgRoms.length - 1;
  }

  @override
  void write(int addr, int data) {
    switch (addr & 0xe000) {
      case 0x6000:
        if (_ram6000 && _ramEnabled) writeSram(addr.mask13, data);
      case 0x8000:
        _command = data.mask4;
      case 0xa000:
        _parameter(data);
      case 0xc000:
        _audioReg = data.mask4;
      case 0xe000:
        _apu.write(_audioReg, data);
    }
  }

  void _parameter(int data) {
    switch (_command) {
      case < 8:
        _chrBank[_command] = data % chrRoms.length;
      case 8:
        _bank6000 = data.mask6;
        _ram6000 = data.bit6;
        _ramEnabled = data.bit7;
      case 9 || 10 || 11:
        _prgBank[_command - 9] = data.mask6 % prgRoms.length;
      case 12:
        mirror(_mirrors[data.mask2]);
      case 13:
        _irqEnabled = data.bit0;
        _counterEnabled = data.bit7;
        holdIrq(false);
      case 14:
        _irqCounter = (_irqCounter & 0xff00) | data;
      case 15:
        _irqCounter = _irqCounter.mask8 | data.shl8;
    }
  }

  static final _mirrors = [
    Mirror.vertical,
    Mirror.horizontal,
    Mirror.oneScreenLow,
    Mirror.oneScreenHigh,
  ];

  @override
  int read(int addr) {
    if (addr & 0xe000 == 0x6000) {
      if (_ram6000) return _ramEnabled ? readSram(addr.mask13) : 0xff;
      return prgRoms[_bank6000 % prgRoms.length][addr.mask13];
    }
    if (addr.bit15) {
      return prgRoms[_prgBank[addr.shr13.mask2]][addr.mask13];
    }
    return 0xff;
  }

  @override
  int readVram(int addr) => chrRoms[_chrBank[addr.shr10]][addr.mask10];

  @override
  void writeVram(int addr, int data) {
    // a board with chr ram
    chrRoms[_chrBank[addr.shr10]][addr.mask10] = data;
  }

  // the counter decrements every cpu cycle, and the IRQ fires as it wraps
  @override
  void handleClock(int cycles) {
    final elapsed = cycles - _prevCycle;
    _prevCycle = cycles;
    if (!_counterEnabled || elapsed <= 0) return;
    final wraps = elapsed > _irqCounter;
    _irqCounter = (_irqCounter - elapsed).mask16;
    if (wraps && _irqEnabled) holdIrq(true);
  }

  @override
  Float32List handleApu(int cycles) => _apu.exec(cycles);

  @override
  String dump() => "rom: chr:${_chrBank.join(' ')} prg:${_prgBank.join(' ')} "
      "irq:${_irqEnabled ? '*' : '-'}${_counterEnabled ? 'c' : '-'} "
      "@$_irqCounter\n${_apu.dump()}\n";
}
