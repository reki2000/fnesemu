// Dart imports:
import 'dart:typed_data';

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
  Rom(this.banks);

  int upperBankOffset = 0;

  int read(int addr) {
    final bank = addr >> 13;
    final offset = addr & 0x1fff;

    if (bank >= banks.length) {
      return switch (banks.length) {
        0x30 => banks[bank & 0x0f | 0x20][offset], // 368kB  momotaro dentetsu
        0x20 => banks[bank & 0x1f][offset], // 256kB
        _ => 0xff,
      };
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
