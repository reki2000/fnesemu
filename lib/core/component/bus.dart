// Dart imports:

// Dart imports:
import 'dart:developer';

// Project imports:
import '../../util.dart';
import '../mapper/mapper.dart';
import '../mapper/mirror.dart';
import 'apu.dart';
import 'cpu.dart';
import 'pad.dart';
import 'ppu.dart';

class Bus {
  late final Cpu cpu;
  late final Ppu ppu;
  late final Apu apu;

  final joypad = Joypad();

  final vram = List<int>.filled(1024 * 2, 0);

  Mirror _mirror = Mirror.horizontal;

  void mirror(Mirror mirror) {
    _mirror = mirror;
  }

  int readVram(int addr) {
    if (addr < 0x2000 || _mirror.isExternal) {
      return mapper.readVram(addr);
    }

    if (addr < 0x3f00) {
      return vram[_mirror.mask(addr & 0x0fff)];
    }

    log("invalid vram addr ${hex16(addr)}");
    return 0xff;
  }

  void writeVram(int addr, int val) {
    if (addr < 0x2000 || _mirror.isExternal) {
      return mapper.writeVram(addr, val);
    }

    if (addr < 0x3f00) {
      vram[_mirror.mask(addr & 0x0fff)] = val;
      return;
    }

    log("invalid vram addr ${hex16(addr)}");
  }

  final List<int> ram = List.filled(0x800, 0);

  Mapper mapper = Mapper();

  int read(int addr) {
    if (addr < 0x800) {
      return ram[addr];
    } else if (0x2000 <= addr && addr <= 0x2007 || addr == 0x4014) {
      return ppu.read(addr);
    } else if (addr == 0x4016 || addr == 0x4017) {
      return joypad.read(addr);
    } else if (0x4000 <= addr && addr <= 0x401f) {
      return apu.read(addr);
    } else if (addr >= 0x6000) {
      return mapper.read(addr);
    } else {
      return 0xff;
    }
  }

  void write(int addr, int data) {
    if (addr < 0x800) {
      ram[addr] = data & 0xff;
    } else if (0x2000 <= addr && addr <= 0x200f) {
      ppu.write(addr, data);
    } else if (0x4014 == addr) {
      final src = data << 8;
      ppu.onDMA(ram.sublist(src, src + 256));
      cpu.cycle += 514;
    } else if (addr == 0x4016) {
      joypad.write(addr, data);
    } else if ((0x4000 <= addr && addr <= 0x4013) ||
        addr == 0x4015 ||
        addr == 0x4017) {
      apu.write(addr, data);
    } else if (addr >= 0x6000) {
      mapper.write(addr, data);
    }
  }

  void onNmi() => cpu.onNmi();

  void onReset() {
    mapper.init();
    ppu.reset();
    apu.reset();
    cpu.releaseIrq();
    cpu.reset();
  }

  void holdIrq() => cpu.holdIrq();
  void releaseIrq() => cpu.releaseIrq();
}
