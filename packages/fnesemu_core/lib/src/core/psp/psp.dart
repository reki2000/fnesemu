import 'dart:typed_data';

import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';

import '../../cdrom_drive.dart';
import '../../compute_sink.dart';
import '../../core.dart';
import '../../media_decoder.dart';
import '../../pad_button.dart';
import '../../sram.dart';
import '../../trace_flow.dart';
import '../../types.dart';
import '../../util/debug.dart';
import '../../util/disasm.dart';
import '../../util/state.dart';
import 'allegrex.dart';
import 'disasm.dart';
import 'disc.dart';
import 'elf.dart';
import 'ge_compute.dart';
import 'kernel.dart';
import 'memory.dart';
import 'memstick.dart';
import 'psp_jit.dart';

final _log = DebugLog('psp');

/// The handheld core: a MIPS32r2 processor with 32 MiB of memory, a
/// frame buffer display of 480 by 272 pixels and a high-level kernel that
/// runs ELF and PBP executables. A disc in the drive is mounted as an
/// ISO 9660 file system: the kernel serves its files to the guest, and
/// with no executable set the core boots the disc's boot file instead.
/// The memory stick is a writable file tree persisted through the
/// framework's backup storage, so saved data survives restarts.
/// The graphics processor is emulated in software (see the graphics
/// engine's own notes for its coverage) or rasterizes on the host GPU
/// with a compute sink, the audio channels are mixed
/// to the framework output and the multimedia coprocessor (VFPU) is
/// emulated with a few documented accuracy limits.
class Psp extends Core {
  static const _stateVersion = 9;
  static const _visibleLines = 272;

  final PspJit? _jit;
  final PspMemory mem;
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

  Psp({bool jit = const bool.fromEnvironment('JIT', defaultValue: true)})
      : this._(jit ? PspJit.create() : null);

  Psp._(this._jit) : mem = _jit?.memory ?? PspMemory();

  @override
  bool get jitEnabled => _jit?.native ?? false;

  @override
  bool get jitSuspended => _jit?.suspended ?? false;

  @override
  set jitSuspended(bool value) => _jit?.suspended = value;

  @override
  int get jitClocks => _jit?.compiledClocks ?? 0;

  @override
  Iterable<JitDiagnostics> get jitDiagnostics => [
        if (_jit case final jit?) jit.diagnostics,
      ];

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
    _gpu?.dispose();
    _gpu = null;
    _jit?.dispose();
  }

  GeCompute? _gpu;
  ComputeSink? _computeSink;

  /// Rasterizes on [sink] when it waits for the GPU by itself. On a sink
  /// that does not, the graphics engine draws in software.
  @override
  set computeSink(ComputeSink? sink) {
    if (identical(sink, _computeSink)) return;
    _computeSink = sink;
    _gpu?.detach();
    _gpu = null;
    _kernel?.ge.compute = null;
    if (sink == null || !sink.waits) return;
    try {
      // blocks compiled from video memory would map its pages
      _jit?.reset();
      final gpu = GeCompute(mem, sink)..onPage = _jit?.setVramPage;
      gpu.attach();
      _gpu = gpu;
      _kernel?.ge.compute = gpu;
      _log.info('drawing on ${sink.name}');
    } catch (e) {
      _log.warn('no compute GE on ${sink.name}: $e');
    }
  }

  Allegrex _createCpu() => Allegrex(mem,
      regs: _jit?.regs, fpr: _jit?.fpr, vfpr: _jit?.vfpr)
      ..onSyscall = (code) => _kernel?.dispatch(cpu, code);

  void _load() {
    _jit?.reset();
    mem.clear();
    // the cleared memory replaces what the GPU holds
    _gpu?.reload();
    final image = PspElf.load(mem, _rom!);
    cpu = _createCpu();
    final kernel = PspKernel(mem, padPort, image.end);
    kernel.audioSink = (samples) =>
        _audioOut?.call(AudioBuffer(44100, 2, samples));
    kernel.disc = _disc;
    kernel.memStick = memStick;
    kernel.mediaDecoder = _mediaDecoder;
    kernel.ge.compute = _gpu;
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
    final jit = step ? null : _jit;
    var executed = false;
    while (cpu.clocks < _nextLineAt) {
      var wake = kernel.nextWake;
      if (wake != null && cpu.clocks >= wake) {
        kernel.wakeDue(cpu);
        wake = kernel.nextWake;
      }
      if (!kernel.runnable) {
        cpu.clocks = wake != null && wake < _nextLineAt ? wake : _nextLineAt;
        continue;
      }
      executed = true;
      var interpret = true;
      if (jit != null) {
        final deadline = wake != null && wake < _nextLineAt ? wake : _nextLineAt;
        if (cpu.clocks < deadline) {
          jit.run(cpu, deadline - cpu.clocks);
          interpret = cpu.clocks < deadline;
        }
      }
      if (interpret && (!cpu.step() || kernel.exited)) {
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
    if (_line >= scanlinesInFrame) {
      _line = 0;
      // after the frame buffer swaps that follow the vblank
      _gpu?.endFrame(kernel.fbAddr, kernel.fbWidth, kernel.fbFormat);
    }
    return ExecResult(cpu.clocks, false, true)..executed0 = executed;
  }

  @override
  ImageBuffer imageBuffer() {
    final kernel = _kernel;
    if (kernel == null) return ImageBuffer.empty();
    final base = kernel.fbAddr, stride = kernel.fbWidth;
    final format = kernel.fbFormat;
    final bpp = format == 3 ? 4 : 2;
    // the GPU shows the frame buffer at the end of the last frame but one
    if (_gpu?.display case final copy?) {
      final stride = _gpu!.displayStride, format = _gpu!.displayFormat;
      final bpp = format == 3 ? 4 : 2;
      for (var y = 0; y < 272; y++) {
        for (var x = 0; x < 480; x++) {
          final at = (y * stride + x) * bpp;
          final word = copy[at >> 2];
          _pixels[y * 480 + x] = _color(
              bpp == 4 ? word : (word >> ((at & 2) * 8)) & 0xffff, format);
        }
      }
      return ImageBuffer(480, 272, _pixels);
    }
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
  static int _pixel(PspMemory mem, int at, int format) =>
      _color(format == 3 ? mem.read32(at) : mem.read16(at), format);

  /// The opaque color of the frame buffer value [v].
  static int _color(int v, int format) {
    switch (format) {
      case 0: // 5 bits red, 6 green, 5 blue
        final r5 = v & 0x1f, g6 = (v >> 5) & 0x3f, b5 = (v >> 11) & 0x1f;
        final r = (r5 << 3) | (r5 >> 2);
        final g = (g6 << 2) | (g6 >> 4);
        final b = (b5 << 3) | (b5 >> 2);
        return 0xff000000 | r | g << 8 | b << 16;
      case 1: // 5 bits per channel and one alpha bit
        final r = (v & 0x1f) << 3 | (v & 0x1f) >> 2;
        final g = (v >> 5 & 0x1f) << 3 | (v >> 5 & 0x1f) >> 2;
        final b = (v >> 10 & 0x1f) << 3 | (v >> 10 & 0x1f) >> 2;
        return 0xff000000 | r | g << 8 | b << 16;
      case 2: // 4 bits per channel
        final r = (v & 0xf) << 4 | v & 0xf;
        final g = (v >> 4 & 0xf) << 4 | (v >> 4 & 0xf);
        final b = (v >> 8 & 0xf) << 4 | (v >> 8 & 0xf);
        return 0xff000000 | r | g << 8 | b << 16;
      default: // 8 bits per channel, stored red first
        return 0xff000000 | v;
    }
  }

  @override
  Uint8List saveState() {
    final kernel = _kernel;
    if (kernel == null) throw StateError('no media loaded');
    _gpu?.sync();
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
    _jit?.reset();
    reader.section('mem');
    reader.bytesInto(mem.ram);
    reader.bytesInto(mem.vram);
    reader.bytesInto(mem.scratch);
    _gpu?.reload();
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
            'prio 0x${t.priority.toRadixString(16)} status ${t.status} pc 0x${t.state.pc.toRadixString(16)} '
            'ra 0x${t.state.r[31].toRadixString(16)}'
            '${_waitDetail(t)}\n').join()}'
        '${kernel.unknownCallLines.map((line) => '  $line\n').join()}'
        '${kernel.log.toString()}';
  }

  /// What a blocked thread waits on, and the kernel call it made last.
  static String _waitDetail(PspThread t) {
    final wait = switch (t.status) {
      PspThreadStatus.waitEvent => ' event ${t.waitEvent} '
          'bits 0x${t.waitBits.toRadixString(16)} mode ${t.waitMode}',
      PspThreadStatus.waitSema => ' sema ${t.waitSema}',
      _ => '',
    };
    final call = t.lastCall;
    return call == null
        ? wait
        : '$wait last ${call.library} 0x${call.nid.toRadixString(16)}';
  }
}
