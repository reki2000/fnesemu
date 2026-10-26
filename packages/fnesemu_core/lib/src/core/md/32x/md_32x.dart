import 'dart:collection';
import 'dart:typed_data';

import '../../../components/sh2/jit/jit.dart';
import '../../../util/int.dart';
import '../../../util/state.dart';
import 'pwm.dart';
import 'sh2/sh2.dart';
import 'video.dart';

/// MD 32x adapter, dual SH-2 buses and shared peripherals.
class Md32x {
  static const clockHz = 53693175 * 3 ~/ 7;
  Uint8List rom = Uint8List(0);
  late final Uint8List ram;
  final mainBoot = Uint8List(0x100);
  final masterBoot = Uint8List(0x800);
  final slaveBoot = Uint8List(0x400);
  // Each SH-2 exposes its own 4 KiB cache data array in the P4 area.
  late final List<Uint8List> cacheData;
  final registers = Uint8List(0x40);
  final video = ExpansionVideo();
  late final ExpansionPwm pwm;
  late final List<ExpansionBus> buses;
  late final List<Sh2> cpus;
  final _masks = [0, 0], _pending = [0, 0];
  final _fifo = Queue<int>();
  int control = 0, _bank = 0, _cycles = 0, _hcount = 0;
  final int sliceClocks;
  bool biosLoaded = false;
  String? stoppedReason;
  bool get enabled => control.bit0;
  bool get released => control.bit1;
  bool get shOwnsVideo => control.bit15;
  bool get romToVram => registers[7].bit0;

  // Drops bits 29 and 30, so the cache-through alias (0x2xxxxxxx) shares the
  // pages of the cached address, and keeps bit 31 for the cache data array.
  static const _jitAddrMask = 0x9fffffff;

  Md32x(
      {bool jit = const bool.fromEnvironment('SH2_JIT_32X', defaultValue: true),
      this.sliceClocks = 64,
      bool jitRegisterReads = const bool.fromEnvironment(
          'SH2_JIT_32X_REGISTER_READS',
          defaultValue: true)}) {
    if (sliceClocks <= 0) throw RangeError.value(sliceClocks, 'sliceClocks');
    final owner = jit
        ? Sh2Jit.create(
            maxInstructions: sliceClocks == 1 ? 1 : 24,
            addrMask: _jitAddrMask,
            highMemory: true,
            releaseCodePages: true,
            macLong: true,
            macWord: true,
            alignMemory: false,
            idleGuards: sliceClocks != 1,
            stopOnNoStore: true)
        : null;
    final other = owner == null
        ? null
        : Sh2Jit.create(
            maxInstructions: sliceClocks == 1 ? 1 : 24,
            addrMask: _jitAddrMask,
            highMemory: true,
            releaseCodePages: true,
            macLong: true,
            macWord: true,
            alignMemory: false,
            idleGuards: sliceClocks != 1,
            stopOnNoStore: true);
    ram = owner?.rt.alloc(0x40000) ?? Uint8List(0x40000);
    for (final compiler in [owner, other]) {
      compiler?.map(0x6000000, ram.length, ram, owner: owner!.rt);
    }
    // The mask keeps bit 31, so the P4 cache data array has its own page.
    cacheData = [
      for (final compiler in [owner, other])
        compiler?.rt.alloc(0x1000) ?? Uint8List(0x1000)
    ];
    for (final (i, compiler) in [owner, other].indexed) {
      compiler?.map(0xc0000000, 0x1000, cacheData[i]);
    }
    buses = [ExpansionBus(this, 0), ExpansionBus(this, 1)];
    cpus = [
      Sh2(buses[0], jit: owner),
      Sh2(buses[1], master: false, jit: other)
    ];
    if (jitRegisterReads) {
      for (var cpu = 0; cpu < cpus.length; cpu++) {
        final index = cpu;
        cpus[cpu].jit?.addReadHelper((address, size) {
          final offset = address & 0x1fffffff;
          // Communication words, the H count register and the video registers
          // are plain state with no read effects. Control, FIFO, palette and
          // PWM reads retain their ordinary CPU exits.
          return address < 0x40000000 &&
              (offset >= 0x4020 && offset + size <= 0x4030 ||
                  offset >= 0x4004 && offset + size <= 0x4006 ||
                  offset >= 0x4100 && offset + size <= 0x4110);
        },
            (address, size) => switch (size) {
                  1 => readSh8(address, index),
                  2 => readSh16(address, index),
                  _ => buses[index].read32(address),
                },
            guardedLiterals: true);
      }
    }
    pwm = ExpansionPwm(() => _raise(0));
    reset();
  }

  /// Saves logical state while the owning core identifies external media.
  void saveState(StateWriter w) {
    w.section('32x-adapter');
    w.bytes(ram);
    w.bytes(cacheData[0]);
    w.bytes(cacheData[1]);
    w.bytes(registers);
    w.ints(_masks);
    w.ints(_pending);
    w.int64(control);
    w.int64(_bank);
    w.int64(_cycles);
    w.int64(_hcount);
    w.boolean(biosLoaded);
    w.boolean(stoppedReason != null);
    if (stoppedReason != null) w.string(stoppedReason!);
    w.ints(_fifo.toList());
    video.saveState(w);
    pwm.saveState(w);
    for (final cpu in cpus) {
      cpu.saveState(w);
    }
  }

  /// Restores existing buffers and keeps callback and bus wiring.
  void loadState(StateReader s) {
    s.section('32x-adapter');
    s.bytesInto(ram);
    s.bytesInto(cacheData[0]);
    s.bytesInto(cacheData[1]);
    s.bytesInto(registers);
    s.intsInto(_masks);
    s.intsInto(_pending);
    control = s.int64();
    _bank = s.int64();
    _cycles = s.int64();
    _hcount = s.int64();
    biosLoaded = s.boolean();
    stoppedReason = s.boolean() ? s.string() : null;
    _fifo
      ..clear()
      ..addAll(s.ints());
    video.loadState(s);
    pwm.loadState(s);
    for (final cpu in cpus) {
      cpu.loadState(s);
    }
  }

  void dispose() {
    cpus[1].jit?.dispose();
    cpus[0].jit?.dispose();
  }

  void setRom(Uint8List bytes) => rom = Uint8List.fromList(bytes);
  void setBootRoms(
      {required Uint8List main,
      required Uint8List master,
      required Uint8List slave}) {
    if (main.length != 0x100 ||
        master.length != 0x800 ||
        slave.length != 0x400) {
      throw ArgumentError(
          'MD 32x boot ROM sizes must be 256, 2048 and 1024 bytes');
    }
    mainBoot.setAll(0, main);
    masterBoot.setAll(0, master);
    slaveBoot.setAll(0, slave);
    biosLoaded = true;
    reset();
  }

  void reset() {
    control = _bank = _cycles = _hcount = 0;
    registers.fillRange(0, registers.length, 0);
    for (final data in cacheData) {
      data.fillRange(0, data.length, 0);
    }
    _masks.fillRange(0, 2, 0);
    _pending.fillRange(0, 2, 0);
    _fifo.clear();
    stoppedReason = null;
    video.reset();
    pwm.reset();
    for (final cpu in cpus) {
      cpu.reset();
    }
  }

  int _word(int offset) => registers[offset].shl8 | registers[offset + 1];
  void _setWord(int offset, int value) {
    registers[offset] = value.shr8.mask8;
    registers[offset + 1] = value.mask8;
  }

  void _raise(int bit, {int? cpu}) {
    for (int i = 0; i < 2; i++) {
      if (cpu == null || cpu == i) _pending[i] |= 1 << bit;
    }
    _updateInterrupts();
  }

  void _updateInterrupts() {
    for (int i = 0; i < 2; i++) {
      final active = _pending[i] & (_masks[i] | 0x10);
      int level = 0;
      for (int bit = 4; bit >= 0; bit--) {
        if ((active & (1 << bit)) != 0) {
          level = 6 + bit * 2;
          break;
        }
      }
      cpus[i].setInterrupt(level, 64 + level ~/ 2);
    }
  }

  void beginLine(int line) {
    if (!enabled || !released) return;
    video.beginLine(line);
    if (line == 224) _raise(3);
    if (line >= 0 && line < 224) {
      if (_hcount == 0) {
        _hcount = registers[5];
        _raise(2);
      } else {
        _hcount--;
      }
    }
  }

  void requestResetInterrupt() => _raise(4);

  /// the FIFO asserts DREQ while it holds data: a DMA channel 0 waiting for an
  /// external request moves the words to the SH-2 memory
  void _dreq() {
    while (_fifo.isNotEmpty) {
      var moved = false;
      for (final cpu in cpus) {
        if (cpu.onchip.dreqTransfer(0)) {
          moved = true;
          break;
        }
      }
      if (!moved) break;
    }
  }

  /// Returns execution flags independently for master and slave.
  (bool, bool, bool) advance(int mainCycles, int mainClockHz,
      {bool step = false}) {
    final target = mainCycles * clockHz ~/ mainClockHz;
    final elapsed = target - _cycles;
    if (elapsed > 0 && enabled && released) {
      video.tick(elapsed);
      pwm.tick(elapsed);
    }
    _cycles = target;
    if (!enabled || !released) {
      for (final cpu in cpus) {
        cpu.setClocks(target);
      }
      return (true, false, false);
    }
    if (!biosLoaded) {
      stoppedReason = 'MD 32x boot ROMs are required';
      return (false, false, false);
    }
    var executed0 = false, executed1 = false;
    final cpu0 = cpus[0], cpu1 = cpus[1];
    // Bound CPU interleaving by both the quantum and the main CPU deadline.
    // Quantum 1 retains legacy instruction alternation for comparisons.
    while (cpu0.clocks <= target || cpu1.clocks <= target) {
      for (int i = 0; i < 2; i++) {
        final cpu = i == 0 ? cpu0 : cpu1;
        if (cpu.clocks > target || (step && (i == 0 ? executed0 : executed1))) {
          continue;
        }
        final sliceEnd = cpu.clocks + sliceClocks;
        final ok = step || sliceClocks == 1
            ? cpu.exec(compiled: !step)
            : cpu.run(sliceEnd < target + 1 ? sliceEnd : target + 1);
        if (!ok) {
          stoppedReason =
              'SH-2 $i unsupported opcode ${cpu.lastOpcode.toRadixString(16)} at ${cpu.pc.toRadixString(16)}';
          return (false, executed0, executed1);
        }
        if (i == 0) {
          executed0 = true;
        } else {
          executed1 = true;
        }
      }
      if (step) break;
    }
    return (true, executed0, executed1);
  }

  bool mapsMain(int address) =>
      (address >= 0xa15100 && address < 0xa15400) ||
      (address >= 0xa130ec && address < 0xa130f0) ||
      (enabled &&
          ((address < 0x100) ||
              (!romToVram && address >= 0x100 && address < 0x400000) ||
              (address >= 0x840000 && address < 0xa00000)));

  int _romByte(int address) =>
      address >= 0 && address < rom.length ? rom[address] : 0xff;
  int readMain8(int address) {
    if (address >= 0xa130ec && address < 0xa130f0) {
      return [0x4d, 0x41, 0x52, 0x53][address - 0xa130ec];
    }
    if (address < 0x100 && enabled) {
      return biosLoaded ? mainBoot[address] : 0xff;
    }
    if (address < 0x400000) return 0xff;
    if (address >= 0x880000 && address < 0x900000) {
      return _romByte(address - 0x880000);
    }
    if (address >= 0x900000 && address < 0xa00000) {
      return _romByte(_bank.shl20 | (address & 0xfffff));
    }
    if (address >= 0x840000 && address < 0x880000) {
      return shOwnsVideo ? 0xff : video.readFrame8(address);
    }
    if (address < 0xa15100 || address >= 0xa15400) return 0xff;
    final word = readMain16(address & ~1);
    return address.isEven ? word.shr8 : word.mask8;
  }

  int readMain16(int address) {
    if (address >= 0xa15100 && address < 0xa15140) {
      return _readSystem(address - 0xa15100, null);
    }
    if (address >= 0xa15180 && address < 0xa15190) {
      return shOwnsVideo ? 0xffff : video.readRegister(address - 0xa15180);
    }
    if (address >= 0xa15200 && address < 0xa15400) {
      return shOwnsVideo ? 0xffff : video.palette[(address - 0xa15200).shr1];
    }
    if (address >= 0xa15100 && address < 0xa15400) return 0xffff;
    return readMain8(address).shl8 | readMain8(address + 1);
  }

  void writeMain8(int address, int value) {
    value &= 255;
    if (address >= 0x840000 && address < 0x880000) {
      if (!shOwnsVideo) {
        video.writeFrame8(address, value, overwrite: address >= 0x860000);
      }
      return;
    }
    // Palette is word-only; byte writes are ignored.
    if (address >= 0xa15200 && address < 0xa15400) return;
    final wordAddress = address & ~1;
    final old = readMain16(wordAddress);
    writeMain16(wordAddress,
        address.isEven ? value.shl8 | old.mask8 : (old & 0xff00) | value);
  }

  void writeMain16(int address, int value) {
    value &= 0xffff;
    if (address >= 0xa15100 && address < 0xa15140) {
      _writeSystem(address - 0xa15100, value, null);
      return;
    }
    if (address >= 0xa15180 && address < 0xa15190) {
      if (!shOwnsVideo) video.writeRegister(address - 0xa15180, value);
      return;
    }
    if (address >= 0xa15200 && address < 0xa15400) {
      if (!shOwnsVideo) video.palette[(address - 0xa15200).shr1] = value;
      return;
    }
    if (address >= 0x840000 && address < 0x880000) {
      writeMain8(address, value.shr8);
      writeMain8(address + 1, value);
    }
  }

  int _readSystem(int offset, int? cpu) {
    if (offset == 0) {
      return cpu == null
          ? control | 0x80
          : (control & 0x8000) | (enabled ? 0x200 : 0) | _masks[cpu];
    }
    if (offset == 4) return cpu == null ? _bank : _word(4);
    if (offset == 6) return _word(6) | (_fifo.length == 4 ? 0x8000 : 0);
    if (offset == 0x12) {
      if (cpu == null || _fifo.isEmpty) return 0xffff;
      final value = _fifo.removeFirst();
      final length = _word(0x10);
      if (length > 0) _setWord(0x10, length - 1);
      return value;
    }
    if (offset >= 0x30 && offset <= 0x38) return pwm.read(offset - 0x30);
    return _word(offset);
  }

  void _writeSystem(int offset, int value, int? cpu) {
    if (offset == 0) {
      if (cpu == null) {
        final wasReleased = released;
        control = value & 0x8003;
        if (released && !wasReleased) {
          for (final sh in cpus) {
            sh.reset();
            sh.setClocks(_cycles);
          }
          _updateInterrupts();
        }
      } else {
        _masks[cpu] = value.mask4;
        control = (control & ~0x8000) | (value & 0x8000);
        _updateInterrupts();
      }
      return;
    }
    if (cpu != null && offset >= 0x14 && offset <= 0x1c) {
      final bit = (0x1c - offset) ~/ 2;
      _pending[cpu] &= ~(1 << bit);
      if (offset == 0x1a) _setWord(2, _word(2) & ~(1 << cpu));
      _updateInterrupts();
      return;
    }
    if (cpu == null && offset == 2) {
      _setWord(2, value.mask2);
      for (int i = 0; i < 2; i++) {
        if ((value & (1 << i)) != 0) _raise(1, cpu: i);
      }
      return;
    }
    if (offset == 4) {
      if (cpu == null) {
        _bank = value.mask2;
      } else {
        _setWord(4, value.mask8);
        _hcount = value.mask8;
      }
      return;
    }
    if (offset == 6) {
      if (cpu == null) {
        _setWord(6, value.mask3);
        if (!value.bit2) _fifo.clear();
      }
      return;
    }
    if (offset == 0x12) {
      if (cpu == null && registers[7].bit2 && _fifo.length < 4) {
        _fifo.addLast(value);
        _dreq();
      }
      return;
    }
    if (offset >= 0x30 && offset <= 0x38) {
      pwm.write(offset - 0x30, value);
      return;
    }
    if (offset >= 8 && offset <= 0x10 && cpu != null) return;
    if ((offset >= 8 && offset <= 0x10) ||
        offset == 0x1a ||
        (offset >= 0x20 && offset <= 0x2e)) {
      _setWord(offset, value);
    }
  }

  int readSh8(int address, int cpu) {
    if ((address & 0xfffff000) == 0xc0000000) {
      return cacheData[cpu][address.mask12];
    }
    // Only P1 is an uncached alias of external memory. P2 is the
    // associative cache purge area, not another alias of SDRAM.
    if (address >= 0x40000000) return 0xff;
    address &= 0x1fffffff;
    // the registers are the most polled area and exclusive with the others
    if (address >= 0x4000 && address < 0x4400) {
      final word = readSh16(address & ~1, cpu);
      return address.isEven ? word.shr8 : word.mask8;
    }
    final boot = cpu == 0 ? masterBoot : slaveBoot;
    if (address < boot.length) return biosLoaded ? boot[address] : 0xff;
    if (address >= 0x02000000 && address < 0x02400000) {
      return romToVram ? 0xff : _romByte(address - 0x02000000);
    }
    if (address >= 0x06000000 && address < 0x06040000) {
      return ram[address & 0x3ffff];
    }
    if (address >= 0x04000000 && address < 0x04040000) {
      return shOwnsVideo ? video.readFrame8(address) : 0xff;
    }
    return 0xff;
  }

  int readSh16(int address, int cpu) {
    // the SDRAM and the cartridge ROM are read directly when both bytes are
    // inside the area; the other cases take the byte reads below
    if (address < 0x40000000) {
      final a = address & 0x1fffffff;
      if (a >= 0x06000000) {
        final i = a & 0x3ffff;
        if (a < 0x06040000 && i < 0x3ffff) {
          final ram = this.ram;
          return ram[i] << 8 | ram[i + 1];
        }
      } else if (a < 0x800) {
        final boot = cpu == 0 ? masterBoot : slaveBoot;
        if (a + 1 < boot.length) {
          return biosLoaded ? boot[a] << 8 | boot[a + 1] : 0xffff;
        }
      } else if (a >= 0x02000000) {
        final i = a - 0x02000000;
        final rom = this.rom;
        if (i + 1 < rom.length && a < 0x02400000 && !romToVram) {
          return rom[i] << 8 | rom[i + 1];
        }
      }
    }
    if ((address & 0xfffff000) == 0xc0000000) {
      return readSh8(address, cpu).shl8 | readSh8(address + 1, cpu);
    }
    if (address >= 0x40000000) return 0xffff;
    address &= 0x1fffffff;
    if (address >= 0x4000 && address < 0x4040) {
      return _readSystem(address - 0x4000, cpu);
    }
    if (address >= 0x4100 && address < 0x4110) {
      return shOwnsVideo ? video.readRegister(address - 0x4100) : 0xffff;
    }
    if (address >= 0x4200 && address < 0x4400) {
      return shOwnsVideo ? video.palette[(address - 0x4200).shr1] : 0xffff;
    }
    if (address >= 0x4000 && address < 0x4400) return 0xffff;
    return readSh8(address, cpu).shl8 | readSh8(address + 1, cpu);
  }

  int readSh32(int address, int cpu) {
    if (address < 0x40000000) {
      final a = address & 0x1fffffff;
      if (a >= 0x06000000) {
        final i = a & 0x3ffff;
        if (a < 0x06040000 && i < 0x3fffd) {
          final ram = this.ram;
          return ram[i] << 24 | ram[i + 1] << 16 | ram[i + 2] << 8 | ram[i + 3];
        }
      } else if (a >= 0x02000000) {
        final i = a - 0x02000000;
        final rom = this.rom;
        if (i + 3 < rom.length && a < 0x02400000 && !romToVram) {
          return rom[i] << 24 | rom[i + 1] << 16 | rom[i + 2] << 8 | rom[i + 3];
        }
      }
    }
    return readSh16(address, cpu).shl16 | readSh16(address + 2, cpu);
  }

  void writeSh32(int address, int value, int cpu) {
    if (address < 0x40000000) {
      final a = address & 0x1fffffff;
      if (a >= 0x06000000) {
        final i = a & 0x3ffff;
        if (a < 0x06040000 && i < 0x3fffd) {
          final ram = this.ram;
          ram[i] = value >> 24;
          ram[i + 1] = value >> 16;
          ram[i + 2] = value >> 8;
          ram[i + 3] = value;
          return;
        }
      }
    }
    writeSh16(address, value.shr16, cpu);
    writeSh16(address + 2, value, cpu);
  }

  void writeSh8(int address, int value, int cpu) {
    if ((address & 0xfffff000) == 0xc0000000) {
      cacheData[cpu][address.mask12] = value.mask8;
      return;
    }
    // The interpreter does not cache external memory, so a P2 purge needs
    // no work. In particular, it must not overwrite the underlying data.
    if (address >= 0x40000000) return;
    address &= 0x1fffffff;
    value &= 255;
    if (address >= 0x06000000 && address < 0x06040000) {
      ram[address & 0x3ffff] = value;
      return;
    }
    if (address >= 0x04000000 && address < 0x04040000) {
      if (shOwnsVideo) {
        video.writeFrame8(address, value, overwrite: address >= 0x04020000);
      }
      return;
    }
    if (address >= 0x4200 && address < 0x4400) return;
    if (address >= 0x4000 && address < 0x4110) {
      final word = readSh16(address & ~1, cpu);
      writeSh16(
          address & ~1,
          address.isEven ? value.shl8 | word.mask8 : (word & 0xff00) | value,
          cpu);
    }
  }

  void writeSh16(int address, int value, int cpu) {
    if (address < 0x40000000) {
      final a = address & 0x1fffffff;
      if (a >= 0x06000000) {
        final i = a & 0x3ffff;
        if (a < 0x06040000 && i < 0x3ffff) {
          final ram = this.ram;
          ram[i] = value >> 8;
          ram[i + 1] = value;
          return;
        }
      }
    }
    if ((address & 0xfffff000) == 0xc0000000) {
      writeSh8(address, value.shr8, cpu);
      writeSh8(address + 1, value, cpu);
      return;
    }
    if (address >= 0x40000000) return;
    address &= 0x1fffffff;
    value &= 0xffff;
    if (address >= 0x4000 && address < 0x4040) {
      _writeSystem(address - 0x4000, value, cpu);
      return;
    }
    if (address >= 0x4100 && address < 0x4110) {
      if (shOwnsVideo) video.writeRegister(address - 0x4100, value);
      return;
    }
    if (address >= 0x4200 && address < 0x4400) {
      if (shOwnsVideo) video.palette[(address - 0x4200).shr1] = value;
      return;
    }
    writeSh8(address, value.shr8, cpu);
    writeSh8(address + 1, value, cpu);
  }
}

class ExpansionBus implements Sh2Bus {
  final Md32x expansion;
  final int cpu;
  ExpansionBus(this.expansion, this.cpu);
  @override
  int read8(int address) => expansion.readSh8(address, cpu);
  @override
  int read16(int address) => expansion.readSh16(address, cpu);
  @override
  int read32(int address) => expansion.readSh32(address, cpu);
  @override
  void write8(int address, int value) =>
      expansion.writeSh8(address, value, cpu);
  @override
  void write16(int address, int value) =>
      expansion.writeSh16(address, value, cpu);
  @override
  void write32(int address, int value) =>
      expansion.writeSh32(address, value, cpu);
}
