import 'dart:typed_data';

import '../../cdrom_drive.dart';
import '../../core.dart';
import '../../media_decoder.dart';
import '../../pad_button.dart';
import '../../sram.dart';
import '../../trace_flow.dart';
import '../../types.dart';
import '../../util/disasm.dart';
import '../../util/state.dart';
import 'allegrex.dart';
import 'disasm.dart';
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
  static const _stateVersion = 8;
  static const _visibleLines = 272;

  final mem = PspMemory();
  late Allegrex cpu = _createCpu();
  PspKernel? _kernel;
  Uint8List? _rom;
  CdromDrive? _drive;
  PspDisc? _disc;

  /// The memory stick the kernel serves on ms0:; [setSram] binds it
  /// to the persistent storage.
  final memStick = PspMemStick();

  @override
  void setSram(Sram sram) => memStick.attach(sram);

  MediaDecoder? _mediaDecoder;

  @override
  set mediaDecoder(MediaDecoder? decoder) {
    _mediaDecoder = decoder;
    _kernel?.mediaDecoder = decoder;
  }
  int _mediaId = 0;
  int _line = 0;
  int _nextLineAt = 0;
  final _pixels = Uint32List(480 * 272);

  void Function(AudioBuffer)? _audioOut;

  @override
  void onAudio(void Function(AudioBuffer) onAudio) {
    _audioOut = onAudio;
  }

  @override
  int get systemClockHz => Allegrex.clockHz;
  @override
  int get scanlinesInFrame => 286;
  @override
  int get clocksInScanline =>
      systemClockHz ~/ PspKernel.displayHz ~/ scanlinesInFrame;
  @override
  int get clocksPerFrame => clocksInScanline * scanlinesInFrame;

  @override
  List<CpuInfo> get cpuInfos => [CpuInfo.ofR3000(0, 'main')];
  @override
  int programCounter(int cpuNo) => cpu.pc;
  @override
  int stackPointer(int cpuNo) => cpu.r[29];

  @override
  (String, int) disasm(int cpuNo, int addr) {
    addr &= 0xfffffffc;
    final word = mem.read32(addr);
    return (
      formatDisasm(_hex8(addr), _hex8(word), AllegrexDisasm.disasm(word, addr),
          codeWidth: 8),
      4
    );
  }

  @override
  TraceLog trace(int cpuNo) {
    final word = mem.read32(cpu.pc);
    final registers = [for (var i = 0; i < 32; i++) cpu.r[i]];
    return TraceLog(
        cpu.pc,
        cpu.clocks,
        disasm(0, cpu.pc).$1.padRight(46),
        [
          for (var i = 1; i < 32; i++)
            '${AllegrexDisasm.regs[i]}:${_hex8(cpu.r[i])}',
        ].join(' '),
        registers,
        instructionKey: _hex8(word),
        flow: traceMipsFlow(word, cpu.pc, registers));
  }

  @override
  int read(int cpuNo, int addr) => mem.read8(addr);

  static String _hex8(int value) =>
      (value & 0xffffffff).toRadixString(16).padLeft(8, '0');
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
  Future<void> setCdromDrive(CdromDrive drive) async {
    _drive = drive;
    final discId = drive.status.discId;
    _disc = null;
    _kernel?.disc = null;
    if (!drive.status.isReady) return;
    final disc = await PspDisc.mount(drive, readBoot: _rom == null);
    if (!identical(_drive, drive) || drive.status.discId != discId) return;
    final boot = disc?.bootBytes;
    if (_rom == null) {
      if (boot == null) throw const FormatException('No PSP boot executable');
      setRom(boot);
    }
    _disc = disc;
    _kernel?.disc = disc;
  }

  @override
  void dispose() {
    _drive = null;
  }

  Allegrex _createCpu() => Allegrex(mem)
      ..onSyscall = (code) => _kernel?.dispatch(cpu, code);

  void _load() {
    mem.clear();
    final image = PspElf.load(mem, _rom!);
    cpu = _createCpu();
    final kernel = PspKernel(mem, padPort, image.end);
    kernel.audioSink = (samples) =>
        _audioOut?.call(AudioBuffer(44100, 2, samples));
    kernel.disc = _disc;
    kernel.memStick = memStick;
    kernel.mediaDecoder = _mediaDecoder;
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

  @override
  ExecResult exec(bool step) {
    final kernel = _kernel;
    if (kernel == null || kernel.exited) {
      return ExecResult(cpu.clocks, true, false)..executed0 = false;
    }
    var executed = false;
    while (cpu.clocks < _nextLineAt) {
      final wake = kernel.nextWake;
      if (wake != null && cpu.clocks >= wake) kernel.wakeDue(cpu);
      if (!kernel.runnable) {
        final nextWake = kernel.nextWake;
        cpu.clocks = nextWake != null && nextWake < _nextLineAt
            ? nextWake
            : _nextLineAt;
        continue;
      }
      executed = true;
      if (!cpu.step() || kernel.exited) {
        return ExecResult(cpu.clocks, true, false);
      }
      final nextWake = kernel.nextWake;
      if (nextWake != null && cpu.clocks >= nextWake) kernel.wakeDue(cpu);
      if (step && cpu.clocks < _nextLineAt) {
        return ExecResult(cpu.clocks, false, false);
      }
    }
    _nextLineAt += clocksInScanline;
    _line++;
    if (_line == _visibleLines) {
      kernel.onVblank(cpu);
      kernel.flushAudio(cpu.clocks);
    }
    if (_line >= scanlinesInFrame) _line = 0;
    return ExecResult(cpu.clocks, false, true)..executed0 = executed;
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

  /// The color of a frame buffer pixel. The display shows no alpha, so
  /// every pixel is opaque whatever its alpha bits hold.
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
        return 0xff000000 | r | g << 8 | b << 16;
      case 2: // 4 bits per channel
        final v = mem.read16(at);
        final r = (v & 0xf) << 4 | v & 0xf;
        final g = (v >> 4 & 0xf) << 4 | (v >> 4 & 0xf);
        final b = (v >> 8 & 0xf) << 4 | (v >> 8 & 0xf);
        return 0xff000000 | r | g << 8 | b << 16;
      default: // 8 bits per channel, stored red first
        return 0xff000000 | mem.read32(at);
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
    cpu.saveState(writer);
    writer.int64(cpu.clocks);
    writer.int32(_line);
    writer.int64(_nextLineAt);
    kernel.saveState(writer, cpu);
    return writer.take();
  }

  @override
  void loadState(Uint8List state) {
    final kernel = _kernel;
    if (kernel == null) throw StateError('no media loaded');
    final reader = StateReader(state, 'psp', _stateVersion, _mediaId,
        minimumVersion: 4);
    reader.section('mem');
    reader.bytesInto(mem.ram);
    reader.bytesInto(mem.vram);
    reader.bytesInto(mem.scratch);
    reader.section('cpu');
    cpu.loadState(reader);
    final legacy = reader.version == 4;
    cpu.clocks = legacy ? reader.int32().toUnsigned(32) : reader.int64();
    _line = reader.int32();
    _nextLineAt = legacy ? reader.int32().toUnsigned(32) : reader.int64();
    kernel.loadState(reader);
    reader.end();
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
    final failed = cpu.failedAt < 0
        ? ''
        : 'failed at 0x${cpu.failedAt.toRadixString(16)} word '
            '0x${cpu.failedWord.toRadixString(16).padLeft(8, '0')}\n';
    return 'pc 0x${cpu.pc.toRadixString(16)} thread ${thread?.name ?? '-'} '
        'vcount ${kernel.vcount} unknown ${kernel.unknownCalls.length}\n'
        '$failed'
        '${kernel.threads.values.map((t) => '  thread ${t.id} ${t.name} '
            'status ${t.status} pc 0x${t.state.pc.toRadixString(16)} '
            'ra 0x${t.state.r[31].toRadixString(16)}\n').join()}'
        '${kernel.unknownCallLines.map((line) => '  $line\n').join()}'
        '${kernel.log.toString()}';
  }
}
