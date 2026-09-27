import 'package:fnesemu/util/int.dart';
// Dart imports:

// Dart imports:
import 'dart:developer';
import 'dart:typed_data';

// Project imports:
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

  Mapper mapper = Mapper.of(0)..setRom(Uint8List(0x4000), Uint8List(0x4000));

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

    log("invalid vram addr ${addr.x4}");
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

    log("invalid vram addr ${addr.x4}");
  }

  final List<int> ram = List.filled(0x800, 0);

  int read(int addr) {
    if (addr < 0x2000) {
      return ram[addr & 0x7ff];
    } else if (addr < 0x4000) {
      return ppu.read(0x2000 | (addr & 0x07));
    } else if (addr == 0x4014) {
      return ppu.read(addr);
    } else if (addr == 0x4016 || addr == 0x4017) {
      return joypad.read(addr);
    } else if (addr <= 0x401f) {
      return apu.read(addr);
    } else if (addr >= 0x6000 || mapper.hasExpansionArea) {
      return mapper.read(addr);
    } else {
      return 0xff;
    }
  }

  void write(int addr, int data) {
    if (addr < 0x2000) {
      ram[addr & 0x7ff] = data & 0xff;
    } else if (addr < 0x4000) {
      ppu.write(0x2000 | (addr & 0x07), data);
    } else if (0x4014 == addr) {
      final src = data.shl8;
      ppu.onDMA(List.generate(256, (i) => read(src + i)));
      cpu.cycle += 514;
    } else if (addr == 0x4016) {
      joypad.write(addr, data);
    } else if ((0x4000 <= addr && addr <= 0x4013) ||
        addr == 0x4015 ||
        addr == 0x4017) {
      apu.write(addr, data);
    } else if (addr >= 0x6000 || (addr >= 0x4020 && mapper.hasExpansionArea)) {
      mapper.write(addr, data);
    }
  }

  void onNmi() => cpu.onNmi();

  void onReset() {
    mapper.init();
    ppu.reset();
    apu.reset();
    cpu.releaseIrq(IrqSource.all);
    cpu.reset();
  }

  void holdIrq([int source = IrqSource.mapper]) => cpu.holdIrq(source);
  void releaseIrq([int source = IrqSource.mapper]) => cpu.releaseIrq(source);
}
