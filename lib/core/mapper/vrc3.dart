// Dart imports:
import 'dart:developer';
import 'dart:typed_data';

// Project imports:
import '../../util.dart';
import 'mapper.dart';

// https://www.nesdev.org/wiki/VRC3
class MapperVrc3 extends Mapper {
  // IRQ related counters, flags etc.
  int _irqLatch = 0;
  int _irqCounter = 0;
  bool _irqEnabled = false;
  bool _irqEnabledAfterAcknoledge = false;
  bool _irqMode16bit = false;

  // ram 8k
  final _ram = Uint8List(8 * 1024);

  // rom 0x8000-0xbfff 16k bank
  late int _prgBank;

  // chr ram
  final chrRam = Uint8List(8 * 1024);

  @override
  void init() {
    if (prgRoms.length - 1 & prgRoms.length != 0) {
      log("invalid prg rom size: ${prgRoms.length}k");
      return;
    }
    _prgBank = 0;
  }

  @override
  void write(addr, data) {
    final reg = addr & 0xf000;

    switch (reg) {
      case 0x6000:
      case 0x7000:
        _ram[addr & 0x1fff] = data;
        return;

      case 0xf000:
        _prgBank = data & 0x07;
        return;

      case 0x8000:
        _irqLatch = _irqLatch.with4Bit(data);
        holdIrq(false);
        return;
      case 0x9000:
        _irqLatch = _irqLatch.with4Bit(data, lsbPosition: 4);
        holdIrq(false);
        return;
      case 0xa000:
        _irqLatch = _irqLatch.with4Bit(data, lsbPosition: 8);
        holdIrq(false);
        return;
      case 0xb000:
        _irqLatch = _irqLatch.with4Bit(data, lsbPosition: 12);
        holdIrq(false);
        return;

      case 0xc000:
        _setIrqControl(data);
        return;
      case 0xd000:
        _setIrqAcknoledge();
        return;
    }
  }

  @override
  int read(int addr) {
    if (addr & 0xe000 == 0x6000) {
      return _ram[addr & 0x1fff];
    }

    final bank = addr & 0xc000;
    final offset = addr & 0x3fff;

    switch (bank) {
      case 0x8000:
        return prgRoms[_prgBank][offset];
      case 0xc000:
        return prgRoms[prgRoms.length - 1][offset];
    }

    return 0xff;
  }

  @override
  int readVram(int addr) {
    final offset = addr & 0x1fff;
    return chrRam[offset];
  }

  @override
  void writeVram(int addr, int data) {
    final offset = addr & 0x1fff;
    chrRam[offset] = data & 0xff;
  }

  void _setIrqControl(data) {
    _irqEnabledAfterAcknoledge = bit0(data);
    _irqEnabled = bit1(data);
    if (_irqEnabled) {
      _irqCounter = _irqLatch;
    }
    _irqMode16bit = !bit2(data);
    holdIrq(false);
  }

  void _setIrqAcknoledge() {
    _irqEnabled = _irqEnabledAfterAcknoledge;
    holdIrq(false);
  }

  int _prevCycle = 0;

  @override
  void handleClock(int cycles) {
    int diff = cycles - _prevCycle;
    _prevCycle = cycles;

    if (_irqEnabled) {
      while (diff > 0) {
        if (_irqMode16bit) {
          if (_irqCounter == 0xffff) {
            _irqCounter = _irqLatch;
            holdIrq(true);
          }
        } else {
          if (_irqCounter & 0xff == 0xff) {
            _irqCounter = _irqCounter.withLowByte(_irqLatch & 0xff);
            holdIrq(true);
          }
        }
        _irqCounter += 1;
        diff -= 1;
      }
    }
  }

  @override
  String dump() {
    final prgBanks = range(0, 2).map((i) => hex8(_prgBank)).toList().join(" ");

    return "rom: irq:${_irqEnabled ? '*' : '-'}${_irqMode16bit ? '16' : ' 8'} "
        "@${hex16(_irqCounter)}"
        "/${hex16(_irqLatch)} "
        "prg: $prgBanks "
        "\n";
  }
}
