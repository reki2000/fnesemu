import 'dart:typed_data';

import 'package:fnesemu_core/src/components/m68k/bus.dart';
import 'package:fnesemu_core/src/components/m68k/cpu.dart';
import 'package:fnesemu_core/src/state.dart';
import 'package:test/test.dart';

class MemoryBus implements M68Bus {
  final bytes = ByteData(0x10000);
  final accesses = <(String, int)>[];
  @override
  int read8(int address) {
    accesses.add(('read8', address));
    return bytes.getUint8(address & 0xffff);
  }

  @override
  int read16(int address) {
    accesses.add(('read16', address));
    return bytes.getUint16(address & 0xffff);
  }

  @override
  void write8(int address, int value) {
    accesses.add(('write8', address));
    bytes.setUint8(address & 0xffff, value & 255);
  }

  @override
  void write16(int address, int value) {
    accesses.add(('write16', address));
    bytes.setUint16(address & 0xffff, value & 0xffff);
  }

  void program(List<int> words) {
    for (var i = 0; i < words.length; i++) {
      bytes.setUint16(0x100 + 2 * i, words[i]);
    }
  }
}

void main() {
  late MemoryBus bus;
  late M68 cpu;
  setUp(() {
    bus = MemoryBus();
    bus.bytes.setUint32(0, 0x8000);
    bus.bytes.setUint32(4, 0x100);
    cpu = M68(bus)..reset();
  });

  Uint8List save(M68 source) {
    final writer = StateWriter('component', 1, 0);
    source.saveState(writer);
    return writer.take();
  }

  void load(M68 target, Uint8List bytes) {
    final reader = StateReader(bytes, 'component', 1, 0);
    target.loadState(reader);
    reader.end();
  }

  test('state restores both stack banks and instruction latches in place', () {
    cpu.d.setAll(0, [0xffffffff, 1, 2, 3, 4, 5, 6, 0x80000000]);
    for (var i = 0; i < 7; i++) {
      cpu.a[i] = 0x200 + i * 4;
    }
    cpu.ssp = 0x8000;
    cpu.usp = 0x7000;
    cpu.sr = 0x201f;
    cpu.pc = 0x240;
    cpu.pc0 = 0x234;
    cpu.op0 = 0x23c0;
    cpu.addr0 = 0x123456;
    cpu.clocks = 0x100000001;
    final snapshot = save(cpu);
    final otherBus = MemoryBus();
    final copy = M68(otherBus);
    final dataRegisters = copy.d, addressRegisters = copy.a.a;
    load(copy, snapshot);
    expect(identical(copy.bus, otherBus), isTrue);
    expect(identical(copy.d, dataRegisters), isTrue);
    expect(identical(copy.a.a, addressRegisters), isTrue);
    expect(save(copy), snapshot);
    expect(copy.a[7], 0x8000);
    copy.sf = false;
    expect(copy.a[7], 0x7000);
    expect((copy.pc0, copy.op0, copy.addr0, copy.clocks),
        (0x234, 0x23c0, 0x123456, 0x100000001));
  }, testOn: 'vm');

  test('state retains STOP and pending interrupt priority through continuation',
      () {
    bus.program([0x4e72, 0x2000, 0x5280, 0x60fe]);
    bus.bytes.setUint32(0x60 + 4 * 4, 0x300);
    bus.bytes.setUint32(0x60 + 2 * 4, 0x400);
    bus.bytes.setUint16(0x300, 0x4e73);
    bus.bytes.setUint16(0x400, 0x4e73);
    expect(cpu.exec(), isTrue);
    final otherBus = MemoryBus();
    otherBus.bytes.buffer
        .asUint8List()
        .setAll(0, bus.bytes.buffer.asUint8List());
    final copy = M68(otherBus);
    load(copy, save(cpu));
    final stoppedPc = cpu.pc;
    expect(cpu.exec(), isTrue);
    expect(copy.exec(), isTrue);
    expect(copy.pc, stoppedPc);
    expect(save(copy), save(cpu));
    cpu.interrupt(2);
    cpu.interrupt(4);
    load(copy, save(cpu));
    for (final pc in [0x300, stoppedPc, 0x400, stoppedPc, stoppedPc + 2]) {
      expect(cpu.exec(), isTrue);
      expect(copy.exec(), isTrue);
      expect(copy.pc, pc);
      expect(save(copy), save(cpu));
      expect(
          otherBus.bytes.buffer.asUint8List(), bus.bytes.buffer.asUint8List());
    }
    expect(copy.d[0], 1);
  }, testOn: 'vm');

  test(
      'state rejects an unexpected component section before changing registers',
      () {
    final writer = StateWriter('component', 1, 0)..section('other');
    final before = save(cpu);
    expect(() => load(cpu, writer.take()), throwsA(isA<StateMismatch>()));
    expect(save(cpu), before);
  }, testOn: 'vm');

  test(
      'standalone CPU resets through the bus contract and executes instructions',
      () {
    expect(cpu.pc, 0x100);
    expect(cpu.ssp, 0x8000);
    expect(cpu.sr, 0x2700);
    bus.program([
      0x70ff, // MOVEQ #-1,D0
      0x5280, // ADDQ.L #1,D0
      0x23c0, 0, 0x0200, // MOVE.L D0,$200
      0x60fe, // BRA.S to itself
    ]);
    expect(cpu.exec(), isTrue);
    expect(cpu.d[0], 0xffffffff);
    expect(cpu.clocks, 4);
    expect(cpu.exec(), isTrue);
    expect(cpu.d[0], 0);
    expect(cpu.zf, isTrue);
    expect(cpu.cf, isTrue);
    expect(cpu.xf, isTrue);
    expect(cpu.clocks, 12);
    bus.bytes.setUint32(0x200, 0xffffffff);
    expect(cpu.exec(), isTrue);
    expect(bus.bytes.getUint32(0x200), 0);
    final loop = cpu.pc;
    expect(cpu.exec(), isTrue);
    expect(cpu.pc, loop);
  });

  test(
      'memory access retains 24-bit addresses, byte masks and big-endian word order',
      () {
    cpu.write8(0x1000200, 0x123);
    expect(bus.bytes.getUint8(0x200), 0x23);
    expect(bus.accesses.last, ('write8', 0x200));
    cpu.write32(0x1000202, 0x12345678);
    expect(bus.bytes.getUint16(0x202), 0x1234);
    expect(bus.bytes.getUint16(0x204), 0x5678);
    expect(cpu.read32(0x1000202), 0x12345678);
    expect(() => cpu.read16(0x201), throwsA(isA<BusError>()));
    expect(() => cpu.write16(0x201, 0), throwsA(isA<BusError>()));
  });

  test('interrupt enters an autovector and RTE restores PC, SR and stack', () {
    bus.bytes.setUint32(0x60 + 4 * 4, 0x300);
    bus.bytes.setUint16(0x300, 0x4e73); // RTE
    cpu.sr = 0x2000;
    cpu.interrupt(4);
    expect(cpu.exec(), isTrue);
    expect(cpu.pc, 0x300);
    expect(cpu.ssp, 0x7ffa);
    expect(bus.bytes.getUint16(0x7ffa), 0x2000);
    expect(bus.bytes.getUint32(0x7ffc), 0x100);
    expect(cpu.clocks, 28); // Preserve the existing interrupt cycle accounting.
    expect(cpu.exec(), isTrue);
    expect(cpu.pc, 0x100);
    expect(cpu.sr, 0x2000);
    expect(cpu.ssp, 0x8000);
  });
}
