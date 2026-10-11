import 'dart:typed_data';

import '../../../util/int.dart';
import '../../cdrom.dart';
import '../../components/m68k/bus.dart';
import '../../components/m68k/cpu.dart';
import '../../sram.dart';
import 'cdc.dart';
import 'cdd.dart';
import 'graphics.dart';
import 'pcm.dart';

/// MD CD-ROM in BIOS boot mode (the cartridge slot is unused).
class MdCdrom {
  static const subClockHz = 12500000;
  final bios = Uint8List(0x20000);
  final programRam = Uint8List(0x80000);
  final wordRam = Uint8List(0x40000);
  final backupRam = Uint8List(0x2000);
  final registers = Uint8List(0x100);
  final pcm = CdPcm();
  late final CdCdc cdc;
  late final CdDrive drive;
  late final CdGraphics graphics;
  late final CdSubBus bus;
  late final M68 cpu;
  Sram? _sram;
  bool _resetReleased = false, _busRequested = true;
  int _memoryMode = 1, _bank = 0, _writeProtect = 0;
  int _cycles = 0, _drivePhase = 0, _timerPhase = 0, _stopwatchBase = 0;
  int _irqMask = 0;
  int hintVector = 0xffff;
  bool get running => _resetReleased && !_busRequested;
  bool get oneMegabit => _memoryMode.bit2;
  bool get mainOwnsWordRam => _memoryMode.bit0;

  MdCdrom(Uint8List body) {
    if (body.length != bios.length) {
      throw ArgumentError('MD CD-ROM BIOS must be exactly 128 KiB');
    }
    bios.setAll(0, body);
    bus = CdSubBus(this);
    cpu = M68(bus);
    cdc = CdCdc(() => interrupt(5), _dmaWrite);
    drive = CdDrive(cdc.decode, () => interrupt(4));
    graphics = CdGraphics(wordRam, registers, () => interrupt(1));
    reset();
  }

  void setDisc(CdromDrive disc) => drive.mount(disc);
  void setSram(Sram sram) {
    _sram = sram;
    sram.init("md_cdrom_bram", backupRam);
    if (sram.data.length == backupRam.length) backupRam.setAll(0, sram.data);
  }

  void reset() {
    _resetReleased = false;
    _busRequested = true;
    _memoryMode = 1;
    _bank = _writeProtect =
        _cycles = _drivePhase = _timerPhase = _stopwatchBase = _irqMask = 0;
    hintVector = 0xffff;
    registers.fillRange(0, registers.length, 0);
    cdc.reset();
    drive.reset();
    pcm.reset();
    graphics.reset();
    cpu.reset();
  }

  void interrupt(int level) {
    if ((_irqMask & (1 << level)) != 0) cpu.interrupt(level);
  }

  /// Advance against an absolute main-CPU time, retaining fractional ratios.
  bool advance(int mainCycles, int mainClockHz, {bool step = false}) {
    final target = mainCycles * subClockHz ~/ mainClockHz;
    final elapsed = target - _cycles;
    if (elapsed <= 0) return true;
    _cycles = target;
    _drivePhase += elapsed * 75;
    while (_drivePhase >= subClockHz) {
      _drivePhase -= subClockHz;
      drive.tick();
    }
    final timer = registers[0x31];
    if (timer != 0) {
      _timerPhase += elapsed;
      while (_timerPhase >= timer * 384) {
        _timerPhase -= timer * 384;
        interrupt(3);
      }
    }
    cdc.tick(elapsed);
    graphics.tick(elapsed);
    if (!running) {
      cpu.clocks = target;
      return true;
    }
    while (cpu.clocks <= target) {
      if (!cpu.exec()) return false;
      if (step) break;
    }
    return true;
  }

  bool mapsMain(int address) =>
      address < 0x40000 ||
      (address >= 0x200000 && address < 0x240000) ||
      (address >= 0xa12000 && address < 0xa12100);

  int readMain8(int address) {
    address &= 0xffffff;
    if (address < 0x20000) {
      if (address == 0x72) return hintVector.shr8;
      if (address == 0x73) return hintVector.mask8;
      return bios[address];
    }
    if (address < 0x40000) {
      return _busRequested || !_resetReleased
          ? programRam[_bank.shl17 | (address & 0x1ffff)]
          : 0xff;
    }
    if (address >= 0x200000 && address < 0x240000) {
      final offset = _wordOffset(true, address - 0x200000);
      return offset == null ? 0xff : wordRam[offset];
    }
    return _readRegister(address.mask8, true);
  }

  int readMain16(int address) {
    if ((address & 0xfffffe) == 0xa12008) return cdc.readHost(2);
    return readMain8(address).shl8 | readMain8(address + 1);
  }

  void writeMain8(int address, int data) {
    data &= 0xff;
    if (address >= 0x20000 && address < 0x40000) {
      if (_busRequested || !_resetReleased) {
        programRam[_bank.shl17 | (address & 0x1ffff)] = data;
      }
    } else if (address >= 0x200000 && address < 0x240000) {
      final offset = _wordOffset(true, address - 0x200000);
      if (offset != null) wordRam[offset] = data;
    } else if (address >= 0xa12000 && address < 0xa12100) {
      _writeRegister(address.mask8, data, true);
    }
  }

  int? _wordOffset(bool main, int offset) {
    if (!oneMegabit) {
      if (main != mainOwnsWordRam) return null;
      return offset & 0x3ffff;
    }
    if (main && offset >= 0x20000) {
      // The cell window presents five bitmap regions as column-major tiles:
      // 512x256, 512x128, 512x64 and two 512x32 pixel images.
      final cellOffset = offset & 0x1ffff;
      final (base, verticalCells) = switch (cellOffset) {
        < 0x10000 => (0, 32),
        < 0x18000 => (0x10000, 16),
        < 0x1c000 => (0x18000, 8),
        < 0x1e000 => (0x1c000, 4),
        _ => (0x1e000, 4),
      };
      final local = cellOffset - base;
      final cell = local.shr5;
      final x = (cell ~/ verticalCells) * 4 + local.mask2;
      final y = (cell % verticalCells) * 8 + local.shr2.mask3;
      offset = base + y * 256 + x;
    }
    // 1M banks are interleaved at word granularity in physical 2M RAM.
    final bank = (main ? _memoryMode : ~_memoryMode).mask1;
    return (offset & 0x1fffe).shl1 | bank.shl1 | offset.mask1;
  }

  int readSub8(int address) {
    address &= 0xffffff;
    if (address < 0x80000) return programRam[address];
    if (address >= 0x80000 && address < 0xe0000) {
      if (oneMegabit && address < 0xc0000) {
        final pixel = address - 0x80000;
        final offset = _wordOffset(false, pixel.shr1)!;
        return (wordRam[offset] >> (pixel.isEven ? 4 : 0)).mask4;
      }
      final offset =
          _wordOffset(false, address - (oneMegabit ? 0xc0000 : 0x80000));
      return offset == null ? 0xff : wordRam[offset];
    }
    if (address >= 0xfe0000 && address < 0xfe4000) {
      return address.isOdd ? backupRam[address.mask14.shr1] : 0xff;
    }
    if (address >= 0xff0000 && address < 0xff4000) {
      return address.isOdd ? pcm.read(address) : 0xff;
    }
    if (address >= 0xff8000 && address < 0xff8100) {
      return _readRegister(address.mask8, false);
    }
    return 0xff;
  }

  int readSub16(int address) {
    if ((address & 0xfffffe) == 0xff8008) return cdc.readHost(3);
    return readSub8(address).shl8 | readSub8(address + 1);
  }

  void writeSub8(int address, int data) {
    address &= 0xffffff;
    data &= 0xff;
    if (address < 0x80000) {
      if (address >= _writeProtect * 512) programRam[address] = data;
    } else if (address >= 0x80000 && address < 0xe0000) {
      if (oneMegabit && address < 0xc0000) {
        final pixel = address - 0x80000;
        final offset = _wordOffset(false, pixel.shr1)!;
        final shift = pixel.isEven ? 4 : 0;
        final old = (wordRam[offset] >> shift).mask4;
        final mode = _memoryMode.shr3.mask2;
        if ((mode == 1 && old != 0) || (mode == 2 && data.mask4 == 0)) return;
        wordRam[offset] =
            (wordRam[offset] & ~(15 << shift)) | (data.mask4 << shift);
      } else {
        final offset =
            _wordOffset(false, address - (oneMegabit ? 0xc0000 : 0x80000));
        if (offset != null) wordRam[offset] = data;
      }
    } else if (address >= 0xfe0000 && address < 0xfe4000 && address.isOdd) {
      final offset = address.mask14.shr1;
      backupRam[offset] = data;
      _sram?.write8(offset, data);
    } else if (address >= 0xff0000 && address < 0xff4000 && address.isOdd) {
      pcm.write(address, data);
    } else if (address >= 0xff8000 && address < 0xff8100) {
      _writeRegister(address.mask8, data, false);
    }
  }

  int _readRegister(int offset, bool main) {
    if (main && offset >= 0x30) return 0xff;
    switch (offset) {
      case 0x58:
        return graphics.busy ? 0x80 : 0;
      case 0:
        return main ? (_irqMask.bit2 ? 0x80 : 0) : 3;
      case 1:
        return main ? (_resetReleased ? 1 : 0) | (_busRequested ? 2 : 0) : 1;
      case 2:
        return _writeProtect;
      case 3:
        return _memoryMode | (main ? _bank.shl6 : 0);
      case 4:
        return cdc.destination |
            (cdc.dataReady ? 0x40 : 0) |
            (cdc.transferEnd ? 0x80 : 0);
      case 5:
        return main ? 0 : cdc.register;
      case 6:
        return main ? hintVector.shr8 : 0;
      case 7:
        return main ? hintVector.mask8 : cdc.readRegister();
      case 0xa:
        return main ? 0 : cdc.dmaAddress.shr8;
      case 0xb:
        return main ? 0 : cdc.dmaAddress.mask8;
      case 0xc:
        return ((_cycles - _stopwatchBase) ~/ 384).mask12.shr8;
      case 0xd:
        return ((_cycles - _stopwatchBase) ~/ 384).mask8;
      case 0x32:
        return 0;
      case 0x33:
        return main ? 0 : _irqMask;
      case 0x36:
        return drive.playingAudio ? 0 : 1;
      case 0x37:
        return drive.hostClock ? 4 : 0;
    }
    if (offset >= 0x38 && offset <= 0x41) return drive.response[offset - 0x38];
    if (offset >= 0x50 && offset <= 0x57) {
      final bits = registers[0x4e].shl8 | registers[0x4f];
      int word = 0;
      final row = (offset - 0x50).shr1;
      for (int i = 0; i < 4; i++) {
        final color = (bits >> (15 - row * 4 - i)).bit0
            ? registers[0x4d].shr4
            : registers[0x4d].mask4;
        word = word.shl4 | color;
      }
      return offset.isEven ? word.shr8 : word.mask8;
    }
    return registers[offset];
  }

  void _writeRegister(int offset, int data, bool main) {
    if (main) {
      switch (offset) {
        case 0:
          if (data.bit0) interrupt(2);
        case 1:
          final release = data.bit0;
          if (release && !_resetReleased) {
            cpu.reset();
            cpu.clocks = _cycles;
          }
          _resetReleased = release;
          _busRequested = data.bit1;
        case 2:
          _writeProtect = data;
        case 3:
          _bank = data.shr6;
          if (!oneMegabit && data.bit1) {
            _memoryMode = (_memoryMode & ~1) | 2;
          }
          if (oneMegabit && !data.bit1) _memoryMode |= 2;
        case 6:
          hintVector = hintVector.mask8 | data.shl8;
        case 7:
          hintVector = (hintVector & 0xff00) | data;
        case 0xe:
          registers[offset] = data;
        case >= 0x10 && <= 0x1f:
          registers[offset] = data;
      }
      return;
    }
    switch (offset) {
      case 0:
        registers[offset] = data.mask2;
      case 1:
        if (!data.bit0) {
          cdc.reset();
          pcm.reset();
          drive.reset();
        }
      case 3:
        final previous = _memoryMode;
        _memoryMode = previous.mask2 | (data & 0x1c);
        if (oneMegabit) {
          _memoryMode = (_memoryMode & ~3) | data.mask1;
        } else if (data.bit0) {
          _memoryMode = (_memoryMode & ~2) | 1;
        }
      case 4:
        cdc.destination = data.mask3;
      case 5:
        cdc.register = data.mask4;
      case 7:
        cdc.writeRegister(data);
      case 0xa:
        cdc.dmaAddress = cdc.dmaAddress.mask8 | data.shl8;
      case 0xb:
        cdc.dmaAddress = (cdc.dmaAddress & 0xff00) | data;
      case 0xc || 0xd:
        _stopwatchBase = _cycles;
      case 0xf:
        registers[offset] = data;
      case >= 0x20 && <= 0x2f:
        registers[offset] = data;
      case 0x31:
        registers[offset] = data;
        _timerPhase = 0;
      case 0x33:
        _irqMask = data & 0x7e;
      case 0x34 || 0x35:
        registers[offset] = data;
        final fade = registers[0x34].shl8 | registers[0x35];
        drive.volume = fade.shr4.mask11.clamp(0, 1024) / 1024;
      case 0x37:
        drive.hostClock = data.bit2;
      case >= 0x42 && <= 0x4b:
        drive.command[offset - 0x42] = data.mask4;
        if (offset == 0x4b) drive.submit();
      case >= 0x4c && <= 0x67:
        registers[offset] = data;
        if (offset == 0x67 && !oneMegabit && !mainOwnsWordRam) {
          graphics.start(_memoryMode.shr3.mask2);
        }
    }
  }

  void _dmaWrite(int destination, int address, int value) {
    switch (destination) {
      case 4:
        pcm.ram[address.mask16] = value;
      case 5:
        programRam[address & 0x7ffff] = value;
      case 7:
        final offset = _wordOffset(false, address);
        if (offset != null) wordRam[offset] = value;
    }
  }

  (double, double) sample(int outputHz) {
    final (pl, pr) = pcm.sample(outputHz);
    final (cl, cr) = drive.sample(outputHz);
    return (pl + cl, pr + cr);
  }
}

class CdSubBus implements M68Bus {
  final MdCdrom cd;
  CdSubBus(this.cd);
  @override
  int read8(int addr) => cd.readSub8(addr);
  @override
  int read16(int addr) => cd.readSub16(addr);
  @override
  void write8(int addr, int data) => cd.writeSub8(addr, data);
  @override
  void write16(int addr, int data) {
    cd.writeSub8(addr, data.shr8);
    cd.writeSub8(addr + 1, data.mask8);
  }
}
