import 'dart:typed_data';

import 'package:fnesemu_core/src/core/ws/v30mz/v30mz.dart';
import 'package:test/test.dart';

class _Bus implements V30Bus {
  final mem = Uint8List(0x100000);
  @override
  int read8(int addr) => mem[addr];
  @override
  void write8(int addr, int data) => mem[addr] = data;
  @override
  int input8(int port) => port;
  @override
  void output8(int port, int data) => mem[0xff000 + port] = data;
}

// runs [count] instructions of [code] placed at 1000:0000 with the stack at
// 0000:2000
V30mz _run(List<int> code, int count, [void Function(V30mz)? setup]) {
  final bus = _Bus();
  bus.mem.setRange(0x10000, 0x10000 + code.length, code);
  final cpu = V30mz(bus)..reset();
  cpu.s[V30mz.cs] = 0x1000;
  cpu.r[V30mz.sp] = 0x2000;
  setup?.call(cpu);
  for (var i = 0; i < count; i++) {
    expect(cpu.exec(), isTrue);
  }
  return cpu;
}

void main() {
  test('pusha and popa save all registers', () {
    final cpu = _run([0x60, 0x31, 0xc0, 0x31, 0xdb, 0x61], 4, (cpu) {
      for (var i = 0; i < 8; i++) {
        if (i != V30mz.sp) cpu.r[i] = 0x1111 * (i + 1);
      }
    });
    for (var i = 0; i < 8; i++) {
      expect(cpu.r[i], i == V30mz.sp ? 0x2000 : 0x1111 * (i + 1));
    }
  });

  test('enter and leave build a stack frame', () {
    final cpu = _run(
        [0xc8, 0x10, 0x00, 0x00, 0xc9], 1, (cpu) => cpu.r[V30mz.bp] = 0x1234);
    expect(cpu.r[V30mz.bp], 0x1ffe);
    expect(cpu.r[V30mz.sp], 0x1fee);
    cpu.exec();
    expect(cpu.r[V30mz.bp], 0x1234);
    expect(cpu.r[V30mz.sp], 0x2000);
  });

  test('immediate push, multiply and shifts', () {
    final cpu = _run([
      0x6a, 0xfe, // push -2
      0x59, // pop cx
      0x6b, 0xc1, 0x03, // imul ax, cx, 3
      0xb3, 0x81, // mov bl, 0x81
      0xc0, 0xeb, 0x03, // shr bl, 3
    ], 5);
    expect(cpu.r[V30mz.cx], 0xfffe);
    expect(cpu.r[V30mz.ax], 0xfffa);
    expect(cpu.reg8(3), 0x10);
  });

  test('maskable interrupts wake the cpu from hlt', () {
    final cpu = _run([0xfb, 0xf4, 0x90], 2);
    cpu.bus.write8(0x20 * 4, 0x00);
    cpu.bus.write8(0x20 * 4 + 1, 0x01);
    cpu.exec();
    expect(cpu.halted, isTrue);
    cpu.irqVector = 0x20;
    cpu.exec();
    expect(cpu.halted, isFalse);
    expect(cpu.ip, 0x0100);
    expect(cpu.s[V30mz.cs], 0);
    expect(cpu.flags & V30mz.iff, 0);
  });

  test('divide by zero raises the interrupt 0', () {
    final cpu = _run([0xf6, 0xf1], 1, (cpu) {
      cpu.bus.write8(0, 0x34);
      cpu.bus.write8(2, 0x00);
      cpu.bus.write8(3, 0x20);
    });
    expect(cpu.s[V30mz.cs], 0x2000);
    expect(cpu.ip, 0x34);
  });
}
