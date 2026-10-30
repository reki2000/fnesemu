import 'dart:typed_data';

import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';

import '../../cdrom_drive.dart';
import '../../core.dart';
import '../../pad_button.dart';
import '../../sram.dart';
import '../../types.dart';
import '../../util/debug.dart';
import 'bus.dart';
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
import 'jit/ps2_jit.dart';
import 'r5900/r5900.dart';
import 'state.dart';

final _log = DebugLog('ps2');

class Ps2 extends Core {
  static const _systemClockHz = 294912000; // EE clock, 294.912MHz

  // Placeholder video timing until the GS exists: 60 frames of 262 lines
  static const _scanlines = 262;

  static const _deviceQuantum = 32;
  static const _vblankLine = 240;

  /// the EE recompiler, or null when the interpreter runs alone
  final Ps2Jit? jit;
  final Ps2Bus bus;
  late final R5900 cpu = R5900(bus, gpr: jit?.gpr);
  late EeIo io = _newIo();

  Ps2({bool jit = const bool.fromEnvironment('JIT', defaultValue: true)})
      : this._(jit ? Ps2Jit.create() : null);

  Ps2._(this.jit) : bus = Ps2Bus(ram: jit?.ram) {
    jit?.attach(cpu);
  }

  @override
  Iterable<JitDiagnostics> get jitDiagnostics =>
      jit == null ? const [] : [jit!.diagnostics];

  @override
  bool get jitEnabled => jit?.native ?? false;

  @override
  bool get jitSuspended => jit?.suspended ?? false;

  @override
  set jitSuspended(bool value) => jit?.suspended = value;

  @override
  int get jitClocks => jit?.compiledClocks ?? 0;

  @override
  void dispose() => jit?.dispose();

  late final IopMemory iopMemory = IopMemory(bus.bios);
  late final Iop iop = Iop(iopMemory);
  late IopIo iopIo = _newIopIo();

  IopIo _newIopIo() {
    final iopIo = IopIo(iopMemory, io.sif)
      ..sio2.pad = _pad
      ..sio2.card = _card
      ..cdvd.drive = _drive
      ..cdvd.discId = _discId
      ..cdvd.dvd = _dvd
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
    final io = EeIo(bus);
    bus.io = io;
    cpu
      ..vu0 = io.vu0
      ..cpCond0 = () => io.dmac.cpCond0;
    io.iopRam = iopMemory.ram;
    return io;
  }

  @override
  int get systemClockHz => _systemClockHz;

  @override
  int get scanlinesInFrame => _scanlines;

  @override
  int get clocksInScanline => _systemClockHz ~/ 60 ~/ _scanlines;

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

  late final _pad = Ps2Pad()..source = padPort;

  @override
  List<PadButton> get buttons => _pad.buttons;

  @override
  List<PadAxis> get axes => Ps2Pad.axes;

  CdromDrive? _drive;
  String? _discId;
  bool _dvd = false;

  /// Inserts [drive] and looks up the game ID in its SYSTEM.CNF and the
  /// media type in the background. The CDVD disc key carries this ID. The ID
  /// of a disc inserted later through the tray is not looked up.
  @override
  void setCdromDrive(CdromDrive drive) {
    _drive = drive;
    _discId = null;
    _dvd = false;
    iopIo.cdvd
      ..drive = drive
      ..discId = null
      ..dvd = false;
    isDvd(drive).then((dvd) {
      if (_drive != drive) return;
      _dvd = dvd;
      iopIo.cdvd.dvd = dvd;
    });
    readSystemCnf(drive).then((text) {
      if (_drive != drive || text == null) return;
      _discId = bootFileName(text);
      iopIo.cdvd.discId = _discId;
    });
  }

  @override
  void reset() {
    jit?.reset();
    cpu.reset();
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

  static const _stateVersion = 1;

  /// The BIOS bytes and the disc TOC. The disc contents beyond the TOC are
  /// not compared, so a state only fits the disc it was saved with.
  int get _media {
    var h = stateMediaHash(bus.bios);
    final toc = _drive?.status.toc;
    if (toc != null) {
      for (final t in toc.tracks) {
        h = (h ^ t.startLba) * 0x100000001b3;
        h = (h ^ t.sectors) * 0x100000001b3;
      }
      h = (h ^ toc.totalSectors) * 0x100000001b3;
    }
    return h;
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
    for (var i = 0; i < steps; i++) {
      iop.step();
    }
    iopIo.advanceTimers(steps);
    iopIo.service();
    if (iopIo.dirty) {
      iopIo.dirty = false;
      iop.setInterrupt(iopIo.asserted);
    }
  }

  void _endOfScanline() {
    io.timers.hblank();
    if (biosLoaded) iopIo.hblank();
    _line++;
    if (_line == _vblankLine) {
      io.intc.raise(Intc.vblankStart);
      io.gs.vblank();
      iopIo.raise(IopIrq.vblankStart);
    } else if (_line == _scanlines) {
      _line = 0;
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
    while (rendered < scanlines) {
      final limit = _nextScanlineClock < _nextDeviceClock
          ? _nextScanlineClock
          : _nextDeviceClock;
      final jit = this.jit;
      while (cpu.clocks < limit) {
        final before = cpu.clocks;
        if (jit != null && jit.run(limit - before)) {
          _result.elapsedClocks = cpu.clocks - before;
          if (io.intc.dirty || io.dmac.dirty) _updateInterruptLines();
          continue;
        }
        if (!cpu.step()) {
          _result
            ..stopped = true
            ..elapsedClocks = 0
            ..scanlineRendered = false;
          return _result;
        }
        _result.elapsedClocks = cpu.clocks - before;
        if (io.intc.dirty || io.dmac.dirty) _updateInterruptLines();
      }
      if (cpu.clocks >= _nextScanlineClock) {
        _nextScanlineClock += clocksInScanline;
        _endOfScanline();
        rendered++;
      }
      if (cpu.clocks >= _nextDeviceClock) _advanceDevices();
      if (io.intc.dirty || io.dmac.dirty) _updateInterruptLines();
    }
    _result
      ..stopped = false
      ..scanlineRendered = true;
    return _result;
  }

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
}
