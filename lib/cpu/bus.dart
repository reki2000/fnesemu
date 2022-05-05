// Dart imports:
import 'dart:developer';

// Project imports:
import 'apu.dart';
import 'cpu.dart';
import 'mapper.dart';
import 'ppu.dart';

class Bus {
  final Cpu cpu;
  final Ppu ppu;
  final Apu apu;

  Bus(this.cpu, this.ppu, this.apu) {
    cpu.bus = this;
    ppu.bus = this;
    apu.bus = this;
  }

  final vram = List<int>.filled(0x2000, 0, growable: false);
  final charROM = List<int>.filled(0x2000, 0, growable: true);

  int mirrorMask = 0x17ff;
  set mirrorVertical(bool vertical) {
    // mirrorVertical:   0x2000 = 0x2800, 0x2400 = 0x2c00, mask 0x37ff
    // mirrorHorizontal: 0x2000 = 0x2400, 0x2800 = 0x2c00, mask 0x3bff
    mirrorMask = vertical ? 0x17ff : 0x1bff;
  }

  set rom(List<int> rom) {
    if (rom.length != 0x2000) {
      log("invalid char rom size!");
    } else {
      charROM.replaceRange(0, 0x2000, rom);
    }
  }

  int readVram(int addr) {
    if (addr < 0x2000) {
      return mapper.readVram(addr);
    } else if (addr < 0x3000) {
      return vram[addr & mirrorMask];
    }
    return vram[addr & 0x1fff];
  }

  void writeVram(int addr, int val) {
    if (addr < 0x2000) {
      return mapper.writeVram(addr, val);
    }
    if (addr < 0x3000) {
      vram[addr & mirrorMask] = val;
    }
    vram[addr & 0x1fff] = val;
  }

  final List<int> ram = List.filled(0x800, 0, growable: false);

  Mapper mapper = Mapper0();

  int read(int addr) {
    if (addr < 0x800) {
      return ram[addr];
    } else if (0x2000 <= addr && addr <= 0x2007 ||
        addr == 0x4014 ||
        addr == 0x4016 ||
        addr == 0x4017) {
      return ppu.read(addr);
    } else if (0x4000 <= addr && addr <= 0x401f) {
      return apu.read(addr);
    } else {
      return mapper.read(addr);
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
    } else if ((0x4000 <= addr && addr <= 0x4013) ||
        addr == 0x4015 ||
        addr == 0x4017) {
      apu.write(addr, data);
    } else {
      mapper.write(addr, data);
    }
  }

  void onNMI() => cpu.onNMI();

  void onReset() => cpu.reset();

  void holdIRQ() => cpu.holdIRQ();
  void releaseIRQ() => cpu.releaseIRQ();
}
