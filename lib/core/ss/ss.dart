import 'dart:typed_data';

import 'package:fnesemu/util/debug.dart';
import 'package:fnesemu/util/int.dart';

import '../core.dart';
import '../disc.dart';
import '../pad_button.dart';
import '../sram.dart';
import '../types.dart';
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

/// SS core
class Ss extends Core {
  final bus = Bus();
  final pad = Pad();

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

  Ss({SsCpu Function(SsCpuBus bus, bool master)? cpuFactory}) {
    final factory = cpuFactory ?? (b, m) => Sh2(b, master: m);
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
        const CpuInfo(0, "SH-2 master", 32, traceDiffs: 2),
        const CpuInfo(1, "SH-2 slave", 32, traceDiffs: 2),
        CpuInfo.ofM68(2, "68000"),
      ];

  // timing
  int _lastClocks = 0;
  int _nextLineClock = 0;
  int _line = 0;
  int _soundClockRemainder = 0;

  final _result = ExecResult(0, false, false);

  // master clocks executed at once before the other processors catch up
  static const _sliceClocks = 32;

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

  void _runSlice(bool step) {
    final m = master;
    final lineEnd = _nextLineClock;
    final target = step
        ? m.clocks + 1
        : (m.clocks + _sliceClocks < lineEnd ? m.clocks + _sliceClocks : lineEnd);

    if (!(step ? m.step() : m.run(target))) {
      debugLog("ss: master sh-2 unimplemented instruction at ${m.pc.x8}");
      _result.stopped = true;
      return;
    }

    final clocks = m.clocks;

    if (_slaveEnabled && slave.clocks < clocks) {
      final s = slave;
      if (!(step ? s.step() : s.run(clocks))) {
        debugLog("ss: slave sh-2 unimplemented instruction at ${s.pc.x8}");
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
        scu.dsp.exec(elapsed >> 1);
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
  void setDisc(Disc disc) => cdblock.setDisc(disc);

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
    return "${master.disasm(master.pc).$1}\n${master.dump()}\n"
        "slave(${_slaveEnabled ? "on" : "off"}): ${slave.dump()}\n"
        "${scu.dump()}\n${smpc.dump()}\n${vdp1.dump()}\n${vdp2.dump()}\n"
        "${scsp.dump()}\n${cdblock.dump()}";
  }

  @override
  (String, int) disasm(int cpuNo, int addr) => cpuNo == 2
      ? ("${addr.x6}: 68k", 2)
      : _cpu(cpuNo).disasm(addr);

  @override
  int programCounter(int cpuNo) => cpuNo == 2 ? scsp.cpu.pc : _cpu(cpuNo).pc;

  @override
  int stackPointer(int cpuNo) => cpuNo == 2 ? scsp.cpu.a[7] : _cpu(cpuNo).sp;

  @override
  TraceLog trace(int cpuNo) {
    final cpu = _cpu(cpuNo);
    return TraceLog(cpu.pc, cpu.clocks, cpu.disasm(cpu.pc).$1.padRight(40),
        cpu.dump().replaceAll("\n", " "), [],
        frame: vdp2.frame, scanline: _line);
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
