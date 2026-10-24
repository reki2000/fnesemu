import 'dart:typed_data';

import 'package:fnesemu_core/src/components/z80/bus.dart';
import 'package:fnesemu_core/src/components/z80/z80.dart';
import 'package:fnesemu_core/src/util/state.dart';
import 'package:test/test.dart';

class _MemoryBus implements Z80Bus {
  final memory = Uint8List(0x10000);

  @override
  int read(int addr) => memory[addr & 0xffff];

  @override
  void write(int addr, int data) => memory[addr & 0xffff] = data & 0xff;

  @override
  int input(int port) => 0xff;

  @override
  void output(int port, int data) {}

  void program(int addr, List<int> bytes) {
    for (var i = 0; i < bytes.length; i++) {
      memory[(addr + i) & 0xffff] = bytes[i];
    }
  }

  _MemoryBus copy() {
    final result = _MemoryBus();
    result.memory.setAll(0, memory);
    return result;
  }
}

void main() {
  Uint8List save(Z80 cpu) {
    final writer = StateWriter('component', 1, 0);
    cpu.saveState(writer);
    return writer.take();
  }

  void load(Z80 cpu, Uint8List bytes) {
    final reader = StateReader(bytes, 'component', 1, 0);
    cpu.loadState(reader);
    reader.end();
  }

  void expectContinuationEqual(Z80 a, Z80 b) {
    expect(a.exec(), isTrue);
    expect(b.exec(), isTrue);
    expect(save(b), save(a));
    expect((b.bus as _MemoryBus).memory, (a.bus as _MemoryBus).memory);
  }

  test('state restores register banks and control latches in place', () {
    final bus = _MemoryBus();
    final cpu = Z80(bus);
    cpu.r.r8.setAll(0, [1, 2, 3, 4, 5, 6, 7, 8]);
    cpu.r.f = 0xd7;
    cpu.r.i = 0x81;
    cpu.r.r = 0xff;
    cpu.r.ixiy.setAll(0, [0x1234, 0xabcd]);
    cpu.r.pc = 0x2468;
    cpu.r.sp = 0xfedc;
    cpu.r.af2 = 0x1357;
    cpu.r.bc2 = 0x2468;
    cpu.r.de2 = 0x369c;
    cpu.r.hl2 = 0x48ad;
    cpu.cycles = 0x100000001;
    cpu.iff1 = true;
    cpu.iff2 = true;
    cpu.im = Z80.imVector;
    cpu.assertInt();
    cpu.triggerNmi();
    cpu.eiDelay = true;
    cpu.halted = true;
    cpu.busReq = true;

    final state = save(cpu);
    final otherBus = _MemoryBus();
    final copy = Z80(otherBus);
    final registers = copy.r.r8;
    final indexRegisters = copy.r.ixiy;
    load(copy, state);

    expect(identical(copy.bus, otherBus), isTrue);
    expect(identical(copy.r.r8, registers), isTrue);
    expect(identical(copy.r.ixiy, indexRegisters), isTrue);
    expect(save(copy), state);
  }, testOn: 'vm');

  test('state continues through EI delay and an asserted maskable interrupt',
      () {
    final bus = _MemoryBus()
      ..program(0x100, [0xfb, 0x00])
      ..program(0x38, [0x3e, 0x42]);
    final cpu = Z80(bus)
      ..r.pc = 0x100
      ..r.sp = 0xff00;
    expect(cpu.exec(), isTrue); // EI leaves its one-instruction delay pending.
    cpu.assertInt();

    final otherBus = bus.copy();
    final copy = Z80(otherBus);
    load(copy, save(cpu));

    expectContinuationEqual(cpu, copy); // NOP runs before the IRQ is taken.
    expect(cpu.r.pc, 0x102);
    expectContinuationEqual(cpu, copy); // The asserted IRQ enters IM 1.
    expect(cpu.r.pc, 0x38);
    expect(cpu.iff1, isFalse);
    expectContinuationEqual(cpu, copy); // Continue in the interrupt handler.
    expect(cpu.r.a, 0x42);
  }, testOn: 'vm');

  test('state retains a pending NMI through HALT and BUSREQ', () {
    final bus = _MemoryBus()
      ..program(0x100, [0x76])
      ..program(0x66, [0x3e, 0x81]);
    final cpu = Z80(bus)
      ..r.pc = 0x100
      ..r.sp = 0xff00;
    expect(cpu.exec(), isTrue);
    expect(cpu.halted, isTrue);
    cpu.triggerNmi();

    final otherBus = bus.copy();
    final copy = Z80(otherBus);
    load(copy, save(cpu));
    expectContinuationEqual(cpu, copy);
    expect(cpu.r.pc, 0x66);
    expect(cpu.halted, isFalse);
    expectContinuationEqual(cpu, copy);
    expect(cpu.r.a, 0x81);

    cpu.busReq = true;
    copy.busReq = true;
    final heldState = save(cpu);
    load(copy, heldState);
    final pc = cpu.r.pc;
    expectContinuationEqual(cpu, copy);
    expect(cpu.r.pc, pc);
  }, testOn: 'vm');

  test('state rejects an unexpected section before changing registers', () {
    final cpu = Z80(_MemoryBus())..r.af = 0x1234;
    final before = save(cpu);
    final writer = StateWriter('component', 1, 0)..section('other');
    expect(() => load(cpu, writer.take()), throwsA(isA<StateMismatch>()));
    expect(save(cpu), before);
  }, testOn: 'vm');
}
