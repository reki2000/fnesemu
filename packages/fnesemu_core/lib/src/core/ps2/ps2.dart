import 'dart:typed_data';

import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';

import '../../cdrom_drive.dart';
import '../../compute_sink.dart';
import '../../core.dart';
import '../../pad_button.dart';
import '../../sram.dart';
import '../../trace_flow.dart';
import '../../types.dart';
import '../../util/debug.dart';
import '../../util/disasm.dart';
import '../../util/int.dart';
import '../../util/register_dump.dart';
import 'bus.dart';
import 'disasm.dart';
import 'ee_idle_loop.dart';
import 'ee_io.dart';
import 'elf.dart';
import 'intc.dart';
import 'iop/iop.dart';
import 'iop/iop_io.dart';
import 'iop/iop_memory.dart';
import 'iop/memory_card.dart';
import 'iop/pad.dart';
import 'iop/spu2.dart';
import 'iso9660.dart';
import 'jit/iop_jit.dart';
import 'jit/ps2_jit.dart';
import 'jit/vu_jit.dart';
import 'r5900/r5900.dart';
import 'state.dart';
import 'vu.dart';
import 'vu_disasm.dart';

final _log = DebugLog('ps2');

class Ps2 extends Core {
  static const _systemClockHz = 294912000; // EE clock, 294.912MHz

  // NTSC timing: 262 lines of 9370 bus clocks, with the vertical blank from
  // line 240 (ps2tek)
  static const _scanlines = 262, _busClocksInScanline = 9370;

  /// The EE clocks between two advances of the devices and the IOP. The
  /// devices see the EE, and the EE sees their interrupts, at this
  /// granularity; each advance costs about as much as tens of compiled EE
  /// instructions.
  static const _deviceQuantum = 128;
  static const _vblankLine = 240;

  /// The EE clocks of an uncached read of an EE register, as seen by
  /// [Intc.upcoming]. The exact bus timing is not documented. It only has
  /// to cover a polling loop of a few instructions.
  static const _registerReadClocks = 32;

  /// the EE recompiler, or null when the interpreter runs alone
  final Ps2Jit? jit;

  /// the IOP recompiler, created with the EE one
  final IopJit? iopJit;

  /// the VU1 recompiler, created with the EE one
  final VuJit? vuJit;

  /// the recompiler of the VU0 micro programs, created with the EE one
  final VuJit? vu0Jit;
  final Ps2Bus bus;
  late final R5900 cpu = R5900(bus,
      gpr: jit?.gpr,
      fpr: jit?.fpr,
      multiply: jit?.multiply,
      fpuControl: jit?.fpuControl);
  late EeIo io = _newIo();

  /// a polling loop of the EE that [runFrame] skips
  late final _idle = EeIdleLoop(cpu);

  Ps2({bool jit = const bool.fromEnvironment('JIT', defaultValue: true)})
      : this._(jit ? Ps2Jit.create() : null, jit ? IopJit.create() : null,
            jit && _vuJit ? VuJit.create() : null,
            jit && _vuJit ? VuJit.create(index: 0) : null);

  static const _vuJit = bool.fromEnvironment('VU_JIT', defaultValue: true);

  Ps2._(this.jit, this.iopJit, this.vuJit, this.vu0Jit)
      : bus = Ps2Bus(ram: jit?.ram, scratch: jit?.scratch) {
    jit?.attach(cpu);
    iopJit?.attach(iop, iopMemory);
  }

  @override
  Iterable<JitDiagnostics> get jitDiagnostics => [
        if (jit != null) jit!.diagnostics,
        if (iopJit != null) iopJit!.diagnostics,
      ];

  @override
  bool get jitEnabled =>
      (jit?.native ?? false) ||
      (iopJit?.native ?? false) ||
      (vuJit?.native ?? false) ||
      (vu0Jit?.native ?? false);

  @override
  bool get jitSuspended =>
      (jit?.suspended ?? false) ||
      (iopJit?.suspended ?? false) ||
      (vuJit?.suspended ?? false) ||
      (vu0Jit?.suspended ?? false);

  @override
  set jitSuspended(bool value) {
    jit?.suspended = value;
    iopJit?.suspended = value;
    vuJit?.suspended = value;
    vu0Jit?.suspended = value;
  }

  @override
  int get jitClocks =>
      (jit?.compiledClocks ?? 0) + (iopJit?.compiledClocks ?? 0);

  @override
  void dispose() {
    _releaseCompute();
    jit?.dispose();
    iopJit?.dispose();
    vuJit?.dispose();
    vu0Jit?.dispose();
  }

  late final IopMemory iopMemory = IopMemory(bus.bios, ram: iopJit?.ram);
  late final Iop iop = Iop(iopMemory, regs: iopJit?.regs);
  late IopIo iopIo = _newIopIo();

  IopIo _newIopIo() {
    final iopIo = IopIo(iopMemory, io.sif)
      ..sio2.pad = _pad
      ..sio2.card = _card
      ..cdvd.drive = _drive
      ..cdvd.discId = _discId
      ..cdvd.dvd = _dvd
      ..cdvd.onDiscChange = _lookUpDisc
      ..spu2.onAudio =
          (samples) => _onAudio(AudioBuffer(Spu2.sampleHz, 2, samples));
    io.cdvd = iopIo.cdvd;
    return iopIo;
  }

  void Function(AudioBuffer) _onAudio = (_) {};

  @override
  void onAudio(void Function(AudioBuffer) onAudio) => _onAudio = onAudio;

  /// The memory card in the first slot. It keeps its own memory until
  /// [setSram] gives it a store.
  Ps2MemoryCard _card = Ps2MemoryCard.formatted();

  @override
  void setSram(Sram sram) {
    sram.init(StorageKey.of('ps2', StorageKey.sram, 'memcard1'),
        Ps2MemoryCard.formattedImage());
    _card = Ps2MemoryCard(sram.read8, sram.write8);
    iopIo.sio2.card = _card;
  }

  /// the IOP only runs when a BIOS provides its program
  bool biosLoaded = false;

  /// entry point of the loaded ELF, or null while no executable is loaded
  int? entry;

  int _nextScanlineClock = 0;
  int _lastDeviceClock = 0;
  int _nextDeviceClock = _deviceQuantum;
  int _busRemainder = 0;
  int _iopFraction = 0;
  int _line = 0;
  final _result = ExecResult(0, false, false);

  @override
  void setBiosFiles(List<Uint8List> files) {
    if (files.isEmpty) return;
    final bios = files.first;
    bus.bios.fillRange(0, bus.bios.length, 0);
    bus.bios.setAll(
        0,
        bios.length > bus.bios.length
            ? bios.sublist(0, bus.bios.length)
            : bios);
    biosLoaded = true;
    reset();
  }

  EeIo _newIo() {
    final io = EeIo(bus, vu0: jit?.newVu0(vu0Jit), vu1: vuJit?.newVu());
    bus.io = io;
    cpu
      ..vu0 = io.vu0
      ..cpCond0 = () => io.dmac.cpCond0;
    io.iopRam = iopMemory.ram;
    io.intc.upcoming = _upcomingIntc;
    io.gs.vblankUpcoming = () => _upcomingIntc() == 1 << Intc.vblankStart;
    io.gs.computeSink = _computeSink;
    return io;
  }

  @override
  int get clocksPerFrame => clocksInScanline * scanlinesInFrame;

  @override
  int get systemClockHz => _systemClockHz;

  @override
  int get scanlinesInFrame => _scanlines;

  @override
  int get clocksInScanline => _busClocksInScanline * 2;

  @override
  int get cpuClocks => cpu.clocks;

  /// loads an ELF executable into main memory and points the CPU at it
  @override
  void setRom(Uint8List body) {
    final elf = Elf.parse(body);
    final ram = bus.ram;
    ram.fillRange(0, ram.length, 0);
    for (final segment in elf.segments) {
      final start = segment.address & (ram.length - 1);
      if (segment.address >= ram.length ||
          start + segment.memorySize > ram.length) {
        throw RangeError('ELF segment at 0x${segment.address.toRadixString(16)}'
            ' is outside main memory');
      }
      ram.setAll(start, segment.data);
    }
    entry = elf.entry;
    reset();
    _log.info('loaded ELF, entry 0x${elf.entry.toRadixString(16)}');
  }

  @override
  ImageBuffer imageBuffer() => io.gs.image();

  ComputeSink? _computeSink;

  @override
  set computeSink(ComputeSink? sink) {
    _computeSink = sink;
    io.gs.computeSink = sink;
  }

  /// Releases the program of the GS on the sink, if it has one.
  void _releaseCompute() {
    if (_computeSink != null) io.gs.computeSink = null;
  }

  late final _pad = Ps2Pad()..source = padPort;

  @override
  List<PadButton> get buttons => _pad.buttons;

  @override
  List<PadAxis> get axes => Ps2Pad.axes;

  CdromDrive? _drive;
  String? _discId;
  bool _dvd = false;

  /// Inserts [drive] and looks up the disc in it with [_lookUpDisc]. The
  /// CDVD looks up a disc changed later through the tray again.
  @override
  void setCdromDrive(CdromDrive drive) {
    _drive = drive;
    drive.clearEvents();
    iopIo.cdvd.drive = drive;
    _lookUpDisc();
  }

  /// Looks up the game ID in SYSTEM.CNF and the media type of the disc in
  /// the drive in the background. The CDVD disc key carries this ID. A
  /// result that arrives after the disc changed again is dropped.
  void _lookUpDisc() {
    final drive = _drive;
    if (drive == null) return;
    _discId = null;
    _dvd = false;
    iopIo.cdvd
      ..discId = null
      ..dvd = false;
    final status = drive.status;
    if (!status.isReady) return;
    final disc = status.discId;
    bool current() => _drive == drive && drive.status.discId == disc;
    discLookup = Future.wait([
      isDvd(drive).then((dvd) {
        if (!current()) return;
        _dvd = dvd;
        iopIo.cdvd.dvd = dvd;
      }),
      readSystemCnf(drive).then((text) {
        if (!current() || text == null) return;
        _discId = bootFileName(text);
        iopIo.cdvd.discId = _discId;
      }),
    ]);
  }

  /// completes when the media type and the disc ID of the drive are known
  Future<void> discLookup = Future.value();

  @override
  void reset() {
    _idle.reset();
    jit?.reset();
    iopJit?.reset();
    vuJit?.reset();
    vu0Jit?.reset();
    cpu.reset();
    // the new GS takes the sink; the old one releases its program
    _releaseCompute();
    io = _newIo();
    iop.reset();
    _pad.reset();
    _card.reset();
    iopMemory.ram.fillRange(0, iopMemory.ram.length, 0);
    iopIo = _newIopIo();
    _iopFraction = 0;
    final start = entry;
    if (start != null) cpu.jumpTo(start);
    _nextScanlineClock = clocksInScanline;
    _lastDeviceClock = 0;
    _nextDeviceClock = _deviceQuantum;
    _busRemainder = 0;
    _line = 0;
  }

  // ---- state ----

  static const _stateVersion = 4;

  /// The BIOS bytes and the disc TOC. The disc contents beyond the TOC are
  /// not compared, so a state only fits the disc it was saved with.
  int get _media {
    final toc = _drive?.status.toc;
    return stateMediaHashAll(stateMediaHash(bus.bios), [
      if (toc != null) ...[
        for (final t in toc.tracks) ...[t.startLba, t.sectors],
        toc.totalSectors,
      ],
    ]);
  }

  /// Saves the state at a frame boundary. The drive's sector cache is not
  /// saved, so a restored run may wait for sectors that the original run
  /// had cached.
  @override
  Uint8List saveState() {
    final w = StateWriter('ps2', _stateVersion, _media);
    w.section('ps2');
    w.ints([
      _nextScanlineClock, _lastDeviceClock, _nextDeviceClock, _busRemainder, //
      _iopFraction, _line, entry ?? -1,
    ]);
    w.boolean(biosLoaded);
    w.typed(bus.ram);
    w.typed(bus.scratch);
    w.typed(iopMemory.ram);
    w.typed(iopMemory.scratch);
    cpu.saveState(w);
    io.saveState(w);
    iop.saveState(w);
    iopIo.saveState(w);
    return w.take();
  }

  /// A state that fails after its header leaves the core partly loaded;
  /// reset it before running.
  @override
  void loadState(Uint8List state) {
    final s = StateReader(state, 'ps2', _stateVersion, _media);
    s.section('ps2');
    final v = s.fields(7, 'ps2');
    _idle.reset();
    _nextScanlineClock = v[0];
    _lastDeviceClock = v[1];
    _nextDeviceClock = v[2];
    _busRemainder = v[3];
    _iopFraction = v[4];
    _line = v[5];
    entry = v[6] < 0 ? null : v[6];
    biosLoaded = s.boolean();
    s.typed(bus.ram);
    s.typed(bus.scratch);
    s.typed(iopMemory.ram);
    s.typed(iopMemory.scratch);
    cpu.loadState(s);
    io.loadState(s);
    iop.loadState(s);
    iopIo.loadState(s);
    s.end();
    // compiled code may hold the old memory
    jit?.reset();
    iopJit?.reset();
    vuJit?.reset();
    vu0Jit?.reset();
    io.intc.dirty = io.dmac.dirty = true;
    _updateInterruptLines();
    iop.setInterrupt(iopIo.asserted);
  }

  /// advances the timers by the CPU clocks since the last call; the bus runs
  /// at half the CPU clock
  void _advanceDevices() {
    final elapsed = cpu.clocks - _lastDeviceClock + _busRemainder;
    _busRemainder = elapsed & 1;
    io.timers.advance(elapsed >> 1);
    io.dmac
      ..advance(elapsed >> 1)
      ..service();
    io.ipu.service();
    if (biosLoaded) _advanceIop(cpu.clocks - _lastDeviceClock);
    _lastDeviceClock = cpu.clocks;
    _nextDeviceClock = cpu.clocks + _deviceQuantum;
  }

  /// the IOP runs at 1/8 of the EE clock
  void _advanceIop(int eeClocks) {
    _iopFraction += eeClocks;
    final steps = _iopFraction >> 3;
    _iopFraction &= 7;
    // An interrupt raised below is taken at the next step.
    var remaining = steps > 0 && iop.idle(steps) ? 0 : steps;
    while (remaining > 0) {
      final ran = iopJit?.run(remaining) ?? 0;
      if (ran > 0) {
        remaining -= ran;
      } else {
        iop.step();
        remaining--;
      }
    }
    iopIo.advanceTimers(steps);
    iopIo.service();
    if (iopIo.dirty) {
      iopIo.dirty = false;
      iop.setInterrupt(iopIo.asserted);
    }
  }

  /// the vblank bit that the next scanline raises when it comes within an
  /// EE register read
  int _upcomingIntc() {
    if (_nextScanlineClock - cpu.clocks > _registerReadClocks) return 0;
    final next = _line + 1;
    if (next == _vblankLine) return 1 << Intc.vblankStart;
    if (next == _scanlines) return 1 << Intc.vblankEnd;
    return 0;
  }

  void _endOfScanline() {
    io.timers.hblank();
    if (biosLoaded) iopIo.hblank();
    _line++;
    if (_line == _vblankLine) {
      io.timers.vblank(true);
      io.intc.raise(Intc.vblankStart);
      io.gs.vblank();
      iopIo.raise(IopIrq.vblankStart);
    } else if (_line == _scanlines) {
      _line = 0;
      io.timers.vblank(false);
      io.intc.raise(Intc.vblankEnd);
      iopIo.raise(IopIrq.vblankEnd);
    }
  }

  /// The same as calling [exec] until [scanlines] scanlines are rendered,
  /// with the checks of the scanline and device clocks done once per batch
  /// of instructions up to the nearer of them.
  @override
  ExecResult runFrame(int scanlines) {
    final cpu = this.cpu;
    var rendered = 0;
    final gs = io.gs;
    while (rendered < scanlines) {
      // A GPU that does not wait brings the memory of the Gs before the
      // core reads a local to host transfer, and before the vblank.
      if (gs.syncRequested) {
        if (gs.computeWait() != null) {
          return _waitForCompute(scanlines - rendered);
        }
        gs.syncCompute();
      }
      final limit = _nextScanlineClock < _nextDeviceClock
          ? _nextScanlineClock
          : _nextDeviceClock;
      final jit = this.jit;
      while (cpu.clocks < limit) {
        final before = cpu.clocks;
        if (_idle.skip(limit, _nextScanlineClock - _registerReadClocks) ||
            _idle.skipSpin(limit)) {
          _result.elapsedClocks = cpu.clocks - before;
          continue;
        }
        if (jit != null && jit.run(limit - before)) {
          _result.elapsedClocks = cpu.clocks - before;
          if (io.intc.dirty || io.dmac.dirty) _updateInterruptLines();
          if (gs.syncRequested) break;
          continue;
        }
        final at = cpu.pc;
        if (!cpu.step()) {
          _result
            ..stopped = true
            ..elapsedClocks = 0
            ..scanlineRendered = false
            ..linesLeft = 0;
          return _result;
        }
        _idle.observe(at);
        _result.elapsedClocks = cpu.clocks - before;
        if (io.intc.dirty || io.dmac.dirty) _updateInterruptLines();
        if (gs.syncRequested) break;
      }
      if (cpu.clocks >= _nextScanlineClock) {
        if (_line + 1 == _vblankLine && gs.computeWait() != null) {
          return _waitForCompute(scanlines - rendered);
        }
        _nextScanlineClock += clocksInScanline;
        _endOfScanline();
        rendered++;
      }
      if (cpu.clocks >= _nextDeviceClock) _advanceDevices();
      if (io.intc.dirty || io.dmac.dirty) _updateInterruptLines();
    }
    _result
      ..stopped = false
      ..scanlineRendered = true
      ..linesLeft = 0;
    return _result;
  }

  ExecResult _waitForCompute(int linesLeft) => _result
    ..stopped = false
    ..scanlineRendered = false
    ..linesLeft = linesLeft;

  @override
  Future<void>? computeWait() => io.gs.computeWait();

  void _updateInterruptLines() {
    io.intc.dirty = io.dmac.dirty = false;
    cpu.setInterruptLine(R5900.ipIntc, io.intc.asserted);
    cpu.setInterruptLine(R5900.ipDmac, io.dmac.asserted);
  }

  @override
  ExecResult exec(bool step) {
    final before = cpu.clocks;
    final ok = cpu.step();
    _result.stopped = !ok;
    _result.elapsedClocks = cpu.clocks - before;
    _result.scanlineRendered = false;
    if (ok && cpu.clocks >= _nextScanlineClock) {
      _nextScanlineClock += clocksInScanline;
      _result.scanlineRendered = true;
      _endOfScanline();
    }
    if (cpu.clocks >= _nextDeviceClock) _advanceDevices();
    if (io.intc.dirty || io.dmac.dirty) _updateInterruptLines();
    return _result;
  }

  @override
  List<CpuInfo> get cpuInfos =>
      const [
        CpuInfo(0, 'R5900', 32),
        CpuInfo(1, 'IOP', 32),
        CpuInfo(2, 'VU0', 16),
        CpuInfo(3, 'VU1', 16),
      ];

  /// The VU of debugger CPU [cpuNo] 2 or 3, or null for the others.
  Vu? _debugVu(int cpuNo) => switch (cpuNo) {
        2 => io.vu0,
        3 => io.vu1,
        _ => null,
      };

  @override
  int programCounter(int cpuNo) => switch (cpuNo) {
        1 => iop.pc,
        2 => io.vu0.pc * 8,
        3 => io.vu1.pc * 8,
        _ => cpu.pc,
      };

  @override
  int stackPointer(int cpuNo) => switch (cpuNo) {
        1 => iop.r[29],
        2 || 3 => 0,
        _ => cpu.reg(29) & 0xffffffff,
      };

  @override
  int read(int cpuNo, int addr) {
    final vu = _debugVu(cpuNo);
    if (vu != null) {
      final word = vu.data[(addr >> 2) % vu.data.length];
      return (word >> ((addr & 3) * 8)) & 0xff;
    }
    return cpuNo == 1 ? iopMemory.read8(addr) : bus.read8(addr);
  }

  @override
  (String, int) disasm(int cpuNo, int addr) {
    final vu = _debugVu(cpuNo);
    if (vu != null) {
      addr &= ~7;
      final low = vu.readMicro(addr >> 2), high = vu.readMicro((addr >> 2) + 1);
      return (
        formatDisasm(addr.x4, '${high.x8} ${low.x8}',
            VuDisasm.pair(low, high, addr),
            codeWidth: 17),
        8
      );
    }
    addr &= ~3;
    if (cpuNo == 1) {
      final op = iopMemory.read32(addr);
      return (
        formatDisasm(addr.x8, op.x8, Ps2Disasm.iop(op, addr), codeWidth: 8),
        4
      );
    }
    final op = bus.read32(addr);
    return (
      formatDisasm(addr.x8, op.x8, Ps2Disasm.ee(op, addr), codeWidth: 8),
      4
    );
  }

  @override
  List<int> get vram => io.gs.mem.bytes;

  @override
  ImageBuffer renderBg() => imageBuffer();

  @override
  ImageBuffer renderVram(bool useSecondBgColor, int paletteNo) => imageBuffer();

  @override
  ImageBuffer renderColorTable(int paletteNo) => ImageBuffer.empty();

  @override
  List<String> spriteInfo() => const [];

  String _traceIopRegisters() => [
        registerRows(
            [for (var i = 0; i < 32; i++) ('r$i', iop.r[i])],
            perLine: 32),
        'HI:${iop.hi.x8} LO:${iop.lo.x8} SR:${iop.readCop0(Iop.cop0Status).x8} CAUSE:${iop.readCop0(Iop.cop0Cause).x8} EPC:${iop.readCop0(Iop.cop0Epc).x8}',
      ].join(' ');

  String _traceEeRegisters() => [
        registerRows([
          for (var i = 0; i < 32; i++) ('r$i', cpu.reg(i)),
          ('HI', cpu.hi),
          ('LO', cpu.lo),
          ('HI1', cpu.hi1),
          ('LO1', cpu.lo1),
        ], bits: 64, perLine: 36),
        registerRows([
          for (var i = 0; i < 32; i++) ('CP0[$i]', cpu.cop0[i]),
        ], perLine: 32),
        'SA:${cpu.sa.x2}',
      ].join(' ');

  @override
  TraceLog trace(int cpuNo) {
    final vu = _debugVu(cpuNo);
    if (vu != null) {
      return TraceLog(
        vu.pc * 8,
        vu.cycles,
        disasm(cpuNo, vu.pc * 8).$1,
        [for (var i = 1; i < 16; i++) 'vi$i:${(vu.vi[i] & 0xffff).x4}']
            .join(' '),
        [vu.pc, for (var i = 0; i < 16; i++) vu.vi[i] & 0xffff],
      );
    }
    if (cpuNo == 1) {
      final opcode = iopMemory.read32(iop.pc & ~3);
      return TraceLog(
        iop.pc,
        iop.clocks,
        disasm(cpuNo, iop.pc).$1,
        _traceIopRegisters(),
        [iop.pc, ...iop.r],
        flow: traceMipsFlow(opcode, iop.pc, iop.r),
      );
    }
    final opcode = bus.read32(cpu.pc & ~3);
    return TraceLog(
      cpu.pc,
      cpu.clocks,
      disasm(cpuNo, cpu.pc).$1,
      _traceEeRegisters(),
      [cpu.pc, for (var i = 0; i < 32; i++) cpu.reg(i) & 0xffffffff],
      flow: traceMipsFlow(
        opcode,
        cpu.pc,
        [for (var i = 0; i < 32; i++) cpu.reg(i)],
        wide: true,
      ),
    );
  }

  @override
  String dump(
      {bool showZeroPage = false,
      bool showSpriteVram = false,
      bool showStack = false,
      bool showApu = false}) {
    final eeDisasm = disasm(0, cpu.pc).$1;
    final iopDisasm = disasm(1, iop.pc).$1;
    return 'PS2 (EE R5900 + IOP)\n'
        'EE $eeDisasm clocks:${cpu.clocks}\n'
        '${registerRows([for (var i = 0; i < 32; i++) ("r$i", cpu.reg(i))], bits: 64)}\n'
        '${registerRows([("HI", cpu.hi), ("LO", cpu.lo), ("HI1", cpu.hi1), ("LO1", cpu.lo1)], bits: 64)} SA:${cpu.sa.x2}\n'
        '${registerRows([for (var i = 0; i < 32; i++) ("CP0[$i]", cpu.cop0[i])])}\n'
        '${registerRows([for (var i = 0; i < 32; i++) ("f$i", cpu.fpr[i])])}\n'
        'FACC:${cpu.facc.x8} FCR31:${cpu.fcr31.x8}\n'
        'INTC stat:${io.intc.stat.x8} mask:${io.intc.mask.x8}\n'
        'DMAC stat:${io.dmac.stat.x8} ctrl:${io.dmac.ctrl.x8}\n'
        'GS CSR:${io.gs.readPrivileged(0x1000).toRadixString(16).padLeft(16, "0")}\n'
        'IOP $iopDisasm clocks:${iop.clocks} (BIOS loaded: $biosLoaded)\n'
        '${registerRows([for (var i = 0; i < 32; i++) ("iop.r$i", iop.r[i])])}\n'
        'IOP HI:${iop.hi.x8} LO:${iop.lo.x8} SR:${iop.readCop0(Iop.cop0Status).x8} CAUSE:${iop.readCop0(Iop.cop0Cause).x8} EPC:${iop.readCop0(Iop.cop0Epc).x8}';
  }
}
