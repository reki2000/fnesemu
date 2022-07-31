// Project imports:
import 'mapper.dart';

// https://www.nesdev.org/wiki/NROM
class MapperNROM extends Mapper {
  int _highMemBank = 0;

  @override
  void init() {
    if (prgRoms.length > 1) {
      _highMemBank = prgRoms.length - 1;
    }
  }

  @override
  int read(int addr) {
    final bank = addr & 0xc000;
    final offset = addr & 0x3fff;
    if (bank == 0x8000) {
      return prgRoms[0][offset];
    } else if (bank == 0xc000) {
      return prgRoms[_highMemBank][offset];
    }

    return 0xff;
  }

  @override
  int readVram(int addr) {
    return chrRoms[0][addr & 0x1fff];
  }
}
