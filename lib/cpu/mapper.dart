// Dart imports:
import 'dart:developer';
import 'dart:typed_data';

import 'package:fnesemu/cpu/util.dart';

class Mapper {
  int read(int addr) {
    return 0xff;
  }

  void write(int addr, int data) {}

  int readVram(int addr) {
    return 0xff;
  }

  void writeVram(int addr, int data) {}

  late final List<Uint8List> _programRoms;
  late final List<Uint8List> _charRoms;

  void loadProgramRom(List<Uint8List> roms) {
    _programRoms = roms;
  }

  void loadCharRom(List<Uint8List> roms) {
    _charRoms = roms;
  }

  void init() {}

  void onScanLine(void Function() irqCallback) {}
  void onVblank() {}
}

class Mapper0 extends Mapper {
  int _highMemBank = 0;

  @override
  void init() {
    if (_programRoms.length > 1) {
      _highMemBank = _programRoms.length - 1;
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

class Mapper2 extends Mapper0 {
  static final _emptyBank = Uint8List(1024 * 16);
  Uint8List _progBank = _emptyBank;
  final Uint8List _vram = Uint8List(1024 * 8);

  @override
  void write(int addr, int data) {
    if (addr & 0x8000 == 0x8000) {
      _progBank = _programRoms[data & 0x0f];
    }
  }

  @override
  int read(int addr) {
    final bank = addr & 0xc000;
    final offset = addr & 0x3fff;
    if (bank == 0x8000) {
      return _progBank[offset];
    } else if (bank == 0xc000) {
      return _programRoms[_highMemBank][offset];
    }

    return 0xff;
  }

  @override
  int readVram(int addr) {
    return _vram[addr & 0x1fff];
  }

  @override
  void writeVram(int addr, int data) {
    _vram[addr & 0x1fff] = data & 0xff;
  }
}

// MMC : Mapper4
class Mapper4 extends Mapper {
  int _r = 0;

  int _irqLatch = 0;
  int _irqCounter = 0;
  bool _irqEnabled = false;

  final Uint8List _ram = Uint8List.fromList(List.filled(8 * 1024, 0));
  bool _ramEnabled = false;
  bool _ramWriteEnabled = false;

  final List<Uint8List> _chrRom1K = List.empty(growable: true);
  final List<Uint8List> _progRom8K = List.empty(growable: true);

  final List<int> _chrBank1K = List.filled(4, 0);
  final List<int> _chrBank2K = List.filled(4, 0);

  // ppu 2 x 4k banks (0000-0fff, 1000-1fff)
  //  each bank has 4 x 1k banks (000-3ff, 400-7ff, 800-bff, c00-fff)
  final List<List<int>> _chrBank = [[], []];

  final List<int> _progBank0 = [0]; // for 8000-9fff or c000-dfff
  final List<int> _progBank2ndLast = [0]; // for 8000-9fff or c000-dfff
  final List<int> _progBankA0 = [0]; // for a000-bfff

  // cpu 4 x 8k banks (8000-9fff, a000-bfff, c000-dfff, e000-ffff)
  final List<List<int>> _progBank = List.filled(4, []);

  @override
  void init() {
    for (final char8k in _charRoms) {
      for (int i = 0; i < 8 * 1024; i += 1024) {
        _chrRom1K.add(char8k.sublist(i, i + 1024));
      }
    }
    _chrBank[0] = _chrBank1K;
    _chrBank[1] = _chrBank2K;

    for (final prog16k in _programRoms) {
      for (int i = 0; i < 16 * 1024; i += 8 * 1024) {
        _progRom8K.add(prog16k.sublist(i, i + 8 * 1024));
      }
    }

    _progBank2ndLast[0] = _progRom8K.length - 2;
    _progBank[0] = _progBank0; // 0x8000-0x9fff
    _progBank[1] = _progBankA0; // 0xa000-0xbfff
    _progBank[2] = _progBank2ndLast; // 0xc000-0xdfff
    _progBank[3] = [_progRom8K.length - 1]; // 0xe000-0xffff
  }

  @override
  void write(int addr, int data) {
    final reg = addr & 0xe000;
    final isOdd = addr & 1 == 1;
    if (reg == 0x6000 && _ramEnabled && _ramWriteEnabled) {
      _ram[reg & 0x1fff] = data;
    } else if (reg == 0x8000) {
      if (isOdd) {
        switch (_r) {
          case 0:
            _chrBank2K[0] = data & 0xfe;
            _chrBank2K[1] = (data & 0xfe) + 1;
            break;
          case 1:
            _chrBank2K[2] = data & 0xfe;
            _chrBank2K[3] = (data & 0xfe) + 1;
            break;
          case 2:
          case 3:
          case 4:
          case 5:
            _chrBank1K[_r - 2] = data;
            break;
          case 6:
            _progBank0[0] = data & 0x3f;
            break;
          case 7:
            _progBankA0[0] = data & 0x3f;
            break;
        }
      } else {
        final chrA12Inversion = data & 0x80 != 0;
        if (chrA12Inversion) {
          _chrBank[0] = _chrBank1K;
          _chrBank[1] = _chrBank2K;
        } else {
          _chrBank[0] = _chrBank2K;
          _chrBank[1] = _chrBank1K;
        }

        final progRomBankMode0 = data & 0x40 == 0;
        if (progRomBankMode0) {
          _progBank[0] = _progBank0;
          _progBank[2] = _progBank2ndLast;
        } else {
          _progBank[0] = _progBank2ndLast;
          _progBank[2] = _progBank0;
        }
        _r = data & 0x07;
      }
    } else if (reg == 0xa000) {
      if (isOdd) {
        _ramEnabled = (data & 0x80) != 0;
        _ramWriteEnabled = (data & 0x40) == 0;
      } else {}
    } else if (reg == 0xc000) {
      if (isOdd) {
        _irqCounter = 0;
      } else {
        _irqCounter = 0;
        _irqLatch = data;
      }
    } else if (reg == 0xe000) {
      _irqEnabled = isOdd;
    }
  }

  @override
  int read(int addr) {
    final bank = (addr >> 13) & 0x03;
    final offset = addr & 0x1fff;

    if ((addr & 0xe000) == 0x6000) {
      return _ramEnabled ? _ram[offset] : 0xff;
    }

    return _progRom8K[_progBank[bank][0]][offset];
  }

  @override
  int readVram(int addr) {
    final bank = addr >> 10;
    final offset = addr & 0x03ff;

    return _chrRom1K[_chrBank[bank >> 2][bank & 0x03]][offset];
  }

  @override
  void onScanLine(void Function() irqCallback) {
    if (_irqCounter > 0) {
      _irqCounter--;
      if (_irqCounter == 0) {
        if (_irqEnabled) {
          log("irq");
          irqCallback();
        }
      }
    }
  }

  @override
  void onVblank() {
    if (_irqCounter == 0) {
      _irqCounter = _irqLatch;
    }
  }
}
