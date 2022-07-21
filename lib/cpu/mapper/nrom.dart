// Project imports:
import 'mapper.dart';

// https://www.nesdev.org/wiki/NROM
class MapperNROM extends Mapper {
  int _highMemBank = 0;

  @override
  void init() {
    if (programRoms.length > 1) {
      _highMemBank = programRoms.length - 1;
    }
  }

  @override
  int read(int addr) {
    final bank = addr & 0xc000;
    final offset = addr & 0x3fff;
    if (bank == 0x8000) {
      return programRoms[0][offset];
    } else if (bank == 0xc000) {
      return programRoms[_highMemBank][offset];
    }

    return 0xff;
  }

  @override
  int readVram(int addr) {
    return charRoms[0][addr & 0x1fff];
  }
}
