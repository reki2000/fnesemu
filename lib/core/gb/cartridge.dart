import 'dart:typed_data';

import 'package:fnesemu/util/int.dart';

import '../sram.dart';

/// cartridge header
class CartridgeHeader {
  final String title;
  final int type;
  final int romSize;
  final int ramSize;
  final bool gbcOnly;

  CartridgeHeader(Uint8List rom)
      : title = String.fromCharCodes(rom
            .sublist(0x134, 0x143)
            .takeWhile((c) => c != 0)
            .map((c) => c >= 0x20 && c < 0x7f ? c : 0x3f)).trim(),
        type = rom[0x147],
        romSize = 0x8000 << rom[0x148],
        ramSize = switch (rom[0x149]) {
          1 => 0x800,
          2 => 0x2000,
          3 => 0x8000,
          4 => 0x20000,
          5 => 0x10000,
          _ => 0,
        },
        gbcOnly = rom[0x143] == 0xc0;

  bool get hasBattery => const [
        0x03, 0x06, 0x09, 0x0d, 0x0f, 0x10, 0x13, 0x1b, 0x1e, 0x22, 0xff //
      ].contains(type);

  @override
  String toString() => "title:$title type:${type.x2} "
      "rom:${romSize ~/ 1024}KB ram:${ramSize ~/ 1024}KB";
}

/// cartridge with a memory bank controller
abstract class Cartridge {
  final Uint8List rom;
  final CartridgeHeader header;

  late final int _romBankMask;

  // external RAM access (backed by a Sram when the cartridge has a battery)
  int Function(int) _ramRead = (_) => 0xff;
  void Function(int, int) _ramWrite = (_, __) {};
  int ramSize = 0;

  bool ramEnabled = false;

  Cartridge(this.rom, this.header) {
    final banks = rom.length ~/ 0x4000;
    // bank count is a power of 2 for valid images
    _romBankMask = banks <= 1 ? 0 : (1 << (banks - 1).bitLength) - 1;
  }

  factory Cartridge.empty() => _RomOnly(Uint8List(0x8000),
      CartridgeHeader(Uint8List(0x8000)..[0x149] = 0));

  /// creates a cartridge. throws when the controller type is not supported
  factory Cartridge.of(Uint8List body) {
    if (body.length < 0x150) {
      throw Exception("invalid rom size: ${body.length}");
    }

    // pad the image to at least 2 banks
    final rom = body.length < 0x8000
        ? (Uint8List(0x8000)..setRange(0, body.length, body))
        : body;
    final header = CartridgeHeader(rom);

    return switch (header.type) {
      0x00 || 0x08 || 0x09 => _RomOnly(rom, header),
      0x01 || 0x02 || 0x03 => _Mbc1(rom, header),
      0x05 || 0x06 => _Mbc2(rom, header),
      0x0f || 0x10 || 0x11 || 0x12 || 0x13 => _Mbc3(rom, header),
      0x19 || 0x1a || 0x1b || 0x1c || 0x1d || 0x1e => _Mbc5(rom, header),
      _ => throw Exception(
          "unsupported cartridge type: ${header.type.x2}"),
    };
  }

  /// size of the external RAM
  int get defaultRamSize => header.ramSize;

  /// attaches the external RAM storage
  void setRam(int size, int Function(int) read, void Function(int, int) write) {
    ramSize = size;
    _ramRead = read;
    _ramWrite = write;
  }

  @pragma('vm:prefer-inline')
  int romBank(int bank, int addr) =>
      rom[((bank & _romBankMask).shl14 | addr.mask14) % rom.length];

  int read(int addr);
  void write(int addr, int data);

  int readRam(int addr);
  void writeRam(int addr, int data);

  int ramOffset(int bank, int addr) =>
      ramSize == 0 ? 0 : (bank.shl13 | addr.mask13) % ramSize;

  int readRamBank(int bank, int addr) {
    if (!ramEnabled || ramSize == 0) {
      return 0xff;
    }
    return _ramRead(ramOffset(bank, addr));
  }

  void writeRamBank(int bank, int addr, int data) {
    if (ramEnabled && ramSize != 0) {
      _ramWrite(ramOffset(bank, addr), data);
    }
  }

  String dump();
}

class _RomOnly extends Cartridge {
  _RomOnly(super.rom, super.header) {
    ramEnabled = true;
  }

  @override
  int read(int addr) => rom[addr];

  @override
  void write(int addr, int data) {}

  @override
  int readRam(int addr) => readRamBank(0, addr);

  @override
  void writeRam(int addr, int data) => writeRamBank(0, addr, data);

  @override
  String dump() => "cart: rom only";
}

class _Mbc1 extends Cartridge {
  int _bank1 = 1;
  int _bank2 = 0;
  int _mode = 0;

  _Mbc1(super.rom, super.header);

  @override
  int read(int addr) => addr < 0x4000
      ? romBank(_mode == 0 ? 0 : _bank2.shl5, addr)
      : romBank(_bank2.shl5 | _bank1, addr);

  @override
  void write(int addr, int data) {
    switch (addr.shr13) {
      case 0:
        ramEnabled = data.mask4 == 0x0a;
      case 1:
        _bank1 = data.mask5;
        if (_bank1 == 0) {
          _bank1 = 1;
        }
      case 2:
        _bank2 = data.mask2;
      case 3:
        _mode = data.mask1;
    }
  }

  int get _ramBank => _mode == 0 ? 0 : _bank2;

  @override
  int readRam(int addr) => readRamBank(_ramBank, addr);

  @override
  void writeRam(int addr, int data) => writeRamBank(_ramBank, addr, data);

  @override
  String dump() => "cart: mbc1 bank1:${_bank1.x2} bank2:${_bank2.x2} "
      "mode:$_mode ram:${ramEnabled ? 1 : 0}";
}

class _Mbc2 extends Cartridge {
  int _bank = 1;

  _Mbc2(super.rom, super.header);

  // built-in 512 x 4bit RAM
  @override
  int get defaultRamSize => 0x200;

  @override
  int read(int addr) => addr < 0x4000 ? rom[addr] : romBank(_bank, addr);

  @override
  void write(int addr, int data) {
    if (addr >= 0x4000) {
      return;
    }
    if (!addr.bit8) {
      ramEnabled = data.mask4 == 0x0a;
    } else {
      _bank = data.mask4;
      if (_bank == 0) {
        _bank = 1;
      }
    }
  }

  @override
  int readRam(int addr) =>
      ramEnabled && ramSize != 0 ? _ramRead(addr.mask9) | 0xf0 : 0xff;

  @override
  void writeRam(int addr, int data) {
    if (ramEnabled && ramSize != 0) {
      _ramWrite(addr.mask9, data.mask4);
    }
  }

  @override
  String dump() => "cart: mbc2 bank:${_bank.x2} ram:${ramEnabled ? 1 : 0}";
}

class _Mbc3 extends Cartridge {
  int _romBank = 1;
  int _ramBank = 0; // 0-3: RAM, 8-c: clock registers
  int _latch = 0xff;

  // real time clock: seconds counted from the host clock
  int _offsetSeconds = 0;
  bool _halted = false;
  int _haltedSeconds = 0;
  bool _dayCarry = false;
  final _latched = List<int>.filled(5, 0);

  _Mbc3(super.rom, super.header);

  int get _hostSeconds => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  int get _seconds => _halted ? _haltedSeconds : _hostSeconds + _offsetSeconds;

  set _seconds(int s) {
    if (_halted) {
      _haltedSeconds = s;
    } else {
      _offsetSeconds = s - _hostSeconds;
    }
  }

  List<int> _clockRegs() {
    var s = _seconds;
    if (s >= 512 * 86400) {
      _dayCarry = true;
      s %= 512 * 86400;
      _seconds = s;
    }
    final days = s ~/ 86400;
    return [
      s % 60,
      s ~/ 60 % 60,
      s ~/ 3600 % 24,
      days.mask8,
      days.shr8.mask1 | (_halted ? 0x40 : 0) | (_dayCarry ? 0x80 : 0),
    ];
  }

  void _writeClock(int reg, int data) {
    final r = _clockRegs();
    r[reg] = data;
    final days = r[3] | r[4].mask1.shl8;
    final s = days * 86400 + r[2] * 3600 + r[1] * 60 + r[0];

    final halt = r[4].bit6;
    _dayCarry = r[4].bit7;

    if (halt && !_halted) {
      _halted = true;
      _haltedSeconds = s;
    } else if (!halt && _halted) {
      _halted = false;
      _offsetSeconds = s - _hostSeconds;
    } else {
      _seconds = s;
    }
  }

  @override
  int read(int addr) => addr < 0x4000 ? rom[addr] : romBank(_romBank, addr);

  @override
  void write(int addr, int data) {
    switch (addr.shr13) {
      case 0:
        ramEnabled = data.mask4 == 0x0a;
      case 1:
        _romBank = data.mask7;
        if (_romBank == 0) {
          _romBank = 1;
        }
      case 2:
        _ramBank = data.mask4;
      case 3:
        if (_latch == 0 && data == 1) {
          _latched.setAll(0, _clockRegs());
        }
        _latch = data;
    }
  }

  @override
  int readRam(int addr) {
    if (_ramBank >= 0x08 && _ramBank <= 0x0c) {
      return ramEnabled ? _latched[_ramBank - 8] : 0xff;
    }
    return readRamBank(_ramBank.mask2, addr);
  }

  @override
  void writeRam(int addr, int data) {
    if (_ramBank >= 0x08 && _ramBank <= 0x0c) {
      if (ramEnabled) {
        _writeClock(_ramBank - 8, data);
      }
      return;
    }
    writeRamBank(_ramBank.mask2, addr, data);
  }

  @override
  String dump() => "cart: mbc3 rom:${_romBank.x2} ram:${_ramBank.x2} "
      "enabled:${ramEnabled ? 1 : 0}";
}

class _Mbc5 extends Cartridge {
  int _romBank = 1;
  int _ramBank = 0;

  _Mbc5(super.rom, super.header);

  @override
  int read(int addr) => addr < 0x4000 ? rom[addr] : romBank(_romBank, addr);

  @override
  void write(int addr, int data) {
    switch (addr.shr12) {
      case 0 || 1:
        ramEnabled = data.mask4 == 0x0a;
      case 2:
        _romBank = (_romBank & 0x100) | data;
      case 3:
        _romBank = _romBank.mask8 | data.mask1.shl8;
      case 4 || 5:
        _ramBank = data.mask4;
    }
  }

  @override
  int readRam(int addr) => readRamBank(_ramBank, addr);

  @override
  void writeRam(int addr, int data) => writeRamBank(_ramBank, addr, data);

  @override
  String dump() => "cart: mbc5 rom:${_romBank.x4} ram:${_ramBank.x2} "
      "enabled:${ramEnabled ? 1 : 0}";
}

/// helper to attach RAM to the cartridge
extension CartridgeRam on Cartridge {
  void attachRam(Sram? sram, String id) {
    final size = defaultRamSize;
    if (size == 0) {
      setRam(0, (_) => 0xff, (_, __) {});
      return;
    }

    if (sram != null && header.hasBattery) {
      sram.init(id, Uint8List(size));
      setRam(size, sram.read8, sram.write8);
      return;
    }

    final ram = Uint8List(size);
    setRam(size, (a) => ram[a], (a, d) => ram[a] = d);
  }
}
