// Dart imports:

// Project imports:
import '../mapper/mapper.dart';
import 'apu.dart';
import 'cpu.dart';
import 'pad.dart';
import 'ppu.dart';

class Mirror {
  //                0x2000/0x2400 0x2800/0x2c00
  // Vertical       0x2000 0x2400 0x2000 0x2400  A/A B/B mask: 0x7ff set: 0
  // Horizontal     0x2000 0x2000 0x2400 0x2400  A/B A/B mask: 0xbff set: 0
  // OneScreenLow   0x2000 0x2000 0x2000 0x2000  A/A A/A mask: 0x3ff set: 0
  // OneScreenHigh  0x2400 0x2400 0x2400 0x2400  B/B B/B mask: 0x3ff set: 0x400
  final int _mask;
  final int _on;
  Mirror({required int mask, required int on})
      : _mask = mask,
        _on = on;

  static final vertical = Mirror(mask: 0x17ff, on: 0);
  static final horizontal = Mirror(mask: 0x1bff, on: 0);
  static final oneScreenLow = Mirror(mask: 0x13ff, on: 0);
  static final oneScreenHigh = Mirror(mask: 0x13ff, on: 0x400);

  int mask(int addr) => addr & _mask | _on;
}

class Bus {
  late final Cpu cpu;
  late final Ppu ppu;
  late final Apu apu;

  final joypad = Joypad();

  final vram = List<int>.filled(0x2000, 0);

  Mirror _mirror = Mirror.horizontal;
  void mirror(Mirror mirror) {
    _mirror = mirror;
  }

  int readVram(int addr) {
    if (addr < 0x2000) {
      return mapper.readVram(addr);
    } else if (addr < 0x3000) {
      return vram[_mirror.mask(addr)];
    }
    return vram[addr & 0x1fff];
  }

  void writeVram(int addr, int val) {
    if (addr < 0x2000) {
      return mapper.writeVram(addr, val);
    }
    if (addr < 0x3000) {
      vram[_mirror.mask(addr)] = val;
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
    ppu.reset();
    apu.reset();
    cpu.releaseIrq();
    cpu.reset();
  }

  void holdIrq() => cpu.holdIrq();
  void releaseIrq() => cpu.releaseIrq();
}
