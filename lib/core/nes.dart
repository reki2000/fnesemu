// Dart imports:
import 'dart:typed_data';

// Project imports:
import '../util.dart';
import 'component/apu.dart';
import 'component/apu_debug.dart';
import 'component/bus.dart';
import 'component/chr_rom_debug.dart';
import 'component/cpu.dart';
import 'component/cpu_debug.dart';
import 'component/cpu_disasm.dart';
import 'component/ppu.dart';
import 'component/ppu_debug.dart';
import 'mapper/mapper.dart';
import 'pad_button.dart';
import 'rom/nes_file.dart';

export 'pad_button.dart';

/// main class for NES emulation. integrates cpu/ppu/apu/bus/pad control
class Nes {
  late final Ppu ppu;
  late final Apu apu;
  late final Cpu cpu;
  late final Bus bus;

  static const cpuClock = 1789773;
  static const apuClock = cpuClock ~/ 2;

  static const cpuCyclesInScanline = 114;
  static const scanlinesInFrame = 262;

  Nes() {
    bus = Bus();
    cpu = Cpu(bus);
    ppu = Ppu(bus);
    apu = Apu(bus);
  }

  int nextPpuCycle = 0;
  int nextApuCycle = 0;

  /// exec 1 cpu instruction and render PPU / APU is enough cycles passed
  /// returns current CPU cycle and bool - false when unimplemented instruction is found
  Pair<int, bool> exec() {
    final cpuOk = cpu.exec();
    if (!cpuOk) {
      return Pair(cpu.cycle, false);
    }

    if (cpu.cycle >= nextPpuCycle) {
      ppu.exec();
      nextPpuCycle += cpuCyclesInScanline;
    }
    if (cpu.cycle >= nextApuCycle) {
      apu.exec();
      nextApuCycle += scanlinesInFrame * cpuCyclesInScanline;
    }
    return Pair(cpu.cycle, true);
  }

  /// returns screen buffer as 250x240xargb
  Uint8List ppuBuffer() {
    return ppu.buffer;
  }

  // returns audio buffer as float32 with (1.78M/2) Hz * 1/60 samples
  Float32List apuBuffer() {
    return apu.buffer;
  }

  /// handles reset button events
  void reset() {
    nextPpuCycle = cpuCyclesInScanline;
    nextApuCycle = scanlinesInFrame * cpuCyclesInScanline;
    bus.onReset();
  }

  /// handles pad down/up events
  void padDown(PadButton k) => bus.joypad.keyDown(k);
  void padUp(PadButton k) => bus.joypad.keyUp(k);

  /// returns the emulator's internal status report
  String dump(
      {bool showZeroPage = false,
      bool showSpriteVram = false,
      bool showStack = false,
      bool showApu = false}) {
    final cpuDump = cpu.dump(showRegs: true);
    final dump = "${cpuDump.substring(0, 48)}\n"
        "${cpuDump.substring(48)}\n"
        "${cpu.dump(showIRQVector: true, showStack: showStack, showZeroPage: showZeroPage)}"
        "${ppu.dump(showSpriteVram: showSpriteVram)}"
        "${showApu ? apu.dump() : ""}"
        "${bus.mapper.dump()}";
    return dump;
    // return '${fps.toStringAsFixed(2)}fps';
  }

  // returns CHR ROM rendered image with 8x8 x 16x16 x 2(=128x256) x 2(chr/obj) ARGB format.
  Uint8List renderChrRom() {
    return ChrRomDebugger.renderChrRom(bus.ppu.readVram);
  }

  // returns dis-assembled 6502 instruction in [String nmemonic, int nextAddr]
  Pair<String, int> disasm(int addr) =>
      Pair(cpu.dumpDisasm(addr, toAddrOffset: 1), Disasm.nextPC(addr));

  // loads an iNES format rom file.
  // throws exception if the mapper typ of the rom file is not supported.
  void setRom(Uint8List body) {
    final nesFile = NesFile();
    nesFile.load(body);

    switch (nesFile.mapper) {
      case 0:
        bus.mapper = MapperNROM();
        break;
      case 1:
        bus.mapper = MapperMMC1();
        break;
      case 2:
        bus.mapper = MapperUxROM();
        break;
      case 3:
        bus.mapper = MapperCNROM();
        break;
      case 4:
        bus.mapper = MapperMMC3();
        break;
      case 75:
        bus.mapper = MapperVrc1();
        break;
      case 21:
        bus.mapper = MapperVrc4a4c();
        break;
      case 23:
        bus.mapper = MapperVrc4f4e();
        break;
      case 25:
        bus.mapper = MapperVrc4b4d();
        break;
      default:
        throw Exception("unimplemented mapper:${nesFile.mapper}!");
    }

    bus.mapper.setRom(nesFile.character, nesFile.program);
    bus.mirrorVertical(nesFile.mirrorVertical);
    bus.mapper.mirrorVertical = bus.mirrorVertical;

    bus.mapper.holdIrq = (hold) => hold ? bus.holdIrq() : bus.releaseIrq();

    reset();
  }
}