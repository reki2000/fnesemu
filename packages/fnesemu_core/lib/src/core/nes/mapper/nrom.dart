import 'dart:typed_data';

import '../../../util/int.dart';
import '../../../util/state.dart';
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
  void saveMapperState(StateWriter w) {
    w.section('nrom');
    w.int32(_highMemBank);
    w.boolean(_chrRam != null);
    if (_chrRam != null) w.bytes(_chrRam!);
  }

  @override
  void loadMapperState(StateReader s) {
    s.section('nrom');
    _highMemBank = s.int32();
    if (s.boolean()) {
      final ram = _chrRam ??= Uint8List(8 * 1024);
      s.bytesInto(ram);
    } else {
      _chrRam = null;
    }
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
