import 'dart:typed_data';

import '../../cdrom.dart';
import '../../core.dart';
import '../../pad_button.dart';
import '../../sram.dart';
import '../../types.dart';
import '../../video_debug.dart';
import 'component/bus.dart';
import 'component/cpu.dart';
import 'component/cpu_debug.dart';
import 'component/cpu_disasm.dart';
import 'component/pic.dart';
import 'component/psg.dart';
import 'component/psg_debug.dart';
import 'component/timer.dart';
import 'component/vdc.dart';
import 'component/vdc_debug.dart';
import 'component/vdc_render.dart';
import 'component/video_debug.dart';
import 'component/vpc.dart';
import 'constants.dart' as hardware;
import 'mapper/rom.dart';
import 'rom/pce_file.dart';

/// main class for NES emulation. integrates cpu/ppu/apu/bus/pad control
class Pce extends Core {
  @override
  bool get hasPatternTables => true;

  // Register access latches SGX mode even when the game disables VDC 1 output.
  bool get _showSecondVdc =>
      vpc.enabled && ((vpc.priority0 | vpc.priority1) & 0x22) != 0;

  @override
  List<DebugVideoLayer> get videoLayers =>
      [...vdc.debugVideoLayers, if (_showSecondVdc) ...vdc2.debugVideoLayers];
  @override
  List<DebugPatternTable> get patternTables => [
        ...vdc.debugPatternTables,
        if (_showSecondVdc) ...vdc2.debugPatternTables
      ];

  late final Vdc vdc;
  late final Vdc vdc2;
  late final Vpc vpc;
  late final Psg psg;
  late final Cpu2 cpu;
  late final Bus bus;
  late final Timer timer;
  late final Pic pic;

  static const systemClockHz_ = hardware.systemClockHz;

  @override
  int get systemClockHz => systemClockHz_;

  @override
  int get scanlinesInFrame => hardware.scanlinesInFrame;

  // computed once: the getter is used twice per instruction in exec()
  static const int _clocksInScanline = hardware.clocksInScanline;

  @override
  int get clocksInScanline => _clocksInScanline;

  @override
  get cpuInfos => [CpuInfo.of6502(1, "Hu6280")];

  Pce() {
    bus = Bus();
    cpu = Cpu2(bus);
    vdc = bus.vdc = Vdc(bus, 0);
    vdc2 = bus.vdc2 = Vdc(bus, 1);
    vdc2.colorTable = vdc.colorTable; // VCE is shared between both VDCs
    vpc = bus.vpc;
    psg = Psg(bus);
    timer = Timer(bus);
    pic = Pic(bus);
  }

  int _nextVdcClocks = 0;
  int _prevPsgClocks = 0;
  bool _vdc2Synced = false;

  // reused for every instruction (the caller reads it right away)
  final _result = ExecResult(0, false, false)
    ..executed0 = false
    ..executed1 = true;

  /// exec 1 cpu instruction and render PPU / APU if enough cycles passed
  /// returns current CPU cycle and bool - false when unimplemented instruction is found
  @override
  ExecResult exec(bool _) {
    final r = _step();
    return _result
      ..elapsedClocks = r == _stopped ? cpu.cycles : cpu.clocks
      ..stopped = r == _stopped
      ..scanlineRendered = r == _rendered;
  }

  /// runs until [scanlines] scanlines are rendered, as exec(false) called
  /// until it reports a rendered scanline [scanlines] times
  @override
  ExecResult runFrame(int scanlines) {
    int r = _executed;
    for (int n = 0; n < scanlines;) {
      r = _step();
      if (r == _rendered) {
        n++;
      } else if (r == _stopped) {
        break;
      }
    }
    return _result
      ..elapsedClocks = r == _stopped ? cpu.cycles : cpu.clocks
      ..stopped = r == _stopped
      ..scanlineRendered = r == _rendered;
  }

  static const _executed = 0;
  static const _rendered = 1;
  static const _stopped = 2;

  // one cpu instruction, then the devices
  int _step() {
    if (!cpu.exec()) {
      return _stopped;
    }

    final clock = cpu.clock;
    timer.exec(clock);
    bus.cdrom.exec(clock);

    final clocks = cpu.clocks;
    if (clocks < _nextVdcClocks &&
        clocks < _prevPsgClocks + _clocksInScanline) {
      return _executed;
    }

    bool rendered = false;

    while (cpu.clocks >= _nextVdcClocks) {
      if (vpc.enabled) {
        // align VDC2's vertical counter to VDC1 the first time SGX activates,
        // so both VDCs render the same scanline in lock-step thereafter.
        if (!_vdc2Synced) {
          vdc2.scanLine = vdc.scanLine;
          _vdc2Synced = true;
        }
      }
      vdc.exec();
      if (vpc.enabled) {
        vdc2.exec();
      }
      _nextVdcClocks += _clocksInScanline;
      rendered = true;
    }

    while (cpu.clocks >= _prevPsgClocks + _clocksInScanline) {
      final elapsed = (cpu.clocks - _prevPsgClocks) ~/ 6 * 6;
      _prevPsgClocks += elapsed;
      final audio = psg.exec(elapsed);
      bus.cdrom.mixAudio(audio, Psg.audioSamplingRate);
      _onAudio(AudioBuffer(Psg.audioSamplingRate, 2, audio));
    }

    return rendered ? _rendered : _executed;
  }

  /// returns screen buffer as hSize x vSize argb
  @override
  ImageBuffer imageBuffer() {
    vpc.render(vdc, vdc2);
    return ImageBuffer(vdc.hSize, vdc.vSize, vpc.frameBuffer);
  }

  void Function(AudioBuffer) _onAudio = (_) {};

  @override
  onAudio(void Function(AudioBuffer) onAudio) {
    _onAudio = onAudio;
  }

  /// handles reset button events
  @override
  void reset() {
    _nextVdcClocks = _clocksInScanline;
    _prevPsgClocks = _clocksInScanline;
    _vdc2Synced = false;
    bus.onReset();
  }

  /// handles pad down/up events
  @override
  void padDown(int controllerId, PadButton k) =>
      bus.joypad.keyDown(controllerId, k);
  @override
  void padUp(int controllerId, PadButton k) =>
      bus.joypad.keyUp(controllerId, k);

  // the CD BIOS is a rom of the card slot
  @override
  void setBiosFiles(List<Uint8List> files) {
    if (files.isNotEmpty) {
      setRom(files.first);
    }
  }

  @override
  void setCdromDrive(CdromDrive drive) {
    bus.arcadeCardEnabled = !drive.isEmpty;
    bus.cdrom.setDisc(drive);
    if (!drive.isEmpty && bus.sram.data.length != 0x800) {
      bus.sram.init('pce-cd-bram', Uint8List(0x800));
    }
  }

  @override
  void dispose() {}

  @override
  void setSram(Sram sram) => bus.sram = sram;

  @override
  List<PadButton> get buttons => bus.joypad.buttons;

  // ROM CRC
  String crc = "";

  // loads an .pce format rom file.
  // throws exception if the mapper type of the rom file is not supported.
  @override
  void setRom(Uint8List body) {
    final file = PceFile();
    file.load(body);
    crc = file.crc;

    bus.rom =
        Rom(file.banks, cartridgeRam: ramCartridgeCrcs.contains(file.bodyCrc));
    bus.arcadeCard.powerOn();

    reset();
  }

  /// debug: returns the emulator's internal status report
  @override
  String dump(
      {bool showZeroPage = false,
      bool showSpriteVram = false,
      bool showStack = false,
      bool showApu = false}) {
    final cpuDump = cpu.dump(showRegs: true);
    final dump = "$cpuDump\n"
        "${cpu.dump(showIRQVector: true, showStack: showStack, showZeroPage: showZeroPage)}"
        "${showApu ? psg.dump() : ""}"
        "${bus.vdc.dump()}";
    return dump;
    // return '${fps.toStringAsFixed(2)}fps';
  }

  // debug: returns dis-assembled 6502 instruction in [String nmemonic, int nextAddr]
  @override
  (String, int) disasm(int _, int addr) =>
      (cpu.dumpDisasm(addr), Disasm.nextPC(cpu.read(addr)));

  // debug: returns PC register
  @override
  int programCounter(int _) => cpu.regs.pc;

  // debug: returns SP register
  @override
  int stackPointer(int _) => cpu.regs.s;

  // debug: set debug logging
  @override
  TraceLog trace(int _) => cpu.trace();

  // debug: dump vram
  @override
  List<int> get vram => vdc.vram.toList(growable: false);

  // debug: read mem
  @override
  int read(int _, int addr) => bus.cpu.read(addr);

  // debug: render BG
  @override
  ImageBuffer renderBg() => vdc.renderBg();
  @override
  ImageBuffer renderVram(bool useSecondBgColor, int paletteNo) {
    final buf = vdc.renderVram(useSecondBgColor, paletteNo);
    if (!vpc.enabled) {
      return buf;
    }
    // sgx: VDC1's vram on top, VDC2's below
    final buf2 = vdc2.renderVram(useSecondBgColor, paletteNo);
    return ImageBuffer(buf.width, buf.height + buf2.height,
        Uint32List.fromList([...buf.buffer, ...buf2.buffer]));
  }

  @override
  ImageBuffer renderColorTable(int paletteNo) =>
      vdc.renderColorTable(paletteNo);

  @override
  List<String> spriteInfo() => vdc.spriteInfo();
}
