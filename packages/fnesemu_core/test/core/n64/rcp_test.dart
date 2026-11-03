import 'dart:typed_data';

import 'package:fnesemu_core/src/core/n64/audio.dart';
import 'package:fnesemu_core/src/core/n64/bus.dart';
import 'package:fnesemu_core/src/core/n64/cpu.dart';
import 'package:fnesemu_core/src/core/n64/fpu.dart';
import 'package:fnesemu_core/src/core/n64/graphics.dart';
import 'package:fnesemu_core/src/pad_button.dart';
import 'package:fnesemu_core/src/pad_source.dart';
import 'package:fnesemu_core/src/sram.dart';
import 'package:fnesemu_core/src/util/int.dart';
import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';
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




}
