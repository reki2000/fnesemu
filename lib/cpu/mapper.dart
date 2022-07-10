// Dart imports:
import 'dart:typed_data';

class Mapper {
  int read(int addr) {
    return 0xff;
  }

  void write(int addr, int data) {}

  int readVram(int addr) {
    return 0xff;
  }

  void writeVram(int add, int data) {}

  late final List<Uint8List> _programRoms;
  late final List<Uint8List> _charRoms;

  void loadProgramRom(List<Uint8List> roms) {
    _programRoms = roms;
  }

  void loadCharRom(List<Uint8List> roms) {
    _charRoms = roms;
  }

  void init() {}
}

class Mapper0 extends Mapper {
  int _highMemBank = 0;

  @override
  void init() {
    if (_programRoms.length > 1) {
      _highMemBank = 1;
    }
  }

  @override
  int read(int addr) {
    final bank = addr & 0xc000;
    final offset = addr & 0x3fff;
    if (bank == 0x8000) {
      return _programRoms[0][offset];
    } else if (bank == 0xc000) {
      return _programRoms[_highMemBank][offset];
    }

    return 0xff;
  }

  @override
  int readVram(int addr) {
    return _charRoms[0][addr & 0x1fff];
  }
}

class Mapper3 extends Mapper0 {
  static final _emptyBank = Uint8List(1024 * 8);
  Uint8List _charBank = _emptyBank;

  @override
  void write(int addr, int data) {
    if (addr & 0x8000 == 0x8000) {
      _charBank = _charRoms[data & 0x03];
    }
  }

  @override
  int readVram(int addr) {
    return _charBank[addr & 0x1fff];
  }
}
