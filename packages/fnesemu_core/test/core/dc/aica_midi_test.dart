import 'package:fnesemu_core/src/core/dc/aica.dart';
import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/util/uint8list.dart';
import 'package:test/test.dart';

void main() {
  late DcBus bus;
  late DcAica aica;
  const base = 0xa0700000;
  int read() => bus.read32(base + 0x2808);
  void write(int offset, int value) => bus.write32(base + offset, value);
  setUp(() {
    bus = DcBus();
    aica = bus.aica;
  });

  test('reset exposes empty FIFOs without inventing an output transition', () {
    expect(read(), 0x900);
    expect(aica.soundPending, 0);
    expect(aica.systemPending, 0);
    expect(aica.takeMidiOutput(), isNull);
    expect(aica.clocksToEvent, isNull);
  });
  test('ARM reset retains MIDI but full device reset discards FIFOs and flags',
      () {
    aica.receiveMidiByte(0xab);
    write(0x280c, 0xcd);
    write(0x2c00, 0);
    write(0x2c00, 1);
    expect(read() & 255, 0xab);
    expect(aica.takeMidiOutput(), 0xcd);
    aica.receiveMidiByte(1);
    write(0x280c, 2);
    aica.reset();
    expect(read(), 0x900);
    expect(aica.takeMidiOutput(), isNull);
    expect(aica.systemPending, 0);
  });
  test('guest ARM byte instructions inspect status and echo one MIDI byte', () {
    const program = [
      0xe59f000c, // LDR r0,[pc,#12]: AICA MIDI registers.
      0xe5d01001, // LDRB r1,[r0,#1]: status without consuming input.
      0xe5d02000, // LDRB r2,[r0]: consume one received byte.
      0xe5c02004, // STRB r2,[r0,#4]: transmit it without modifying MSLC.
      0xeafffffe, // B .
      0x00802808,
    ];
    for (var i = 0; i < program.length; i++) {
      aica.memory.setUint32LE(i * 4, program[i]);
    }
    aica.write(0x280d, 1, 0x41, fromArm: true);
    aica.receiveMidiByte(0xfa);
    write(0x2c00, 0);
    aica.tickMasterClocks(5000);
    expect(aica.arm.r[1], 8);
    expect(aica.arm.r[2], 0xfa);
    expect(aica.sound.monitor, 0x4100);
    expect(aica.soundPending & 8, 0);
    expect(aica.takeMidiOutput(), 0xfa);
    expect(aica.takeMidiOutput(), isNull);
  });
}
