// Dart imports:
import 'dart:typed_data';

// Project imports:
import '../../util/util.dart';
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
import 'component/vdc_debug.dart';
import 'mapper/rom.dart';
import 'rom/pce_file.dart';

/// main class for NES emulation. integrates cpu/ppu/apu/bus/pad control
class Pce implements Core {
  late final Vdc vdc;
  late final Vdc vdc2;
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

  @override
  get cpuInfos => [CpuInfo.of6502(1, "Hu6280")];

  Pce() {
    bus = Bus();
    cpu = Cpu2(bus);
    vdc = bus.vdc = Vdc(bus, 0);
    vdc2 = bus.vdc2 = Vdc(bus, 1);
    psg = Psg(bus);
    timer = Timer(bus);
    pic = Pic(bus);
  }

  int _nextVdcClocks = 0;
  int _prevPsgClocks = 0;

  /// exec 1 cpu instruction and render PPU / APU if enough cycles passed
  /// returns current CPU cycle and bool - false when unimplemented instruction is found
  @override
  ExecResult exec(bool _) {
    if (!cpu.exec()) {
      return ExecResult(cpu.cycles, true, false);
    }

    bus.timer.exec(cpu.clock);

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
      _onAudio(AudioBuffer(Psg.audioSamplingRate, 2, psg.exec(elapsed)));
    }

    return ExecResult(cpu.clocks, false, rendered);
  }

  /// returns screen buffer as hSize x vSize argb
  @override
  ImageBuffer imageBuffer() {
    return ImageBuffer(
        vdc.hSize, vdc.vSize, VdcRenderer.buffer.buffer.asUint8List());
  }

  void Function(AudioBuffer) _onAudio = (_) {};

  @override
  onAudio(void Function(AudioBuffer) onAudio) {
    _onAudio = onAudio;
  }

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
  (String, int) disasm(int _, int addr) =>
      (cpu.dumpDisasm(addr), Disasm.nextPC(cpu.read(addr)));

  // debug: returns PC register
  @override
  int programCounter(int _) => cpu.regs.pc;

  // debug: returns SP register
  @override
  int stackPointer(int _) => cpu.regs.s;

  // debug: set debug logging
  @override
  TraceLog trace(int _) => cpu.trace();

  // debug: dump vram
  @override
  List<int> get vram => vdc.vram.toList(growable: false);

  // debug: read mem
  @override
  int read(int _, int addr) => bus.cpu.read(addr);

  // debug: render BG
  @override
  ImageBuffer renderBg() => vdc.renderBg();
  @override
  ImageBuffer renderVram(bool useSecondBgColor, int paletteNo) {
    final buf = vdc.renderVram(useSecondBgColor, paletteNo);
    return buf;
    // final buf2 = vdc2.renderVram(useSecondBgColor, paletteNo);
    // return ImageBuffer(buf.width, buf.height + buf2.height,
    //     Uint8List.fromList([...buf.buffer, ...buf2.buffer]));
  }

  @override
  ImageBuffer renderColorTable(int paletteNo) =>
      vdc.renderColorTable(paletteNo);

  @override
  List<String> spriteInfo() => vdc.spriteInfo();
}
