import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/core/dc/gpio.dart';
import 'package:fnesemu_core/src/core/dc/sh4.dart';
import 'package:test/test.dart';

void main() {
  test('all twenty pins select sampled inputs or retained output latches', () {
    for (var pin = 0; pin < 20; pin++) {
      final gpio = DcGpio();
      final port = pin < 16 ? 0 : 1, bit = pin < 16 ? pin : pin - 16;
      final control = port == 0 ? 0x2c : 0x40;
      final data = port == 0 ? 0x30 : 0x44;
      gpio.drivenMask = 1 << pin;
      gpio.tickBusClocks(1);
      expect(gpio.read(data, 2) & (1 << bit), 0);
      gpio.write(data, 2, 1 << bit);
      expect(gpio.read(data, 2) & (1 << bit), 0);
      gpio.write(control, 4, 1 << (bit * 2));
      expect(gpio.read(data, 2) & (1 << bit), 1 << bit);
      gpio.write(control, 4, 0);
      expect(gpio.read(data, 2) & (1 << bit), 0);
    }
  });

  test('external drivers override pull-ups only on a new bus-clock edge', () {
    final gpio = DcGpio();
    gpio.tickBusClocks(1);
    expect(gpio.read(0x30, 2), 0xffff);
    gpio.drivenMask = 3;
    gpio.drivenValues = 2;
    gpio.tickBusClocks(0);
    expect(gpio.read(0x30, 2), 0xffff);
    gpio.tickBusClocks(1);
    expect(gpio.read(0x30, 2), 0xfffe);
    gpio.write(0x2c, 4, 2 << 4);
    gpio.tickBusClocks(1);
    expect(gpio.read(0x30, 2), 0xfffa);
    gpio.drivenMask |= 4;
    gpio.drivenValues |= 4;
    gpio.tickBusClocks(100);
    expect(gpio.read(0x30, 2), 0xfffe);
    expect(() => gpio.tickBusClocks(-1), throwsArgumentError);
  });

  test(
      'active-low input OR requests require PORTEN, GPIOIC and input direction',
      () {
    final gpio = DcGpio()..drivenMask = 0xffff;
    gpio.tickBusClocks(1);
    gpio.write(0x48, 2, 0x8001);
    expect(gpio.interruptPending, isFalse);
    gpio.enabled = true;
    expect(gpio.interruptPending, isTrue);
    gpio.write(0x2c, 4, 0x40000001);
    expect(gpio.interruptPending, isFalse);
    gpio.write(0x2c, 4, 1);
    expect(gpio.interruptPending, isTrue);
    gpio.drivenValues = 0x8000;
    gpio.tickBusClocks(1);
    expect(gpio.interruptPending, isFalse);
    gpio.write(0x48, 2, 2);
    expect(gpio.interruptPending, isTrue);
    gpio.write(0x48, 2, 0);
    expect(gpio.interruptPending, isFalse);
  });

  test('manual reset retains control and power-on reset retains data latches',
      () {
    final gpio = DcGpio()..enabled = true;
    gpio.write(0x2c, 4, 0x55555555);
    gpio.write(0x30, 2, 0x1234);
    gpio.write(0x48, 2, 0xffff);
    gpio.reset(powerOn: false);
    expect(gpio.read(0x2c, 4), 0x55555555);
    expect(gpio.read(0x48, 2), 0xffff);
    expect(gpio.read(0x30, 2), 0x1234);
    gpio.reset();
    expect(gpio.read(0x2c, 4), 0);
    expect(gpio.read(0x48, 2), 0);
    expect(gpio.enabled, isFalse);
    gpio.write(0x2c, 4, 0x55555555);
    expect(gpio.read(0x30, 2), 0x1234);
  });

  test('bus aliases, PORTEN and IPRC deliver GPIOI to the SH4 vector', () {
    final bus = DcBus();
    final cpu = Sh4(bus)
      ..sr = 0x40000000
      ..pc = 0x0c010000
      ..vbr = 0x0c020000;
    bus.write16(cpu.pc, 9);
    bus.write16(cpu.pc + 2, 9);
    bus.write32(0xff80002c, 0);
    expect(bus.read32(0x1f80002c), 0);
    bus.write16(0xff800004, 0x3ffd);
    bus.write16(0xff800048, 1);
    bus.gpio.drivenMask = 1;
    bus.tickMasterClocks(bus.cpg.busPeriod - 1);
    expect(bus.read16(0xff800030) & 1, 1);
    bus.tickMasterClocks(1);
    expect(bus.read16(0xff800030) & 1, 0);
    cpu.step();
    expect(cpu.pc, 0x0c010002);
    bus.write16(0xffd0000c, 0xa000);
    expect(bus.intc.pending(5, bus.tmu, gpio: bus.gpio), (10, 0x2a0));
    cpu.sr = 0x400000a0;
    cpu.step();
    expect(cpu.pc, 0x0c010004);
    cpu.sr = 0x40000090;
    cpu.step();
    expect(cpu.pc, 0x0c020600);
    expect(bus.intevt, 0x620);
    expect(bus.gpio.interruptPending, isTrue);
    bus.write16(0xff800004, 0x3ffc);
    expect(bus.gpio.interruptPending, isFalse);
    expect(() => bus.read8(0xff800030), throwsA(isA<DcUnsupported>()));
    expect(() => bus.read32(0xdf80002c), throwsA(isA<DcUnsupported>()));
  });
}
