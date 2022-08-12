// Dart imports:

// Project imports:
import '../mapper/mapper.dart';
import 'apu.dart';
import 'cpu.dart';
import 'pad.dart';
import 'ppu.dart';

class Bus {
  late final Cpu cpu;
  late final Ppu ppu;
  late final Apu apu;

  final joypad = Joypad();

  final vram = List<int>.filled(0x2000, 0);

  int mirrorMask = 0x17ff;
  void mirrorVertical(bool vertical) {
    // mirrorVertical:   0x2000 = 0x2800, 0x2400 = 0x2c00, mask 0x37ff
    // mirrorHorizontal: 0x2000 = 0x2400, 0x2800 = 0x2c00, mask 0x3bff
    mirrorMask = vertical ? 0x17ff : 0x1bff;
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
    cpu.releaseIrq();
    cpu.reset();
  }

  void holdIrq() => cpu.holdIrq();
  void releaseIrq() => cpu.releaseIrq();
}
