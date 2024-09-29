// Dart imports:
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

// Project imports:
import '../../util.dart';
import '../core.dart';
import '../pad_button.dart';
import '../types.dart';
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
import 'mapper/mirror.dart';
import 'rom/nes_file.dart';
import 'storage.dart';

/// main class for NES emulation. integrates cpu/ppu/apu/bus/pad control
class Nes implements Core {
  Nes() {
    bus = Bus();
    cpu = Cpu(bus);
    ppu = Ppu(bus);
    apu = Apu(bus);
  }

  late final Ppu ppu;
  late final Apu apu;
  late final Cpu cpu;
  late final Bus bus;

  final storage = Storage.of();

  static const cpuClock = 1789773;

  static const apuClock = cpuClock ~/ 2;

  static const scanlinesInFrame_ = 262;

  static const cpuCyclesInScanline = cpuClock / 59.97 ~/ scanlinesInFrame_;

  static const imageWidth = 256;
  static const imageHeight = 240;

  @override
  int get scanlinesInFrame => scanlinesInFrame_;

  @override
  int get clocksInScanline => cpuCyclesInScanline;

  @override
  int get systemClockHz => cpuClock;

  int _nextPpuCycle = 0;
  int _nextApuCycle = 0;

  StreamSink<AudioBuffer>? _audioSink;

  /// exec 1 cpu instruction and render PPU / APU is enough cycles passed
  /// returns current CPU cycle and bool - false when unimplemented instruction is found
  @override
  ExecResult exec() {
    final cpuOk = cpu.exec();
    if (!cpuOk) {
      return ExecResult(cpu.cycle, false, false);
    }

    bool rendered = false;
    if (cpu.cycle >= _nextPpuCycle) {
      ppu.exec();
      bus.mapper.handleClock(cpu.cycle);
      _nextPpuCycle += cpuCyclesInScanline;
      rendered = true;
    }

    if (cpu.cycle >= _nextApuCycle) {
      apu.exec();
      bus.mapper.handleApu();
      _nextApuCycle += scanlinesInFrame * cpuCyclesInScanline;

      _pushApuBuffer();
    }

    return ExecResult(cpu.cycle, true, rendered);
  }

  // returns audio buffer as float32 with (1.78M/2) Hz * 1/60 samples
  void _pushApuBuffer() {
    final aux = bus.mapper.apuBuffer();

    // if mapper has aux buffer, mix with apu buffer
    if (aux.isNotEmpty) {
      final buf = Float32List(aux.length);

      // mix apu.buffer + aux with normalization
      var maxVolume = 1.0;
      for (int i = 0; i < aux.length; i++) {
        maxVolume = max(maxVolume, (aux[i] + apu.buffer[i]).abs());
      }

      for (int i = 0; i < buf.length; i++) {
        buf[i] = (aux[i] + apu.buffer[i]) / maxVolume;
      }

      _audioSink?.add(AudioBuffer(apuClock, 1, buf));
      return;
    }

    _audioSink?.add(AudioBuffer(apuClock, 1, apu.buffer));
  }

  /// returns screen buffer as 250 240 argb
  @override
  ImageBuffer imageBuffer() {
    return ImageBuffer(
        imageWidth, imageHeight, ppu.buffer.buffer.asUint8List());
  }

  @override
  setAudioStream(StreamSink<AudioBuffer>? sink) {
    _audioSink = sink;
  }

  /// handles reset button events
  @override
  void reset() {
    _nextPpuCycle = cpuCyclesInScanline;
    _nextApuCycle = scanlinesInFrame * cpuCyclesInScanline;
    bus.onReset();
  }

  /// handles pad down/up events
  @override
  void padDown(int id, PadButton k) => bus.joypad.keyDown(id, k);
  @override
  void padUp(int id, PadButton k) => bus.joypad.keyUp(id, k);

  @override
  List<PadButton> get buttons => bus.joypad.buttons;

  // ROM CRC
  String crc = "";
  bool hasBatteryBackup = false;

  // loads an iNES format rom file.
  // throws exception if the mapper type of the rom file is not supported.
  @override
  void setRom(Uint8List body) {
    final nesFile = NesFile();
    nesFile.load(body);
    crc = nesFile.crc;
    hasBatteryBackup = nesFile.hasBatteryBackup;

    bus.mirror(nesFile.mirrorVertical ? Mirror.vertical : Mirror.horizontal);

    bus.mapper = Mapper.of(nesFile.mapper)
      ..setRom(
          Uint8ListEx.join(nesFile.character),
          Uint8ListEx.join(nesFile.program),
          hasBatteryBackup ? storage.load(crc) : Uint8List(0))
      ..mirror = bus.mirror
      ..holdIrq = ((hold) => hold ? bus.holdIrq() : bus.releaseIrq());

    reset();
  }

  /// save SRAM
  void saveSram() {
    if (hasBatteryBackup) {
      storage.save(crc, bus.mapper.exportSram());
    }
  }

  /// debug: returns the emulator's internal status report
  @override
  String dump(
      {bool showZeroPage = false,
      bool showSpriteVram = false,
      bool showStack = false,
      bool showApu = false}) {
    final cpuDump = cpu.dump(showRegs: true);
    final dump = "${cpuDump.substring(0, 48)}"
        "${cpuDump.substring(48)}\n"
        "${cpu.dump(showIRQVector: true, showStack: showStack, showZeroPage: showZeroPage)}"
        "${ppu.dump(showSpriteVram: showSpriteVram)}"
        "${showApu ? apu.dump() : ""}"
        "${bus.mapper.dump()}";
    return dump;
    // return '${fps.toStringAsFixed(2)}fps';
  }

  // debug: returns dis-assembled 6502 instruction in [String nmemonic, int nextAddr]
  @override
  Pair<String, int> disasm(int addr) =>
      Pair(cpu.dumpDisasm(addr, toAddrOffset: 1), Disasm.nextPC(addr));

  // debug: returns PC register
  @override
  int get programCounter => cpu.regs.pc;

  // debug: set debug logging
  @override
  String get tracingState => cpu.trace();

  // debug: dump vram
  @override
  List<int> get vram => bus.vram;

  // debug: read mem
  @override
  int read(int addr) => bus.read(addr);

  // debug: returns CHR ROM rendered image with 8x8 x 16x16 x 2(=128x256) x 2(chr/obj) ARGB format.
  @override
  ImageBuffer renderBg() => ChrRomDebugger.renderChrRom(bus.ppu.readVram);

  @override
  ImageBuffer renderVram(bool useSecondBgColor, int paletteNo) =>
      ImageBuffer(0, 0, Uint8List(0));

  @override
  ImageBuffer renderColorTable(int paletteNo) =>
      ImageBuffer(0, 0, Uint8List(0));

  @override
  List<String> spriteInfo() => List.empty();
}
