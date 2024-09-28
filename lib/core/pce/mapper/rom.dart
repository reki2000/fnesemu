// Dart imports:
import 'dart:typed_data';

class Rom {
  final List<Uint8List> banks;

  // constructor to set rom data
  Rom(this.banks);

  int upperBankOffset = 0;

  int read(int addr) {
    final bank = addr >> 13;
    final offset = addr & 0x1fff;

    if (bank >= banks.length) {
      return 0xff;
    } else if (bank >= 0x40) {
      return banks[upperBankOffset + bank][offset];
    }

    return banks[bank][offset];
  }

  void write(int addr, int data) {
    // SF2 mapper: each 512kB = 8kB x 64banks(0x40) is mapped to bank 0x40-0x7f
    if (0x1ff0 <= addr && addr <= 0x1fff) {
      upperBankOffset = (addr & 0x0f) << 6;
    }
  }

  String dump() => "rom: ";
}
