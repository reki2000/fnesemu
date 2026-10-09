import 'dart:typed_data';

import 'package:fnesemu_core/util/int.dart';

/*
 * 128kB: bank 0x00-0x0f (0x10 * 0x2000 = 0x20000 = 128kB)
 * 256kB: bank 0x00-0x1f (0x20 * 0x2000 = 0x40000 = 256kB)
 * 384kB: bank 0x00-0x3f (0x30-0x3f is mirrored to 0x00-0x0f)
 * 512kB: bank 0x00-0x3f (0x40 * 0x2000 = 0x80000 = 512kB)
 * sf2: each 512kB = 8kB x 64banks(0x40) is mapped to bank 0x40-0x7f
 */
class Rom {
  final List<Uint8List> banks;

  // constructor to set rom data
  Rom(this.banks) {
    _updateMap();
  }

  int _upperBankOffset = 0;

  int get upperBankOffset => _upperBankOffset;

  set upperBankOffset(int value) {
    _upperBankOffset = value;
    _updateMap();
  }

  // the bank mapped at each of the 0x80 cpu banks, resolved by _readBank.
  // null where no bank is mapped (read by _readBank itself).
  final _map = List<Uint8List?>.filled(0x80, null);

  void _updateMap() {
    for (int bank = 0; bank < 0x80; bank++) {
      _map[bank] = _bankOf(bank);
    }
  }

  Uint8List? _bankOf(int bank) {
    if (bank >= banks.length) {
      return switch (banks.length) {
        0x30 => banks[bank & 0x0f | 0x20], // 368kB
        0x20 => banks[bank & 0x1f], // 256kB
        _ => null,
      };
    } else if (bank >= 0x40) {
      final i = _upperBankOffset + bank;
      return i < banks.length ? banks[i] : null;
    }
    return banks[bank];
  }

  @pragma('vm:prefer-inline')
  int read(int addr) {
    final b = _map[(addr >> 13) & 0x7f];
    return b != null && addr < 0x100000 ? b[addr & 0x1fff] : _readBank(addr);
  }

  int _readBank(int addr) {
    final bank = addr.shr13;
    final offset = addr & 0x1fff;

    if (bank >= banks.length) {
      return switch (banks.length) {
        0x30 => banks[bank & 0x0f | 0x20][offset], // 368kB
        0x20 => banks[bank & 0x1f][offset], // 256kB
        _ => 0xff,
      };
    } else if (bank >= 0x40) {
      return banks[_upperBankOffset + bank][offset];
    }

    return banks[bank][offset];
  }

  void write(int addr, int data) {
    // SF2 mapper: each 512kB = 8kB x 64banks(0x40) is mapped to bank 0x40-0x7f
    if (0x1ff0 <= addr && addr <= 0x1fff) {
      upperBankOffset = (addr & 0x0f).shl6;
    }
  }

  String dump() => "rom: ";
}
