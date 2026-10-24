import 'dart:typed_data';

import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';

import '../../cdrom_drive.dart';
import '../../components/m68k/disasm.dart';
import '../../components/sh2/jit/jit.dart';
import '../../core.dart';
import '../../pad_button.dart';
import '../../sram.dart';
import '../../state.dart';
import '../../trace_flow.dart';
import '../../types.dart';
import '../../util/debug.dart';
import '../../util/disasm.dart';
import '../../util/int.dart';
import '../../video_debug.dart';
import 'bus.dart';
import 'cdblock.dart';
import 'cpu.dart';
import 'pad.dart';
import 'scsp.dart';
import 'scu.dart';
import 'sh2/sh2.dart';
import 'smpc.dart';
import 'vdp1.dart';
import 'vdp2.dart';

final _log = DebugLog('ss');

/// SS core
class Ss extends Core {
  @override
  bool get hasPatternTables => true;

  @override
  List<DebugVideoLayer> get videoLayers => vdp2.debugVideoLayers;
  @override
  List<DebugPatternTable> get patternTables => vdp2.debugPatternTables;

  late final Bus bus;
  final pad = Pad();

  @override
  Iterable<JitDiagnostics> get jitDiagnostics sync* {
    for (final cpu in [master, slave]) {
      if (cpu is Sh2 && cpu.jit != null) yield cpu.jit!.diagnostics;
    }
  }

  @override
  bool get jitEnabled => master is Sh2 && (master as Sh2).jit?.native == true;
  @override
  bool get jitSuspended =>
      master is Sh2 && ((master as Sh2).jit?.suspended ?? false);
  @override
  set jitSuspended(bool value) {
    for (final cpu in [master, slave]) {
      if (cpu is Sh2) cpu.jit?.suspended = value;
    }
  }
  @override
  int get cpuClocks => master.clocks + slave.clocks;
  @override
  int get jitClocks =>
      (master is Sh2 ? (master as Sh2).jit?.compiledClocks ?? 0 : 0) +
      (slave is Sh2 ? (slave as Sh2).jit?.compiledClocks ?? 0 : 0);
  @override
  void dispose() {
    if (slave is Sh2) (slave as Sh2).jit?.dispose();
    if (master is Sh2) (master as Sh2).jit?.dispose();
  }

  late final SsCpu master;
  late final SsCpu slave;

  late final Smpc smpc;
  late final Scu scu;
  final vdp1 = Vdp1();
  final vdp2 = Vdp2();
  final scsp = Scsp();
  final cdblock = CdBlock();

  bool _slaveEnabled = false;

  static const _masterClockHz = 28636360; // 352 dot mode, NTSC
  static const _soundClockHz = Scsp.cpuClockHz;

  Ss(
      {SsCpu Function(SsCpuBus bus, bool master)? cpuFactory,
      bool jit = const bool.fromEnvironment('JIT', defaultValue: false),
      bool jitMacLong = true,
      bool jitMacWord = true,
      bool jitFtcsr = true,
      bool jitIdleGuards = true,
      int sliceClocks = 64})
      : _sliceClocks = sliceClocks {
    if (sliceClocks <= 0) throw RangeError.value(sliceClocks, 'sliceClocks');
    final owner = cpuFactory == null && jit
        ? Sh2Jit.create(
            macLong: jitMacLong,
            macWord: jitMacWord,
            idleGuards: jitIdleGuards)
        : null;
    bus = Bus(allocate: owner?.rt.alloc);
    final factory = cpuFactory ??
        (b, m) {
          final compiler = m
              ? owner
              : owner == null
                  ? null
                  : Sh2Jit.create(
                      macLong: jitMacLong,
                      macWord: jitMacWord,
                      idleGuards: jitIdleGuards);
          if (compiler != null) {
            final rt = owner!.rt;
            compiler.map(0, bus.bios.length, bus.bios,
                writable: false, owner: rt);
            compiler.map(0x80000, bus.bios.length, bus.bios,
                writable: false, owner: rt);
            compiler.map(0x200000, bus.wramL.length, bus.wramL, owner: rt);
            for (var at = 0x6000000; at < 0x8000000; at += bus.wramH.length) {
              compiler.map(at, bus.wramH.length, bus.wramH, owner: rt);
            }
          }
          return Sh2(b, master: m, jit: compiler, jitFtcsr: jitFtcsr);
        };
    master = factory(bus, true);
    slave = factory(bus, false);

    smpc = Smpc(pad);
    scu = Scu(bus);

    bus.master = master;
    bus.slave = slave;
    bus.smpc = smpc;
    bus.scu = scu;
    bus.vdp1 = vdp1;
    bus.vdp2 = vdp2;
    bus.scsp = scsp;
    bus.cdblock = cdblock;

    vdp2.vdp1 = vdp1;

    for (final cpu in [master, slave]) {
      if (cpu is Sh2) {
        cpu.setFastFetch(wramHigh: bus.wramHData, rom: bus.biosData);
      }
    }

    // interrupt wiring
    scu.onMasterIrl = master.setIrl;
    scu.onSlaveIrl = slave.setIrl;
    master.onIrlAck = scu.acknowledgeMaster;
    slave.onIrlAck = scu.acknowledgeSlave;

    vdp1.onDrawEnd = scu.onSpriteDrawEnd;
    scsp.onMainInterrupt = scu.onSoundRequest;
    cdblock.onInterrupt = () => scu.setExternal(0);

    smpc.onInterrupt = scu.onSystemManager;
    smpc.onSlaveCpu = (on) {
      if (on) slave.reset();
      _slaveEnabled = on;
    };
    smpc.onSoundCpu = scsp.setCpuEnabled;
    smpc.onNmi = master.nmi;
    smpc.onSystemReset = reset;
    smpc.onClockChange = (_) {};
  }

  @override
  int get systemClockHz => _masterClockHz;

  @override
  int get scanlinesInFrame => Vdp2.scanlinesNtsc;

  @override
  int get clocksInScanline => _masterClockHz ~/ 60 ~/ scanlinesInFrame;

  @override
  List<CpuInfo> get cpuInfos => [
        const CpuInfo(0, "SH-2 master", 32),
        const CpuInfo(1, "SH-2 slave", 32),
        CpuInfo.ofM68(2, "68000"),
      ];

  // timing
  int _lastClocks = 0;
  int _nextLineClock = 0;
  int _line = 0;
  int _soundClockRemainder = 0;

  final _result = ExecResult(0, false, false);

  // master clocks executed at once before the other processors catch up
  final int _sliceClocks;

  @override
  ExecResult exec(bool step) {
    _result.scanlineRendered = false;
    _result.stopped = false;
    _result.executed0 = true;
    _result.executed1 = false;

    // step: 1 instruction, otherwise: until the end of the scanline
    do {
      _runSlice(step);
    } while (!step && !_result.scanlineRendered && !_result.stopped);

    final clocks = master.clocks;
    _result.elapsedClocks = clocks;

    debugStatus.clock = clocks;
    debugStatus.frame = vdp2.frame;
    debugStatus.scanline = _line;
    debugStatus.pc = master.pc;

    return _result;
  }

  /// same as exec(false) called until `scanlines` lines are rendered
  @override
  ExecResult runFrame(int scanlines) {
    final result = _result;
    result.stopped = false;
    result.executed0 = true;

    int lines = 0;
    while (lines < scanlines) {
      // a new exec(false)
      result.scanlineRendered = false;
      result.executed1 = false;
      do {
        _runSlice(false);
      } while (!result.scanlineRendered && !result.stopped);
      if (result.stopped) break;
      lines++;
    }

    final clocks = master.clocks;
    result.elapsedClocks = clocks;

    debugStatus.clock = clocks;
    debugStatus.frame = vdp2.frame;
    debugStatus.scanline = _line;
    debugStatus.pc = master.pc;

    return result;
  }

  void _runSlice(bool step) {
    final m = master;
    final lineEnd = _nextLineClock;
    final target = step
        ? m.clocks + 1
        : (m.clocks + _sliceClocks < lineEnd
            ? m.clocks + _sliceClocks
            : lineEnd);

    if (!(step ? m.step() : m.run(target))) {
      _log.warnc(() => "master sh-2 unimplemented instruction at ${m.pc.x8}");
      _result.stopped = true;
      return;
    }

    final clocks = m.clocks;

    if (_slaveEnabled && slave.clocks < clocks) {
      final s = slave;
      if (!(step ? s.step() : s.run(clocks))) {
        _log.warnc(() => "slave sh-2 unimplemented instruction at ${s.pc.x8}");
        _result.stopped = true;
      }
      _result.executed1 = true;
    }

    final elapsed = clocks - _lastClocks;
    _lastClocks = clocks;

    if (elapsed > 0) {
      smpc.exec(elapsed);
      vdp1.exec(elapsed);
      cdblock.exec(elapsed);
      if (scu.dsp.executing) {
        scu.dsp.exec(elapsed.shr1);
      }
      _execSound(elapsed);
    }

    if (clocks >= _nextLineClock) {
      _nextLineClock += clocksInScanline;
      _runLine();
      _result.scanlineRendered = true;
    }
  }

  void _runLine() {
    final h = vdp2.displayLines;

    if (_line == 0) {
      vdp2.vblank = false;
      scu.onVBlankOut();
    }

    vdp2.line = _line;
    vdp2.hblank = false;

    if (_line < h) {
      if (vdp2.doubleDensity) {
        // one field per frame, the other field keeps the previous lines
        vdp2.renderLine(_line * 2 + (vdp2.oddField ? 1 : 0));
      } else {
        vdp2.renderLine(_line);
      }
    }

    vdp2.hblank = true;
    scu.onHBlankIn();

    if (_line == h - 1) {
      vdp2.vblank = true;
      vdp1.onVBlankIn();
      scu.onVBlankIn();
    }

    _line++;
    if (_line >= scanlinesInFrame) {
      _line = 0;
      vdp2.frame++;
      vdp2.oddField = !vdp2.oddField;
    }
  }

  // ---- sound ----

  final _audioBuffer = Float32List(1024 * 2);
  int _audioIndex = 0;
  void Function(AudioBuffer) _onAudio = (_) {};

  void _execSound(int masterClocks) {
    final total = masterClocks * _soundClockHz + _soundClockRemainder;
    final soundClocks = total ~/ _masterClockHz;
    _soundClockRemainder = total % _masterClockHz;

    final start = _audioIndex;
    _audioIndex = scsp.exec(soundClocks, _audioBuffer, _audioIndex);

    // mix CD-DA
    for (int i = start; i < _audioIndex; i++) {
      if (cdblock.cddaRead != cdblock.cddaWrite) {
        final s = cdblock.cdda[cdblock.cddaRead] / 32768.0;
        cdblock.cddaRead = (cdblock.cddaRead + 1) % cdblock.cdda.length;
        _audioBuffer[i] = (_audioBuffer[i] + s).clamp(-1.0, 1.0);
      }
    }

    // flush before the buffer overflows in the next slice
    if (_audioIndex >= _audioBuffer.length - 64) {
      _onAudio(AudioBuffer(Scsp.sampleHz, 2,
          Float32List.fromList(_audioBuffer.sublist(0, _audioIndex))));
      _audioIndex = 0;
    }
  }

  @override
  void onAudio(void Function(AudioBuffer) onAudio) => _onAudio = onAudio;

  // ---- state ----

  /// Saves everything but the media, which the caller identifies. Work RAM
  /// is written in place on load because compiled code may share it.
  void saveDeviceState(StateWriter w) {
    w.section('ss');
    w.ints([_lastClocks, _nextLineClock, _line, _soundClockRemainder]);
    w.boolean(_slaveEnabled);
    w.floats(_audioBuffer.sublist(0, _audioIndex));
    w.bytes(bus.wramL);
    w.bytes(bus.wramH);
    w.bytes(_sram.data);
    pad.saveState(w);
    smpc.saveState(w);
    scu.saveState(w);
    vdp1.saveState(w);
    vdp2.saveState(w);
    scsp.saveState(w);
    cdblock.saveState(w);
    for (final cpu in [master, slave]) {
      if (cpu is! Sh2) throw UnsupportedError('state of a non-SH-2 CPU');
      cpu.saveState(w);
    }
  }

  void loadDeviceState(StateReader s) {
    s.section('ss');
    final v = s.ints();
    if (v.length != 4) throw const StateMismatch('ss scheduler state layout');
    _lastClocks = v[0];
    _nextLineClock = v[1];
    _line = v[2];
    _soundClockRemainder = v[3];
    _slaveEnabled = s.boolean();
    final audio = s.floats();
    _audioBuffer.setAll(0, audio);
    _audioIndex = audio.length;
    s.bytesInto(bus.wramL);
    s.bytesInto(bus.wramH);
    final backup = s.bytes();
    if (backup.length != _sram.data.length) {
      throw const StateMismatch('different backup memory size');
    }
    _sram.data.setAll(0, backup);
    pad.loadState(s);
    smpc.loadState(s);
    scu.loadState(s);
    vdp1.loadState(s);
    vdp2.loadState(s);
    scsp.loadState(s);
    cdblock.loadState(s);
    for (final cpu in [master, slave]) {
      if (cpu is! Sh2) throw UnsupportedError('state of a non-SH-2 CPU');
      cpu.loadState(s);
    }
  }

  static const _stateVersion = 1;

  /// The BIOS bytes and the disc TOC. Disc contents beyond the TOC are not
  /// compared, so a state is only meaningful for the disc it was saved
  /// with. The drive's sector cache is not saved: a restored run may wait
  /// for sectors that the original run had cached.
  int get _media {
    var h = stateMediaHash(bus.bios);
    final toc = cdblock.disc.status.toc;
    for (final v in [
      toc.totalSectors,
      for (final t in toc.tracks) ...[
        t.number,
        t.isAudio ? 1 : 0,
        t.startLba,
        t.sectors
      ],
    ]) {
      h = (h ^ v) * 0x100000001b3;
    }
    return h;
  }

  @override
  Uint8List saveState() {
    final w = StateWriter('ss', _stateVersion, _media);
    saveDeviceState(w);
    return w.take();
  }

  /// A state that fails after its header leaves the core partly loaded;
  /// reset it before running.
  @override
  void loadState(Uint8List state) {
    final s = StateReader(state, 'ss', _stateVersion, _media);
    loadDeviceState(s);
    s.end();
  }

  // ---- media ----

  late Sram _sram;

  @override
  void setRom(Uint8List body) {
    bus.bios.fillRange(0, bus.bios.length, 0);
    bus.bios.setRange(
        0, body.length < bus.bios.length ? body.length : bus.bios.length, body);

    _sram.init("ss_bram", Bus.blankBram);
    bus.bramRead = _sram.read8;
    bus.bramWrite = _sram.write8;
  }

  @override
  void setBiosFiles(List<Uint8List> files) {
    if (files.isNotEmpty) {
      setRom(files.first);
    }
  }

  @override
  void setCdromDrive(CdromDrive drive) => cdblock.setDisc(drive);

  @override
  void setSram(Sram sram) => _sram = sram;

  @override
  void reset() {
    bus.reset();
    smpc.reset();
    scu.reset();
    vdp1.reset();
    vdp2.reset();
    scsp.reset();
    cdblock.reset();
    pad.reset();

    master.reset();
    slave.reset();
    _slaveEnabled = false;

    _lastClocks = master.clocks;
    _nextLineClock = master.clocks + clocksInScanline;
    _line = 0;
    _soundClockRemainder = 0;
    _audioIndex = 0;
  }

  @override
  ImageBuffer imageBuffer() => vdp2.imageBuffer;

  @override
  void padDown(int controllerId, PadButton k) => pad.keyDown(controllerId, k);

  @override
  void padUp(int controllerId, PadButton k) => pad.keyUp(controllerId, k);

  @override
  List<PadButton> get buttons => pad.buttons;

  // ---- debug ----

  SsCpu _cpu(int no) => no == 1 ? slave : master;

  @override
  String dump(
      {bool showZeroPage = false,
      bool showSpriteVram = false,
      bool showStack = false,
      bool showApu = false}) {
    return "SH-2 master\n${master.disasm(master.pc).$1}\n${master.dump()}\n"
        "slave(${_slaveEnabled ? "on" : "off"}): ${slave.dump()}\n"
        "68000 sound\n${scsp.cpu.dump()}\n${scu.dump()}\n${smpc.dump()}\n${vdp1.dump()}\n${vdp2.dump()}\n"
        "${scsp.dump()}\n${cdblock.dump()}";
  }

  @override
  (String, int) disasm(int cpuNo, int addr) =>
      cpuNo == 2 ? _soundDisasm(addr) : _cpu(cpuNo).disasm(addr);

  (String, int) _soundDisasm(int address) {
    final words =
        List.generate(6, (i) => scsp.bus.read16((address + i * 2).mask24));
    try {
      final (text, length) = Disasm().disasm(words, address);
      return (
        formatDisasm(
            address.x6, words.take(length).map((v) => v.x4).join(' '), text,
            codeWidth: 29),
        length * 2
      );
    } catch (_) {
      return (
        formatDisasm(address.x6, words.first.x4, 'dc.w \$${words.first.x4}',
            codeWidth: 29),
        2
      );
    }
  }

  @override
  int programCounter(int cpuNo) => cpuNo == 2 ? scsp.cpu.pc : _cpu(cpuNo).pc;

  @override
  int stackPointer(int cpuNo) => cpuNo == 2 ? scsp.cpu.a[7] : _cpu(cpuNo).sp;

  @override
  TraceLog trace(int cpuNo) {
    final pc = programCounter(cpuNo);
    int word(int address) =>
        read(cpuNo, address) << 8 | read(cpuNo, address + 1);
    final flow = cpuNo == 2
        ? traceM68kFlow(word(pc), pc, extension: word(pc + 2))
        : traceSh2Flow(word(pc), pc);
    return _trace(cpuNo).withFlow(flow);
  }

  TraceLog _trace(int cpuNo) {
    if (cpuNo == 2) {
      final cpu = scsp.cpu;
      return TraceLog(
          cpu.pc,
          cpu.clocks,
          _soundDisasm(cpu.pc).$1,
          cpu.dump().replaceAll('\n', ' '),
          [for (var i = 0; i < 8; i++) cpu.a[i], ...cpu.d, cpu.sr],
          frame: vdp2.frame,
          scanline: _line);
    }
    final cpu = _cpu(cpuNo);
    return TraceLog(
        cpu.pc,
        cpu.clocks,
        cpu.disasm(cpu.pc).$1.padRight(40),
        cpu.dump().replaceAll("\n", " "),
        cpu is Sh2
            ? [...cpu.r, cpu.sr, cpu.pr, cpu.gbr, cpu.vbr, cpu.mach, cpu.macl]
            : [],
        frame: vdp2.frame,
        scanline: _line);
  }

  @override
  List<int> get vram => vdp2.vram;

  @override
  int read(int cpuNo, int addr) =>
      cpuNo == 2 ? scsp.bus.read8(addr) : bus.read8(addr);

  @override
  ImageBuffer renderBg() => ImageBuffer.empty();

  @override
  List<String> spriteInfo() => [];

  @override
  ImageBuffer renderVram(bool useSecondBgColor, int paletteNo) =>
      ImageBuffer.empty();

  @override
  ImageBuffer renderColorTable(int paletteNo) => ImageBuffer.empty();
}
