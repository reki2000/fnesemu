import 'dart:typed_data';

import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';

import '../../components/arm7/jit/translator.dart';
import '../../util/jit_adapter.dart';
import 'arm7tdmi/arm7.dart';
import 'bus.dart';

/// Compiled ARM7TDMI execution for the GBA core.
///
/// The runtime owns the work RAM buffers and the cartridge ROM copy
/// it maps (the native runtime can only map its own allocations), and
/// the bus uses those same buffers, so compiled loads and stores hit
/// the bytes the interpreter uses, and the block guards see
/// interpreter and DMA writes. Everything else (BIOS, I/O, palette,
/// VRAM, OAM, save memory, and the first page of each ROM window,
/// which holds the cartridge GPIO registers) stays unmapped: a
/// translated access there exits to the interpreter, which performs
/// it through the bus. The register file lives in the runtime context
/// and is shared with the interpreter, as on the DC core; the driver
/// tag carries the Thumb state, so a run resumes in the state the
/// previous run or the interpreter left.
final class GbaJit extends JitAdapter {
  GbaJit._(super.rt, super.native);

  @override
  JitDriver get driver => _driver;

  /// The work RAM the bus runs on, allocated by the runtime so it can
  /// be mapped for compiled code.
  late final Uint8List ewram = rt.alloc(0x40000);
  late final Uint8List iwram = rt.alloc(0x8000);

  late final _code = JitCodeMemory(rt);
  late final ArmTranslator _translator;
  late final JitDriver _driver;
  late final Bus _bus;

  /// The mapped copy of the current cartridge ROM and the length of
  /// it that is mapped (page-aligned, past the skipped first page).
  Uint8List _rom = Uint8List(0);
  int _romMappedLength = 0;

  /// The ARM registers, shared with the interpreter.
  late final Uint32List registers = Uint32List.view(
      rt.ctx.buffer, rt.ctx.offsetInBytes + ArmTranslator.regs * 4, 16);

  /// The recompiler of this host, or null if it has none; [native]
  /// false interprets the blocks instead, for tests.
  static GbaJit? create({bool native = true}) {
    if (native) JitRuntime.resetPool();
    late final GbaJit jit;
    int read(int addr, int size) => jit._read(addr, size);
    void write(int addr, int size, int value) => jit._write(addr, size, value);
    final rt = native
        ? JitRuntime.native(
            ctxWords: ArmTranslator.ctxWords,
            addrMask: 0x0fffffff,
            read: read,
            write: write)
        : JitRuntime.interpreter(
            ctxWords: ArmTranslator.ctxWords,
            addrMask: 0x0fffffff,
            read: read,
            write: write);
    if (rt == null) return null;
    return jit = GbaJit._(rt, native);
  }

  /// Connects the bus: maps the work RAM and cartridge ROM and binds
  /// the translator and driver to it. The bus must run on this
  /// adapter's [ewram] and [iwram] buffers.
  void attach(Bus bus) {
    _bus = bus;
    _code.map(0x02000000, ewram.length, ewram);
    _code.map(0x03000000, iwram.length, iwram);
    _translator = ArmTranslator(
        fetch: _fetch,
        fetchHalf: _fetchHalf,
        protect: _code.protect,
        policy: ArmTranslatorPolicy.gba);
    _driver = JitDriver(rt,
        translate: (pc, tag) => _translator.translate(pc, tag: tag),
        codeWord: _fetch,
        codeMemory: _code,
        threshold: 4,
        prepareFirst: true,
        maxDispatches: 64,
        continueAfterExit: (reason) =>
            reason == JitReason.invalid ||
            reason == JitReason.miss &&
                rt.ctx[JitCtx.stop] == 0 &&
                rt.ctx[JitCtx.budget].toSigned(32) > 0);
    mapRom();
  }

  /// Copies the current cartridge ROM into runtime memory and maps
  /// it into every ROM window, skipping each window's first page: the
  /// cartridge GPIO registers live there and their reads must keep
  /// going through the bus. Called when a cartridge is loaded; the
  /// old blocks go with the old ROM.
  void mapRom() {
    final rom = _bus.cart.rom;
    driver.reset();
    _rom = Uint8List(0);
    _romMappedLength = 0;
    if (rom.length <= 0x1000) return;
    final copy = rt.alloc(rom.length);
    copy.setAll(0, rom);
    _rom = copy;
    final size = (rom.length - 0x1000) & ~(rt.pageBytes - 1);
    if (size <= 0) return;
    _romMappedLength = 0x1000 + size;
    for (final base in [0x08000000, 0x0a000000, 0x0c000000]) {
      _code.map(base + 0x1000, size, copy, offset: 0x1000, writable: false);
    }
  }

  /// The mapped buffer and offset holding [addr], or null when the
  /// address is not compiled-code memory (see the class doc).
  (Uint8List, int)? _region(int addr) {
    if (addr >= 0x02000000 && addr < 0x02040000) return (ewram, addr - 0x02000000);
    if (addr >= 0x03000000 && addr < 0x03008000) return (iwram, addr - 0x03000000);
    if (addr >= 0x08000000 && addr < 0x0e000000) {
      final offset = addr & 0x01ffffff;
      if (offset >= 0x1000 && offset < _romMappedLength) return (_rom, offset);
    }
    return null;
  }

  int? _fetch(int pc) {
    if (pc & 3 != 0) return null;
    final region = _region(pc);
    if (region == null) return null;
    final (buffer, offset) = region;
    if (offset + 4 > buffer.length) return null;
    return buffer[offset] |
        (buffer[offset + 1] << 8) |
        (buffer[offset + 2] << 16) |
        (buffer[offset + 3] << 24);
  }

  int? _fetchHalf(int pc) {
    if (pc & 1 != 0) return null;
    final region = _region(pc);
    if (region == null) return null;
    final (buffer, offset) = region;
    if (offset + 2 > buffer.length) return null;
    return buffer[offset] | (buffer[offset + 1] << 8);
  }

  // The runtime's fallback access path; translated code only reaches
  // it for addresses outside the mapped regions, which the translator
  // already exits on, so these just mirror the bus.
  int _read(int addr, int size) => switch (size) {
        1 => _bus.read8(addr),
        2 => _bus.read16(addr),
        _ => _bus.read32(addr),
      };

  void _write(int addr, int size, int value) {
    switch (size) {
      case 1:
        _bus.write8(addr, value);
      case 2:
        _bus.write16(addr, value);
      default:
        _bus.write32(addr, value);
    }
  }

  /// Runs compiled blocks from the CPU state for up to [budget]
  /// cycles and returns the cycles they took; zero means the caller
  /// should step the interpreter instead.
  int run(Arm7 cpu, int budget) {
    if (suspended) return 0;
    final ctx = rt.ctx;
    final tag = cpu.regs.thumb ? 1 : 0;
    if (_driver.isFallback(cpu.pc, tag)) return 0;
    ctx[ArmTranslator.cpsr] = cpu.regs.cpsr;
    ctx[JitCtx.faultAddr] = 0;
    final reason = _driver.runBudgeted(cpu.pc, tag, budget);
    final cycles = _driver.lastClocks;
    if (cycles > 0) {
      cpu.regs.cpsr = ctx[ArmTranslator.cpsr];
      cpu.regs.r[15] = rt.exitPc + (rt.exitTag == 1 ? 4 : 8);
      cpu.cycles += cycles;
    }
    if (reason == ArmTranslator.interpret) {
      // A store into a code page: leave later stores to the entry guards.
      final fault = ctx[JitCtx.faultAddr];
      if (fault != 0 && _code.isProtected(fault)) _code.release(fault);
    }
    return cycles;
  }
}
