import 'dart:typed_data';

import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';

import '../../../util/int.dart';
import '../bus.dart';
import '../r3000/r3000.dart';
import 'r3000_translator.dart';

/// Runs the R3000 with [JitRuntime] blocks and falls back to the
/// interpreter for what the blocks leave out.
///
/// The registers and the memory accessed by the blocks live in the buffers
/// of the runtime, so the interpreter and the blocks share them. The
/// interpreter runs the instructions which need its full state: exceptions,
/// interrupts, COP0, cache isolation and the BIOS hooks. It is entered and
/// left only at instruction boundaries outside a branch delay slot; a load
/// still in its delay is carried as the block tag, see [R3000Translator].
final class PsJit {
  final JitRuntime rt;
  late final R3000 cpu;
  late final Bus bus;
  late final R3000Translator _translator;

  static const ctxRegs = JitCtx.user;
  static const ctxHi = ctxRegs + 32, ctxLo = ctxHi + 1;
  static const ctxPendingValue = ctxLo + 1;
  static const _ctxWords = ctxPendingValue + 1;

  /// the exit of an instruction run by the interpreter
  static const reasonInterpret = JitReason.user;

  late final Uint8List ram = rt.alloc(2 * 1024 * 1024);
  late final Uint8List rom = rt.alloc(512 * 1024);

  /// a page, of which the scratchpad uses the first 1KiB
  late final Uint8List scratchPad = rt.alloc(JitRuntime.pageSize);
  late final Uint32List regs = Uint32List.sublistView(rt.ctx, ctxRegs, ctxHi);

  bool _scratchPadMapped = false;

  PsJit._(this.rt);

  /// the recompiler of this host, or null if it has none; [native] false
  /// interprets the blocks instead, for tests
  static PsJit? create({bool native = true}) {
    late final PsJit jit;
    int read(int addr, int size) => jit._read(addr, size);
    void write(int addr, int size, int value) => jit._write(addr, size, value);
    const mask = 0x1fffffff;
    final rt = native
        ? JitRuntime.native(
            ctxWords: _ctxWords, addrMask: mask, read: read, write: write)
        : JitRuntime.interpreter(
            ctxWords: _ctxWords, addrMask: mask, read: read, write: write);
    if (rt == null) return null;
    return jit = PsJit._(rt);
  }

  /// connects the cpu and the bus created on [regs], [ram], [rom] and
  /// [scratchPad]
  void attach(R3000 cpu, Bus bus) {
    this.cpu = cpu;
    this.bus = bus;

    // reads mirror the ram over 128MiB and the rom over 2MiB, writes the
    // ram over 8MiB, like the fast paths of Bus
    for (int a = 0; a < 0x8000000; a += ram.length) {
      rt.mapPages(a, ram.length, ram, write: a < 0x800000);
    }
    for (int a = 0x1fc00000; a < 0x1fe00000; a += rom.length) {
      rt.mapPages(a, rom.length, rom, write: false);
    }

    final cop2 = cpu.cop2;
    _translator = R3000Translator(
      fetch: _fetch,
      cop2Cmd: rt.addHelper((inst, _, __) {
        cop2.execCmd(inst);
        return 0;
      }),
      mfc2: rt.addHelper((reg, _, __) => cop2.readReg(reg)),
      cfc2: rt.addHelper((reg, _, __) => cop2.readCtrl(reg)),
      mtc2: rt.addHelper((reg, value, _) {
        cop2.writeReg(reg, value);
        return 0;
      }),
      ctc2: rt.addHelper((reg, value, _) {
        cop2.writeCtrl(reg, value);
        return 0;
      }),
      div: rt.addHelper((a, b, signed) {
        signed != 0 ? cpu.div(a, b) : cpu.divu(a, b);
        rt.ctx[ctxHi] = cpu.hi;
        rt.ctx[ctxLo] = cpu.lo;
        return 0;
      }),
    );
  }

  /// the code word at [pc], or null outside the ram and the rom; a ram word
  /// is guarded against modification
  (int, bool)? _fetch(int pc) {
    final offset = pc & 0x1fffffff;
    if (offset < 0x800000) return (bus.read32(pc), true);
    if (offset >= 0x1fc00000 && offset < 0x1fc80000) {
      return (bus.read32(pc), false);
    }
    return null;
  }

  int _read(int addr, int size) {
    final v = switch (size) {
      1 => cpu.read8(addr),
      2 => cpu.read16(addr),
      _ => cpu.read32(addr),
    };
    _afterIo();
    return v;
  }

  void _write(int addr, int size, int value) {
    switch (size) {
      case 1:
        cpu.write8(addr, value);
      case 2:
        cpu.write16(addr, value);
      default:
        cpu.write32(addr, value);
    }
    _afterIo();
  }

  /// an I/O access may raise an interrupt or toggle the scratchpad
  void _afterIo() {
    rt.ctx[JitCtx.stop] = _stop;
    _syncScratchPad();
  }

  void _syncScratchPad() {
    if (bus.useScratchPad == _scratchPadMapped) return;
    _scratchPadMapped = bus.useScratchPad;
    // the 3KiB after the scratchpad, unused by the hardware, are mapped too
    if (_scratchPadMapped) {
      rt.mapPages(0x1f800000, JitRuntime.pageSize, scratchPad);
    } else {
      rt.unmapPages(0x1f800000, JitRuntime.pageSize);
    }
  }

  /// whether the interpreter must run: an interrupt is taken, or the cache
  /// is isolated
  int get _stop {
    final cpu = this.cpu;
    final sr = cpu.sr;
    return ((cpu.cause & sr & 0xff00) != 0 && sr.bit0) || sr.bit16 ? 1 : 0;
  }

  /// drops every block, after the rom or the whole memory changes
  void reset() => rt.clear();

  /// frees the runtime with the memory; nothing runs afterwards
  void dispose() => rt.dispose();

  /// runs until [R3000.clocks] passes [limit], like repeating
  /// [R3000.step]; the last block may pass it by a block
  void run(int limit) {
    final cpu = this.cpu, rt = this.rt, ctx = rt.ctx;
    _syncScratchPad();
    while (cpu.clocks <= limit) {
      if (_stop != 0) {
        _interpret();
        continue;
      }

      int pc = cpu.pc, tag = cpu.nextDelayReg;
      ctx[ctxPendingValue] = cpu.nextDelayVal;
      ctx[ctxHi] = cpu.hi;
      ctx[ctxLo] = cpu.lo;
      final budget = limit - cpu.clocks + 1;
      ctx[JitCtx.budget] = budget;
      ctx[JitCtx.stop] = 0;

      int reason;
      for (;;) {
        reason = rt.run(pc, tag);
        if (reason == JitReason.invalid) {
          rt.invalidate(rt.exitPc, rt.exitTag);
        } else if (reason != JitReason.miss) {
          break;
        }
        pc = rt.exitPc;
        tag = rt.exitTag;
        rt.install(_translator.translate(pc, tag));
      }

      cpu.clocks += budget - ctx[JitCtx.budget].toSigned(32);
      cpu.pc = rt.exitPc;
      cpu.nextPc = cpu.pc.inc4.mask32;
      cpu.nextDelayReg = rt.exitTag;
      cpu.nextDelayVal = ctx[ctxPendingValue];
      cpu.hi = ctx[ctxHi];
      cpu.lo = ctx[ctxLo];

      if (reason == reasonInterpret || ctx[JitCtx.stop] != 0) _interpret();
    }
  }

  /// steps the interpreter to the next instruction outside a delay slot
  void _interpret() {
    final cpu = this.cpu;
    do {
      cpu.step();
    } while (cpu.nextPc != cpu.pc.inc4.mask32);
    _syncScratchPad();
  }
}
