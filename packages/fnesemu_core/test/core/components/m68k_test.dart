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
