// Dart imports:
import 'dart:typed_data';

class Rom {
  final List<Uint8List> banks;

  // constructor to set rom data
  Rom(List<Uint8List> b) : banks = b;

  int read(int addr) {
    final bank = addr >> 13;
    final offset = addr & 0x1fff;

    if (bank >= banks.length) {
      return 0xff;
    }

    return banks[bank][offset];
  }

  void write(int addr, int data) {}

  String dump() => "rom: ";
}
