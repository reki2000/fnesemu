import 'dart:typed_data';

import '../../cdrom_drive.dart';
import '../../core.dart';
import '../../pad_button.dart';
import '../../sram.dart';
import '../../types.dart';
import '../../util/state.dart';
import 'allegrex.dart';
import 'disc.dart';
import 'elf.dart';
import 'kernel.dart';
import 'memory.dart';
import 'memstick.dart';

/// The handheld core: a MIPS32r2 processor with 32 MiB of memory, a
/// frame buffer display of 480 by 272 pixels and a high-level kernel that
/// runs ELF and PBP executables. A disc in the drive is mounted as an
/// ISO 9660 file system: the kernel serves its files to the guest, and
/// with no executable set the core boots the disc's boot file instead.
/// The memory stick is a writable file tree persisted through the
/// framework's backup storage, so saved data survives restarts.
/// The graphics processor is emulated in software (see the graphics
/// engine's own notes for its coverage), the audio channels are mixed
/// to the framework output and the multimedia coprocessor (VFPU) is
/// emulated with a few documented accuracy limits.
class Psp extends Core {
  static const _stateVersion = 4;
  static const _cpuHz = 222000000;
  static const _visibleLines = 272;

  final mem = PspMemory();
  late Allegrex cpu;
  PspKernel? _kernel;
  Uint8List? _rom;
  CdromDrive? _drive;
  PspDisc? _disc;

  /// The memory stick the kernel serves on ms0:; [setSram] binds it
  /// to the persistent storage.
  final memStick = PspMemStick();

  @override
  void setSram(Sram sram) => memStick.attach(sram);
  int _mediaId = 0;
  int _line = 0;
  int _nextLineAt = 0;
  final _pixels = Uint32List(480 * 272);

  void Function(AudioBuffer)? _audioOut;

  Psp() {
    cpu = Allegrex(mem);
    cpu.onSyscall = (code) => _kernel?.dispatch(cpu, code);
  }

  @override
  void onAudio(void Function(AudioBuffer) onAudio) {
    _audioOut = onAudio;
  }

  @override
  int get systemClockHz => _cpuHz;
  @override
  int get scanlinesInFrame => 286;
  @override
  int get clocksInScanline => _cpuHz ~/ 60 ~/ 286;
  @override
  int get clocksPerFrame => clocksInScanline * scanlinesInFrame;

  @override
  List<CpuInfo> get cpuInfos => [CpuInfo.ofR3000(0, 'main')];
  @override
  int programCounter(int cpuNo) => cpu.pc;
  @override
  int stackPointer(int cpuNo) => cpu.r[29];
  @override
  int get cpuClocks => cpu.clocks;

  /// What the guest wrote to its standard output and error streams,
  /// collected by the kernel for test harnesses and diagnostics.
  String get kernelLog => _kernel?.log.toString() ?? '';

  /// The import codes the kernel has no handler for, by call count.
  Map<int, int> get unknownCalls => _kernel?.unknownCalls ?? {};

  /// The buttons in the unified key order: S is the triangle, Z the
  /// square, X the cross, C the circle, Q and E are the shoulder buttons,
  /// the R slot is the home button, Enter is start and Shift is select.
  @override
  List<PadButton> get buttons => const [
        PadButton.up,
        PadButton.down,
        PadButton.left,
        PadButton.right,
        PadButton('^'),
        PadButton('#'),
        PadButton('x'),
        PadButton('o'),
        PadButton.none,
        PadButton.none,
        PadButton.none,
        PadButton('L'),
        PadButton('R'),
        PadButton.none,
        PadButton.none,
        PadButton.none,
        PadButton.none,
        PadButton('Home'),
        PadButton('Start'),
        PadButton('Select'),
      ];

  @override
  List<PadAxis> get axes => const [PadAxis.leftX, PadAxis.leftY];

  @override
  void setRom(Uint8List body) {
    _rom = body;
    _mediaId = _mediaIdOf(body);
    _load();
  }

  static int _mediaIdOf(Uint8List body) {
    var hash = 0x811c9dc5;
    for (final byte in body) {
      hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
    }
    return hash;
  }

  /// Mounts the disc in [drive] as the kernel's file system. When no
  /// executable was set, the disc's boot file becomes the executable;
  /// with one set, the running program simply gains the disc's files.
  @override
  void setCdromDrive(CdromDrive drive) {
    _drive = drive;
    PspDisc.mount(drive).then((disc) {
      if (!identical(_drive, drive) || disc == null) return;
      _disc = disc;
      _kernel?.disc = disc;
      if (_rom == null && disc.bootBytes != null) {
        _rom = disc.bootBytes;
        _mediaId = _mediaIdOf(_rom!);
        _load();
      }
    });
  }

  void _load() {
    mem.clear();
    cpu = Allegrex(mem);
    cpu.onSyscall = (code) => _kernel?.dispatch(cpu, code);
    final image = PspElf.load(mem, _rom!);
    final kernel = PspKernel(mem, padPort, image.end);
    kernel.audioSink = (samples) =>
        _audioOut?.call(AudioBuffer(44100, 2, samples));
    kernel.disc = _disc;
    kernel.memStick = memStick;
    _kernel = kernel;
    final main = kernel.startModule(image);
    cpu.copyFrom(main.state);
    _line = 0;
    _nextLineAt = clocksInScanline;
  }

  @override
  void reset() {
    if (_rom != null) _load();
  }

  static const _stepLine = 1;
  static const _stepStopped = 2;

  @override
  ExecResult exec(bool step) {
    final status = _advance();
    return ExecResult(cpu.clocks, status == _stepStopped, status == _stepLine);
  }

  /// Runs to the next scanline boundary. When no thread can run, time
  /// still passes: the clock jumps to the next wake-up or the boundary.
  int _advance() {
    final kernel = _kernel;
    if (kernel == null || kernel.exited) return _stepStopped;
    final target = _nextLineAt;
    while (cpu.clocks < target) {
      if (!kernel.runnable) {
        final wake = kernel.nextWake;
        var jump = target;
        if (wake != null && wake < jump) jump = wake;
        if (jump > cpu.clocks) cpu.clocks = jump;
        if (wake != null && cpu.clocks >= wake) kernel.wakeDue(cpu);
        if (!kernel.runnable && cpu.clocks >= target) break;
        if (kernel.exited) return _stepStopped;
        continue;
      }
      if (!cpu.step()) return _stepStopped;
      if (kernel.exited) return _stepStopped;
      final wake = kernel.nextWake;
      if (wake != null && cpu.clocks >= wake) kernel.wakeDue(cpu);
    }
    _nextLineAt += clocksInScanline;
    _line++;
    if (_line == _visibleLines) {
      kernel.onVblank(cpu);
      kernel.flushAudio(cpu.clocks);
    }
    if (_line >= scanlinesInFrame) _line = 0;
    return _stepLine;
  }

  @override
  ImageBuffer imageBuffer() {
    final kernel = _kernel;
    if (kernel == null) return ImageBuffer.empty();
    final base = kernel.fbAddr, stride = kernel.fbWidth;
    final format = kernel.fbFormat;
    final bpp = format == 3 ? 4 : 2;
    for (var y = 0; y < 272; y++) {
      for (var x = 0; x < 480; x++) {
        _pixels[y * 480 + x] = base == 0
            ? 0xff000000
            : _pixel(mem, base + (y * stride + x) * bpp, format);
      }
    }
    return ImageBuffer(480, 272, _pixels);
  }

  static int _pixel(PspMemory mem, int at, int format) {
    switch (format) {
      case 0: // 5 bits red, 6 green, 5 blue
        final v = mem.read16(at);
        final r5 = v & 0x1f, g6 = (v >> 5) & 0x3f, b5 = (v >> 11) & 0x1f;
        final r = (r5 << 3) | (r5 >> 2);
        final g = (g6 << 2) | (g6 >> 4);
        final b = (b5 << 3) | (b5 >> 2);
        return 0xff000000 | r | g << 8 | b << 16;
      case 1: // 5 bits per channel and one alpha bit
        final v = mem.read16(at);
        final r = (v & 0x1f) << 3 | (v & 0x1f) >> 2;
        final g = (v >> 5 & 0x1f) << 3 | (v >> 5 & 0x1f) >> 2;
        final b = (v >> 10 & 0x1f) << 3 | (v >> 10 & 0x1f) >> 2;
        return (v & 0x8000 != 0 ? 0xff000000 : 0) | r | g << 8 | b << 16;
      case 2: // 4 bits per channel
        final v = mem.read16(at);
        final r = (v & 0xf) << 4 | v & 0xf;
        final g = (v >> 4 & 0xf) << 4 | (v >> 4 & 0xf);
        final b = (v >> 8 & 0xf) << 4 | (v >> 8 & 0xf);
        final a = (v >> 12 & 0xf) << 4 | (v >> 12 & 0xf);
        return a << 24 | r | g << 8 | b << 16;
      default: // 8 bits per channel, stored red first
        return mem.read32(at);
    }
  }

  @override
  Uint8List saveState() {
    final kernel = _kernel;
    if (kernel == null) throw StateError('no media loaded');
    final writer = StateWriter('psp', _stateVersion, _mediaId);
    writer.section('mem');
    writer.bytes(mem.ram);
    writer.bytes(mem.vram);
    writer.bytes(mem.scratch);
    writer.section('cpu');
    _writeCpu(writer, cpu);
    writer.int32(cpu.clocks);
    writer.int32(_line);
    writer.int32(_nextLineAt);
    kernel.saveState(writer, cpu);
    return writer.take();
  }

  @override
  void loadState(Uint8List state) {
    final kernel = _kernel;
    if (kernel == null) throw StateError('no media loaded');
    final reader = StateReader(state, 'psp', _stateVersion, _mediaId);
    reader.section('mem');
    reader.bytesInto(mem.ram);
    reader.bytesInto(mem.vram);
    reader.bytesInto(mem.scratch);
    reader.section('cpu');
    _readCpu(reader, cpu);
    cpu.clocks = reader.int32();
    _line = reader.int32();
    _nextLineAt = reader.int32();
    kernel.loadState(reader);
    reader.end();
  }

  static void _writeCpu(StateWriter writer, AllegrexState state) {
    writer.ints(state.r);
    writer.bytes(state.f.buffer
        .asUint8List(state.f.offsetInBytes, state.f.lengthInBytes));
    writer.ints(state.cop0);
    writer.int32(state.hi);
    writer.int32(state.lo);
    writer.int32(state.pc);
    writer.int32(state.nextPc);
    writer.int32(state.fcr31);
    writer.int32(state.fcc);
    writer.boolean(state.linked);
    writer.bytes(state.v.buffer
        .asUint8List(state.v.offsetInBytes, state.v.lengthInBytes));
    writer.int32(state.vpfxs);
    writer.int32(state.vpfxt);
    writer.int32(state.vpfxd);
    writer.int32(state.vcc);
    writer.ints(state.rcx);
  }

  static void _readCpu(StateReader reader, AllegrexState state) {
    reader.intsInto(state.r);
    reader.bytesInto(state.f.buffer
        .asUint8List(state.f.offsetInBytes, state.f.lengthInBytes));
    reader.intsInto(state.cop0);
    state.hi = reader.int32();
    state.lo = reader.int32();
    state.pc = reader.int32();
    state.nextPc = reader.int32();
    state.fcr31 = reader.int32();
    state.fcc = reader.int32();
    state.linked = reader.boolean();
    reader.bytesInto(state.v.buffer
        .asUint8List(state.v.offsetInBytes, state.v.lengthInBytes));
    state.vpfxs = reader.int32();
    state.vpfxt = reader.int32();
    state.vpfxd = reader.int32();
    state.vcc = reader.int32();
    reader.intsInto(state.rcx);
  }

  @override
  String dump(
      {bool showZeroPage = false,
      bool showSpriteVram = false,
      bool showStack = false,
      bool showApu = false}) {
    final kernel = _kernel;
    if (kernel == null) return 'psp: no media';
    final thread = kernel.current;
    return 'pc 0x${cpu.pc.toRadixString(16)} thread ${thread?.name ?? '-'} '
        'vcount ${kernel.vcount} unknown ${kernel.unknownCalls.length}\n'
        '${kernel.log.toString()}';
  }
}
