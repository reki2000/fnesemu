import 'dart:typed_data';

import '../../../util/int.dart';
import 'mapper.dart';

// https://www.nesdev.org/wiki/NROM
class MapperNROM extends Mapper {
  int _highMemBank = 0;

  // a board without CHR ROM has 8KB of CHR RAM
  Uint8List? _chrRam;

  @override
  void init() {
    if (prgRoms.length > 1) {
      _highMemBank = prgRoms.length - 1;
    }
    _chrRam = chrRoms.isEmpty ? Uint8List(8 * 1024) : null;
  }

  @override
  int read(int addr) {
    final bank = addr & 0xc000;
    final offset = addr.mask14;
    if (bank == 0x8000) {
      return prgRoms[0][offset];
    } else if (bank == 0xc000) {
      return prgRoms[_highMemBank][offset];
    }

    return 0xff;
  }

  @override
  int readVram(int addr) {
    return _chrRam?[addr.mask13] ?? chrRoms[0][addr.mask13];
  }

  @override
  void writeVram(int addr, int data) {
    _chrRam?[addr.mask13] = data.mask8;
  }
}
