import 'dart:typed_data';

import '../../core.dart';
import '../../pad_button.dart';
import '../../sram.dart';
import '../../types.dart';
import '../../util/crc32.dart';
import '../../util/disasm.dart';
import '../../util/int.dart';
import 'bus.dart';
import 'display.dart';
import 'sound.dart';
import 'v30mz/disasm.dart';
import 'v30mz/v30mz.dart';

/// main class of the WonderSwan and WonderSwan Color core
class Ws extends Core {
  final bool color;
  final Bus bus;

  Ws({required this.color}) : bus = Bus(color: color);

  V30mz get cpu => bus.cpu;
  Display get display => bus.display;
  Sound get sound => bus.sound;

  static const clockHz = 3072000;
  static const clocksInLine = 256;

  @override
  int get systemClockHz => clockHz;

  @override
  int get scanlinesInFrame => bus.linesInFrame;

  @override
  int get clocksInScanline => clocksInLine;

  @override
  List<CpuInfo> get cpuInfos => [const CpuInfo(0, "V30MZ", 20)];

  int _nextLineCycles = clocksInLine;
  int _soundCycles = 0;
  int frames = 0;

  Sram? _sram;
  String crc = "";

  static const _stepContinues = 0;
  static const _stepRenderedLine = 1;
  static const _stepStopped = 2;

  @override
  ExecResult exec(bool step) {
    final status = _advance();
    return ExecResult(
        cpu.cycles, status == _stepStopped, status == _stepRenderedLine);
  }

  @override
  ExecResult runFrame(int scanlines) {
    var rendered = false;
    while (scanlines > 0) {
      final status = _advance();
      if (status == _stepStopped) return ExecResult(cpu.cycles, true, false);
      rendered = status == _stepRenderedLine;
      if (rendered) scanlines--;
    }
    return ExecResult(cpu.cycles, false, rendered);
  }

  @pragma('vm:prefer-inline')
  int _advance() {
    final cpu = this.cpu;
    if (!cpu.exec()) return _stepStopped;
    if (cpu.cycles < _nextLineCycles) return _stepContinues;

    _nextLineCycles += clocksInLine;
    final elapsed = cpu.cycles - _soundCycles;
    _soundCycles = cpu.cycles;
    bus.runSoundDma(elapsed);
    sound.run(elapsed);
    if (bus.runLine()) {
      frames++;
      _flushAudio();
    }
    return _stepRenderedLine;
  }

  void _flushAudio() {
    if (sound.samples == 0) return;
    _onAudio(AudioBuffer(Sound.sampleRate, 2,
        Float32List.fromList(sound.buffer.sublist(0, sound.samples * 2))));
    sound.samples = 0;
  }

  void Function(AudioBuffer) _onAudio = (_) {};

  @override
  void onAudio(void Function(AudioBuffer) onAudio) {
    _onAudio = onAudio;
  }

  @override
  ImageBuffer imageBuffer() => display.imageBuffer;

  @override
  void setSram(Sram sram) {
    _sram = sram;
  }

  @override
  void reset() {
    bus.reset();
    // starts the cartridge at its entry point FFFF:0000
    cpu.s[V30mz.cs] = 0xffff;
    cpu.ip = 0;
    _nextLineCycles = cpu.cycles + clocksInLine;
    _soundCycles = cpu.cycles;
    frames = 0;
  }

  @override
  void padDown(int controllerId, PadButton k) {
    if (controllerId == 0 && bus.pad.keyDown(k)) {
      bus.interrupt(Bus.intKey);
    }
  }

  @override
  void padUp(int controllerId, PadButton k) {
    if (controllerId == 0) bus.pad.keyUp(k);
  }

  /// the buttons in the order of the keys A S Z X C Q W E
  @override
  List<PadButton> get buttons => const [
        PadButton.up,
        PadButton.down,
        PadButton.left,
        PadButton.right,
        Pad.y1,
        Pad.start,
        Pad.b,
        Pad.a,
        Pad.y2,
        Pad.y4,
        Pad.y3,
      ];

  @override
  void setRom(Uint8List body) {
    if (body.length < 16) throw Exception("Not a WonderSwan ROM");
    crc = crc32Hex(body);
    bus.setRom(body);
    bus.attachSaves(_sram, "${color ? "wsc" : "ws"}-$crc");
    reset();
  }

  // ----------------------------------------------------------------------
  // debug

  @override
  bool get hasPatternTables => true;

  int _linear(int seg, int off) => (seg.shl4 + off.mask16) & 0xfffff;

  @override
  String dump(
      {bool showZeroPage = false,
      bool showSpriteVram = false,
      bool showStack = false,
      bool showApu = false}) {
    final (asm, _) = disasm(0, programCounter(0));
    final stack = showStack
        ? "\n${List.generate(16, (i) => bus.read8(_linear(cpu.s[V30mz.ss], cpu.r[V30mz.sp] + i)).x2).join(" ")}"
        : "";
    return "$asm\n${cpu.dump()}$stack\n${bus.dump()} clk:${cpu.cycles.format3}"
        "${showApu ? "\n${sound.dump()}" : ""}";
  }

  @override
  (String, int) disasm(int cpuNo, int addr) {
    int byte(int offset) => bus.read8((addr + offset) & 0xfffff);
    try {
      final (inst, length) = disasmV30(byte, addr.mask16);
      final hex = List.generate(length, (i) => byte(i).x2).join(' ');
      return (
        formatDisasm(addr.hex.padLeft(5, '0'), hex, inst, codeWidth: 17),
        length
      );
    } catch (e) {
      return (formatDisasm(addr.hex, byte(0).x2, '[$e]', codeWidth: 17), 1);
    }
  }

  @override
  int programCounter(int cpuNo) => _linear(cpu.s[V30mz.cs], cpu.ip);

  @override
  int stackPointer(int cpuNo) => _linear(cpu.s[V30mz.ss], cpu.r[V30mz.sp]);

  @override
  TraceLog trace(int cpuNo) {
    final pc = programCounter(0);
    final (text, length) = disasm(0, pc);
    return TraceLog(pc, cpu.cycles, text.padRight(48),
        cpu.dump().replaceAll("\n", " "), [...cpu.r, ...cpu.s, cpu.flags],
        frame: frames,
        scanline: bus.line,
        flow:
            traceV30Flow((i) => bus.read8((pc + i) & 0xfffff), cpu.ip, length));
  }

  @override
  List<int> get vram => bus.ram;

  @override
  int read(int cpuNo, int addr) => bus.read8(addr & 0xfffff);

  @override
  ImageBuffer renderVram(bool useSecondBgColor, int paletteNo) =>
      display.renderTiles(paletteNo);

  @override
  ImageBuffer renderColorTable(int paletteNo) => display.renderColors();
}
