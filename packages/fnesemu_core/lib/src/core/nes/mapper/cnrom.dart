import 'dart:typed_data';

import '../../../util/int.dart';
import '../../../util/state.dart';
import 'nrom.dart';

// https://www.nesdev.org/wiki/INES_Mapper_003
class MapperCNROM extends MapperNROM {
  late Uint8List _charBank;

  @override
  void init() {
    super.init();
    _charBank = chrRoms[0];
  }

  @override
  void saveMapperState(StateWriter w) {
    super.saveMapperState(w);
    w.section('cnrom');
    w.int32(chrRoms.indexWhere((bank) => identical(bank, _charBank)));
  }

  @override
  void loadMapperState(StateReader s) {
    super.loadMapperState(s);
    s.section('cnrom');
    final bank = s.int32();
    if (bank < 0 || bank >= chrRoms.length) {
      throw const StateMismatch('cnrom chr bank');
    }
    _charBank = chrRoms[bank];
  }

  @override
  void write(int addr, int data) {
    if (addr & 0x8000 == 0x8000) {
      _charBank = chrRoms[data.mask2 % chrRoms.length];
    }
  }

  @override
  int readVram(int addr) {
    return _charBank[addr.mask13];
  }
}
