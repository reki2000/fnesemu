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

/// main class of the ws core: the mono and the color consoles
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
    final audio =
        Float32List.fromList(sound.buffer.sublist(0, sound.samples * 2));
    // The SOUND button controls the console speaker independently of games.
    const gains = [0.0, 0.25, 0.5, 1.0];
    final gain = gains[speakerVolume];
    if (gain != 1.0) {
      for (var i = 0; i < audio.length; i++) {
        audio[i] *= gain;
      }
    }
    _onAudio(AudioBuffer(Sound.sampleRate, 2, audio));
    sound.samples = 0;
  }

  void Function(AudioBuffer) _onAudio = (_) {};

  @override
  void onAudio(void Function(AudioBuffer) onAudio) {
    _onAudio = onAudio;
  }

  /// the console held vertically: the frame is shown turned 90 degrees to
  /// the left, and the directions are turned with it
  bool vertical = false;
  Uint32List _turned = Uint32List(0);

  static const rotate = PadButton("Rotate");

  /// Emulated speaker output level (0 = mute, 3 = full volume).
  int speakerVolume = 3;

  @override
  ImageBuffer imageBuffer() {
    final image = display.imageBuffer;
    if (!vertical) return image;
    final w = image.width, h = image.height;
    if (_turned.length != w * h) _turned = Uint32List(w * h);
    final src = image.buffer, dst = _turned;
    // the pixel (x, y) moves to (y, w - 1 - x) of the h x w frame
    for (var y = 0; y < h; y++) {
      final row = y * w;
      for (var x = 0; x < w; x++) {
        dst[(w - 1 - x) * h + y] = src[row + x];
      }
    }
    return ImageBuffer(h, w, dst);
  }

  // A rotated display uses the Y group for arrows and the X group for
  // WASD, with both directions corrected for the display rotation.
  static PadButton _turn(PadButton k) => switch (k.name) {
        "up" => Pad.y2,
        "right" => Pad.y3,
        "down" => Pad.y4,
        "left" => Pad.y1,
        "Y1" => Pad.x2,
        "Y2" => Pad.x3,
        "Y3" => Pad.x4,
        "Y4" => Pad.x1,
        _ => k,
      };

  // Keep input identities across rotation so held keys can be released
  // and rebound without sticking to their previous orientation.
  final _heldKeys = <String, PadButton>{};
  final _mappedKeys = <String, PadButton>{};

  void _syncPad() {
    final next = <String, PadButton>{};
    for (final key in _heldKeys.values) {
      final mapped = vertical ? _turn(key) : key;
      next[mapped.name] = mapped;
    }
    for (final entry in _mappedKeys.entries) {
      if (!next.containsKey(entry.key)) bus.pad.keyUp(entry.value);
    }
    for (final entry in next.entries) {
      if (!_mappedKeys.containsKey(entry.key) && bus.pad.keyDown(entry.value)) {
        bus.interrupt(Bus.intKey);
      }
    }
    _mappedKeys
      ..clear()
      ..addAll(next);
  }

  @override
  void setSram(Sram sram) {
    _sram = sram;
  }

  @override
  void reset() {
    bus.reset();
    _heldKeys.clear();
    _mappedKeys.clear();
    // starts the cartridge at its entry point FFFF:0000
    cpu.s[V30mz.cs] = 0xffff;
    cpu.ip = 0;
    _nextLineCycles = cpu.cycles + clocksInLine;
    _soundCycles = cpu.cycles;
    frames = 0;
  }

  @override
  void padDown(int controllerId, PadButton k) {
    if (controllerId != 0) return;
    if (k == Pad.sound) {
      speakerVolume = (speakerVolume + 3) % 4;
      return;
    }
    if (k == rotate) {
      vertical = !vertical;
      _syncPad();
      return;
    }
    _heldKeys[k.name] = k;
    _syncPad();
  }

  @override
  void padUp(int controllerId, PadButton k) {
    if (controllerId != 0 || k == rotate || k == Pad.sound) return;
    _heldKeys.remove(k.name);
    _syncPad();
  }

  /// the buttons in the order of the keys A S Z X C Q W E R D
  @override
  List<PadButton> get buttons => const [
        PadButton.up,
        PadButton.down,
        PadButton.left,
        PadButton.right,
        Pad.y4, // A
        Pad.y3, // S
        Pad.b, // Z
        Pad.a, // X
        PadButton.none, // C
        Pad.sound, // Q
        Pad.y1, // W
        Pad.start, // E
        rotate, // R
        Pad.y2, // D
      ];

  @override
  void setRom(Uint8List body) {
    if (body.length < 16) throw Exception("Not a ws ROM");
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
