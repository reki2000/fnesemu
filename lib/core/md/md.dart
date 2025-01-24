// Dart imports:
import 'dart:math';
import 'dart:typed_data';

import 'package:fnesemu/core/md/vdp_debug.dart';
import 'package:fnesemu/core/md/vdp_renderer.dart';
import 'package:fnesemu/core/md/ym2612.dart';
import 'package:fnesemu/core/md/z80/z80_disasm.dart';
import 'package:fnesemu/util/int.dart';

import '../../util/util.dart';
import '../core.dart';
import '../pad_button.dart';
import '../types.dart';
import 'bus_m68.dart';
import 'bus_z80.dart';
import 'm68/m68.dart';
import 'm68/m68_disasm.dart';
import 'sn76489.dart';
import 'vdp.dart';
import 'z80/z80.dart';

/// main class for NES emulation. integrates cpu/ppu/apu/bus/pad control
class Md implements Core {
  late final M68 cpuM68;
  late final Z80 cpuZ80;

  late final BusZ80 busZ80;
  late final BusM68 busM68;

  final vdp = Vdp();
  final psg = Sn76489();
  final fm = Ym2612();

  static const masterClockNtscHz = 53693175;
  static const masterClockPalHz = 53203424;
  static const masterClockHz = masterClockNtscHz;

  static const m68ClockHz = masterClockHz ~/ 7;
  static const z80ClockHz = masterClockHz ~/ 15;

  @override
  int get systemClockHz => m68ClockHz;

  @override
  int get scanlinesInFrame => Vdp.height + Vdp.retrace;

  @override
  int get clocksInScanline => m68ClockHz ~/ 59.97 ~/ scanlinesInFrame;

  @override
  List<String> get cpuInfos => ["68000", "Z80"];

  Md() {
    busM68 = BusM68();
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

  int _clocks = 0;
  int _nextScanClock = 0;

  bool _hsyncRequired = false;

  /// exec 1 cpu instruction and render PPU / APU if enough cycles passed
  /// returns current CPU cycle and bool - false when unimplemented instruction is found
  @override
  ExecResult exec() {
    bool scanlineProceeded = false;

    final m68ExecSuccess = cpuM68.exec();

    _clocks = cpuM68.clocks;

    while (_clocks > m68ClockHz * cpuZ80.clocks / z80ClockHz) {
      final z80Result = cpuZ80.exec();
      if (!z80Result) {
        print("z80 unimplemented instruction at ${cpuZ80.r.pc.hex16}");
      }
    }

    if (_hsyncRequired && _clocks >= _nextScanClock - 36) {
      vdp.startHsync();
      _hsyncRequired = false;
    }

    if (_clocks >= _nextScanClock) {
      _nextScanClock += clocksInScanline;
      _hsyncRequired = vdp.renderLine();
      scanlineProceeded = true;
    }

    while (_clocks > m68ClockHz * fm.elapsedSamples / Ym2612.sampleHz) {
      final fmSamples = Ym2612.sampleHz * clocksInScanline ~/ m68ClockHz;
      final psgSamples = Sn76489.sampleHz * clocksInScanline ~/ m68ClockHz;

      final psgOut = psg.render(psgSamples);
      final fmOut = fm.render(fmSamples);

      // mix psgOut + fmOut with normalization
      final buf = Float32List(fmSamples * 2);

      for (int i = 0; i < fmSamples; i += 2) {
        final psgIndex = (i >> 1) * Sn76489.sampleHz ~/ Ym2612.sampleHz;

        buf[i + 0] = (psgOut[psgIndex] + fmOut[i + 0] * 4) / 5;
        buf[i + 1] = (psgOut[psgIndex] + fmOut[i + 1] * 4) / 5;
      }

      _onAudio(AudioBuffer(Ym2612.sampleHz, 2, buf));
    }

    return ExecResult(_clocks, m68ExecSuccess, scanlineProceeded);
  }

  /// returns screen buffer as hSize x vSize argb
  @override
  ImageBuffer imageBuffer() => vdp.imageBuffer;

  void Function(AudioBuffer) _onAudio =
      (_) {}; // call this after rendering audio

  // set audio callback. used by CoreController
  @override
  onAudio(void Function(AudioBuffer) onAudio) {
    _onAudio = onAudio;
  }

  /// handles reset button events
  @override
  void reset() {
    busM68.onReset();
    busZ80.onReset();
    _clocks = 0;
    _nextScanClock = scanlinesInFrame;
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
    busM68.rom.load(body);

    reset();
  }

  /// debug: returns the emulator's internal status report
  @override
  String dump(
      {bool showZeroPage = false,
      bool showSpriteVram = false,
      bool showStack = false,
      bool showApu = false}) {
    final regM68 = cpuM68.dump();
    final (asmM68, _) = disasmM68(cpuM68.pc);
    final stackM68 =
        List.generate(16, (i) => busM68.ram[0xfff0 + i].hex8, growable: false)
            .join(" ");

    final (asmZ80, _) = disasmZ80(cpuZ80.r.pc);
    final regZ80 = cpuZ80.dump();

    final vdpRegs = vdp.dump();

    final ym2612Stat = fm.dump();

    return "$asmM68\n$regM68 v:${vdp.vCounter}\n$stackM68\n\n$asmZ80\n$regZ80\n\n$vdpRegs\n$ym2612Stat";
  }

  (String, int) disasmZ80(int addr) {
    final addrHex = addr.hex16;
    final data = List.generate(4, (i) => busZ80.read((addr + i).mask16),
        growable: false);
    try {
      final (inst, next) = Z80Disasm.disasm(data, addr);

      final dataHex =
          List.generate(4, (i) => i < next ? data[i].hex8 : "  ").join(" ");
      return ("$addrHex: $dataHex  $inst", next);
    } catch (e) {
      return ("$addrHex: [$e]", 1);
    }
  }

  (String, int) disasmM68(int addr) {
    final addrHex = addr.hex24;
    final data = List.generate(6, (i) => busM68.read16((addr + i * 2).mask24),
        growable: false);
    try {
      final (inst, next) = Disasm().disasm(data, addr);
      return ("$addrHex: ${data[0].hex16}  $inst", next * 2);
    } catch (e) {
      return ("$addrHex: [$e]", 2);
    }
  }

  // debug: returns dis-assembled instruction in [String nmemonic, int nextAddr]
  @override
  Pair<String, int> disasm(int cpuNo, int addr) {
    final (asm, i) = cpuNo == 0 ? disasmM68(addr) : disasmZ80(addr);
    return Pair(asm, i);
  }

  // debug: returns PC register
  @override
  int programCounter(int cpuNo) => cpuNo == 0 ? cpuM68.pc : cpuZ80.r.pc;

  // debug: set debug logging
  @override
  String tracingState(int cpuNo) => cpuNo == 0
      ? "${disasmM68(cpuM68.pc).$1.padRight(44)} ${cpuM68.dump().replaceAll("\n", " " "")}"
      : "${disasmZ80(cpuZ80.r.pc).$1.padRight(44)} ${cpuZ80.dump().replaceAll("\n", " ")}";

  // debug: dump vram
  @override
  List<int> get vram => List.empty();

  // debug: read mem
  @override
  int read(int cpuNo, int addr) =>
      cpuNo == 0 ? busM68.read8(addr) : busZ80.read(addr);

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
  List<String> spriteInfo() => List.empty();
}
