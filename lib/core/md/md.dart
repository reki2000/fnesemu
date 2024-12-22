// Dart imports:
import 'dart:typed_data';

import 'package:fnesemu/core/md/vdp_debug.dart';
import 'package:fnesemu/core/md/vdp_renderer.dart';
import 'package:fnesemu/util/int.dart';

import '../../util/util.dart';
import '../core.dart';
import '../pad_button.dart';
import '../types.dart';
import 'bus_m68.dart';
import 'bus_z80.dart';
import 'm68/m68.dart';
import 'm68/m68_disasm.dart';
import 'psg.dart';
import 'vdp.dart';
import 'z80/z80.dart';

/// main class for NES emulation. integrates cpu/ppu/apu/bus/pad control
class Md implements Core {
  late final M68 cpuM68;
  late final Z80 cpuZ80;

  late final BusZ80 busZ80;
  late final BusM68 busM68;

  final vdp = Vdp();
  final psg = Psg();

  static const systemClockHz_ = 21477270; // 21.47727MHz

  @override
  int get systemClockHz => systemClockHz_;

  @override
  int get scanlinesInFrame => Vdp.height + Vdp.retrace;

  @override
  int get clocksInScanline => systemClockHz_ ~/ 59.97 ~/ scanlinesInFrame;

  Md() {
    busM68 = BusM68();
    busZ80 = BusZ80();

    cpuM68 = M68(busM68);
    cpuZ80 = Z80(busZ80);

    busM68.cpu = cpuM68;
    busM68.busZ80 = busZ80;
    busM68.vdp = vdp;
    busM68.psg = psg;

    vdp.bus = busM68;

    busZ80.cpu = cpuZ80;
    busZ80.busM68 = busM68;
    busZ80.psg = psg;
  }

  int _clocks = 0;
  int _nextScanClock = 0;
  int _nextAudioClock = 0;

  bool _hsyncRequired = false;

  /// exec 1 cpu instruction and render PPU / APU if enough cycles passed
  /// returns current CPU cycle and bool - false when unimplemented instruction is found
  @override
  ExecResult exec() {
    bool scanlineProceeded = false;

    final m68ExecSuccess = cpuM68.exec();

    _clocks = cpuM68.clocks;

    while (_clocks < cpuZ80.clocks) {
      cpuZ80.exec();
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

    if (_clocks >= _nextAudioClock) {
      _nextAudioClock += clocksInScanline;
      _onAudio(AudioBuffer(44100, 2, psg.render(1000)));
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
    _nextAudioClock = scanlinesInFrame;
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
    final asmM68 = disasm(cpuM68.pc);
    final stackM68 =
        List.generate(16, (i) => busM68.ram[0xfff0 + i].hex8, growable: false)
            .join(" ");

    final regZ80 = cpuZ80.dump();

    final vdpRegs = vdp.dump();

    return "${asmM68.i0}\n$regM68 v:${vdp.vCounter}\n$stackM68\n\n$regZ80\n\n$vdpRegs";
  }

  // debug: returns dis-assembled instruction in [String nmemonic, int nextAddr]
  @override
  Pair<String, int> disasm(int addr) {
    final addrHex = addr.hex24;
    final data =
        List.generate(6, (i) => busM68.read16(addr + i * 2), growable: false);
    try {
      final (inst, next) = Disasm().disasm(data, addr);
      return Pair("$addrHex: ${data[0].hex16}  $inst", next * 2);
    } catch (e) {
      return Pair("$addrHex: [$e]", 2);
    }
  }

  // debug: returns PC register
  @override
  int get programCounter => cpuM68.pc;

  // debug: set debug logging
  @override
  String get tracingState =>
      "${disasm(cpuM68.pc).i0.padRight(44)} ${cpuM68.dump().replaceAll("\n", " " "")}";

  // debug: dump vram
  @override
  List<int> get vram => List.empty();

  // debug: read mem
  @override
  int read(int addr) => busM68.read8(addr);

  // debug: render BG
  @override
  ImageBuffer renderBg() => ImageBuffer.empty();

  @override
  ImageBuffer renderVram(bool useSecondBgColor, int paletteNo) =>
      ImageBuffer.empty();

  @override
  ImageBuffer renderColorTable(int paletteNo) =>
      vdp.renderColorTable(paletteNo);

  @override
  List<String> spriteInfo() => List.empty();
}
