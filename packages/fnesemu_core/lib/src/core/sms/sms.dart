import 'dart:typed_data';

import '../../components/z80/z80.dart';
import '../../components/z80/z80_disasm.dart';
import '../../core.dart';
import '../../pad_button.dart';
import '../../sram.dart';
import '../../trace_flow.dart';
import '../../types.dart';
import '../../util/crc32.dart';
import '../../util/disasm.dart';
import '../../util/int.dart';
import 'bus.dart';
import 'pad.dart';
import 'vdp.dart';

/// main class of the SG-1000, Master System and Game Gear core
class Sms extends Core {
  final SmsModel model;
  final Bus bus;

  Sms(this.model) : bus = Bus(model);

  Z80 get cpu => bus.cpu;
  Vdp get vdp => bus.vdp;

  static const clockHz = 3579545;
  static const clocksInLine = 228;

  // the PSG renders a sample every 16 clocks; 5 of them make an output sample
  static const _psgClocks = 16;
  static const _decimation = 5;
  static const sampleRate = clockHz ~/ (_psgClocks * _decimation);

  @override
  int get systemClockHz => clockHz;

  @override
  int get scanlinesInFrame => Vdp.linesInFrame;

  @override
  int get clocksInScanline => clocksInLine;

  @override
  List<CpuInfo> get cpuInfos => [CpuInfo.ofZ80(0, "Z80")];

  int _nextLineCycles = clocksInLine;
  int _frames = 0;

  Sram? _sram;

  // ROM CRC
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
    if (vdp.irq) {
      cpu.assertInt();
    } else {
      cpu.deassertInt();
    }
    if (!cpu.exec()) return _stepStopped;

    if (cpu.cycles < _nextLineCycles) return _stepContinues;

    bus.lineStartCycles = _nextLineCycles;
    _nextLineCycles += clocksInLine;
    vdp.runLine();
    _renderAudio();
    if (vdp.frames != _frames) {
      _frames = vdp.frames;
      _flushAudio();
    }
    return _stepRenderedLine;
  }

  // ----------------------------------------------------------------------
  // audio

  var _psgBuffer = Float32List(2 * 64);
  int _psgFrames = 0;
  final _audio = Float32List(2 * 2048);
  int _audioFrames = 0;

  void _renderAudio() {
    final psg = bus.psg;
    final samples = cpu.cycles ~/ _psgClocks - psg.elapsedSamples;
    if (samples <= 0) return;
    if (_psgBuffer.length < (_psgFrames + samples) * 2) {
      _psgBuffer = Float32List((_psgFrames + samples) * 2 * 2)
        ..setRange(0, _psgFrames * 2, _psgBuffer);
    }
    psg.renderStereoTo(_psgBuffer, _psgFrames * 2, samples);
    _psgFrames += samples;

    // decimates by averaging
    var i = 0;
    while (_psgFrames - i >= _decimation && _audioFrames * 2 < _audio.length) {
      var l = 0.0, r = 0.0;
      for (var j = 0; j < _decimation; j++) {
        l += _psgBuffer[(i + j) * 2];
        r += _psgBuffer[(i + j) * 2 + 1];
      }
      _audio[_audioFrames * 2] = l / _decimation;
      _audio[_audioFrames * 2 + 1] = r / _decimation;
      _audioFrames++;
      i += _decimation;
    }
    _psgBuffer.setRange(0, (_psgFrames - i) * 2, _psgBuffer, i * 2);
    _psgFrames -= i;
  }

  void _flushAudio() {
    if (_audioFrames == 0) return;
    _onAudio(AudioBuffer(
        sampleRate,
        2,
        Float32List.fromList(
            Float32List.sublistView(_audio, 0, _audioFrames * 2))));
    _audioFrames = 0;
  }

  void Function(AudioBuffer) _onAudio = (_) {};

  @override
  void onAudio(void Function(AudioBuffer) onAudio) {
    _onAudio = onAudio;
  }

  // ----------------------------------------------------------------------
  // media and controls

  @override
  ImageBuffer imageBuffer() => vdp.imageBuffer;

  @override
  void setSram(Sram sram) {
    _sram = sram;
  }

  @override
  void reset() {
    bus.reset();
    bus.pad.reset();
    _nextLineCycles = clocksInLine;
    _frames = 0;
    _psgFrames = _audioFrames = 0;
  }

  @override
  void padDown(int controllerId, PadButton k) {
    if (k == Pad.pause) {
      cpu.triggerNmi();
    } else if (k == Pad.start) {
      bus.ggStart = true;
    } else {
      bus.pad.keyDown(controllerId, k);
    }
  }

  @override
  void padUp(int controllerId, PadButton k) {
    if (k == Pad.start) {
      bus.ggStart = false;
    } else {
      bus.pad.keyUp(controllerId, k);
    }
  }

  /// the buttons in the order of the keys A S Z X
  @override
  List<PadButton> get buttons => [
        PadButton.up,
        PadButton.down,
        PadButton.left,
        PadButton.right,
        PadButton.none,
        model == SmsModel.gg ? Pad.start : Pad.pause,
        Pad.button1,
        Pad.button2,
      ];

  @override
  void setRom(Uint8List body) {
    crc = crc32Hex(body);
    bus.setRom(body);
    if (bus.mapper == Mapper.sega) {
      bus.attachCartRam(_sram, "${model.name}-$crc");
    }
    reset();
  }

  // ----------------------------------------------------------------------
  // debug

  @override
  bool get hasPatternTables => true;

  @override
  String dump(
      {bool showZeroPage = false,
      bool showSpriteVram = false,
      bool showStack = false,
      bool showApu = false}) {
    final (asm, _) = disasm(0, cpu.r.pc);
    final stack = showStack
        ? "\n${List.generate(16, (i) => bus.read((cpu.r.sp + i).mask16).x2).join(" ")}"
        : "";
    return "$asm\n${cpu.dump()}$stack\n${bus.dump()} clk:${cpu.cycles.format3}\n"
        "${vdp.dump()}\n${showApu ? bus.psg.dump() : ""}";
  }

  @override
  (String, int) disasm(int cpuNo, int addr) {
    final data =
        List.generate(4, (i) => bus.read((addr + i).mask16), growable: false);
    try {
      final (inst, length) = Z80Disasm.disasm(data, addr);
      final hex = data.take(length).map((value) => value.x2).join(' ');
      return (formatDisasm(addr.x4, hex, inst, codeWidth: 11), length);
    } catch (e) {
      return (formatDisasm(addr.x4, data.first.x2, '[$e]', codeWidth: 11), 1);
    }
  }

  @override
  int programCounter(int cpuNo) => cpu.r.pc;

  @override
  int stackPointer(int cpuNo) => cpu.r.sp;

  @override
  TraceLog trace(int cpuNo) {
    final pc = cpu.r.pc;
    return TraceLog(
        pc,
        cpu.cycles,
        disasm(0, pc).$1.padRight(36),
        cpu.dump().replaceAll("\n", " "),
        [cpu.r.af, cpu.r.bc, cpu.r.de, cpu.r.hl, cpu.r.ix, cpu.r.iy, cpu.r.sp],
        frame: vdp.frames,
        scanline: vdp.line,
        flow: traceZ80Flow(bus.read(pc), pc, cpu.r.af & 255,
            operand:
                bus.read((pc + 1) & 0xffff) | bus.read((pc + 2) & 0xffff) << 8,
            second: bus.read((pc + 1) & 0xffff)));
  }

  @override
  List<int> get vram => vdp.vram;

  @override
  int read(int cpuNo, int addr) => bus.read(addr.mask16);

  @override
  ImageBuffer renderVram(bool useSecondBgColor, int paletteNo) =>
      vdp.renderPatterns(paletteNo);

  @override
  ImageBuffer renderColorTable(int paletteNo) => vdp.renderColors();
}
