import 'dart:typed_data';

import '../../cdrom_drive.dart';
import '../../state.dart';
import '../../util/int.dart';
import '../../util/uint8list.dart';
import 'aica.dart';
import 'bsc.dart';
import 'cache.dart';
import 'cpg.dart';
import 'dmac.dart';
import 'fault.dart';
import 'flash.dart';
import 'g1.dart';
import 'g2.dart';
import 'gpio.dart';
import 'gpu.dart';
import 'intc.dart';
import 'maple.dart';
import 'maple_controller.dart';
import 'memory_card.dart';
import 'mmu.dart';
import 'optical_drive.dart';
import 'rtc.dart';
import 'sci.dart';
import 'scif.dart';
import 'system_bus.dart';
import 'tmu.dart';

/// Little-endian physical bus with explicit CPU translation and cache access.
/// Unimplemented devices stop explicitly.
class DcBus {
  DcBus() {
    systemBus.gpuDma.bind(dma, _gpuDmaTransfer);
    systemBus.sortDma.bind(dma, (address) {
      final (bytes, offset) = _readExternal(address, 32, true);
      return Uint8List.fromList(bytes.sublist(offset, offset + 32));
    }, gpu.writePolygon);
    systemBus.onG2Trigger = () => g2.trigger();
    g2.setTransferRequest(
        0, true); // Synchronous AICA writes leave its functional FIFO empty.
    intc.onNmi = () => dma.nmi();
    gpu.spg.onInterrupt = systemBus.raiseNormal;
    gpu.onNormal = systemBus.raiseNormal;
    gpu.onError = systemBus.raiseError;
    gpu.spg.onVerticalBlankIn = () => maple.verticalBlankIn();
    gpu.spg.onVerticalBlankOut = () => maple.verticalBlankOut();
  }
  static const biosSize = 2 * 1024 * 1024;
  static const ramSize = 16 * 1024 * 1024;
  final bios = Uint8List(biosSize);
  final ram = Uint8List(ramSize);
  final _storeQueues = Uint8List(64);
  final _qacr = Uint32List(2);
  final bsc = DcBsc();
  final gpio = DcGpio();
  final tmu = DcTmu();
  final intc = DcIntc();
  final scif = DcScif();
  final sci = DcSci();
  late final DcDmac dma = DcDmac(_dmaTransfer,
      externalRequest: (channel, resource) =>
          channel == 2 &&
          resource == 2 &&
          dma.ddtEnabled &&
          systemBus.c2DmaActive,
      peripheralRequest: (resource) => switch (resource) {
            8 => sci.transmitRequest,
            9 => sci.receiveRequest,
            10 => scif.transmitRequest,
            11 => scif.receiveRequest,
            _ => false,
          });
  late final cache = DcCache(_resolve,
      readExternal: _readExternal,
      writeExternal: _writeExternal,
      readInstructionExternal: _readInstructionExternal);
  final cpg = DcCpg();
  final sh4Rtc = DcRtc();
  // BIOS bring-up uses the documented reset/disabled UBC control state only.
  static bool _disabledUbcControl(int address) =>
      !(address >= 0xc0000000 && address < 0xe0000000) &&
      const [0x1f200008, 0x1f200014, 0x1f200020].contains(address & 0x1fffffff);
  final flash = DcFlash();
  final systemBus = DcSystemBus();
  final gpu = DcGpu();
  late final aica = DcAica(
      externalActive: () => opticalDrive.audio.playing,
      externalSample: () => opticalDrive.sampleAudio(),
      onInterrupt: (level) => systemBus
          .setExternal((systemBus.externalStatus & ~2) | (level ? 2 : 0)));
  late final DcOpticalDrive opticalDrive = DcOpticalDrive(
      bypassBootChecks: () => g1.bypassBiosVerification,
      onInterrupt: (level) => systemBus
          .setExternal((systemBus.externalStatus & ~1) | (level ? 1 : 0)));
  late final DcG1 g1 = DcG1(opticalDrive, dma, writeRoot: (address, values) {
    _validateExternalWrite(address, values.length);
    _writeExternal(address, values);
  }, onNormal: systemBus.raiseNormal, onError: systemBus.raiseError);
  late final g2 = DcG2(dma,
      readRoot: (address) {
        final (bytes, offset) = _readExternal(address, 32, true);
        return Uint8List.fromList(bytes.sublist(offset, offset + 32));
      },
      writeRoot: (address, bytes) {
        _validateExternalWrite(address, 32);
        _writeExternal(address, bytes);
      },
      readG2: (address) {
        final register = DcAica.registerOffset(address);
        if (register != null) return aica.read(register, 4);
        final (bytes, offset) = _readExternal(address, 4, true);
        return bytes.getUint32LE(offset);
      },
      writeG2: (address, value) {
        final register = DcAica.registerOffset(address);
        if (register != null) return aica.write(register, 4, value);
        _validateExternalWrite(address, 4);
        _writeExternal(address, _valueBytes(4, value));
      },
      hardwareRequest: () => systemBus.g2DmaRequest,
      onNormal: systemBus.raiseNormal,
      onError: systemBus.raiseError);
  late final maple = DcMaple(ram,
      dma: dma, onNormal: systemBus.raiseNormal, onError: systemBus.raiseError);
  final mmu = DcMmu();
  int tea = 0, tra = 0, expevt = 0, intevt = 0;
  int get pteh => mmu.pteh;
  set pteh(int value) => mmu.pteh = value & 0xfffffcff;
  int get mmucr => mmu.control;
  set mmucr(int value) => mmu.control = value;

  void validateStateTarget() {
    flash.validateStateTarget();
    maple.validateStateTarget();
  }

  String? _identifyDdtOwner(Object owner) =>
      systemBus.sortDma.identifyDdtOwner(owner) ??
      systemBus.gpuDma.identifyDdtOwner(owner) ??
      g1.identifyDdtOwner(owner) ??
      g2.identifyDdtOwner(owner) ??
      maple.identifyDdtOwner(owner);

  DcDdtStateBinding? _resolveDdtOwner(String id, int address, bool write) =>
      systemBus.sortDma.resolveDdtOwner(id, address, write) ??
      systemBus.gpuDma.resolveDdtOwner(id, address, write) ??
      g1.resolveDdtOwner(id, address, write) ??
      g2.resolveDdtOwner(id, address, write) ??
      maple.resolveDdtOwner(id, address, write);

  void _saveComponents(StateWriter writer) {
    cpg.saveState(writer);
    sh4Rtc.saveState(writer);
    bsc.saveState(writer);
    gpio.saveState(writer);
    tmu.saveState(writer);
    intc.saveState(writer);
    sci.saveState(writer);
    scif.saveState(writer);
    mmu.saveState(writer);
    cache.saveState(writer);
    flash.saveState(writer);
    gpu.saveState(writer);
    opticalDrive.saveState(writer);
    aica.saveState(writer);
    g1.saveState(writer);
    g2.saveState(writer);
    maple.saveState(writer);
    dma.saveState(writer, identifyDdtOwner: _identifyDdtOwner);
    systemBus.saveState(writer);
  }

  void _loadComponents(StateReader reader) {
    // AICA restores its external IRQ level; this must not create a G2 grant.
    final trigger = systemBus.onG2Trigger;
    final gpuTriggers = systemBus.dmaTriggersEnabled;
    systemBus.onG2Trigger = null;
    systemBus.dmaTriggersEnabled = false;
    try {
      cpg.loadState(reader);
      sh4Rtc.loadState(reader);
      bsc.loadState(reader);
      gpio.loadState(reader);
      tmu.loadState(reader);
      intc.loadState(reader);
      sci.loadState(reader);
      scif.loadState(reader);
      mmu.loadState(reader);
      cache.loadState(reader);
      flash.loadState(reader);
      gpu.loadState(reader);
      opticalDrive.loadState(reader);
      aica.loadState(reader);
      g1.loadState(reader);
      g2.loadState(reader);
      maple.loadState(reader);
      dma.loadState(reader, resolveDdtOwner: _resolveDdtOwner);
      // Restore sampled HOLLY levels after all device-owned IRQ updates.
      systemBus.loadState(reader);
      systemBus.gpuDma.validateDdtBinding();
      systemBus.sortDma.validateDdtBinding();
    } finally {
      systemBus.onG2Trigger = trigger;
      systemBus.dmaTriggersEnabled = gpuTriggers;
    }
  }

  void saveState(StateWriter writer) {
    validateStateTarget();
    writer.section('dc.bus');
    writer.ints([tea, tra, expevt, intevt]);
    writer.bytes(ram);
    writer.bytes(_storeQueues);
    writer.ints(_qacr);
    _saveComponents(writer);
  }

  void _readState(StateReader reader) {
    reader.section('dc.bus');
    final registers = reader.ints(), memory = reader.bytes();
    final queues = reader.bytes(), qacr = reader.ints();
    if (registers.length != 4 ||
        registers.any((value) => value < 0 || value > 0xffffffff) ||
        memory.length != ramSize ||
        queues.length != 64 ||
        qacr.length != 2 ||
        qacr.any((value) => value < 0 || value & ~0x1c != 0)) {
      throw const StateMismatch('DC bus memory or register state');
    }
    _loadComponents(reader);
    tea = registers[0];
    tra = registers[1];
    expevt = registers[2];
    intevt = registers[3];
    ram.setAll(0, memory);
    _storeQueues.setAll(0, queues);
    _qacr.setAll(0, qacr);
  }

  DcBusState stageState(StateReader reader) {
    validateStateTarget();
    final staged = DcBus();
    staged.aica.sound.diagnosticByteAddressAdpcm =
        aica.sound.diagnosticByteAddressAdpcm;
    // Port topology is build configuration; preserve destination device objects.
    for (var port = 0; port < 4; port++) {
      final controller = maple.controllers[port];
      if (controller == null) {
        staged.maple.controllers[port] = null;
        continue;
      }
      final clone = DcMapleController();
      for (var slot = 0; slot < 2; slot++) {
        final child = controller.expansions[slot];
        if (child is DcMemoryCard)
          clone.expansions[slot] = DcMemoryCard(unit: child.unit);
      }
      staged.maple.controllers[port] = clone;
    }
    staged._readState(reader);
    return DcBusState._(staged);
  }

  void loadState(StateReader reader) => applyState(stageState(reader));

  void applyState(DcBusState state) {
    validateStateTarget();
    final staged = state._bus;
    final writer = StateWriter('dc.bus.transfer', 1, 0);
    staged._saveComponents(writer);
    final components = StateReader(writer.take(), 'dc.bus.transfer', 1, 0);
    _loadComponents(components);
    components.end();
    ram.setAll(0, staged.ram);
    _storeQueues.setAll(0, staged._storeQueues);
    _qacr.setAll(0, staged._qacr);
    tea = staged.tea;
    tra = staged.tra;
    expevt = staged.expevt;
    intevt = staged.intevt;
  }

  static bool isStoreQueue(int address) =>
      address.mask32 >= 0xe0000000 && address.mask32 < 0xe4000000;

  DcTranslation? translateCpu(int address,
          {bool write = false,
          bool instruction = false,
          bool privileged = true,
          bool touch = true}) =>
      mmu.translate(address,
          write: write,
          instruction: instruction,
          privileged: privileged,
          touch: touch,
          ram: !instruction &&
              DcCache.isRamArea(address) &&
              cache.ccr & 0x21 == 0x21);

  /// Brings deferred device clocks up to the current CPU time.
  void Function()? onDeviceAccess;

  /// Changes whenever device state may have changed: on ticks and on CPU
  /// accesses outside main RAM. The CPU reuses its interrupt scan in between.
  int deviceEpoch = 0;

  /// Synchronizes the devices before a CPU operation that observes them.
  void syncDevices() {
    deviceEpoch++;
    onDeviceAccess?.call();
  }

  /// Main RAM holds no device state, so its accesses need no device sync.
  /// Other data accesses, and root-bus fetches while G1 DMA runs, sync first.
  void _syncFor(int address, DcTranslation? mapping, {bool fetch = false}) {
    if (_ordinaryRam(mapping?.physical ?? address)) return;
    if (fetch && !g1.busy) return;
    syncDevices();
  }

  /// Main RAM addressed without translation (MMU off, or P1/P2).
  bool _directRam(int address) {
    address = address.mask32;
    return _ordinaryRam(address) && (address >= 0x80000000 || !mmu.enabled);
  }

  /// Fetches an aligned instruction word. Untranslated fetches that hit the
  /// instruction cache or read uncached main RAM skip the general path; both
  /// have no side effects.
  int fetchInstruction(int address, {required bool privileged}) {
    address = address.mask32;
    if (address < 0xe0000000 &&
        (!mmu.enabled || (address >= 0x80000000 && address < 0xc0000000))) {
      final hit = cache.instructionHit(address);
      if (hit >= 0) return hit;
      if (_ordinaryRam(address) &&
          (address >= 0xa0000000 || cache.ccr & 0x100 == 0)) {
        final offset = address & (ramSize - 1);
        return ram[offset] | (ram[offset + 1] << 8);
      }
    }
    return cpuRead(address, 2, privileged: privileged, instruction: true);
  }

  int cpuRead(int address, int size,
      {bool privileged = true, bool instruction = false, bool peek = false}) {
    if (!instruction &&
        !peek &&
        address & (size - 1) == 0 &&
        _directRam(address)) {
      final hit = cache.operandHit(address, size);
      if (hit >= 0) return hit;
      if (address >= 0xa0000000 || cache.ccr & 1 == 0) {
        final offset = address & (ramSize - 1);
        return switch (size) {
          1 => ram[offset],
          2 => ram[offset] | (ram[offset + 1] << 8),
          _ => ram[offset] |
              (ram[offset + 1] << 8) |
              (ram[offset + 2] << 16) |
              (ram[offset + 3] << 24),
        };
      }
    }
    final mapping = translateCpu(address,
        privileged: privileged, instruction: instruction, touch: !peek);
    if (!peek) _syncFor(address, mapping, fetch: instruction);
    if (instruction) {
      final (bytes, offset) = cache.readLocation(address, size,
          instruction: true,
          fill: !peek,
          physical: mapping?.physical,
          cacheable: mapping?.cacheable);
      return bytes.getUint16LE(offset);
    }
    return switch (size) {
      1 => read8(address, mapping: mapping, peek: peek),
      2 => read16(address, mapping: mapping, peek: peek),
      _ => read32(address, mapping: mapping, peek: peek),
    };
  }

  void cpuWrite(int address, int size, int value,
      {bool privileged = true, bool allocate = false}) {
    if (!allocate && address & (size - 1) == 0 && _directRam(address)) {
      if (cache.operandWriteHit(address, size, value)) return;
      if (address >= 0xa0000000 || cache.ccr & 1 == 0) {
        final offset = address & (ramSize - 1);
        for (var i = 0; i < size; i++) {
          ram[offset + i] = value >> (i * 8);
        }
        return;
      }
    }
    var mapping = translateCpu(address, write: true, privileged: privileged);
    // A queue store validates its translation but writes on-chip queue storage.
    if (isStoreQueue(address)) {
      mapping = null;
    } else {
      _syncFor(address, mapping);
    }
    switch (size) {
      case 1:
        write8(address, value, mapping: mapping);
      case 2:
        write16(address, value, mapping: mapping);
      case 4:
        write32(address, value, mapping: mapping, allocate: allocate);
    }
  }

  (int, int) cpuReadPair(int address, {bool privileged = true}) {
    final mapping = translateCpu(address, privileged: privileged);
    _syncFor(address, mapping);
    return readPair(address, mapping: mapping);
  }

  void cpuWritePair(int address, int first, int second,
      {bool privileged = true}) {
    var mapping = translateCpu(address, write: true, privileged: privileged);
    if (isStoreQueue(address)) {
      mapping = null;
    } else {
      _syncFor(address, mapping);
    }
    writePair(address, first, second, mapping: mapping);
  }

  void cpuCacheOperation(int address, int operation, {bool privileged = true}) {
    final mapping =
        translateCpu(address, write: operation == 0, privileged: privileged);
    cache.operate(address, operation,
        physical: mapping?.physical, cacheable: mapping?.cacheable);
  }

  void cpuPrefetch(int address, {bool privileged = true}) {
    try {
      final mapping = translateCpu(address, privileged: privileged);
      cache.prefetch(address,
          physical: mapping?.physical, cacheable: mapping?.cacheable);
    } on DcCpuException catch (error) {
      if (error.reset) rethrow;
    }
  }

  /// Synchronous burst model; bus arbitration and transfer latency are pending.
  void transferStoreQueue(int address, {bool privileged = true}) {
    syncDevices();
    address = address.mask32;
    final queue = (address >> 5) & 1;
    final translated = translateCpu(address, privileged: privileged);
    final destination = translated == null
        ? (address & 0x03ffffe0) | ((_qacr[queue] & 0x1c) << 24)
        : translated.physical & ~31;
    // Validate the whole burst before committing any external bytes.
    _writeExternal(destination,
        Uint8List.fromList(_storeQueues.sublist(queue * 32, queue * 32 + 32)));
  }

  void resetCpuRegisters(
      {bool manual = false, bool preserveClockControl = false}) {
    cpg.reset(powerOn: !manual && !preserveClockControl);
    sh4Rtc.reset(powerOn: !manual);
    bsc.reset(powerOn: !manual);
    gpio.reset(powerOn: !manual);
    cache.reset(manual: manual);
    tea = tra = expevt = intevt = 0;
    mmu.reset(manual: manual);
    _qacr.fillRange(0, 2, 0);
    _storeQueues.fillRange(0, 64, 0);
    tmu.reset();
    intc.reset();
    sci.reset();
    sci.clockEnabled = cpg.standby & 1 == 0;
    scif.reset();
    scif.clockEnabled = cpg.standby & 8 == 0;
    dma.reset();
  }

  bool _dmaTransfer(int source, int destination, int size, int resource) {
    if (resource == 2 && systemBus.c2DmaActive) {
      if (size != 32) {
        throw const DcUnsupported('TA channel-2 DMA requires 32-byte units');
      }
      final target = systemBus.c2Destination;
      _validateExternalWrite(target, size);
      final (bytes, offset) = _readExternal(source, size, true);
      _writeExternal(
          target, Uint8List.fromList(bytes.sublist(offset, offset + size)));
      systemBus.completeC2Burst();
      return true;
    }
    if ((resource == 8 && destination != 0x1fe0000c) ||
        (resource == 9 && source != 0x1fe00014) ||
        (resource == 10 && destination != 0x1fe8000c) ||
        (resource == 11 && source != 0x1fe80014)) {
      throw DcUnsupported(
          'DMA serial request requires its matching data register');
    }
    if ([5, 8, 10, 13].contains(resource)) {
      if (destination == 0x1fe0000c) {
        if (size != 1) return false;
        final (input, offset) = _readExternal(source, 1, true);
        sci.dmaWrite(input[offset]);
        return true;
      }
      if (destination == 0x1fe8000c) {
        if (size != 1) return false;
        final (input, offset) = _readExternal(source, 1, true);
        scif.dmaWrite(input[offset]);
        return true;
      }
      throw DcUnsupported('unimplemented DMA peripheral destination');
    }
    if ([6, 9, 11, 14].contains(resource)) {
      if (source == 0x1fe00014) {
        if (size != 1) return false;
        _validateExternalWrite(destination, 1);
        _writeExternal(destination, Uint8List.fromList([sci.dmaRead()]));
        return true;
      }
      if (source == 0x1fe80014) {
        if (size != 1) return false;
        _validateExternalWrite(destination, 1);
        _writeExternal(destination, Uint8List.fromList([scif.dmaRead()]));
        return true;
      }
      throw DcUnsupported('unimplemented DMA peripheral source');
    }
    final (input, inputOffset) = _resolve(source, size, false);
    _validateExternalWrite(destination, size);
    g1.observeRootAccess(source);
    if (DcAica.memoryOffset(source) != null) {
      aica.validateSystemMemory(write: false);
    }
    final (readBytes, readOffset) =
        _flashOffset(source) == null && DcGpu.vramOffset(source) == null
            ? (input, inputOffset)
            : _readExternal(source, size, true);
    final values =
        Uint8List.fromList(readBytes.sublist(readOffset, readOffset + size));
    _writeExternal(destination, values);
    return true;
  }

  bool _gpuDmaTransfer(int target, int root, bool toRoot) {
    final register = _gpuOffset(target);
    if (register == null) {
      final source = toRoot ? target : root;
      final destination = toRoot ? root : target;
      final (bytes, offset) = _readExternal(source, 32, true);
      final values = Uint8List.fromList(bytes.sublist(offset, offset + 32));
      _validateExternalWrite(destination, 32);
      _writeExternal(destination, values);
    } else if (toRoot) {
      final bytes = ByteData(32);
      for (var i = 0; i < 32; i += 4) {
        bytes.setUint32(i, gpu.read(register + i, 4), Endian.little);
      }
      _validateExternalWrite(root, 32);
      _writeExternal(root, bytes.buffer.asUint8List());
    } else {
      final (bytes, offset) = _readExternal(root, 32, true);
      final values = ByteData.sublistView(bytes, offset, offset + 32);
      for (var i = 0; i < 32; i += 4) {
        gpu.write(register + i, 4, values.getUint32(i, Endian.little));
      }
    }
    return true;
  }

  void tickCpuClocks(int clocks) => tickMasterClocks(clocks * cpg.cpuPeriod);

  void tickMasterClocks(int clocks) {
    if (clocks < 0) throw ArgumentError.value(clocks, 'clocks');
    deviceEpoch++;
    while (clocks > 0) {
      opticalDrive.prepare();
      g1.prepare();
      systemBus.gpuDma.prepare();
      systemBus.sortDma.prepare();
      g2.prepare();
      maple.prepare();
      final interleave = g1.hasDirectRootRequest ||
          g2.hasDirectRootRequest ||
          (!cpg.deepSleeping &&
              cpg.standby & 0x10 == 0 &&
              (systemBus.c2DmaActive ||
                  dma.hasDdtTransfers ||
                  dma.hasPeripheralTransfers ||
                  dma.hasAutoMemoryTransferTo(DcGpu.yuvFifo) ||
                  ((gpu.spg.running ||
                          gpu.render.busy ||
                          aica.needsSampleClock ||
                          aica.internalDmaBusy) &&
                      dma.hasAutoMemoryTransfers)));
      var quantum = clocks;
      if (interleave && cpg.clocksToBusEdge < quantum) {
        quantum = cpg.clocksToBusEdge;
      }
      if (maple.busy && maple.clocksToEvent < quantum) {
        quantum = maple.clocksToEvent;
      }
      if (maple.busy) {
        final edge = gpu.spg.clocksToVerticalBlankIn;
        if (edge != null && edge < quantum) quantum = edge;
      }
      if (g1.clocksToEvent > 0 && g1.clocksToEvent < quantum) {
        quantum = g1.clocksToEvent;
      }
      if (g2.clocksToEvent > 0 && g2.clocksToEvent < quantum) {
        quantum = g2.clocksToEvent;
      }
      if (g2.needsHardwareTrigger) {
        final edge = gpu.spg.clocksToInterrupt(systemBus.g2NormalMask);
        if (edge != null && edge < quantum) quantum = edge;
      }
      if (systemBus.gpuDma.needsHardwareTrigger) {
        final edge = gpu.spg.clocksToInterrupt(systemBus.gpuNormalMask);
        if (edge != null && edge < quantum) quantum = edge;
      }
      if (opticalDrive.clocksToEvent > 0 &&
          opticalDrive.clocksToEvent < quantum) {
        quantum = opticalDrive.clocksToEvent;
      }
      final renderEvent = gpu.render.clocksToEvent;
      if (renderEvent != null && renderEvent < quantum) quantum = renderEvent;
      final stripEvent = gpu.clocksToStripScan;
      if (stripEvent != null && stripEvent < quantum) quantum = stripEvent;
      final soundEvent = aica.clocksToEvent;
      if (soundEvent != null && soundEvent < quantum) quantum = soundEvent;
      if (maple.hardwareEnabled) {
        final edge = gpu.spg.clocksToVerticalBlankOut;
        if (edge != null && edge < quantum) quantum = edge;
      }
      _tickMasterClocks(quantum);
      clocks -= quantum;
    }
  }

  void _tickMasterClocks(int clocks) {
    final g2Ticket = g2.serialTicket;
    final g2RootMask = g2.directRootMask;
    aica.tickMasterClocks(clocks);
    flash.tickMasterClocks(clocks);
    opticalDrive.tickMasterClocks(clocks, prepared: true);
    maple.tickMasterClocks(clocks);
    gpu.spg.tickMasterClocks(clocks);
    gpu.render.tickMasterClocks(clocks);
    final (peripheralClocks, busClocks) = cpg.advance(clocks);
    if (busClocks != 0) bsc.tickBusClocks(busClocks);
    gpio.enabled = bsc.read(4, 2) & 1 != 0;
    if (busClocks != 0) gpio.tickBusClocks(busClocks);
    // SCI/SCIF can start queued transfers even with zero elapsed clocks.
    if (cpg.standby & 1 == 0) sci.tickPeripheralClocks(peripheralClocks);
    if (peripheralClocks != 0 && cpg.standby & 4 == 0) {
      tmu.tickPeripheralClocks(peripheralClocks);
    }
    if (cpg.standby & 8 == 0) scif.tickPeripheralClocks(peripheralClocks);
    if (!cpg.deepSleeping && cpg.standby & 0x10 == 0) {
      dma.tickTransferUnits(busClocks);
    }
    g1.tickRootUnits(busClocks);
    g2.tickRootUnits(busClocks, eligibleMask: g2RootMask);
    g1.tickMasterClocks(clocks);
    g2.tickMasterClocks(clocks, g2Ticket);
    maple.prepare();
  }

  void _writeCpg(int offset, int size, int value) {
    cpg.write(offset, size, value);
    sci.clockEnabled = cpg.standby & 1 == 0;
    scif.clockEnabled = cpg.standby & 8 == 0;
  }

  int? _cpgOffset(int address) {
    address = address.mask32;
    if (address >= 0xc0000000 && address < 0xe0000000) return null;
    final physical = address & 0x1fffffff;
    return physical >= 0x1fc00000 && physical <= 0x1fc00013
        ? physical - 0x1fc00000
        : null;
  }

  int? _g2Offset(int address) {
    final physical = DcAica.physical(address);
    return physical != null && physical >= 0x005f7800 && physical < 0x005f7900
        ? physical - 0x005f7800
        : null;
  }

  int? _g1Offset(int address) {
    address = address.mask32;
    if (address >= 0xc0000000) return null;
    final physical = address & 0x1dffffff;
    return physical >= 0x005f7400 && physical < 0x005f7500
        ? physical - 0x005f7400
        : null;
  }

  int? _opticalDriveOffset(int address) {
    address = address.mask32;
    if (address >= 0xc0000000) return null;
    final physical = address & 0x1dffffff;
    return physical >= 0x005f7000 && physical < 0x005f70a0
        ? physical - 0x005f7000
        : null;
  }

  int? _mapleOffset(int address) {
    address = address.mask32;
    if (address >= 0xc0000000) return null;
    final physical = address & 0x1dffffff;
    return physical >= 0x005f6c00 && physical < 0x005f6d00
        ? physical - 0x005f6c00
        : null;
  }

  int? _systemBusOffset(int address) {
    address = address.mask32;
    if (address >= 0xc0000000) return null;
    final physical = address & 0x1dffffff;
    return ((physical >= 0x005f6800 && physical <= 0x005f684f) ||
            (physical >= 0x005f6860 && physical <= 0x005f6863) ||
            (physical >= 0x005f688c && physical <= 0x005f68af) ||
            (physical >= 0x005f7c00 && physical <= 0x005f7c1b) ||
            (physical >= 0x005f7c80 && physical <= 0x005f7c83) ||
            (physical >= 0x005f7cf0 && physical <= 0x005f7cfb) ||
            (physical >= 0x005f6900 && physical <= 0x005f6957))
        ? physical - 0x005f6900
        : null;
  }

  int? _flashOffset(int address) {
    address = address.mask32;
    if (address >= 0xc0000000) return null;
    final physical = address & 0x1fffffff;
    return physical >= 0x00200000 && physical < 0x00220000
        ? physical - 0x00200000
        : null;
  }

  bool _flashCached(int address, bool? cacheable) =>
      (cacheable ?? address < 0xa0000000) && cache.ccr & 1 != 0;

  (Uint8List, int) _readInstructionExternal(
      int address, int size, bool sideEffects) {
    address &= 0xffffffff;
    if (_ordinaryRead(address)) {
      if (sideEffects) g1.observeRootAccess(address);
      final physical = address & 0x1fffffff;
      if (physical < biosSize) return (bios, physical);
      return (ram, physical & (ramSize - 1));
    }
    if (sideEffects) return _readExternal(address, size, true);
    return _resolve(address, size, false);
  }

  (Uint8List, int) _readExternal(int address, int size, bool sideEffects) {
    if (sideEffects) g1.observeRootAccess(address);
    final location = _resolve(address, size, false);
    if (sideEffects && DcAica.memoryOffset(address) != null) {
      aica.validateSystemMemory(write: false);
    }
    if (DcGpu.vramOffset(address) != null) {
      return (gpu.readMemory(address, size, peek: !sideEffects), 0);
    }
    final offset = _flashOffset(address);
    if (offset == null || !sideEffects) return location;
    return (
      Uint8List.fromList(
          [for (var i = 0; i < size; i++) flash.read(offset + i)]),
      0
    );
  }

  void _validateExternalWrite(int address, int size) {
    _resolve(address, size, true);
    if ((DcGpu.polygonFifo(address) ||
            DcGpu.textureFifo(address) ||
            DcGpu.yuvFifo(address)) &&
        size != 32) {
      throw const DcUnsupported('TA FIFO requires a 32-byte burst');
    }
    if (DcAica.memoryOffset(address) != null) {
      aica.validateSystemMemory(write: true);
    }
    if (DcGpu.vramOffset(address) != null) gpu.validateTransfer(size);
  }

  void _writeExternal(int address, Uint8List values) {
    if (DcGpu.polygonFifo(address)) return gpu.writePolygon(values);
    if (DcGpu.yuvFifo(address)) return gpu.writeYuv(values);
    if (DcGpu.textureFifo(address)) return gpu.writeTexture(address, values);
    final (bytes, offset) = _resolve(address, values.length, true);
    if (DcAica.memoryOffset(address) != null) {
      aica.validateSystemMemory(write: true);
    }
    if (DcGpu.vramOffset(address) != null) {
      gpu.writeMemory(address, values);
    } else {
      bytes.setRange(offset, offset + values.length, values);
    }
  }

  int? _fifoRegister(int address) {
    address &= 0xffffffff;
    if (address >= 0xc0000000) return null;
    final physical = address & 0x1dffffff;
    return physical >= 0x005f6880 && physical < 0x005f688c
        ? physical - 0x005f6800
        : null;
  }

  int? _gpuOffset(int address) {
    address = address.mask32;
    if (address >= 0xc0000000) return null;
    final physical = address & 0x1dffffff;
    return physical >= 0x005f8000 && physical < 0x005fa000
        ? physical - 0x005f8000
        : null;
  }

  void _writeFlash(
      int address, int offset, int size, int value, bool? cacheable) {
    if (offset & (size - 1) != 0) throw DcUnsupported('unaligned flash write');
    if (_flashCached(address, cacheable)) {
      throw DcUnsupported('DC flash permits only uncached writes');
    }
    g1.observeRootAccess(address);
    // The G1 device is byte-wide; complete the CPU access in address order.
    for (var i = 0; i < size; i++) {
      flash.write(offset + i, value >> (i * 8));
    }
  }

  int? _sciOffset(int address) {
    address = address.mask32;
    if (address >= 0xc0000000 && address < 0xe0000000) return null;
    final physical = address & 0x1fffffff;
    return physical >= 0x1fe00000 && physical <= 0x1fe0001f
        ? physical - 0x1fe00000
        : null;
  }

  int? _scifOffset(int address) {
    address = address.mask32;
    if (address >= 0xc0000000 && address < 0xe0000000) return null;
    final physical = address & 0x1fffffff;
    return physical >= 0x1fe80000 && physical <= 0x1fe80027
        ? physical - 0x1fe80000
        : null;
  }

  int? _dmaOffset(int address) {
    address = address.mask32;
    if (address >= 0xc0000000 && address < 0xe0000000) return null;
    final physical = address & 0x1fffffff;
    return physical >= 0x1fa00000 && physical <= 0x1fa00040
        ? physical - 0x1fa00000
        : null;
  }

  int? _intcOffset(int address) {
    address = address.mask32;
    if (address >= 0xc0000000 && address < 0xe0000000) return null;
    final physical = address & 0x1fffffff;
    return physical >= 0x1fd00000 && physical <= 0x1fd0000e && physical & 1 == 0
        ? physical - 0x1fd00000
        : null;
  }

  int? _tmuOffset(int address) {
    address = address.mask32;
    if (address >= 0xc0000000 && address < 0xe0000000) return null;
    final physical = address & 0x1fffffff;
    return physical >= 0x1fd80000 && physical <= 0x1fd8002f
        ? physical - 0x1fd80000
        : null;
  }

  int? _cpuRegister(int address) {
    address = address.mask32;
    // P4 and direct area-7 aliases only; P3 remains unsupported.
    if (address >= 0xc0000000 && address < 0xe0000000) return null;
    final physical = address & 0x1fffffff;
    return [
      0x1f000000,
      0x1f000004,
      0x1f000008,
      0x1f00000c,
      0x1f000010,
      0x1f00001c,
      0x1f000030,
      0x1f000044,
      0x1f000020,
      0x1f000024,
      0x1f000028,
      0x1f000034,
      0x1f000038,
      0x1f00003c
    ].contains(physical)
        ? physical & 255
        : null;
  }

  (Uint8List, int) _resolve(int address, int size, bool write) {
    address = address.mask32;
    if (address & (size - 1) != 0) {
      throw DcUnsupported('unaligned $size-byte access at ${address.x8}');
    }
    if (write && (size == 4 || size == 8) && isStoreQueue(address)) {
      return (_storeQueues, address & 63);
    }
    // P0/P1/P2 are direct-mapped while the MMU is disabled. P3 and P4
    // must never silently alias ordinary physical memory.
    if (address >= 0xc0000000) {
      throw DcUnsupported('unimplemented address region at ${address.x8}');
    }
    final physical = address & 0x1fffffff;
    if (DcGpu.polygonFifo(address) ||
        DcGpu.textureFifo(address) ||
        DcGpu.yuvFifo(address)) {
      if (!write || ![4, 8, 32].contains(size)) {
        throw const DcUnsupported(
            'TA FIFO is write-only with longword cache lanes');
      }
      return (Uint8List(size), 0);
    }
    final soundMemory = DcAica.memoryOffset(address);
    if (soundMemory != null) {
      aica.validateMemory(soundMemory, size);
      return (aica.memory, soundMemory);
    }
    if (DcGpu.vramOffset(address) != null) {
      return (
        write ? Uint8List(size) : gpu.readMemory(address, size, peek: true),
        0
      );
    }
    if (physical < biosSize && !write) return (bios, physical);
    final flashOffset = _flashOffset(address);
    if (flashOffset != null) {
      if (write) {
        throw DcUnsupported('flash protocol requires direct byte accesses');
      }
      return (
        Uint8List.fromList([
          for (var i = 0; i < size; i++)
            flash.read(flashOffset + i, sideEffects: false)
        ]),
        0
      );
    }
    if (physical >= 0x0c000000 && physical < 0x10000000) {
      return (ram, physical & (ramSize - 1));
    }
    throw DcUnsupported(
        '${write ? "write" : "read"} at ${address.x8} ($size bytes)');
  }

  int read8(int address, {DcTranslation? mapping, bool peek = false}) {
    final decoded = mapping?.physical ?? address;
    // No optional G2 modem is attached; return an absent-device ID.
    if (decoded < 0xc0000000 && decoded & 0x1dffffff == 0x00600004) return 0xff;
    final fifoRegister = _fifoRegister(decoded);
    if (fifoRegister != null) return gpu.readFifoRegister(fifoRegister, 1);
    final g2Register = _g2Offset(decoded);
    if (g2Register != null) return g2.read(g2Register, 1);
    final sound = DcAica.registerOffset(decoded);
    if (sound != null) return aica.read(sound, 1, sideEffects: !peek);
    final rtc = DcAica.rtcOffset(decoded);
    if (rtc != null) return aica.readRtc(rtc, 1);
    final video = _gpuOffset(decoded);
    if (video != null) return gpu.read(video, 1);
    final system = _systemBusOffset(decoded);
    if (system != null) return systemBus.read(system, 1);
    final drive = _opticalDriveOffset(decoded);
    if (drive != null) {
      if (!peek) g1.observeRootAccess(decoded);
      return opticalDrive.read(drive, 1, sideEffects: !peek);
    }
    final g1Register = _g1Offset(decoded);
    if (g1Register != null) return g1.read(g1Register, 1);
    final mapleRegister = _mapleOffset(decoded);
    if (mapleRegister != null) return maple.read(mapleRegister, 1);
    final clock = _cpgOffset(decoded);
    if (clock != null) return cpg.read(clock, 1);
    final rtcRegister = DcRtc.offset(decoded);
    if (rtcRegister != null) return sh4Rtc.read(rtcRegister, 1);
    final busControl = DcBsc.offset(decoded);
    if (busControl != null) return bsc.read(busControl, 1);
    final port = DcGpio.offset(decoded);
    if (port != null) return gpio.read(port, 1);
    final serial1 = _sciOffset(decoded);
    if (serial1 != null) return sci.read(serial1, 1, sideEffects: !peek);
    final serial = _scifOffset(decoded);
    if (serial != null) return scif.read(serial, 1, sideEffects: !peek);
    final timer = _tmuOffset(decoded);
    if (timer != null) return tmu.read(timer, 1);
    final (bytes, offset) = cache.readLocation(address, 1,
        physical: mapping?.physical,
        cacheable: mapping?.cacheable,
        fill: !peek);
    return bytes[offset];
  }

  // Ordinary reads still use the cache/MMU path, but cannot address a device.
  static bool _ordinaryRead(int address) {
    address &= 0xffffffff;
    if (address >= 0xc0000000) return false;
    final physical = address & 0x1fffffff;
    return physical < biosSize ||
        (physical >= 0x0c000000 && physical < 0x10000000);
  }

  static bool _ordinaryRam(int address) {
    // Callers use translated addresses when available; direct P3/P4 stays excluded.
    address &= 0xffffffff;
    return address < 0xc0000000 && address & 0x1c000000 == 0x0c000000;
  }

  int read16(int address, {DcTranslation? mapping, bool peek = false}) {
    final decoded = mapping?.physical ?? address;
    if (_ordinaryRead(decoded)) {
      final (bytes, offset) = cache.readLocation(address, 2,
          physical: mapping?.physical,
          cacheable: mapping?.cacheable,
          fill: !peek);
      return bytes.getUint16LE(offset);
    }
    final fifoRegister = _fifoRegister(decoded);
    if (fifoRegister != null) return gpu.readFifoRegister(fifoRegister, 2);
    final g2Register = _g2Offset(decoded);
    if (g2Register != null) return g2.read(g2Register, 2);
    final sound = DcAica.registerOffset(decoded);
    if (sound != null) return aica.read(sound, 2, sideEffects: !peek);
    final rtc = DcAica.rtcOffset(decoded);
    if (rtc != null) return aica.readRtc(rtc, 2);
    final video = _gpuOffset(decoded);
    if (video != null) return gpu.read(video, 2);
    final system = _systemBusOffset(decoded);
    if (system != null) return systemBus.read(system, 2);
    final drive = _opticalDriveOffset(decoded);
    if (drive != null) {
      if (!peek) g1.observeRootAccess(decoded);
      return opticalDrive.read(drive, 2, sideEffects: !peek);
    }
    final g1Register = _g1Offset(decoded);
    if (g1Register != null) return g1.read(g1Register, 2);
    final mapleRegister = _mapleOffset(decoded);
    if (mapleRegister != null) return maple.read(mapleRegister, 2);
    final clock = _cpgOffset(decoded);
    if (clock != null) return cpg.read(clock, 2);
    final rtcRegister = DcRtc.offset(decoded);
    if (rtcRegister != null) return sh4Rtc.read(rtcRegister, 2);
    if (_disabledUbcControl(decoded)) return 0;
    final busControl = DcBsc.offset(decoded);
    if (busControl != null) return bsc.read(busControl, 2);
    final port = DcGpio.offset(decoded);
    if (port != null) return gpio.read(port, 2);
    final serial1 = _sciOffset(decoded);
    if (serial1 != null) return sci.read(serial1, 2, sideEffects: !peek);
    final serial = _scifOffset(decoded);
    if (serial != null) return scif.read(serial, 2, sideEffects: !peek);
    final interrupt = _intcOffset(decoded);
    if (interrupt != null) return intc.read(interrupt);
    final timer = _tmuOffset(decoded);
    if (timer != null) return tmu.read(timer, 2);
    final (bytes, offset) = cache.readLocation(address, 2,
        physical: mapping?.physical,
        cacheable: mapping?.cacheable,
        fill: !peek);
    return bytes.getUint16LE(offset);
  }

  int fetch16(int address) {
    final (bytes, offset) = cache.readLocation(address, 2, instruction: true);
    return bytes.getUint16LE(offset);
  }

  int peekInstruction16(int address, {bool privileged = true}) {
    try {
      return cpuRead(address, 2,
          privileged: privileged, instruction: true, peek: true);
    } on DcCpuException catch (error) {
      throw DcUnsupported(
          'instruction translation fault ${error.event.toRadixString(16)}');
    }
  }

  int peek8(int address, {bool privileged = true}) {
    try {
      return cpuRead(address, 1, privileged: privileged, peek: true);
    } on DcCpuException catch (error) {
      throw DcUnsupported(
          'data translation fault ${error.event.toRadixString(16)}');
    }
  }

  int read32(int address, {DcTranslation? mapping, bool peek = false}) {
    final decoded = mapping?.physical ?? address;
    if (_ordinaryRead(decoded)) {
      final (bytes, offset) = cache.readLocation(address, 4,
          physical: mapping?.physical,
          cacheable: mapping?.cacheable,
          fill: !peek);
      return bytes.getUint32LE(offset).mask32;
    }
    final fifoRegister = _fifoRegister(decoded);
    if (fifoRegister != null) return gpu.readFifoRegister(fifoRegister, 4);
    final g2Register = _g2Offset(decoded);
    if (g2Register != null) return g2.read(g2Register, 4);
    final sound = DcAica.registerOffset(decoded);
    if (sound != null) return aica.read(sound, 4, sideEffects: !peek);
    final rtc = DcAica.rtcOffset(decoded);
    if (rtc != null) return aica.readRtc(rtc, 4);
    final video = _gpuOffset(decoded);
    if (video != null) return gpu.read(video, 4);
    final system = _systemBusOffset(decoded);
    if (system != null) return systemBus.read(system, 4);
    final drive = _opticalDriveOffset(decoded);
    if (drive != null) {
      if (!peek) g1.observeRootAccess(decoded);
      return opticalDrive.read(drive, 4, sideEffects: !peek);
    }
    final g1Register = _g1Offset(decoded);
    if (g1Register != null) return g1.read(g1Register, 4);
    final mapleRegister = _mapleOffset(decoded);
    if (mapleRegister != null) return maple.read(mapleRegister, 4);
    final clock = _cpgOffset(decoded);
    if (clock != null) return cpg.read(clock, 4);
    final busControl = DcBsc.offset(decoded);
    if (busControl != null) return bsc.read(busControl, 4);
    final port = DcGpio.offset(decoded);
    if (port != null) return gpio.read(port, 4);
    final serial1 = _sciOffset(decoded);
    if (serial1 != null) return sci.read(serial1, 4, sideEffects: !peek);
    final serial = _scifOffset(decoded);
    if (serial != null) return scif.read(serial, 4, sideEffects: !peek);
    final dmaRegister = _dmaOffset(decoded);
    if (dmaRegister != null) return dma.read(dmaRegister, sideEffects: !peek);
    if (DcMmu.isArray(decoded)) return mmu.readArray(decoded);
    if (DcCache.isArray(decoded)) return cache.readArray(decoded);
    final timer = _tmuOffset(decoded);
    if (timer != null) return tmu.read(timer, 4);
    final register = _cpuRegister(decoded);
    if (register != null) {
      return switch (register) {
        0 => pteh,
        4 => mmu.ptel,
        8 => mmu.ttb,
        52 => mmu.ptea,
        12 => tea,
        16 => mmucr,
        28 => cache.ccr,
        // TN-SH7-361B/E defines 040205xx; low-byte stepping is provisional.
        48 => 0x04020580,
        68 => 0,
        32 => tra,
        36 => expevt,
        40 => intevt,
        _ => _qacr[(register - 56) ~/ 4],
      };
    }
    final (bytes, offset) = cache.readLocation(address, 4,
        physical: mapping?.physical,
        cacheable: mapping?.cacheable,
        fill: !peek);
    return bytes.getUint32LE(offset).mask32;
  }

  (int, int) readPair(int address, {DcTranslation? mapping}) {
    final (bytes, offset) = cache.readLocation(address, 8,
        physical: mapping?.physical, cacheable: mapping?.cacheable);
    return (
      bytes.getUint32LE(offset).mask32,
      bytes.getUint32LE(offset + 4).mask32
    );
  }

  void writePair(int address, int firstValue, int secondValue,
      {DcTranslation? mapping}) {
    final values = Uint8List(8)
      ..setUint32LE(0, firstValue)
      ..setUint32LE(4, secondValue);
    cache.write(address, values,
        physical: mapping?.physical,
        cacheable: mapping?.cacheable,
        writeThrough: mapping?.writeThrough);
  }

  Uint8List _valueBytes(int size, int value) {
    final bytes = Uint8List(size);
    for (var index = 0; index < size; index++) {
      bytes[index] = (value >> (index * 8)) & 255;
    }
    return bytes;
  }

  void write8(int address, int value, {DcTranslation? mapping}) {
    final decoded = mapping?.physical ?? address;
    if (_ordinaryRam(decoded)) {
      cache.write(address, _valueBytes(1, value),
          physical: mapping?.physical,
          cacheable: mapping?.cacheable,
          writeThrough: mapping?.writeThrough);
      return;
    }
    final fifoRegister = _fifoRegister(decoded);
    if (fifoRegister != null) {
      return gpu.writeFifoRegister(fifoRegister, 1, value);
    }
    final g2Register = _g2Offset(decoded);
    if (g2Register != null) return g2.write(g2Register, 1, value);
    final sound = DcAica.registerOffset(decoded);
    if (sound != null) return aica.write(sound, 1, value);
    final rtc = DcAica.rtcOffset(decoded);
    if (rtc != null) return aica.writeRtc(rtc, 1, value);
    final video = _gpuOffset(decoded);
    if (video != null) return gpu.write(video, 1, value);
    final system = _systemBusOffset(decoded);
    if (system != null) return systemBus.write(system, 1, value);
    final drive = _opticalDriveOffset(decoded);
    if (drive != null) {
      g1.observeRootAccess(decoded);
      return opticalDrive.write(drive, 1, value);
    }
    final g1Register = _g1Offset(decoded);
    if (g1Register != null) return g1.write(g1Register, 1, value);
    final mapleRegister = _mapleOffset(decoded);
    if (mapleRegister != null) return maple.write(mapleRegister, 1, value);
    final flashOffset = _flashOffset(decoded);
    if (flashOffset != null) {
      return _writeFlash(address, flashOffset, 1, value, mapping?.cacheable);
    }
    final clock = _cpgOffset(decoded);
    if (clock != null) return _writeCpg(clock, 1, value);
    final rtcRegister = DcRtc.offset(decoded);
    if (rtcRegister != null) return sh4Rtc.write(rtcRegister, 1, value);
    final busControl = DcBsc.offset(decoded);
    if (busControl != null) {
      bsc.write(busControl, 1, value);
      gpio.enabled = bsc.read(4, 2) & 1 != 0;
      return;
    }
    final port = DcGpio.offset(decoded);
    if (port != null) return gpio.write(port, 1, value);
    final modeArea = DcBsc.modeArea(decoded);
    if (modeArea != null) return bsc.writeMode(modeArea, decoded, 1);
    final serial1 = _sciOffset(decoded);
    if (serial1 != null) return sci.write(serial1, 1, value);
    final serial = _scifOffset(decoded);
    if (serial != null) return scif.write(serial, 1, value);
    final timer = _tmuOffset(decoded);
    if (timer != null) return tmu.write(timer, 1, value);
    cache.write(address, _valueBytes(1, value),
        physical: mapping?.physical,
        cacheable: mapping?.cacheable,
        writeThrough: mapping?.writeThrough);
  }

  void write16(int address, int value, {DcTranslation? mapping}) {
    final decoded = mapping?.physical ?? address;
    if (_ordinaryRam(decoded)) {
      cache.write(address, _valueBytes(2, value),
          physical: mapping?.physical,
          cacheable: mapping?.cacheable,
          writeThrough: mapping?.writeThrough);
      return;
    }
    final fifoRegister = _fifoRegister(decoded);
    if (fifoRegister != null) {
      return gpu.writeFifoRegister(fifoRegister, 2, value);
    }
    final g2Register = _g2Offset(decoded);
    if (g2Register != null) return g2.write(g2Register, 2, value);
    final sound = DcAica.registerOffset(decoded);
    if (sound != null) return aica.write(sound, 2, value);
    final rtc = DcAica.rtcOffset(decoded);
    if (rtc != null) return aica.writeRtc(rtc, 2, value);
    final video = _gpuOffset(decoded);
    if (video != null) return gpu.write(video, 2, value);
    final system = _systemBusOffset(decoded);
    if (system != null) return systemBus.write(system, 2, value);
    final drive = _opticalDriveOffset(decoded);
    if (drive != null) {
      g1.observeRootAccess(decoded);
      return opticalDrive.write(drive, 2, value);
    }
    final g1Register = _g1Offset(decoded);
    if (g1Register != null) return g1.write(g1Register, 2, value);
    final mapleRegister = _mapleOffset(decoded);
    if (mapleRegister != null) return maple.write(mapleRegister, 2, value);
    final flashOffset = _flashOffset(decoded);
    if (flashOffset != null) {
      return _writeFlash(address, flashOffset, 2, value, mapping?.cacheable);
    }
    final clock = _cpgOffset(decoded);
    if (clock != null) return _writeCpg(clock, 2, value);
    final rtcRegister = DcRtc.offset(decoded);
    if (rtcRegister != null) return sh4Rtc.write(rtcRegister, 2, value);
    if (_disabledUbcControl(decoded)) {
      if (value & 0xffff != 0) {
        throw const DcUnsupported('SH7750 active UBC break configuration');
      }
      return;
    }
    final busControl = DcBsc.offset(decoded);
    if (busControl != null) {
      bsc.write(busControl, 2, value);
      gpio.enabled = bsc.read(4, 2) & 1 != 0;
      return;
    }
    final port = DcGpio.offset(decoded);
    if (port != null) return gpio.write(port, 2, value);
    final modeArea = DcBsc.modeArea(decoded);
    if (modeArea != null) return bsc.writeMode(modeArea, decoded, 2);
    final serial1 = _sciOffset(decoded);
    if (serial1 != null) return sci.write(serial1, 2, value);
    final serial = _scifOffset(decoded);
    if (serial != null) return scif.write(serial, 2, value);
    final interrupt = _intcOffset(decoded);
    if (interrupt != null) return intc.write(interrupt, value);
    final timer = _tmuOffset(decoded);
    if (timer != null) return tmu.write(timer, 2, value);
    cache.write(address, _valueBytes(2, value),
        physical: mapping?.physical,
        cacheable: mapping?.cacheable,
        writeThrough: mapping?.writeThrough);
  }

  void write32(int address, int value,
      {bool allocate = false, DcTranslation? mapping}) {
    final decoded = mapping?.physical ?? address;
    if (_ordinaryRam(decoded)) {
      cache.write(address, _valueBytes(4, value),
          allocate: allocate,
          physical: mapping?.physical,
          cacheable: mapping?.cacheable,
          writeThrough: mapping?.writeThrough);
      return;
    }
    final fifoRegister = _fifoRegister(decoded);
    if (fifoRegister != null) {
      return gpu.writeFifoRegister(fifoRegister, 4, value);
    }
    final g2Register = _g2Offset(decoded);
    if (g2Register != null) return g2.write(g2Register, 4, value);
    final sound = DcAica.registerOffset(decoded);
    if (sound != null) return aica.write(sound, 4, value);
    final rtc = DcAica.rtcOffset(decoded);
    if (rtc != null) return aica.writeRtc(rtc, 4, value);
    final video = _gpuOffset(decoded);
    if (video != null) return gpu.write(video, 4, value);
    final system = _systemBusOffset(decoded);
    if (system != null) return systemBus.write(system, 4, value);
    final drive = _opticalDriveOffset(decoded);
    if (drive != null) {
      g1.observeRootAccess(decoded);
      return opticalDrive.write(drive, 4, value);
    }
    final g1Register = _g1Offset(decoded);
    if (g1Register != null) return g1.write(g1Register, 4, value);
    final mapleRegister = _mapleOffset(decoded);
    if (mapleRegister != null) return maple.write(mapleRegister, 4, value);
    final flashOffset = _flashOffset(decoded);
    if (flashOffset != null) {
      return _writeFlash(address, flashOffset, 4, value, mapping?.cacheable);
    }
    final clock = _cpgOffset(decoded);
    if (clock != null) return _writeCpg(clock, 4, value);
    final busControl = DcBsc.offset(decoded);
    if (busControl != null) {
      bsc.write(busControl, 4, value);
      gpio.enabled = bsc.read(4, 2) & 1 != 0;
      return;
    }
    final port = DcGpio.offset(decoded);
    if (port != null) return gpio.write(port, 4, value);
    final modeArea = DcBsc.modeArea(decoded);
    if (modeArea != null) return bsc.writeMode(modeArea, decoded, 4);
    final serial1 = _sciOffset(decoded);
    if (serial1 != null) return sci.write(serial1, 4, value);
    final serial = _scifOffset(decoded);
    if (serial != null) return scif.write(serial, 4, value);
    final dmaRegister = _dmaOffset(decoded);
    if (dmaRegister != null) return dma.write(dmaRegister, value);
    if (DcMmu.isArray(decoded)) return mmu.writeArray(decoded, value);
    if (DcCache.isArray(decoded)) {
      if (mmu.enabled && decoded & 0x01000008 == 8) {
        final translated = mmu.associative(value & 0xfffffc00,
            instruction: decoded & 0x04000000 == 0);
        if (translated == null) return;
        value = (translated.physical & 0x1ffffc00) | (value & 3);
      }
      return cache.writeArray(decoded, value);
    }
    final timer = _tmuOffset(decoded);
    if (timer != null) return tmu.write(timer, 4, value);
    final register = _cpuRegister(decoded);
    if (register != null) {
      switch (register) {
        case 48:
        case 68:
          throw const DcUnsupported('SH7750 version registers are read-only');
        case 0:
          pteh = value & 0xfffffcff;
        case 4:
          mmu.ptel = value & 0x1ffffdff;
        case 8:
          mmu.ttb = value.mask32;
        case 52:
          mmu.ptea = value & 15;
        case 12:
          tea = value.mask32;
        case 16:
          mmucr = value;
        case 28:
          cache.ccr = value;
        case 32:
          tra = value & 0x3fc;
        case 36:
          expevt = value & 0xfff;
        case 40:
          intevt = value & 0xfff;
        case 56:
        case 60:
          _qacr[(register - 56) ~/ 4] = value & 0x1c;
      }
      return;
    }
    cache.write(address, _valueBytes(4, value),
        allocate: allocate,
        physical: mapping?.physical,
        cacheable: mapping?.cacheable,
        writeThrough: mapping?.writeThrough);
  }
}

/// A validated bus graph, retained privately until the owning core commits it.
class DcBusState {
  DcBusState._(this._bus);
  final DcBus _bus;
  void validateCpuSleep(bool sleeping) {
    if (_bus.cpg.deepSleeping && (!sleeping || _bus.bsc.read(20, 4) & 6 != 6)) {
      throw const StateMismatch(
          'DC deep sleep requires a sleeping CPU and SDRAM self-refresh');
    }
  }

  void validateDrive(CdromDriveStatus media) =>
      _bus.opticalDrive.validateDriveAfterLoad(media);
}
