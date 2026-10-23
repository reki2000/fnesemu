import 'dart:math' as math;
import 'dart:typed_data';

import '../../core.dart';
import '../../pad_button.dart';
import '../../sram.dart';
import '../../state.dart';
import '../../trace_flow.dart';
import '../../types.dart';
import '../../util/debug.dart';
import '../../util/disasm.dart';
import '../../util/int.dart';
import '../../util/register_dump.dart';
import '../../video_debug.dart';
import 'audio.dart';
import 'bus.dart';
import 'cpu.dart';
import 'disasm.dart';
import 'graphics.dart';
import 'jit/n64_jit.dart';
import 'rom.dart';

/// N64 core with recompilation, CPU fallback and graphics/audio HLE.
class N64 extends Core {
  @override
  List<DebugVideoLayer> get videoLayers => [
        DebugVideoLayer('VI Framebuffer', _debugFramebuffer,
            hasMap: true, kind: DebugLayerKind.framebuffer)
      ];
  DebugRaster _debugFramebuffer(bool map) {
    final image = bus.image();
    if (!map) return DebugRaster.copy(image);
    final stride = bus.vi[2] & 0xfff, mode = bus.vi[0] & 3;
    if (stride == 0 || mode < 2) return DebugRaster.copy(image);
    final canvas = DebugCanvas(stride, image.height);
    final origin = bus.vi[1] & 0xffffff, bytes = mode == 2 ? 2 : 4;
    for (var y = 0; y < image.height; y++)
      for (var x = 0; x < stride; x++) {
        final a = origin + (y * stride + x) * bytes;
        if (a + bytes > bus.ram.length) continue;
        if (bytes == 4) {
          canvas.pixels[y * stride + x] = 0xff000000 |
              bus.ram[a] |
              bus.ram[a + 1] << 8 |
              bus.ram[a + 2] << 16;
        } else {
          final c = bus.ram[a] << 8 | bus.ram[a + 1];
          int expand(int n) => (n << 3) | (n >> 2);
          canvas.pixels[y * stride + x] = 0xff000000 |
              expand((c >> 11) & 31) |
              expand((c >> 6) & 31) << 8 |
              expand((c >> 1) & 31) << 16;
        }
      }
    canvas.viewport(0, 0, image.width, image.height);
    return canvas.raster();
  }

  final N64Bus bus;
  late final Vr4300 cpu;
  final N64Jit? jit;
  @override
  bool get jitEnabled => jit?.native ?? false;
  @override
  bool get jitSuspended => jit?.suspended ?? false;
  @override
  set jitSuspended(bool value) => jit?.suspended = value;
  @override
  int get cpuClocks => cpu.clocks;
  @override
  int get jitClocks => jit?.compiledClocks ?? 0;
  late final graphics = N64Graphics(bus);
  late final audio = N64Audio(bus);
  N64(
      {bool jit = const bool.fromEnvironment('JIT', defaultValue: true),
      bool jitStatistics = const bool.fromEnvironment('N64_JIT_STATS'),
      int? compileThreshold,
      int? maxBlockInstructions,
      bool jitCop1 =
          const bool.fromEnvironment('N64_JIT_COP1', defaultValue: true),
      bool jitNativeFpu =
          const bool.fromEnvironment('N64_JIT_NATIVE_FPU', defaultValue: true),
      bool jitFpu =
          const bool.fromEnvironment('N64_JIT_FPU', defaultValue: false),
      bool inlineJumps = const bool.fromEnvironment('N64_JIT_INLINE_JUMPS',
          defaultValue: false)})
      : this._(jit
            ? N64Jit.create(
                compileThreshold: compileThreshold,
                statistics: jitStatistics,
                maxBlockInstructions: maxBlockInstructions,
                fpuHelpers: jitFpu,
                cop1: jitCop1,
                nativeFpu: jitCop1 && jitNativeFpu,
                inlineJumps: inlineJumps)
            : null);

  N64._(this.jit) : bus = N64Bus(ram: jit?.ram) {
    cpu = Vr4300(bus, registers: jit?.regs, fpu: jit?.fpu);
    jit?.attach(cpu, bus);
    bus.onDp = (start, end) => graphics.commands(start, end);
    bus.onTask = () {
      final task = ByteData.sublistView(bus.sp, 0xfc0);
      final type = task.getUint32(0);
      if (type == 1) {
        graphics.task(task.getUint32(48) & 0x7fffff, task.getUint32(52),
            task.getUint32(24) & 0x7fffff, task.getUint32(28));
      } else if (type == 2) {
        audio.task(task.getUint32(48) & 0x7fffff, task.getUint32(52),
            newer: _rom?.bytes[0x3f] == 3);
      } else {
        throw UnsupportedError('RSP task type $type');
      }
    };
  }
  N64Rom? _rom;
  int _nextLine = 0, _frame = 0;
  final _result = ExecResult(0, false, false);

  @override
  int get systemClockHz => 93750000;
  @override
  int get scanlinesInFrame => 262;
  @override
  int get clocksInScanline => systemClockHz ~/ 60 ~/ scanlinesInFrame;
  @override
  List<CpuInfo> get cpuInfos => [const CpuInfo(0, 'VR4300', 32)];

  @override
  void setRom(Uint8List body) {
    final rom = N64Rom(body);
    _rom = rom;
    _mediaHash = null;
    bus.rom = rom.bytes;
    bus.sram?.init(
        'n64_${rom.bytes.sublist(0x10, 0x18).map((v) => v.x2).join()}',
        Uint8List(512 + 0x8000)..fillRange(0, 512, 255)); // EEPROM + SRAM
  }

  @override
  void reset() {
    final rom = _rom;
    if (rom == null) throw StateError('N64 ROM not loaded');
    jit?.reset();
    bus.reset();
    graphics.reset();
    audio.reset();
    // Deliberately bypass IPL/CIC. Only the first MiB of the payload is copied.
    final destination = rom.entryPoint & 0x1fffffff;
    final length = math.min(
      0x100000,
      math.min(rom.bytes.length - 0x1000, bus.ram.length - destination),
    );
    bus.ram.setRange(destination, destination + length, rom.bytes, 0x1000);
    cpu.reset(rom.entryPoint);
    bus.ramWrite(0x318, 0x800000, 4);
    bus.ramWrite(0x300, 1, 4); // osTvType: NTSC
    bus.ramWrite(0x304, 0, 4); // osRomType: cartridge
    bus.ramWrite(0x308, 0xb0000000, 4); // osRomBase
    bus.ramWrite(0x30c, 0, 4); // osResetType
    bus.ramWrite(0x310, rom.cicSeed, 4); // CIC seed
    cpu.r[20] = 1;
    cpu.r[22] = rom.cicSeed;

    _nextLine = clocksInScanline;
    _frame = 0;
    debugStatus.clock = debugStatus.frame = debugStatus.scanline = 0;
    debugStatus.pc = cpu.pc;
  }

  @override
  ExecResult exec(bool step) {
    final line = _advance(step);
    _updateResult(line);
    return _result;
  }

  @override
  ExecResult runFrame(int scanlines) {
    var line = false;
    while (scanlines > 0) {
      line = _advance(false, compiled: true);
      if (cpu.stopReason != null) break;
      if (line) scanlines--;
    }
    _updateResult(line);
    return _result;
  }

  @pragma('vm:prefer-inline')
  bool _advance(bool step, {bool compiled = false}) {
    final before = cpu.clocks;
    if (!step && cpu.idleLoop) {
      cpu.idle(_nextLine - cpu.clocks);
      jit?.recordIdle(cpu.clocks - before);
    } else if (step || !compiled || jit == null || jit!.suspended) {
      cpu.step();
    } else {
      var budget = math.min(_nextLine - cpu.clocks, cpu.clocksUntilCompare);
      if (bus.audioCycles > 0) budget = math.min(budget, bus.audioCycles);
      if (!jit!.run(budget)) {
        jit!.recordCpuFallback();
        cpu.step();
      }
    }
    bus.tick(cpu.clocks - before);
    var line = false;
    if (cpu.clocks >= _nextLine) {
      _nextLine += clocksInScanline;
      bus.scanline++;
      if (bus.scanline == scanlinesInFrame) {
        bus.scanline = 0;
        _frame++;
      }
      if (bus.scanline * 2 == bus.vi[3].mask10) bus.interrupt(8);
      line = true;
    }
    return line;
  }

  void _updateResult(bool line) {
    debugStatus.clock = cpu.clocks;
    debugStatus.frame = _frame;
    debugStatus.scanline = bus.scanline;
    debugStatus.pc = cpu.pc;
    _result.elapsedClocks = cpu.clocks;
    _result.stopped = cpu.stopReason != null;
    _result.scanlineRendered = line;
  }

  @override
  void dispose() => jit?.dispose();

  static const _stateVersion = 1;
  int? _mediaHash;
  int get _media {
    final rom = _rom;
    if (rom == null) throw StateError('N64 ROM not loaded');
    return _mediaHash ??= stateMediaHash(rom.bytes);
  }

  @override
  Uint8List saveState() {
    final w = StateWriter('n64', _stateVersion, _media);
    w.section('n64');
    w.int64(_nextLine);
    w.int64(_frame);
    cpu.saveState(w);
    bus.saveState(w);
    graphics.saveState(w);
    audio.saveState(w);
    return w.take();
  }

  /// A state that fails after its header leaves the core partly loaded;
  /// reset it before running.
  @override
  void loadState(Uint8List state) {
    final s = StateReader(state, 'n64', _stateVersion, _media);
    // Compiled blocks and code protection belong to the replaced memory.
    jit?.reset();
    s.section('n64');
    _nextLine = s.int64();
    _frame = s.int64();
    cpu.loadState(s);
    bus.loadState(s);
    graphics.loadState(s);
    audio.loadState(s);
    s.end();
  }

  @override
  ImageBuffer imageBuffer() => bus.image();
  @override
  void onAudio(void Function(AudioBuffer) onAudio) {
    bus.onAudio = onAudio;
  }

  @override
  void setSram(Sram sram) {
    bus.sram = sram;
  }

  // Arrow buttons drive the analog stick; the remaining buttons use PIF bits.
  // The D-pad follows the buttons of the keys.
  @override
  List<PadButton> get buttons => [
        PadButton.up,
        PadButton.down,
        PadButton.left,
        PadButton.right,
        const PadButton('C-left'), // keyA
        const PadButton('C-down'), // keyS
        const PadButton('B'), // keyZ
        const PadButton('A'), // keyX
        const PadButton('Z'), // keyC
        const PadButton('L'), // keyQ
        const PadButton('C-up'), // keyW
        const PadButton('R'), // keyE
        const PadButton('Start'), // keyR
        const PadButton('C-right'), // keyD
        const PadButton('D-up'),
        const PadButton('D-down'),
        const PadButton('D-left'),
        const PadButton('D-right'),
      ];
  @override
  void padDown(int controllerId, PadButton k) => bus.pad(controllerId, k, true);
  @override
  void padUp(int controllerId, PadButton k) => bus.pad(controllerId, k, false);
  @override
  int programCounter(int cpuNo) => cpu.pc;
  @override
  int stackPointer(int cpuNo) => cpu.address(cpu.r[29]);
  @override
  (String, int) disasm(int cpuNo, int addr) {
    final opcode = bus.read(addr, 4);
    return (
      formatDisasm(addr.x8, opcode.x8, Vr4300Disasm.disasm(opcode, addr),
          codeWidth: 8),
      4
    );
  }

  @override
  TraceLog trace(int cpuNo) => TraceLog(
        cpu.pc,
        cpu.clocks,
        disasm(cpuNo, cpu.pc).$1,
        _traceRegisters(),
        [cpu.pc, ...cpu.r.map(cpu.address)],
        frame: _frame,
        scanline: bus.scanline,
        flow: traceMipsFlow(bus.read(cpu.pc, 4), cpu.pc, cpu.r, wide: true),
      );

  String _traceRegisters() => [
        registerRows([
          for (var i = 0; i < 32; i++) ('r$i', cpu.r[i]),
          ('HI', cpu.hi),
          ('LO', cpu.lo),
        ], bits: 64, perLine: 34),
        registerRows([
          for (var i = 0; i < 32; i++) ('CP0[$i]', cpu.cop0[i]),
        ], perLine: 32),
        registerRows([
          for (var i = 0; i < 32; i++)
            ('f$i', cpu.fpu.wide ? cpu.fpu.long(i) : cpu.fpu.word(i)),
        ], bits: cpu.fpu.wide ? 64 : 32, perLine: 32),
        'FCR31:${cpu.fpu.control.x8}',
      ].join(' ');
  @override
  String dump({
    bool showZeroPage = false,
    bool showSpriteVram = false,
    bool showStack = false,
    bool showApu = false,
  }) =>
      'N64 ${_rom?.title ?? ''} (Dart / task HLE)\n'
      'PC:${cpu.pc.hex} cycles:${cpu.clocks}\n'
      '${registerRows([
            for (var i = 0; i < 32; i++) ("r$i", cpu.r[i])
          ], bits: 64)}\n'
      '${registerRows([("HI", cpu.hi), ("LO", cpu.lo)], bits: 64)}\n'
      '${registerRows([
            for (var i = 0; i < 32; i++) ("CP0[$i]", cpu.cop0[i])
          ])}\n'
      '${registerRows([
            for (var i = 0; i < 32; i++)
              ("f$i", cpu.fpu.wide ? cpu.fpu.long(i) : cpu.fpu.word(i))
          ], bits: cpu.fpu.wide ? 64 : 32)}\n'
      'FCR31:${cpu.fpu.control.x8}\n'
      'RSP graphics:${graphics.tasks} triangles:${graphics.triangles} audio:${audio.tasks}\n'
      '${cpu.stopReason ?? ''}';
  @override
  int read(int cpuNo, int addr) => bus.read8(addr);
  @override
  List<int> get vram => bus.ram;
  @override
  ImageBuffer renderBg() => imageBuffer();
  @override
  List<String> spriteInfo() => [];
  @override
  ImageBuffer renderVram(bool useSecondBgColor, int paletteNo) => imageBuffer();
  @override
  ImageBuffer renderColorTable(int paletteNo) => ImageBuffer.empty();
}
