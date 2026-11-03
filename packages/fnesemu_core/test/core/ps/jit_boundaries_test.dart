import 'dart:async';
import 'package:fnesemu_core/src/core/ps/bus.dart';
import 'package:fnesemu_core/src/core/ps/interrupt.dart';
import 'package:fnesemu_core/src/core/ps/jit/ps_jit.dart';
import 'package:fnesemu_core/src/core/ps/r3000/r3000.dart';
import 'package:fnesemu_core/src/core/ps/timer.dart';
import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';
import 'package:test/test.dart';

const _code = 0x80010000, _device = 0x1f801810;
int _i(int op, int rs, int rt, int imm) =>
    op << 26 | rs << 21 | rt << 16 | (imm & 0xffff);
int _j(int address) => 2 << 26 | (address >> 2) & 0x3ffffff;

class _Bus extends Bus {
  _Bus(PsJit? jit)
      : super(mem: jit?.ram, rom: jit?.rom, scratchPad: jit?.scratchPad);

  final accesses = <(String, int, int)>[];

  @override
  int read32(int addr) {
    if (addr == _device) {
      accesses.add(('read', cpu.clocks, 123));
      return 123;
    }
    return super.read32(addr);
  }

  @override
  void write32(int addr, int value) {
    if (addr == _device) {
      accesses.add(('write', cpu.clocks, value));
      return;
    }
    super.write32(addr, value);
  }
}

final _liveMachines = <_Machine>[];

void _disposeLiveMachines() {
  for (final m in _liveMachines) {
    m.jit?.dispose();
  }
  _liveMachines.clear();
}

final class _Machine {
  final PsJit? jit;
  late final _Bus bus;
  late final R3000 cpu;

  _Machine(bool? native, List<int> program)
      : jit = native == null
            ? null
            : PsJit.create(native: native, compileThreshold: 1)! {
    bus = _Bus(jit);
    cpu = R3000(bus, regs: jit?.regs);
    bus.cpu = cpu;
    bus.interrupt = InterruptController()..cpu = cpu;
    bus.timer = TimerController(bus)..reset();
    jit?.attach(cpu, bus);
    cpu.reset();
    cpu.pc = _code;
    cpu.nextPc = _code + 4;
    for (final (n, word) in program.indexed) {
      bus.write32(_code + 4 * n, word);
    }
    final end = _code + 4 * program.length;
    bus.write32(end, _j(end));
    bus.write32(end + 4, 0);
    _liveMachines.add(this);
  }

  void run() {
    final jit = this.jit;
    if (jit != null) {
      jit.run(cpu.clocks + 100);
    } else {
      final limit = cpu.clocks + 100;
      do {
        cpu.step();
      } while (cpu.clocks <= limit);
    }
  }
}

class _CaseSkip implements Exception {
  const _CaseSkip();
}

void main() {
  // Aggregated cases: the per-case tests of this file are collected
  // in this table and executed by the aggregated test(s) at the end of
  // main; every case name stays visible here and in the run output.
  final aggCases = <(String, FutureOr<void> Function())>[];
  final aggTeardowns = <void Function()>[];
  void aggCase(String name, FutureOr<void> Function() body) =>
      aggCases.add((name, body));
  void aggGroup(String name, void Function() body, {Object? skip}) {
    if (skip == null || skip == false) body();
  }
  Future<void> runAggCases(
      Iterable<(String, FutureOr<void> Function())> cases) async {
    for (final (name, body) in cases) {
      print('case: $name');
      try {
        await body();
      } on _CaseSkip {
        print('skipped: $name');
      } finally {
        for (final teardown in aggTeardowns) {
          teardown();
        }
        aggTeardowns.clear();
        _disposeLiveMachines();
      }
    }
  }

  for (final native in <bool?>[null, false, true]) {
    final name = native == null
        ? 'CPU'
        : native
            ? 'native'
            : 'IR';
    aggGroup(name, () {
      for (final (op, taken) in [(0x05, false), (0x04, true)]) {
        aggCase('compiled delay slots clear interpreter branch state before interrupts ($taken)', () {
          // Both branches leave nextPc sequential, so JIT can run the slot after cpu.step().
          final m = _Machine(native, [
            _i(op, 0, 0, 1),
            _i(0x23, 2, 1, 0),
            _j(_code + 8),
            0,
          ]);
          m.cpu.r[2] = _code + 0x4000;
          m.bus.write32(_code + 0x4000, 1234);
          m.cpu.step();
          expect(m.cpu.inBranchDelay, isTrue);
          expect(m.cpu.inBranchTaken, taken);
          if (m.jit != null) {
            m.jit!.run(23);
          } else {
            while (m.cpu.clocks <= 23) {
              m.cpu.step();
            }
          }
          expect(m.cpu.r[1], 1234);
          final interruptedPc = m.cpu.pc;
          m.cpu.sr = 0x401;
          m.cpu.cause = 0x400;
          m.cpu.step();
          expect(m.cpu.epc, interruptedPc);
          expect(m.cpu.cause & 0xc0000000, 0);
        });
      }

      aggCase('resumes a branch stepped by the debugger', () {
        final m = _Machine(native, [
          _j(_code + 16),
          _i(9, 0, 2, 7),
          _i(9, 0, 1, 111),
          0,
          _i(9, 0, 3, 9),
        ]);
        m.cpu.step();
        m.run();
        expect(m.cpu.r[1], 0);
        expect(m.cpu.r[2], 7);
        expect(m.cpu.r[3], 9);
      });

      for (final (op, offset, value) in [
        (0x28, 4, 2), // sb
        (0x29, 4, 2), // sh
        (0x2b, 4, _i(9, 0, 1, 2)), // sw
        (0x2a, 7, _i(9, 0, 1, 2)), // swl: all four bytes
        (0x2e, 4, _i(9, 0, 1, 2)), // swr: all four bytes
      ]) {
        aggCase('store $op sees upcoming code changed through a RAM alias', () {
          final m = _Machine(native, [
            _i(op, 2, 3, offset),
            _i(9, 0, 1, 1),
          ]);
          m.cpu.r[2] = _code | 0x20000000;
          m.cpu.r[3] = value;
          m.run();
          expect(m.cpu.r[1], 2);
        });
      }

      aggCase('a code page written by a loop still sees changed code', () {
        // the loop stores data next to its code more often than a code page
        // stays protected, then changes the instruction after a store
        final m = _Machine(native, [
          _i(9, 0, 4, 40), // addiu r4, r0, 40
          _i(15, 0, 2, _code >> 16), // lui r2, code
          _i(0x2b, 2, 4, 0x100), // loop: sw r4, 0x100(r2)
          _i(9, 4, 4, -1), // addiu r4, r4, -1
          _i(5, 4, 0, -3), // bne r4, r0, loop
          0,
          _i(0x2b, 2, 3, 0x1c), // sw r3, 0x1c(r2)
          _i(9, 0, 1, 1), // addiu r1, r0, 1
        ]);
        m.cpu.r[3] = _i(9, 0, 1, 2);
        for (int n = 0; n < 20; n++) {
          m.run();
        }
        expect(m.bus.read32(_code + 0x100), 1);
        expect(m.cpu.r[1], 2);
      });

      aggCase('timer reads observe elapsed instructions', () {
        final m = _Machine(native, [
          _i(0x25, 2, 1, 0),
          0,
          0,
          0,
          _i(0x25, 2, 3, 0),
          0,
        ]);
        m.cpu.r[2] = 0x1f801100;
        m.run();
        expect(m.cpu.r[1], 0);
        expect(m.cpu.r[3], 8);
      });

      aggCase('timer writes reset at their instruction clock', () {
        final m = _Machine(native, [
          0,
          0,
          0,
          0,
          _i(0x29, 2, 0, 0),
          0,
          0,
          _i(0x25, 2, 3, 0),
          0,
        ]);
        m.cpu.r[2] = 0x1f801100;
        m.run();
        expect(m.cpu.r[3], 6);
      });

      aggCase('a device write takes an interrupt before a following ack', () {
        final m = _Machine(native, [
          _i(0x29, 2, 1, 4), // enable I_MASK
          _i(0x29, 2, 0, 0), // acknowledge I_STAT
          _i(9, 0, 3, 111),
        ]);
        m.cpu.r[1] = 1;
        m.cpu.r[2] = 0x1f801070;
        m.cpu.sr = 0x401;
        m.bus.interrupt.setIrq(Interrupt.vBlank);
        m.run();
        expect(m.cpu.epc, _code + 4);
        expect(m.cpu.r[3], 0);
        expect(m.bus.interrupt.status, 1);
      });

      for (final (op, offset) in [(0x2a, 3), (0x2e, 0)]) {
        aggCase('store $op does not read a fully overwritten device word', () {
          final m = _Machine(native, [_i(op, 2, 1, offset)]);
          m.cpu.r[2] = _device;
          m.cpu.r[1] = 99;
          m.run();
          expect(m.bus.accesses, [('write', 0, 99)]);
        });
      }

      aggCase('a delay-slot device access observes a pending load', () {
        final m = _Machine(native, [
          _i(0x23, 4, 2, 0),
          _j(_code + 16),
          _i(0x2b, 2, 1, 0),
          _i(9, 0, 3, 111),
        ]);
        m.cpu.r[1] = 99;
        m.cpu.r[2] = 0x80100000;
        m.cpu.r[4] = 0x80100004;
        m.bus.write32(0x80100004, _device);
        m.run();
        expect(m.bus.accesses, [('write', 4, 99)]);
        expect(m.cpu.r[3], 0);
      });

      aggCase('a delay-slot address observes the branch link register', () {
        final m = _Machine(native, [
          3 << 26 | ((_code + 16) >> 2) & 0x3ffffff, // jal
          _i(0x2b, 31, 1, 0),
          0,
          0,
          _i(9, 0, 3, 9),
        ]);
        m.cpu.r[1] = 99;
        m.cpu.r[31] = _device;
        m.run();
        expect(m.bus.accesses, isEmpty);
        expect(m.bus.read32(_code + 8), 99);
        expect(m.cpu.r[3], 9);
      });

      aggCase('a device load in a delay slot retains its load delay', () {
        final m = _Machine(native, [
          _j(_code + 12),
          _i(0x23, 2, 1, 0),
          _i(9, 0, 3, 111),
          1 << 21 | 3 << 11 | 0x21, // addu r3, r1, r0
          0,
          1 << 21 | 4 << 11 | 0x21, // addu r4, r1, r0
        ]);
        m.cpu.r[1] = 9;
        m.cpu.r[2] = _device;
        m.run();
        expect(m.bus.accesses, [('read', 2, 123)]);
        expect(m.cpu.r[3], 9);
        expect(m.cpu.r[4], 123);
      });
    },
        skip: native == true && !JitRuntime.nativeSupported
            ? 'no native recompiler on this host'
            : false);
  }

  const chunkCount = 6;
  final chunkSize = (aggCases.length + chunkCount - 1) ~/ chunkCount;
  for (var part = 0; part < chunkCount; part++) {
    final partCases =
        aggCases.skip(part * chunkSize).take(chunkSize).toList();
    if (partCases.isEmpty) continue;
    test('aggregated cases ${part + 1} of $chunkCount', () async {
      await runAggCases(partCases);
    }, timeout: const Timeout(Duration(minutes: 10)));
  }
}
