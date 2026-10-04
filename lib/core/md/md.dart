// Dart imports:
import 'dart:typed_data';

import 'package:fnesemu/core/md/vdp_debug.dart';
import 'package:fnesemu/core/md/vdp_renderer.dart';
import 'package:fnesemu/core/md/ym2612.dart';
import 'package:fnesemu/core/md/z80/z80_disasm.dart';
import 'package:fnesemu/util/double.dart';
import 'package:fnesemu/util/int.dart';

import '../core.dart';
import '../cdrom_drive.dart';
import '../disc.dart';
import '../pad_button.dart';
import '../sram.dart';
import '../types.dart';
import 'bus_m68.dart';
import 'cd/md_cdrom.dart';
import '32x/md_32x.dart';
import '32x/bus_m68.dart';
import '32x/sh2/sh2.dart';
import 'bus_z80.dart';
import 'm68/m68.dart';
import 'm68/m68_disasm.dart';
import 'sn76489.dart';
import 'vdp.dart';
import 'z80/z80.dart';

class Md implements Core {
  MdCdrom? get cdrom => busM68.cdrom;
  final bool cdBoot;
  final bool expansionBoot;
  Md32x? get expansion =>
      busM68 is Md32xBus ? (busM68 as Md32xBus).adapter : null;
  int get _shCpuBase => cdrom == null ? 2 : 3;
  bool _isShCpu(int no) =>
      expansion != null && no >= _shCpuBase && no < _shCpuBase + 2;
  Sh2 _shCpu(int no) => expansion!.cpus[no - _shCpuBase];

  void setExpansionBootRoms(
      {required Uint8List main,
      required Uint8List master,
      required Uint8List slave}) {
    _attach32x();
    expansion!.setBootRoms(main: main, master: master, slave: slave);
  }

  Disc? _disc;
  Sram? _sram;

  late final M68 cpuM68;
  late final Z80 cpuZ80;

  late final BusZ80 busZ80;
  late BusM68 busM68;

  final vdp = Vdp();
  final psg = Sn76489();
  final fm = Ym2612();

  static const masterClockNtscHz = 53693175;
  static const masterClockPalHz = 53203424;
  static const masterClockHz = masterClockNtscHz;

  static const m68ClockHz = masterClockHz ~/ 7;
  static const z80ClockHz = masterClockHz ~/ 15;

  static const _regionDomestic = 0x00;
  static const _regionOversea = 0x80;
  static const _regionOverseaPal = 0xc0;

  @override
  int get systemClockHz => m68ClockHz;

  @override
  int get scanlinesInFrame => Vdp.height + Vdp.retrace;

  @override
  int get clocksInScanline => m68ClockHz ~/ 59.97 ~/ scanlinesInFrame;

  @override
  get cpuInfos => [
        CpuInfo.ofM68(0, "68000"),
        CpuInfo.ofZ80(1, "Z80"),
        if (cdrom != null) CpuInfo.ofM68(2, "MD CD-ROM 68000"),
        if (expansion != null) CpuInfo(_shCpuBase, "SH-2 master", 32),
        if (expansion != null) CpuInfo(_shCpuBase + 1, "SH-2 slave", 32),
      ];

  Md({this.cdBoot = false, this.expansionBoot = false}) {
    busM68 = BusM68();
    if (expansionBoot) busM68 = Md32xBus(Md32x(), busM68);
    busZ80 = BusZ80();

    cpuM68 = M68(busM68);
    cpuZ80 = Z80(busZ80);

    busM68.cpu = cpuM68;
    busM68.busZ80 = busZ80;
    busM68.vdp = vdp;
    busM68.psg = psg;
    busM68.fm = fm;

    vdp.bus = busM68;
    vdp.busZ80 = busZ80;

    busZ80.cpu = cpuZ80;
    busZ80.busM68 = busM68;
    busZ80.psg = psg;
    busZ80.ym2612 = fm;
  }

  void _attach32x() {
    if (expansion != null) return;
    final adapter = Md32x()..setRom(busM68.rom.rom);
    _replaceMainBus(Md32xBus(adapter, busM68));
  }

  void _replaceMainBus(BusM68 next) {
    next.region = busM68.region;
    next.cdrom = busM68.cdrom;
    next.cpu = cpuM68;
    next.busZ80 = busZ80;
    next.vdp = vdp;
    next.psg = psg;
    next.fm = fm;
    busM68 = next;
    cpuM68.bus = next;
    vdp.bus = next;
    busZ80.busM68 = next;
  }

  int _clocks = 0;
  int _nextScanClock = 0;

  bool _waitHBlank = false;

  /// exec 1 cpu instruction and render VDO / FM-PSG if enough cycles passed
  /// returns current CPU cycle and bool - false when unimplemented instruction is found
  @override
  ExecResult exec(bool step) {
    final result = ExecResult(0, false, false);
    result.executed0 = false;

    while (_clocks >= cpuM68.clocks) {
      if (!cpuM68.exec()) {
        print("m68000 unimplemented instruction at ${cpuM68.pc.x6}");
        result.stopped = true;
        break;
      }

      result.executed0 = true;

      if (step) {
        break;
      }
    }

    while (_clocks >= m68ClockHz * cpuZ80.clocks / z80ClockHz) {
      if (!cpuZ80.exec()) {
        print("z80 unimplemented instruction at ${cpuZ80.r.pc.x4}");
        result.stopped = true;
        break;
      }

      result.executed1 = true;

      if (step) {
        break;
      }
    }

    final cd = cdrom;
    if (cd != null) {
      final before = cd.cpu.clocks;
      if (!cd.advance(_clocks, m68ClockHz, step: step)) {
        result.stopped = true;
      }
      result.executed2 = cd.running && cd.cpu.clocks != before;
    }

    final adapter = expansion;
    if (adapter != null) {
      final (ok, master, slave) =
          adapter.advance(_clocks, m68ClockHz, step: step);
      result.setExecuted(_shCpuBase, master);
      result.setExecuted(_shCpuBase + 1, slave);
      if (!ok) {
        result.stopped = true;
      }
    }

    if (_clocks >= _nextScanClock) {
      // video rendering
      _nextScanClock += clocksInScanline;
      vdp.trackOpacity = adapter?.enabled == true && adapter?.released == true;
      vdp.renderLine();
      adapter?.beginLine((vdp.vCounter - 2));
      if (vdp.trackOpacity) {
        adapter!.video
            .renderLine((vdp.vCounter - 2), vdp.buffer, vdp.opaque, vdp.width);
      }

      // raise h/v interrupts right after the line is rendered, so that the
      // handler has a whole line to update the vdp before the next line is
      // drawn (e.g. per-line vscroll changes by h-int)
      vdp.finishLine();
      _waitHBlank = true;
      result.scanlineRendered = true;

      // audio rendering
      _renderAudio();
    }

    if (_waitHBlank && _clocks >= _nextScanClock - 36) {
      vdp.startHBlank();
      if (vdp.trackOpacity) adapter!.video.hblank = true;
      _waitHBlank = false;
    }

    _clocks += 12;
    result.elapsedClocks = _clocks;

    return result;
  }

  final _fmBuffer = Float32List(250 * 2); // about 5ms: stereo 50kHz * 2ch
  final _psgBuffer = Float32List(250 * 5); // about 5ms + headroom
  int _fmBufferIndex = 0;
  int _psgBufferIndex = 0;

  void _renderAudio() {
    // calculate how many samples to render
    final fmSamples = _clocks * fm.sampleHz ~/ m68ClockHz - fm.elapsedSamples;
    final psgSamples =
        _clocks * psg.sampleHz ~/ m68ClockHz - psg.elapsedSamples;

    // when buffer is full, push current buffer to audio callback
    if (_fmBufferIndex + fmSamples * 2 >= _fmBuffer.length) {
      final out = Float32List(_fmBufferIndex);

      // mix resampled psgBuffer + fmBuffer
      for (int i = 0; i < _fmBufferIndex; i += 2) {
        final psgIndex = i.shr1 * psg.sampleHz ~/ fm.sampleHz;
        final psgVal = _psgBuffer[psgIndex.clip(0, _psgBufferIndex - 1)] / 4;

        final mixL = psgVal + _fmBuffer[i + 0] * 2;
        final mixR = psgVal + _fmBuffer[i + 1] * 2;
        out[i + 0] = mixL.clip(-1, 1);
        out[i + 1] = mixR.clip(-1, 1);
      }

      _onAudio(AudioBuffer(fm.sampleHz, 2, out));

      _fmBufferIndex = 0;
      _psgBufferIndex = 0;
    }

    // add rendered audio to buffer
    psg.render(psgSamples).forEach((d) => _psgBuffer[_psgBufferIndex++] = d);
    final rendered = fm.render(fmSamples);
    final adapter = expansion;
    if (adapter == null || !adapter.enabled || !adapter.released) {
      for (int i = 0; i < rendered.length; i += 2) {
        final (left, right) = cdrom?.sample(fm.sampleHz) ?? (0.0, 0.0);
        _fmBuffer[_fmBufferIndex++] = rendered[i] + left / 2;
        _fmBuffer[_fmBufferIndex++] = rendered[i + 1] + right / 2;
      }
      return;
    }
    for (int i = 0; i < rendered.length; i += 2) {
      final (left, right) = cdrom?.sample(fm.sampleHz) ?? (0.0, 0.0);
      final (pwmLeft, pwmRight) = adapter.pwm.sample();
      _fmBuffer[_fmBufferIndex++] = rendered[i] + (left + pwmLeft) / 2;
      _fmBuffer[_fmBufferIndex++] = rendered[i + 1] + (right + pwmRight) / 2;
    }
  }

  /// returns screen buffer as hSize x vSize argb
  @override
  ImageBuffer imageBuffer() =>
      (expansion?.enabled == true && expansion?.released == true)
          ? ImageBuffer(320, 224, expansion!.video.output.buffer.asUint8List())
          : vdp.imageBuffer;

  // call this after rendering audio
  void Function(AudioBuffer) _onAudio = (_) {};

  // set audio callback. used by CoreController
  @override
  onAudio(void Function(AudioBuffer) onAudio) {
    _onAudio = onAudio;
  }

  @override
  void setCdromDrive(CdromDrive drive) {
    final disc = Disc(drive);
    _disc = disc;
    cdrom?.setDisc(disc);
  }

  @override
  void setSram(Sram sram) {
    _sram = sram;
    cdrom?.setSram(sram);
  }

  /// handles reset button events
  @override
  void reset() {
    cdrom?.reset();
    expansion?.reset();
    busM68.onReset();
    busZ80.onReset();
    _clocks = 0;
    _nextScanClock = scanlinesInFrame;
    _waitHBlank = false;
    _fmBufferIndex = _psgBufferIndex = 0;
  }

  /// handles pad down/up events
  @override
  void padDown(int controllerId, PadButton k) =>
      busM68.pad.keyDown(controllerId, k);
  @override
  void padUp(int controllerId, PadButton k) =>
      busM68.pad.keyUp(controllerId, k);

  @override
  List<PadButton> get buttons => busM68.pad.buttons;

  // ROM CRC
  String crc = "";

  // loads an .gen format rom file.
  @override
  void setRom(Uint8List body) {
    if (cdBoot ||
        (body.length == 0x20000 &&
            String.fromCharCodes(body.sublist(0x100, 0x180))
                .contains("SEGA BOOT"))) {
      final cd = MdCdrom(body);
      busM68.cdrom = cd;
      if (_disc != null) cd.setDisc(_disc!);
      if (_sram != null) cd.setSram(_sram!);
    } else {
      busM68.cdrom = null;
      busM68.rom.load(body);
      final isExpansion = body.length >= 0x110 &&
          String.fromCharCodes(body.sublist(0x100, 0x110)).contains('32X');
      if (expansionBoot || isExpansion) {
        _attach32x();
        expansion!.setRom(body);
      } else {
        if (expansion != null) {
          _replaceMainBus(
              BusM68(ram: busM68.ram, pad: busM68.pad, rom: busM68.rom));
        }
      }
    }

    // check ROM region
    final r0 = String.fromCharCode(body[0x1f0]);
    final r1 = String.fromCharCode(body[0x1f1]);
    final r2 = String.fromCharCode(body[0x1f2]);

    final newStyleIndex = "0123456789ABCD F".indexOf(r0);
    if (newStyleIndex != -1) {
      if (newStyleIndex.bit0) {
        busM68.region = _regionDomestic;
      } else if (newStyleIndex.bit2) {
        busM68.region = _regionOversea;
      } else if (newStyleIndex.bit3) {
        busM68.region = _regionOverseaPal;
      } else {
        throw Exception("unknown ROM region:$r0");
      }
    } else if ("$r0$r1$r2".contains("J")) {
      busM68.region = _regionDomestic;
    } else if ("$r0$r1$r2".contains("U")) {
      busM68.region = _regionOversea;
    } else if ("$r0$r1$r2".contains("E")) {
      busM68.region = _regionOverseaPal;
    } else {
      throw Exception("unknown ROM region:$r0$r1$r2");
    }

    reset();
  }

  /// debug: returns the emulator's internal status report
  @override
  String dump(
      {bool showZeroPage = false,
      bool showSpriteVram = false,
      bool showStack = false,
      bool showApu = false}) {
    final regM68 = "${cpuM68.dump()} cl:${cpuM68.clocks.format3}";
    final (asmM68, _) = disasmM68(cpuM68.pc);
    final stackM68 =
        List.generate(16, (i) => busM68.ram[0xfff0 + i].x2, growable: false)
            .join(" ");

    final (asmZ80, _) = disasmZ80(cpuZ80.r.pc);
    final regZ80 = "${cpuZ80.dump()} cl:${cpuZ80.cycles.format3}";
    final bus =
        "bus: region:${busM68.region.x2} z80bank:${busZ80.bank.x6} clc:$_clocks";

    final vdpRegs = vdp.dump();

    final ym2612Stat = fm.dump();
    final psgStat = psg.dump();

    final cdStat = cdrom == null
        ? ""
        : "\n\nMD CD-ROM: ${cdrom!.cpu.dump()}\nCDD status:${cdrom!.drive.status.x2} lba:${cdrom!.drive.lba} running:${cdrom!.running}";

    return "$asmM68\n$regM68 v:${vdp.vCounter}\n$stackM68\n\n$asmZ80\n$regZ80\n\n$bus\n$vdpRegs\n$ym2612Stat\n$psgStat$cdStat${expansion == null ? "" : "\nMD 32x: ${expansion!.stoppedReason ?? 'running'}\n${expansion!.cpus[0].dump()}\n${expansion!.cpus[1].dump()}"}";
  }

  (String, int) disasmZ80(int addr) {
    final addrHex = addr.x4;
    final data = List.generate(4, (i) => busZ80.read((addr + i).mask16),
        growable: false);
    try {
      final (inst, next) = Z80Disasm.disasm(data, addr);

      final dataHex =
          List.generate(4, (i) => i < next ? data[i].x2 : "  ").join(" ");
      return ("$addrHex: $dataHex  $inst", next);
    } catch (e) {
      return ("$addrHex: [$e]", 1);
    }
  }

  (String, int) disasmM68(int addr, {bool subCpu = false}) {
    final bus = subCpu ? cdrom!.bus : busM68;
    final addrHex = addr.x6;
    final data = List.generate(6, (i) => bus.read16((addr + i * 2).mask24),
        growable: false);
    try {
      final (inst, next) = Disasm().disasm(data, addr);
      return ("$addrHex: ${data[0].x4}  $inst", next * 2);
    } catch (e) {
      return ("$addrHex: [$e]", 2);
    }
  }

  // debug: returns dis-assembled instruction in [String nmemonic, int nextAddr]
  @override
  (String, int) disasm(int cpuNo, int addr) {
    if (_isShCpu(cpuNo)) {
      final op = _shCpu(cpuNo).bus.read16(addr);
      return (
        '${addr.toRadixString(16).padLeft(8, '0')}: ${op.toRadixString(16).padLeft(4, '0')}  ${Sh2.disasm(op, addr)}',
        2
      );
    }
    return cpuNo == 0
        ? disasmM68(addr)
        : cpuNo == 2
            ? disasmM68(addr, subCpu: true)
            : disasmZ80(addr);
  }

  // debug: returns PC register
  @override
  int programCounter(int cpuNo) => _isShCpu(cpuNo)
      ? _shCpu(cpuNo).pc
      : cpuNo == 0
          ? cpuM68.pc
          : cpuNo == 2
              ? cdrom!.cpu.pc
              : cpuZ80.r.pc;

  // debug: returns SP register
  @override
  int stackPointer(int cpuNo) => _isShCpu(cpuNo)
      ? _shCpu(cpuNo).r[15]
      : cpuNo == 0
          ? cpuM68.a[7]
          : cpuNo == 2
              ? cdrom!.cpu.a[7]
              : cpuZ80.r.sp;

  // debug: set debug logging
  @override
  TraceLog trace(int cpuNo) {
    if (_isShCpu(cpuNo)) {
      final cpu = _shCpu(cpuNo);
      return TraceLog(cpu.pc, cpu.clocks, disasm(cpuNo, cpu.pc).$1, cpu.dump(),
          [...cpu.r, cpu.sr, cpu.gbr, cpu.vbr, cpu.pr, cpu.mach, cpu.macl]);
    }
    return cpuNo == 2
        ? TraceLog(
            cdrom!.cpu.pc,
            cdrom!.cpu.clocks,
            disasmM68(cdrom!.cpu.pc, subCpu: true).$1.padRight(44),
            cdrom!.cpu.dump().replaceAll("\n", " "), [
            for (int i = 0; i < 8; i++) cdrom!.cpu.a[i],
            ...cdrom!.cpu.d,
            cdrom!.cpu.sr
          ])
        : cpuNo == 0
            ? TraceLog(
                cpuM68.pc,
                cpuM68.clocks,
                disasmM68(cpuM68.pc).$1.padRight(44),
                cpuM68.dump().replaceAll("\n", " "), [
                for (int i = 0; i < 8; i++) cpuM68.a[i],
                ...cpuM68.d,
                cpuM68.sr
              ])
            : TraceLog(
                cpuZ80.r.pc,
                cpuZ80.cycles,
                "${cpuZ80.r.pc.x4}: ${disasmZ80(cpuZ80.r.pc).$1.padRight(36)}",
                cpuZ80.dump().replaceAll("\n", " "), [
                cpuZ80.r.af,
                cpuZ80.r.bc,
                cpuZ80.r.de,
                cpuZ80.r.hl,
                cpuZ80.r.af2,
                cpuZ80.r.bc2,
                cpuZ80.r.de2,
                cpuZ80.r.hl2,
                cpuZ80.r.ix,
                cpuZ80.r.iy,
                cpuZ80.r.sp
              ]);
  }

  // debug: dump vram
  @override
  List<int> get vram => vdp.vram;

  // debug: read mem
  @override
  int read(int cpuNo, int addr) => _isShCpu(cpuNo)
      ? _shCpu(cpuNo).bus.read8(addr)
      : cpuNo == 0
          ? busM68.read8(addr)
          : cpuNo == 2
              ? cdrom!.bus.read8(addr)
              : busZ80.read(addr);

  // debug: render BG
  @override
  ImageBuffer renderBg() => vdp.renderBg();

  @override
  ImageBuffer renderVram(bool useSecondBgColor, int paletteNo) =>
      vdp.renderVram(useSecondBgColor, paletteNo);

  @override
  ImageBuffer renderColorTable(int paletteNo) =>
      vdp.renderColorTable(paletteNo);

  @override
  List<String> spriteInfo() => vdp.debugSpriteInfo();
}
