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
    if (0x8000 < addr && addr < 0xc000) {
      return _programRoms[0][addr - 0x8000];
    } else if (0xc000 <= addr && addr < 0x10000) {
      return _programRoms[_highMemBank][addr - 0xc000];
    }

    return 0xff;
  }

  @override
  int readVram(int addr) {
    if (0x0000 < addr && addr < 0x2000) {
      return _charRoms[0][addr];
    }
    return 0xff;
  }
}

class Mapper3 extends Mapper {
  static final _emptyBank = Uint8List(1024 * 8);

  Uint8List _charBank = _emptyBank;
  int _highMemBank = 0;

  @override
  void init() {
    if (_programRoms.length > 1) {
      _highMemBank = 1;
    }
  }

  @override
  int read(int addr) {
    if (0x8000 < addr && addr < 0xc000) {
      return _programRoms[1][addr - 0x8000];
    } else if (0xc000 <= addr && addr < 0x10000) {
      return _programRoms[_highMemBank][addr - 0xc000];
    }

    return 0xff;
  }

  @override
  void write(int addr, int data) {
    if (0x8000 < addr && addr < 0x10000) {
      if (data < _charRoms.length) {
        _charBank = _charRoms[data];
      } else {
        _charBank = _emptyBank;
      }
    }
  }

  @override
  int readVram(int addr) {
    if (0x0000 <= addr && addr < 0x2000) {
      _charBank[addr];
    }
    return 0xff;
  }
}
