import 'dart:typed_data';

import '../../cdrom_drive.dart';
import '../../core.dart';
import '../../pad_button.dart';
import '../../sram.dart';
import '../../trace_flow.dart';
import '../../types.dart';
import '../../util/debug.dart';
import '../../util/disasm.dart';
import '../../util/int.dart';
import '../../util/uint8list.dart';
import '../../video_debug.dart';
import 'bus.dart';
import 'cdrom.dart';
import 'dma.dart';
import 'gpu/gpu.dart';
import 'gpu/gpu_debug.dart';
import 'interrupt.dart';
import 'jit/ps_jit.dart';
import 'log.dart';
import 'mdec.dart';
import 'memory_card.dart';
import 'pad.dart';
import 'r3000/disasm.dart';
import 'r3000/r3000.dart';
import 'serial.dart';
import 'spu/spu.dart';
import 'timer.dart';

final _log = DebugLog('ps');

const _fastboot = bool.fromEnvironment("FASTBOOT", defaultValue: false);

/// runs the cpu with the recompiler where the host supports it
const _jit = bool.fromEnvironment("JIT", defaultValue: true);

class Ps extends Core {
  @override
  List<DebugVideoLayer> get videoLayers => gpu.debugVideoLayers;

  final Bus bus;
  late final R3000 cpu;
  late final Gpu gpu;
  late final Pad pad;
  late final MemoryCard memoryCard;
  late final MemoryCard memoryCard2;
  late final Serial serial;
  late final Spu spu;
  late final TimerController timer;
  late final Cdrom cdrom;
  late final Mdec mdec;
  late final Dma dma;

  bool fastBoot = _fastboot;

  /// the recompiler, or null when the interpreter runs every instruction;
  /// it is off while tracing, which hooks every BIOS call
  final PsJit? jit;

  Ps({Uint8List? memoryCard2Image, bool jit = _jit})
      : this._(jit && !psTrace ? PsJit.create() : null, memoryCard2Image);

  Ps._(this.jit, Uint8List? memoryCard2Image)
      : bus = Bus(mem: jit?.ram, rom: jit?.rom, scratchPad: jit?.scratchPad) {
    cpu = R3000(bus, regs: jit?.regs);
    gpu = Gpu(bus);
    pad = Pad();
    memoryCard = MemoryCard();

    memoryCard2 = MemoryCard();
    if (memoryCard2Image != null) {
      memoryCard2.setRw((addr) => memoryCard2Image[addr],
          (addr, value) => memoryCard2Image[addr] = value);
    }

    serial = Serial(
      bus,
      pad,
      memoryCard,
      memoryCard2,
    );
    spu = Spu(bus);
    timer = TimerController(bus);
    cdrom = Cdrom(bus);
    mdec = Mdec();
    dma = Dma(bus);

    bus.interrupt = InterruptController()..cpu = cpu;
    bus.dma = dma;
    bus.gpu = gpu;
    bus.cpu = cpu;
    bus.serial = serial;
    bus.spu = spu;
    bus.timer = timer;
    bus.cdrom = cdrom;
    bus.mdec = mdec;
    jit?.attach(cpu, bus);
  }

  static const _systemClockHz = 33868800; // 33.8688MHz

  @override
  int get systemClockHz => _systemClockHz;

  @override
  int get clocksInScanline => _systemClockHz ~/ 60 ~/ Gpu.scanlinesInFrame;

  @override
  int get scanlinesInFrame => Gpu.scanlinesInFrame;

  @override
  List<CpuInfo> get cpuInfos => [CpuInfo.ofR3000(0, "R3000")];

  /// loads a PS-EXE, which runs after the BIOS boot
  @override
  void setRom(Uint8List body) {
    if (body.length < 8 ||
        body.getUint32BE(0) != 0x50532d58 ||
        body.getUint32BE(4) != 0x20455845) {
      throw Exception("not a PS-EXE");
    }

    cpu.exe = body;
    _log.info("loaded PS-EXE");
  }

  @override
  void setBiosFiles(List<Uint8List> files) {
    if (files.isEmpty) {
      return;
    }

    bus.rom.setAll(0, files.first);

    if (fastBoot) {
      const fastBootSequence = [
        // turn display on by writing GP1(03h) = 0 to GPU I/O: 1f801814
        0x3c0a1f80, // lui  t2, 0x1f80
        0x354a1814, // ori  t2, t2, 0x1814
        0x3c0b0300, // lui  t3, 0x0300
        0xad4b0000, // sw   t3, 0(t2)
        0x03e00008, // jr   ra
        0x00000000, // nop
      ];
      const patchAddr = 0x18000 >> 2;
      bus.rom32.setRange(
          patchAddr, patchAddr + fastBootSequence.length, fastBootSequence);
    }
    jit?.reset();

    cdrom.closeShell();

    _sram.init(StorageKey.of("ps", StorageKey.sram, "memcard1"),
        MemoryCard.blankImage);
    memoryCard.setRw(_sram.read8, _sram.write8);
  }

  int nextScanlineClock = 0;
  int nextTimerClock = 0;
  bool _waitFinishLine = false;
  int nextDmaClock = 0;
  int nextSpuClock = 0;
  int nextSerialClock = 0;
  int nextCdromClock = 0;

  late Sram _sram;

  void Function(AudioBuffer) _onAudio = (_) {};
  final audioBuffer = Float32List(1000 * 2);
  int audioBufferIndex = 0;

  ExecResult result = ExecResult(0, false, false);

  /// runs cpu instructions until one of the periodic devices is due. [step]
  /// runs a single instruction (debugger). the devices are checked after
  /// each instruction in the order below; instructions between two device
  /// events are run in a batch, as no check fires before [cpu.clocks] passes
  /// the nearest event clock.
  @override
  ExecResult exec(bool step) {
    result.scanlineRendered = _run(step);
    result.elapsedClocks = cpu.clocks;
    return result;
  }

  /// runs until [scanlines] scanlines are rendered, same as calling
  /// exec(false) until that many scanlines are reported
  @override
  ExecResult runFrame(int scanlines) {
    for (int n = 0; n < scanlines;) {
      if (_run(false)) n++;
    }
    result.scanlineRendered = true;
    result.elapsedClocks = cpu.clocks;
    return result;
  }

  /// runs one batch of instructions and the device events due after it,
  /// returns true if a scanline is rendered
  bool _run(bool step) {
    final cpu = this.cpu, jit = this.jit;

    if (step) {
      cpu.step();
    } else {
      // the clock up to which none of the checks below fires
      int limit = nextTimerClock;
      if (nextScanlineClock < limit) limit = nextScanlineClock;
      if (_waitFinishLine && nextScanlineClock - 201 < limit) {
        limit = nextScanlineClock - 201;
      }
      // the recompiler runs to the next event without stopping for an idle
      // dma, as stopping costs more than the instructions in 24 clocks
      if (nextDmaClock < limit && (jit == null || bus.dma.active)) {
        limit = nextDmaClock;
      }
      if (nextSpuClock < limit) limit = nextSpuClock;
      if (nextSerialClock < limit) limit = nextSerialClock;
      if (nextCdromClock < limit) limit = nextCdromClock;

      if (jit != null) {
        jit.run(limit);
      } else {
        do {
          cpu.step();
        } while (cpu.clocks <= limit);
      }
    }

    if (cpu.clocks > nextTimerClock) {
      nextTimerClock += 100;
      bus.timer.catchUp();
    }

    bool scanlineRendered = false;
    if (cpu.clocks > nextScanlineClock) {
      bus.timer.endHBlank();
      nextScanlineClock += clocksInScanline;
      gpu.renderScanline();
      _waitFinishLine = true;
      scanlineRendered = true;
    }

    if (_waitFinishLine && cpu.clocks >= nextScanlineClock - 200) {
      bus.timer.startHBlank();
      _waitFinishLine = false;
    }

    if (cpu.clocks > nextDmaClock) {
      nextDmaClock += 24;
      bus.dma.exec(24);
    }
    if (jit != null && !bus.dma.active) nextDmaClock = cpu.clocks;

    if (cpu.clocks > nextSpuClock) {
      nextSpuClock += 768; // master clock 33.8688MHz / 44100Hz
      spu.renderSample();
      audioBuffer[audioBufferIndex + 0] = spu.outLeft;
      audioBuffer[audioBufferIndex + 1] = spu.outRight;
      audioBufferIndex += 2;
      if (audioBufferIndex >= audioBuffer.length) {
        _onAudio(AudioBuffer(44100, 2, audioBuffer));
        audioBufferIndex = 0;
      }
    }

    if (cpu.clocks > nextSerialClock) {
      nextSerialClock += 100;
      bus.serial.exec(100);
    }

    if (cpu.clocks > nextCdromClock) {
      nextCdromClock += 200;
      bus.cdrom.exec(200);
    }

    debugStatus.clock = cpu.clocks;
    debugStatus.frame = gpu.frame;
    debugStatus.scanline = gpu.scanline;
    debugStatus.pc = cpu.pc;

    return scanlineRendered;
  }

  @override
  void reset() {
    cpu.reset();
    jit?.reset();

    nextScanlineClock = 0;
    nextTimerClock = 0;
    nextDmaClock = 0;
    nextSpuClock = 0;
    nextSerialClock = 0;
    nextCdromClock = 0;
    _waitFinishLine = false;
    audioBuffer.fillRange(0, audioBuffer.length, 0);

    gpu.reset();
    spu.reset();
    pad.reset();
    memoryCard.reset();
    serial.reset();
    cdrom.reset();
    timer.reset();
    bus.reset();

    debugStatus.clock = 0;
    debugStatus.frame = 0;
    debugStatus.scanline = 0;
    debugStatus.pc = cpu.pc;
  }

  @override
  void dispose() => jit?.dispose();

  @override
  ImageBuffer imageBuffer() => gpu.imageBuffer;

  @override
  onAudio(void Function(AudioBuffer p1) f) => _onAudio = f;

  @override
  void setCdromDrive(CdromDrive drive) {
    _log.infoc(() => "set cdrom drive: ${drive.status.state.name}");
    bus.cdrom.attachDrive(drive);
  }

  @override
  void setSram(Sram sram) => _sram = sram;

  @override
  List<PadButton> get buttons => pad.buttons;

  @override
  void padDown(int id, PadButton k) => pad.keyDown(id, k);

  @override
  void padUp(int id, PadButton k) => pad.keyUp(id, k);

  @override
  int programCounter(int _) => cpu.pc;

  @override
  int stackPointer(int _) => cpu.r[29];

  @override
  (String, int) disasm(int _, int addr) {
    addr = addr.mask32 & ~0x03;
    final inst32 = bus.read32(addr);
    return (
      formatDisasm(
          addr.x8, inst32.x8, DisasmR3000.disasm(inst32, pc: addr, regs: cpu.r),
          codeWidth: 8),
      4
    );
  }

  @override
  String dump(
      {bool showZeroPage = false,
      bool showSpriteVram = false,
      bool showStack = false,
      bool showApu = false}) {
    return "${disasm(0, cpu.pc).$1}\n${cpu.dump()} cy:${cpu.clocks}\n"
        "${range(0, 7).map((ch) => bus.dma.channels[ch].dump()).join("\n")}\n"
        "${timer.timers.map((t) => t.dump()).join(" ")}\n"
        "${bus.interrupt.dump()}\n"
        "${gpu.dump()}\n"
        "${spu.dump()}\n"
        "${serial.dump()}\n"
        "cdrom: ${cdrom.dump()}\n"
        "mdec: ${mdec.dump()}";
  }

  @override
  TraceLog trace(int cpuNo) {
    final opcode = bus.read32(cpu.pc);
    return TraceLog(
        cpu.pc,
        cpu.clocks,
        disasm(0, cpu.pc).$1.padRight(46),
        cpu.dump().replaceAll("\n", " "),
        [for (int i = 0; i < 32; i++) cpu.r[i]],
        frame: gpu.frame,
        scanline: gpu.scanline,
        instructionKey: opcode.x8,
        flow: traceMipsFlow(opcode, cpu.pc, cpu.r));
  }

  @override
  int read(int _, int addr) => (addr.shr28 == 0x07)
      ? bus.spu.ram[addr & 0x7ffff]
      : bus.read32(addr & 0x1fffff);

  @override
  ImageBuffer renderBg() => gpu.renderBg();

  @override
  ImageBuffer renderColorTable(int paletteNo) => ImageBuffer.empty();

  @override
  ImageBuffer renderVram(bool useSecondBgColor, int paletteNo) =>
      ImageBuffer.empty();

  @override
  List<String> spriteInfo() => [];

  @override
  List<int> get vram => [];
}
