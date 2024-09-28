// Dart imports:
import 'dart:async';
import 'dart:typed_data';

import 'package:fnesemu/core/pce/component/vdc_debug.dart';

import '../../util.dart';
// Project imports:
import '../core.dart';
import '../pad_button.dart';
import '../types.dart';
import 'component/bus.dart';
import 'component/cpu.dart';
import 'component/cpu_debug.dart';
import 'component/cpu_disasm.dart';
import 'component/pic.dart';
import 'component/psg.dart';
import 'component/psg_debug.dart';
import 'component/timer.dart';
import 'component/vdc.dart';
import 'component/vdc_render.dart';
import 'mapper/rom.dart';
import 'rom/pce_file.dart';

export '../pad_button.dart';

/// main class for NES emulation. integrates cpu/ppu/apu/bus/pad control
class Pce implements Core {
  late final Vdc vdc;
  late final Psg psg;
  late final Cpu2 cpu;
  late final Bus bus;
  late final Timer timer;
  late final Pic pic;

  static const systemClockHz_ = 21477270; // 21.47727MHz

  @override
  int get systemClockHz => systemClockHz_;

  @override
  int get scanlinesInFrame => 263;

  @override
  int get clocksInScanline => systemClockHz ~/ 59.97 ~/ scanlinesInFrame;

  Pce() {
    bus = Bus();
    cpu = Cpu2(bus);
    vdc = Vdc(bus);
    psg = Psg(bus);
    timer = Timer(bus);
    pic = Pic(bus);
  }

  int _nextVdcClocks = 0;
  int _prevPsgClocks = 0;

  @override
  int get clocks => cpu.clocks;

  /// exec 1 cpu instruction and render PPU / APU if enough cycles passed
  /// returns current CPU cycle and bool - false when unimplemented instruction is found
  @override
  ExecResult exec() {
    final cpuOk = cpu.exec();

    bus.timer.exec(cpu.clock);

    if (!cpuOk) {
      return ExecResult(cpu.cycles, false, false);
    }

    bool rendered = false;

    while (cpu.clocks >= _nextVdcClocks) {
      vdc.exec();
      _nextVdcClocks += clocksInScanline;
      // print(
      //     "cpu.clocks:${cpu.clocks} cpu.cycles:${cpu.cycles} nextVdcClocks: $nextVdcClocks");
      rendered = true;
    }

    while (cpu.clocks >= _prevPsgClocks + clocksInScanline) {
      final elapsed = (cpu.clocks - _prevPsgClocks) ~/ 6 * 6;
      _prevPsgClocks += elapsed;
      _audioStream?.add(psg.exec(elapsed));
    }

    return ExecResult(cpu.cycles, true, rendered);
  }

  /// returns screen buffer as hSize x vSize argb
  @override
  ImageBuffer imageBuffer() {
    return ImageBuffer(
        vdc.hSize, vdc.vSize, VdcRenderer.buffer.buffer.asUint8List());
  }

  StreamSink<Float32List>? _audioStream;

  @override
  setAudioStream(StreamSink<Float32List>? stream) {
    _audioStream = stream;
  }

  @override
  int get audioSampleRate => Psg.audioSamplingRate;

  /// handles reset button events
  @override
  void reset() {
    _nextVdcClocks = clocksInScanline;
    _prevPsgClocks = clocksInScanline;
    bus.onReset();
  }

  /// handles pad down/up events
  @override
  void padDown(int controllerId, PadButton k) =>
      bus.joypad.keyDown(controllerId, k);
  @override
  void padUp(int controllerId, PadButton k) =>
      bus.joypad.keyUp(controllerId, k);

  @override
  List<PadButton> get buttons => bus.joypad.buttons;

  // ROM CRC
  String crc = "";

  // loads an .pce format rom file.
  // throws exception if the mapper type of the rom file is not supported.
  @override
  void setRom(Uint8List body) {
    final file = PceFile();
    file.load(body);
    crc = file.crc;

    bus.rom = Rom(file.banks);

    reset();
  }

  /// debug: returns the emulator's internal status report
  @override
  String dump(
      {bool showZeroPage = false,
      bool showSpriteVram = false,
      bool showStack = false,
      bool showApu = false}) {
    final cpuDump = cpu.dump(showRegs: true);
    final dump = "$cpuDump\n"
        "${cpu.dump(showIRQVector: true, showStack: showStack, showZeroPage: showZeroPage)}"
        "${showApu ? psg.dump() : ""}"
        "${bus.vdc.dump()}";
    return dump;
    // return '${fps.toStringAsFixed(2)}fps';
  }

  // debug: returns dis-assembled 6502 instruction in [String nmemonic, int nextAddr]
  @override
  Pair<String, int> disasm(int addr) => Pair(
      cpu.dumpDisasm(addr, toAddrOffset: 1), Disasm.nextPC(cpu.read(addr)));

  // debug: returns PC register
  @override
  int get programCounter => cpu.regs.pc;

  // debug: set debug logging
  @override
  String get tracingState => "${cpu.trace()} ${vdc.dump()}";

  // debug: dump vram
  @override
  List<int> get vram => vdc.vram.toList(growable: false);

  // debug: dump color table
  @override
  List<int> get colorTable => vdc.colorTable;

  // debug: dump sprite table
  @override
  List<int> get spriteTable => vdc.sat;

  // debug: read mem
  @override
  int read(int addr) => bus.cpu.read(addr);

  // debug: render BG
  @override
  ImageBuffer renderBg() => vdc.renderBg();
}
