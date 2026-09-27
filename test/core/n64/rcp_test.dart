import 'dart:typed_data';
import 'package:fnesemu/core/n64/bus.dart';
import 'package:fnesemu/core/n64/cpu.dart';
import 'package:fnesemu/core/n64/fpu.dart';
import 'package:fnesemu/core/n64/graphics.dart';
import 'package:fnesemu/core/n64/audio.dart';
import 'package:fnesemu/core/pad_button.dart';
import 'package:fnesemu/core/sram.dart';
import 'package:test/test.dart';

void main() {
  test('SP memory word stores and PC register do not alias DMA registers', () {
    final bus = N64Bus();
    bus.write(0xa4000000, 0x12345678, 4);
    bus.write(0xa4001000, 0xabcdef01, 4);
    expect(bus.read(0xa4000000, 4), 0x12345678);
    expect(bus.read(0xa4001000, 4), 0xabcdef01);
    expect(bus.spRegs[0], 0);
    bus.spRegs[0] = 0x123;
    bus.write(0xa4080000, 0xabc, 4);
    expect(bus.read(0xa4080000, 4), 0xabc);
    expect(bus.read8(0xa4080002), 0x0a);
    expect(bus.spRegs[0], 0x123);
  });

  test('MI mask commands and VI interrupt acknowledgement', () {
    final b = N64Bus()..reset();
    b.interrupt(8);
    expect(b.interruptPending, false);
    b.write(0xa430000c, 0x80, 4);
    expect(b.interruptPending, true);
    b.write(0xa4400010, 0, 4);
    expect(b.interruptPending, false);
    b.interrupt(8);
    b.write(0xa430000c, 0x40, 4);
    expect(b.interruptPending, false);
  });
  test('SP DMA rows wrap within a DMEM bank and honour skip', () {
    final b = N64Bus()..reset();
    for (var i = 0; i < 32; i++) {
      b.ram[0x100 + i] = i;
    }
    b.write(0xa4040000, 0xff8, 4);
    b.write(0xa4040004, 0x100, 4);
    b.write(0xa4040008, (8 << 20) | (1 << 12) | 7, 4);
    expect(b.sp.sublist(0xff8, 0x1000), List.generate(8, (i) => i));
    expect(b.sp.sublist(0, 8), List.generate(8, (i) => 16 + i));
    expect(b.sp.sublist(0x1000, 0x1008), List.filled(8, 0));
  });
  test('SI delivers controller buttons and analog stick through PIF packets',
      () {
    final b = N64Bus()..reset();
    b.pad(0, const PadButton('A'), true);
    b.pad(0, PadButton.left, true);
    b.pad(0, PadButton.up, true);
    b.ram.setRange(0x100, 0x109, [1, 4, 1, 0, 0, 0, 0, 0xfe, 0]);
    b.ram[0x13f] = 1;
    b.write(0xa4800000, 0x100, 4);
    b.write(0xa4800010, 0x1fc007c0, 4);
    b.write(0xa4800000, 0x200, 4);
    b.write(0xa4800004, 0x1fc007c0, 4);
    expect(b.ram.sublist(0x203, 0x207), [0x80, 0, 176, 80]);
    b.pad(0, const PadButton('A'), false);
    b.pad(0, PadButton.left, false);
    b.write(0xa4800004, 0x1fc007c0, 4);
    expect(b.ram.sublist(0x203, 0x207), [0, 0, 0, 80]);
    expect(b.mi[2] & 2, 2);
    b.write(0xa4800018, 0, 4);
    expect(b.mi[2] & 2, 0);
  });
  test('EEPROM write/read uses persistent Sram, independently of reset', () {
    final b = N64Bus()..reset();
    b.sram = Sram()..init('n64', Uint8List(512));
    final packet = [0, 0, 0, 0, 10, 1, 5, 3, 1, 2, 3, 4, 5, 6, 7, 8, 0, 0xfe];
    b.ram.setRange(0x100, 0x100 + packet.length, packet);
    b.ram[0x13f] = 1;
    b.write(0xa4800000, 0x100, 4);
    b.write(0xa4800010, 0x1fc007c0, 4);
    expect(b.sram!.data.sublist(24, 32), [1, 2, 3, 4, 5, 6, 7, 8]);
    b.reset();
    final read = [0, 0, 0, 0, 2, 8, 4, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0xfe];
    b.ram.setRange(0x100, 0x100 + read.length, read);
    b.ram[0x13f] = 1;
    b.write(0xa4800000, 0x100, 4);
    b.write(0xa4800010, 0x1fc007c0, 4);
    b.write(0xa4800000, 0x200, 4);
    b.write(0xa4800004, 0x1fc007c0, 4);
    expect(b.ram.sublist(0x208, 0x210), [1, 2, 3, 4, 5, 6, 7, 8]);
  });
  test(
      'AI decodes signed stereo PCM, schedules completion and acknowledges IRQ',
      () {
    final b = N64Bus()..reset();
    b.ramWrite(0x100, 0x7fff8000, 4);
    b.ramWrite(0x104, 0, 4);
    var samples = Float32List(0), rate = 0;
    b.onAudio = (audio) {
      samples = audio.buffer;
      rate = audio.sampleRate;
    };
    b.write(0xa4500010, 1520, 4);
    b.write(0xa4500000, 0x100, 4);
    b.write(0xa4500004, 8, 4);
    expect(rate, closeTo(32000, 20));
    expect(samples[0], closeTo(1, 0.0001));
    expect(samples[1], -1);
    expect(b.ai[3], 0x40000000);
    b.tick(10000);
    expect(b.mi[2] & 4, 4);
    b.write(0xa450000c, 0, 4);
    expect(b.mi[2] & 4, 0);
  });
  test('CP0 Compare timer is delivered after idle fast forward', () {
    final b = N64Bus()..reset();
    b.ramWrite(0, 0x1000ffff, 4);
    final c = Vr4300(b)..reset(0x80000000);
    c.cop0[12] = 0x8001;
    c.cop0[11] = 100;
    c.step();
    c.step();
    expect(c.idleLoop, true);
    c.idle(1000);
    expect(c.count, 100);
    expect(c.idleLoop, false);
    c.step();
    expect(c.pc, 0x80000180);
    expect(c.cop0[14], 0x80000000);
    expect(c.cop0[13] & 0x8000, 0x8000);
    b.ramWrite(0x180, 0x42000018, 4);
    c.step();
    expect(c.pc, 0x80000000);
    expect(c.cop0[12] & 2, 0);
  });
  test('delay slot exceptions record branch PC and Cause.BD', () {
    final b = N64Bus()..reset();
    b.ramWrite(0, 0x10000001, 4);
    b.ramWrite(4, 12, 4);
    final c = Vr4300(b)..reset(0x80000000);
    c.step();
    c.step();
    expect(c.cop0[14], 0x80000000);
    expect(c.cop0[13] & 0x80000000, 0x80000000);
    expect((c.cop0[13] >> 2) & 31, 8);
  });
  test('unaligned big endian LWL/LWR merge the addressed bytes', () {
    final b = N64Bus()..reset();
    b.ram.setRange(0x101, 0x105, [0x12, 0x34, 0x56, 0x78]);
    b.ramWrite(0, 0x88010101, 4);
    b.ramWrite(4, 0x98010104, 4);
    final c = Vr4300(b)..reset(0x80000000);
    c.step();
    c.step();
    expect(c.r[1], BigInt.from(0x12345678));
  });
  test(
      'COP1 disabled raises a coprocessor-unusable exception for OS lazy FPU context switching',
      () {
    final b = N64Bus()..reset();
    b.ramWrite(0, 0x44010000, 4);
    final c = Vr4300(b)..reset(0x80000000);
    c.cop0[12] = 0xff01;
    c.step();
    expect(c.pc, 0x80000180);
    expect((c.cop0[13] >> 2) & 31, 11);
    expect((c.cop0[13] >> 28) & 3, 1);
  });
  test('GBI viewport flips clip Y into screen coordinates', () {
    final b = N64Bus()..reset(), g = N64Graphics(b);
    g.width = 4;
    g.colorImage = 0x1000;
    g.scRight = g.scBottom = 4;
    g.scale = [2, 2, 1];
    g.translate = [2, 2, 1];
    g.combine1 = (7 << 28) | (4 << 15) | (7 << 12) | (6 << 9);
    g.triangle(
        const N64Vertex([-1, -1, 0, 1], [255, 0, 0, 255], 0, 0),
        const N64Vertex([1, -1, 0, 1], [255, 0, 0, 255], 0, 0),
        const N64Vertex([0, 1, 0, 1], [255, 0, 0, 255], 0, 0));
    expect(b.ramRead(0x1000, 2), 0);
    expect(b.ramRead(0x1000 + (1 * 4 + 1) * 2, 2), 0xf801);
  });

  test('COP1 single/double conversion, FR mode and nearest-even rounding', () {
    final f = N64Fpu();
    f.setValue(0, 16, 1.25);
    f.setValue(2, 16, 2.5);
    f.execute(16, 2, 0, 4, 0);
    expect(f.value(4, 16), 3.75);
    f.execute(16, 0, 4, 6, 33);
    expect(f.value(6, 17), 3.75);
    f.setValue(0, 16, 2.5);
    f.execute(16, 0, 0, 2, 12);
    expect(f.word(2), 2);
    f.setValue(0, 16, -3.5);
    f.execute(16, 0, 0, 2, 12);
    expect(f.word(2).toSigned(32), -4);
    f.wide = true;
    f.setValue(1, 17, 7.5);
    f.setValue(2, 17, 3);
    f.execute(17, 2, 1, 3, 2);
    expect(f.value(3, 17), 22.5);
  });
  test('software RDP fill, RGBA16 texture load and rectangle copy', () {
    final b = N64Bus()..reset(), g = N64Graphics(b);
    g.rdp(0xff100003, 0x1000);
    g.rdp(0xed000000, (16 << 12) | 16); // 4x4 framebuffer/scissor
    g.rdp(0xef300000, 0);
    g.rdp(0xf7000000, 0xf801f801);
    g.rdp(0xf6000000 | (12 << 12) | 12, 0);
    expect(b.ramRead(0x1000, 2), 0xf801);
    expect(b.ramRead(0x101e, 2), 0xf801);
    b.ramWrite(0x2000, 0x07c1, 2);
    g.rdp(0xfd100000, 0x2000);
    g.rdp(0xf5100200, 0);
    g.rdp(0xf3000000, 0);
    g.rdp(0xf2000000, 0);
    g.rdp(0xef200000, 0);
    g.textureRect(0xe4000000, 0, 0, 0x10000400, false);
    expect(b.ramRead(0x1000, 2), 0x07c1);
  });
  test('audio commands load, mix and interleave stereo through DMEM', () {
    final b = N64Bus()..reset(), a = N64Audio(b);
    b.ramWrite(0x100, 0x40004000, 4);
    b.ramWrite(0x104, 0x40004000, 4);
    final words = [
      0x14010100,
      0x100,
      0x02000200,
      16,
      0x0c017fff,
      0x01000200,
      0x0d010300,
      0x01000200,
      0x15020300,
      0x200
    ];
    for (var i = 0; i < words.length; i++) {
      b.ramWrite(0x800 + i * 4, words[i], 4);
    }
    a.task(0x800, words.length * 4, newer: true);
    expect(b.ramRead(0x200, 2), 0x4000);
    expect(b.ramRead(0x202, 2), 0x3fff);
  });
}
