import 'dart:typed_data';

import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';

import '../../cdrom_drive.dart';
import '../../core.dart';
import '../../pad_button.dart';
import '../../pad_source.dart';
import '../../sram.dart';
import '../../state.dart';
import '../../types.dart';
import '../../util/disasm.dart';
import '../../util/int.dart';
import '../../util/register_dump.dart';
import '../../video_debug.dart';
import 'aica.dart';
import 'arm7di_disasm.dart';
import 'arm_jit.dart';
import 'bus.dart';
import 'disc.dart';
import 'disc_bootstrap.dart';
import 'fault.dart';
import 'flash.dart';
import 'maple_controller.dart';
import 'memory_card.dart';
import 'sh4.dart';
import 'sh4_disasm.dart';
import 'storage.dart';

/// Experimental DC bring-up core with functional framebuffer readout.
class Dc extends Core {
  /// [jit] compiles SH-4 code when the host supports it.
  Dc(
      {this.bootBringUp = const bool.fromEnvironment('DC_BOOT_BRINGUP'),
      bool jit = const bool.fromEnvironment('DC_JIT', defaultValue: true)})
      : _jit = jit ? Sh4Jit.create() : null,
        _armJit = jit ? DcArmJit.create(DcAica.memorySize) : null {
    bus.onDeviceAccess = _syncDevices;
    bus.maple.source = padPort;
    // Compiled code reads and writes main RAM directly.
    if (_jit != null) bus.cache.coherent = true;
    if (bootBringUp) {
      bus.g1.bypassBiosVerification = true;
      bus.aica.dsp.diagnosticBypassUnsupportedProgram = true;
      bus.aica.sound.diagnosticByteAddressAdpcm = true;
      bus.aica.sound.diagnosticFilterApproximation = true;
    }
  }

  /// Explicit experimental board, timing and audio policies used by BIOS bring-up.
  /// This does not authenticate media or establish hardware-matched DSP effects.
  final bool bootBringUp;
  final Sh4Jit? _jit;
  final DcArmJit? _armJit;
  late final bus =
      DcBus(ram: _jit?.ram, storeQueues: _jit?.storeQueues, armJit: _armJit);
  late final cpu = Sh4(bus, jit: _jit);
  int _compiledClocks = 0;
  Uint8List? _program;
  bool _hasBios = false;
  Sram? _storage;
  int _clocks = 0;
  int _pendingClocks = 0;
  // Device clocks deferred by runFrame; flushed before device-visible accesses.
  int _batchedClocks = 0, _batchDeadline = 0;
  int _pinsEpoch = -1;
  // Compiled code runs whole blocks, so it uses longer device batches.
  int get _batchLimit => _jit == null ? 256 : 8192;
  String? stopReason;
  CdromDrive? _discDrive;
  int _bootstrapEpoch = 0;

  static const programAddress = 0x8c010000;
  static const programOffset = 0x10000;

  @override
  int get systemClockHz => 200000000;

  // Inactive/external SPG uses bounded diagnostic slices.
  @override
  int get scanlinesInFrame =>
      bus.gpu.spg.running ? bus.gpu.spg.linesPerField : 525;
  @override
  int get clocksInScanline =>
      bus.gpu.spg.running ? bus.gpu.spg.nominalLineClocks : 6350;
  @override
  int get cpuClocks => _clocks;
  @override
  List<CpuInfo> get cpuInfos =>
      const [CpuInfo(0, 'SH-4', 32), CpuInfo(1, 'ARM7DI', 32)];

  @override
  void setBiosFiles(List<Uint8List> files) {
    final boot = files.where((file) => file.length == DcBus.biosSize).toList();
    final flash = files.where((file) => file.length == DcFlash.size).toList();
    if (boot.length != 1 ||
        files.length != 1 + flash.length ||
        flash.length > 1) {
      throw ArgumentError(
          'DC requires a 2 MiB boot ROM and a 128 KiB flash image');
    }
    bus.bios.setAll(0, boot.single);
    if (flash.isNotEmpty) bus.flash.loadImage(flash.single);
    _hasBios = true;
    reset();
  }

  @override
  void setCdromDrive(CdromDrive drive) {
    bus.opticalDrive.attach(drive);
    _discDrive = drive;
    _bootstrapEpoch++;
  }

  @override
  void onAudio(void Function(AudioBuffer) onAudio) =>
      bus.aica.sound.setAudio(onAudio);

  @override
  void setSram(Sram sram) {
    bus.flash.attachStorage(DcStorageRegion(sram));
    _storage = sram;
    for (var port = 0; port < 4; port++) {
      final controller = bus.maple.controllers[port];
      if (controller == null) continue;
      for (var slot = 0; slot < 2; slot++) {
        final child = controller.expansions[slot];
        if (child is DcMemoryCard) {
          child.attachStorage(DcStorageRegion(sram), '${port}_$slot');
        }
      }
    }
  }

  /// Attaches a memory card without app-owned device or persistence configuration.
  void attachMemoryCard(int port, int slot, DcMemoryCard? memoryCard) {
    RangeError.checkValueInInterval(port, 0, 3, 'port');
    RangeError.checkValueInInterval(slot, 0, 1, 'slot');
    final controller = bus.maple.controllers[port];
    if (controller == null) {
      throw StateError('Memory card requires an attached controller');
    }
    if (memoryCard != null && memoryCard.unit != 1 << slot) {
      throw ArgumentError(
          'Memory card endpoint must match its controller slot');
    }
    memoryCard?.resetDevice();
    final storage = _storage;
    if (memoryCard != null && storage != null) {
      memoryCard.attachStorage(DcStorageRegion(storage), '${port}_$slot');
    }
    controller.expansions[slot] = memoryCard;
  }

  /// Loads an unscrambled flat diagnostic binary, not a disc executable loader.
  /// The .dc extension is a local development convention.
  @override
  void setRom(Uint8List body) {
    if (body.isEmpty || body.length > DcBus.ramSize - programOffset) {
      throw ArgumentError('DC diagnostic program must fit in main RAM');
    }
    _program = Uint8List.fromList(body);
    reset();
  }

  /// Loads an unscrambled ISO program through the attached format-independent drive.
  /// The caller must pause guest execution while sector reads are pending.
  /// This explicit diagnostic fallback does not establish BIOS self-bootability.
  Future<DcBootstrap> bootUnscrambledDisc(
      {int entry = 0x8c00e000, Future<void> Function()? waitForSector}) async {
    if (!_hasBios) throw StateError('Disc bootstrap requires a loaded BIOS');
    final drive = _discDrive;
    if (drive == null) {
      throw StateError('Disc bootstrap requires an attached drive');
    }
    final epoch = _bootstrapEpoch, clocks = _clocks, pc = cpu.pc;
    bool current() =>
        epoch == _bootstrapEpoch &&
        clocks == _clocks &&
        pc == cpu.pc &&
        identical(drive, _discDrive);
    final boot = await loadDcBootstrap(drive,
        waitForSector: waitForSector, isCurrent: current);
    if (!current()) {
      throw StateError('Core changed during disc bootstrap loading');
    }
    startDiscBootstrap(boot.ip, boot.program, entry: entry);
    return boot;
  }

  /// Starts an explicitly loaded, unscrambled disc program through IP.BIN.
  /// This diagnostic handoff does not establish BIOS authentication or self-bootability.
  void startDiscBootstrap(Uint8List ip, Uint8List program,
      {int entry = 0x8c00e000}) {
    if (!_hasBios) throw StateError('Disc bootstrap requires a loaded BIOS');
    if (ip.length != 32768 ||
        String.fromCharCodes(ip.sublist(0, dcDiscSignature.length)) !=
            dcDiscSignature) {
      throw const FormatException(
          'Disc bootstrap requires a valid 32 KiB IP.BIN');
    }
    if (program.length < 2 || program.length > DcBus.ramSize - programOffset) {
      throw const FormatException('Disc program must fit in main RAM');
    }
    if (![0x8c008300, 0x8c00b800, 0x8c00e000, programAddress].contains(entry)) {
      throw ArgumentError.value(entry, 'entry', 'Unsupported bootstrap entry');
    }
    if (stopReason != null) {
      throw StateError(
          'Cannot start disc bootstrap while stopped: $stopReason');
    }
    // Complete the old instruction stream before replacing its bytes.
    if (cpu.inDelaySlot && exec(false).stopped) {
      throw StateError('Cannot finish BIOS delay slot: $stopReason');
    }
    _bootstrapEpoch++;
    for (final group in [0x10, 0x20, 0x30]) {
      for (final source in [0, 4, 8]) {
        bus.systemBus.write(group + source, 4, 0);
      }
    }
    if (entry == 0x8c008300) {
      // The original license code waits on the BIOS level-2 VBlank service.
      bus.systemBus.write(0x10, 4, 1 << 3);
    }
    bus.cache.reset();
    // The BIOS boot has already read the drive's media-change report.
    bus.opticalDrive.acknowledgeMediaChange();
    bus.ram.setRange(0x8000, 0x10000, ip);
    bus.ram.setRange(programOffset, programOffset + program.length, program);
    cpu
      ..sr = 0x400000f0
      ..vbr = 0x8c000000
      ..pc = entry
      ..sleeping = false;
    cpu.r[15] = 0x8d000000;
    _pendingClocks = 0;
  }

  @override
  void reset() {
    _bootstrapEpoch++;
    bus.gpu.reset(clearMemory: true);
    bus.maple.reset();
    bus.flash.reset();
    bus.systemBus.reset(clearExternal: true);
    bus.aica.reset(clearMemory: true);
    bus.g1.reset();
    bus.g2.reset(clearPins: true);
    bus.g2.setTransferRequest(0, true);
    bus.opticalDrive.reset();
    bus.ram.fillRange(0, bus.ram.length, 0);
    _jit?.reset();
    _armJit?.reset();
    cpu.reset();
    cpu.irlPins = 15;
    bus.intc.nmiHigh = true;
    _clocks = 0;
    _pendingClocks = 0;
    _batchedClocks = 0;
    stopReason = null;
    final program = _program;
    if (program != null) {
      bus.ram.setAll(programOffset, program);
      cpu.pc = programAddress;
      cpu.r[15] = 0x8d000000;
    }
  }

  static const _stateVersion = 4;

  // The drive interface supplies TOC/capabilities, not a whole-disc content hash.
  int get _stateMedia {
    final writer = StateWriter('dc.media', _stateVersion, 0);
    writer.boolean(bus.g1.bypassBiosVerification);
    if (bootBringUp) writer.int32(0x42525550);
    writer.boolean(_hasBios);
    writer.bytes(bus.bios);
    writer.boolean(_program != null);
    if (_program != null) writer.bytes(_program!);
    final drive = bus.opticalDrive.driveStatus, toc = drive.toc;
    writer.ints([
      drive.state.index,
      toc.totalSectors,
      toc.tracks.length,
      toc.isXa == null
          ? -1
          : toc.isXa!
              ? 1
              : 0
    ]);
    writer.boolean(bus.opticalDrive.hasSubcodeProvider);
    for (final track in toc.tracks) {
      writer.ints(
          [track.number, track.isAudio ? 1 : 0, track.startLba, track.sectors]);
    }
    writer.boolean(toc.sessions != null);
    if (toc.sessions != null) {
      writer.int32(toc.sessions!.length);
      for (final session in toc.sessions!) {
        writer.ints([session.number, session.firstTrack, session.startLba]);
      }
    }
    return stateMediaHash(writer.take());
  }

  @override
  Uint8List saveState() {
    if (!_hasBios && _program == null) {
      throw const StateMismatch(
          'DC state requires a BIOS or diagnostic program');
    }
    final processor = cpu;
    final writer = StateWriter('dc', _stateVersion, _stateMedia);
    writer.section('dc.core');
    writer.ints([_clocks, _pendingClocks]);
    writer.boolean(stopReason != null);
    if (stopReason != null) writer.string(stopReason!);
    processor.saveState(writer);
    bus.saveState(writer);
    return writer.take();
  }

  @override
  void loadState(Uint8List state) {
    if (!_hasBios && _program == null) {
      throw const StateMismatch('DC state requires matching loaded media');
    }
    final reader = StateReader(state, 'dc', _stateVersion, _stateMedia);
    reader.section('dc.core');
    final clocks = reader.ints();
    final reason = reader.boolean() ? reader.string() : null;
    if (clocks.length != 2 ||
        clocks.any((value) => value < 0) ||
        clocks[1] > 0x7fffffff) {
      throw const StateMismatch('DC core scheduling state');
    }
    // CPU construction resets its bus; use an isolated bus before validation.
    final stagedCpu = Sh4(DcBus())..loadState(reader);
    final stagedBus = bus.stageState(reader);
    reader.end();
    stagedBus.validateCpuSleep(stagedCpu.sleeping);
    stagedBus.validateDrive(bus.opticalDrive.driveStatus);
    final writer = StateWriter('dc.cpu.transfer', _stateVersion, 0);
    stagedCpu.saveState(writer);
    final cpuReader =
        StateReader(writer.take(), 'dc.cpu.transfer', _stateVersion, 0);
    final processor = cpu;
    _bootstrapEpoch++;
    bus.applyState(stagedBus);
    processor.loadState(cpuReader);
    cpuReader.end();
    _clocks = clocks[0];
    _pendingClocks = clocks[1];
    _batchedClocks = 0;
    stopReason = reason;
    bus.opticalDrive.rebindDriveAfterLoad();
    final jit = _jit;
    if (jit != null) {
      // Restored dirty lines go to RAM before compiled code reads it.
      bus.cache.coherent = true;
      jit.reset();
    }
  }

  void _driveBringUpPins() {
    // Provisional shared net for GPIO 0/1, matching the BIOS alternating checks.
    final gpio = bus.gpio;
    final control = gpio.read(0x2c, 4), data = gpio.read(0x30, 2);
    var driven = false, high = true, pullup = false;
    for (var pin = 0; pin < 2; pin++) {
      if (control & (1 << (pin * 2)) != 0) {
        driven = true;
        if (data & (1 << pin) == 0) high = false;
      } else if (control & (2 << (pin * 2)) == 0) {
        pullup = true;
      }
    }
    gpio.drivenMask |= 3;
    gpio.drivenValues =
        (gpio.drivenValues & ~3) | ((driven ? high : pullup) ? 3 : 0);
  }

  static const _executionStopped = 1;
  static const _executionScanline = 2;
  static const _executionSh4 = 4;
  static const _executionArm = 8;

  static ExecResult _executionResult(int elapsed, int flags) => ExecResult(
      elapsed, flags & _executionStopped != 0, flags & _executionScanline != 0)
    ..executed0 = flags & _executionSh4 != 0
    ..executed1 = flags & _executionArm != 0;

  @override
  ExecResult exec(bool step) {
    if (!_flushDevices()) return _executionResult(0, _executionStopped);
    final (elapsed, flags) = _execute(step);
    return _executionResult(elapsed, flags);
  }

  /// Ticks the devices by the deferred clocks. Returns false when stopped.
  bool _flushDevices() {
    final clocks = _batchedClocks;
    if (clocks == 0) return true;
    _batchedClocks = 0;
    try {
      bus.tickMasterClocks(clocks);
    } on DcUnsupported catch (error) {
      stopReason = error.toString();
      return false;
    }
    return true;
  }

  void _syncDevices() {
    final clocks = _batchedClocks;
    if (clocks == 0) return;
    _batchedClocks = 0;
    bus.tickMasterClocks(clocks);
  }

  /// Returns elapsed clocks and packed status for the instruction loop.
  /// With [batch], device clocks are deferred up to the next line boundary.
  (int, int) _execute(bool step, {bool batch = false}) {
    if (stopReason != null) {
      return (0, _executionStopped);
    }
    if (!_hasBios && _program == null) {
      stopReason = 'No DC BIOS or diagnostic program loaded';
      return (0, _executionStopped);
    }
    // GPIO control and data change only through device-visible accesses.
    if (bootBringUp && _pinsEpoch != bus.deviceEpoch) {
      _driveBringUpPins();
      _pinsEpoch = bus.deviceEpoch;
    }
    final previousClocks = _clocks;
    final previousLines = bus.gpu.spg.completedLines;
    final wasVideoRunning = bus.gpu.spg.running;
    final previousArmInstructions = bus.aica.executedInstructions;
    var sh4Executed = false;
    if (_pendingClocks == 0) {
      final duration =
          bus.cpg.stabilizing ? bus.cpg.stabilizationClocks : bus.cpg.cpuPeriod;
      try {
        cpu.step();
      } on DcUnsupported catch (error) {
        stopReason = error.toString();
        return (0, _executionStopped);
      }
      sh4Executed = cpu.instructionExecuted;
      _pendingClocks = duration * (bootBringUp ? 8 : 1);
    }
    var elapsed = _pendingClocks;
    // Preserve one ARM instruction per debugger observation even when the SH4
    // clock is divided or stopped for PLL stabilization.
    final soundEvent = step ? bus.aica.clocksToEvent : null;
    if (soundEvent != null && !bus.aica.armReset && soundEvent < elapsed) {
      elapsed = soundEvent;
    }
    _pendingClocks -= elapsed;
    // CPU steps stand in for clocks until the timing model exists.
    _clocks += elapsed;
    var stopped = false;
    if (batch) {
      if (_batchedClocks == 0) {
        final line = bus.gpu.spg.clocksToNextLine;
        _batchDeadline =
            line != null && line < _batchLimit ? line : _batchLimit;
      }
      _batchedClocks += elapsed;
      if (_batchedClocks >= _batchDeadline) stopped = !_flushDevices();
    } else {
      try {
        bus.tickMasterClocks(elapsed);
      } on DcUnsupported catch (error) {
        stopReason = error.toString();
        stopped = true;
      }
    }
    final rendered = wasVideoRunning || bus.gpu.spg.running
        ? bus.gpu.spg.completedLines != previousLines
        : _clocks ~/ clocksInScanline != previousClocks ~/ clocksInScanline;
    return (
      elapsed,
      (stopped ? _executionStopped : 0) |
          (rendered ? _executionScanline : 0) |
          (sh4Executed ? _executionSh4 : 0) |
          (bus.aica.executedInstructions != previousArmInstructions
              ? _executionArm
              : 0)
    );
  }

  /// Runs compiled SH-4 code up to the device batch deadline. Returns null
  /// when the interpreter takes the next step.
  (int, int)? _executeCompiled() {
    if (_pendingClocks != 0 || stopReason != null) return null;
    if (bootBringUp && _pinsEpoch != bus.deviceEpoch) {
      _driveBringUpPins();
      _pinsEpoch = bus.deviceEpoch;
    }
    if (_batchedClocks == 0) {
      final line = bus.gpu.spg.clocksToNextLine;
      _batchDeadline = line != null && line < _batchLimit ? line : _batchLimit;
    }
    final period = bus.cpg.cpuPeriod * (bootBringUp ? 8 : 1);
    final previousClocks = _clocks;
    final previousLines = bus.gpu.spg.completedLines;
    final wasVideoRunning = bus.gpu.spg.running;
    final previousArmInstructions = bus.aica.executedInstructions;
    final steps = cpu
        .runCompiled((_batchDeadline - _batchedClocks + period - 1) ~/ period);
    if (steps == 0) return null;
    final elapsed = steps * period;
    _clocks += elapsed;
    _compiledClocks += elapsed;
    _batchedClocks += elapsed;
    final stopped = _batchedClocks >= _batchDeadline && !_flushDevices();
    final rendered = wasVideoRunning || bus.gpu.spg.running
        ? bus.gpu.spg.completedLines != previousLines
        : _clocks ~/ clocksInScanline != previousClocks ~/ clocksInScanline;
    return (
      elapsed,
      _executionSh4 |
          (stopped ? _executionStopped : 0) |
          (rendered ? _executionScanline : 0) |
          (bus.aica.executedInstructions != previousArmInstructions
              ? _executionArm
              : 0)
    );
  }

  @override
  Iterable<JitDiagnostics> get jitDiagnostics =>
      [if (_jit case final jit?) jit.diagnostics];
  @override
  bool get jitEnabled => _jit != null;
  @override
  bool get jitSuspended => _jit?.suspended ?? false;
  @override
  set jitSuspended(bool value) => _jit?.suspended = value;
  @override
  int get jitClocks => _compiledClocks;
  @override
  void dispose() {
    _jit?.dispose();
    _armJit?.dispose();
  }

  @override
  ExecResult runFrame(int scanlines) {
    var elapsed = 0, flags = _executionSh4;
    cpu.cacheInterrupts = true;
    bus.deviceEpoch++;
    try {
      while (scanlines > 0) {
        final previousLines = bus.gpu.spg.completedLines;
        final wasVideoRunning = bus.gpu.spg.running;
        (elapsed, flags) = _executeCompiled() ?? _execute(false, batch: true);
        if (flags & _executionStopped != 0) break;
        if (wasVideoRunning || bus.gpu.spg.running) {
          scanlines -= bus.gpu.spg.completedLines - previousLines;
        } else if (flags & _executionScanline != 0) {
          scanlines--;
        }
      }
      if (!_flushDevices()) flags |= _executionStopped;
    } finally {
      cpu.cacheInterrupts = false;
    }
    return _executionResult(elapsed, flags);
  }

  /// Controllers attached before the input is connected read through
  /// [padPort] from here; the bus hands it to controllers attached
  /// later when they exchange.
  @override
  set input(PadSource source) {
    super.input = source;
    for (final controller in bus.maple.controllers) {
      controller?.source = padPort;
    }
  }

  @override
  List<PadButton> get buttons => DcMapleController.buttons;

  @override
  List<PadAxis> get axes => const [
        PadAxis.leftX,
        PadAxis.leftY,
      ];

  @override
  List<DebugVideoLayer> get videoLayers {
    final layers = [...super.videoLayers];
    for (var port = 0; port < 4; port++) {
      final controller = bus.maple.controllers[port];
      if (controller == null) continue;
      for (var slot = 0; slot < 2; slot++) {
        final child = controller.expansions[slot];
        if (child is DcMemoryCard) {
          layers.add(DebugVideoLayer(
              'Memory card ${String.fromCharCode(65 + port)}${slot + 1}',
              (_) => DebugRaster(child.lcd.image()),
              kind: DebugLayerKind.framebuffer));
        }
      }
    }
    return layers;
  }

  @override
  ImageBuffer imageBuffer() =>
      bus.gpu.spg.running ? bus.gpu.presentedImage : bus.gpu.image();

  @override
  int programCounter(int cpuNo) => cpuNo == 1 ? bus.aica.arm.pc : cpu.pc;
  @override
  int stackPointer(int cpuNo) => cpuNo == 1 ? bus.aica.arm.r[13] : cpu.r[15];
  @override
  int read(int cpuNo, int addr) => cpuNo == 1
      ? bus.aica.peekArmByte(addr)
      : bus.peek8(addr, privileged: cpu.privileged);

  @override
  (String, int) disasm(int cpuNo, int addr) {
    if (cpuNo == 1) {
      try {
        var op = 0;
        for (var i = 0; i < 4; i++) {
          op |= bus.aica.peekArmByte(addr + i) << (8 * i);
        }
        return (
          formatDisasm(addr.x8, op.x8, dcArm7diDisasm(op, addr), codeWidth: 8),
          4
        );
      } on DcUnsupported {
        return (
          formatDisasm(addr.x8, '????????', '<unmapped>', codeWidth: 8),
          4
        );
      }
    }
    try {
      final op = bus.peekInstruction16(addr, privileged: cpu.privileged);
      return (
        formatDisasm(addr.x8, op.x4, dcSh4Disasm(op, addr, fpscr: cpu.fpscr),
            codeWidth: 4),
        2
      );
    } on DcUnsupported {
      return (formatDisasm(addr.x8, '????', '<unmapped>', codeWidth: 4), 2);
    }
  }

  String get _registers => registerRows([
        for (var i = 0; i < 16; i++) ('R$i', cpu.r[i]),
        ('PC', cpu.pc),
        ('SR', cpu.sr),
        ('PR', cpu.pr),
        ('GBR', cpu.gbr),
        ('VBR', cpu.vbr),
        ('SSR', cpu.ssr),
        ('SPC', cpu.spc),
        ('SGR', cpu.sgr),
        ('DBR', cpu.dbr),
        for (var i = 0; i < 8; i++) ('BANK$i', cpu.bank[i]),
        ('TEA', bus.tea),
        ('EXPEVT', bus.expevt),
        ('TRA', bus.tra),
        ('MACH', cpu.mach),
        ('MACL', cpu.macl),
        ('IRL', cpu.irlPins),
        ('FPUL', cpu.fpul),
        ('FPSCR', cpu.fpscr),
        for (var i = 0; i < 16; i++) ('FR$i', cpu.fr[i]),
      ]);

  @override
  String dump(
          {bool showZeroPage = false,
          bool showSpriteVram = false,
          bool showStack = false,
          bool showApu = false}) =>
      'Experimental DC core${bootBringUp ? " (boot bring-up profile)" : ""}\n$_registers\n${showApu ? _armRegisters : ""}\n${stopReason ?? "Running"}';

  String get _dspStatus {
    final dsp = bus.aica.dsp, reason = bus.aica.dsp.programUnsupportedReason;
    final status = dsp.diagnosticBypassProgram
        ? 'full bypass'
        : dsp.programBypassed
            ? 'unsupported program bypassed'
            : reason != null
                ? 'unsupported program'
                : dsp.hasProgram
                    ? 'functional MPRO'
                    : 'no program';
    return 'AICA DSP: $status${reason == null ? '' : ' ($reason)'}';
  }

  String get _armRegisters => '$_dspStatus\nAICA ARM7DI\n${registerRows([
            for (var i = 0; i < 16; i++) ('R$i', bus.aica.arm.r[i]),
            ('CPSR', bus.aica.arm.cpsr),
            if (bus.aica.arm.mode != 0x10) ('SPSR', bus.aica.arm.spsr),
            ('RESET', bus.aica.armReset ? 1 : 0),
          ])}';

  @override
  TraceLog trace(int cpuNo) => cpuNo == 1
      ? TraceLog(
          bus.aica.arm.pc,
          bus.aica.arm.cycles,
          disasm(cpuNo, bus.aica.arm.pc).$1,
          _armRegisters,
          bus.aica.arm.debugState)
      : TraceLog(cpu.pc, _clocks, disasm(cpuNo, cpu.pc).$1, _registers, [
          ...cpu.r,
          cpu.sr,
          cpu.pr,
          ...cpu.bank,
          cpu.gbr,
          cpu.vbr,
          cpu.ssr,
          cpu.spc,
          cpu.sgr,
          cpu.dbr,
          bus.pteh,
          bus.tea,
          bus.tra,
          bus.expevt,
          bus.intevt,
          cpu.mach,
          cpu.macl,
          cpu.irlPins,
          cpu.fpul,
          cpu.fpscr,
          ...cpu.fr,
          ...cpu.xf,
        ]);
}
