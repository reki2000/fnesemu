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
  test('four received bytes retain FIFO order and pre-read full/empty flags',
      () {
    for (final value in [0x90, 60, 127, 0]) {
      expect(aica.receiveMidiByte(value), isTrue);
    }
    expect(read(), 0xa90);
    expect(read(), 0x83c);
    expect(read(), 0x87f);
    expect(read(), 0x800);
    expect(read(), 0x900);
    expect(aica.systemPending & 8, 0);
  });
  test('RX overflow drops the newest byte and reports the flag before read',
      () {
    for (var value = 1; value <= 4; value++) {
      aica.receiveMidiByte(value);
    }
    expect(aica.receiveMidiByte(99), isFalse);
    expect(aica.read(0x2808, 4, sideEffects: false), 0xe01);
    expect(aica.read(0x2808, 4, sideEffects: false), 0xe01);
    expect(read(), 0xe01);
    expect(read(), 0x802);
    expect(read(), 0x803);
    expect(read(), 0x804);
    expect(read(), 0x904);
  });
  test('input requests remain asserted until both CPU views drain the FIFO',
      () {
    write(0x28b4, 8);
    aica.receiveMidiByte(0x90);
    aica.receiveMidiByte(0x40);
    expect(aica.soundPending & 8, 8);
    expect(aica.systemPending & 8, 8);
    expect(bus.systemBus.externalStatus & 2, 2);
    write(0x28a4, 8);
    write(0x28bc, 8);
    expect(aica.systemPending & 8, 8);
    expect(read() & 255, 0x90);
    expect(bus.systemBus.externalStatus & 2, 2);
    expect(aica.read(0x2808, 1, fromArm: true), 0x40);
    expect(bus.systemBus.externalStatus & 2, 0);
    expect(aica.soundPending & 8, 0);
  });
  test('ARM status lanes and peeks do not pop or clear RX overflow', () {
    for (var value = 0; value < 5; value++) {
      aica.receiveMidiByte(0x41 + value);
    }
    expect(aica.read(0x2809, 1, fromArm: true), 14);
    expect(aica.read(0x280a, 1, fromArm: true), 0);
    expect(aica.read(0x2808, 1, fromArm: true, sideEffects: false), 0x41);
    expect(read(), 0xe41);
    expect(aica.read(0x2809, 1, fromArm: true), 8);
    expect(aica.read(0x2808, 1, fromArm: true), 0x42);
  });
  test('TX bytes include zero and empty interrupts occur on final completion',
      () {
    write(0x28b4, 0x200);
    write(0x280c, 0x90);
    write(0x280c, 0);
    expect(read() & 0x1800, 0);
    expect(aica.takeMidiOutput(), 0x90);
    expect(aica.systemPending & 0x200, 0);
    expect(aica.takeMidiOutput(), 0);
    expect(aica.soundPending & 0x200, 0x200);
    expect(aica.systemPending & 0x200, 0x200);
    expect(bus.systemBus.externalStatus & 2, 2);
    write(0x28a4, 0x200);
    expect(aica.soundPending & 0x200, 0);
    expect(aica.systemPending & 0x200, 0x200);
    write(0x280c, 0xf8);
    expect(aica.systemPending & 0x200, 0);
    expect(bus.systemBus.externalStatus & 2, 0);
    expect(aica.takeMidiOutput(), 0xf8);
    expect(aica.systemPending & 0x200, 0x200);
  });
  test('functional TX capacity preserves oldest bytes and reports full', () {
    for (var value = 1; value <= 5; value++) {
      write(0x280c, value);
    }
    expect(read() & 0x1800, 0x1000);
    expect([for (var i = 0; i < 4; i++) aica.takeMidiOutput()], [1, 2, 3, 4]);
    expect(aica.takeMidiOutput(), isNull);
    expect(read() & 0x1800, 0x800);
  });
  test(
      'ARM monitor byte writes do not transmit and data writes preserve monitor',
      () {
    aica.write(0x280d, 1, 0x41, fromArm: true);
    expect(aica.sound.monitor, 0x4100);
    expect(aica.takeMidiOutput(), isNull);
    aica.write(0x280c, 1, 0, fromArm: true);
    aica.write(0x280e, 1, 0xff, fromArm: true);
    expect(aica.sound.monitor, 0x4100);
    expect(aica.takeMidiOutput(), 0);
    expect(aica.takeMidiOutput(), isNull);
    write(0x280c, 0x2234);
    expect(aica.sound.monitor, 0x2200);
    expect(aica.takeMidiOutput(), 0x34);
  });
  test('MIDI input follows existing ARM interrupt number/end handshake', () {
    write(0x28a8, 8);
    write(0x289c, 8);
    write(0x2c00, 0);
    aica.receiveMidiByte(0xfa);
    expect(aica.armInterruptLevel, 1);
    expect(aica.arm.fiq, isTrue);
    expect(read() & 255, 0xfa);
    expect(aica.soundPending & 8, 0);
    expect(aica.arm.fiq, isTrue);
    aica.write(0x2d04, 4, 1, fromArm: true);
    expect(aica.arm.fiq, isFalse);
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
  test('MIDI bytes do not require or synthesize audio sample ticks', () {
    aica.receiveMidiByte(0xf8);
    write(0x280c, 0xfa);
    expect(aica.clocksToEvent, isNull);
    expect(read() & 255, 0xf8);
    expect(aica.takeMidiOutput(), 0xfa);
    expect(aica.systemPending & 0x400, 0);
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
  test('system widths and write-only output retain existing MMIO restrictions',
      () {
    expect(() => bus.read8(base + 0x2808), throwsA(isA<DcUnsupported>()));
    expect(() => bus.read32(base + 0x280c), throwsA(isA<DcUnsupported>()));
    expect(() => write(0x2808, 0), throwsA(isA<DcUnsupported>()));
  });
}
