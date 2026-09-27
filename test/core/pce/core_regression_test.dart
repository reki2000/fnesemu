import 'package:fnesemu/core/pce/component/bus.dart';
import 'package:fnesemu/core/pce/component/cpu.dart';
import 'package:fnesemu/core/pce/component/pad.dart';
import 'package:fnesemu/core/pce/component/pic.dart';
import 'package:fnesemu/core/pce/component/timer.dart';
import 'package:fnesemu/core/pce/pce.dart';
import 'package:test/test.dart';

void main() {
  test('writes to CD RAM do not change work RAM', () {
    final bus = Bus();
    bus.write(0xf8 << 13, 0x12);
    bus.write(0x80 << 13, 0x34);
    expect(bus.read(0xf8 << 13), 0x12);
    expect(bus.read(0x80 << 13), 0x34);
  });

  test('all SGX RAM banks retain distinct values at the same offset', () {
    final bus = Bus()..vpc.enabled = true;
    final banks = [
      0xf8,
      0xf9,
      0xfa,
      0xfb,
      ...List.generate(8, (i) => 0x80 + i),
    ];
    for (var i = 0; i < banks.length; i++) {
      bus.write((banks[i] << 13) | 0x1fff, i + 1);
    }
    for (var i = 0; i < banks.length; i++) {
      expect(bus.read((banks[i] << 13) | 0x1fff), i + 1);
    }
  });

  test('controller buttons are independent', () {
    final pad = Pad();
    pad.keyDown(0, pad.buttons[7]);
    pad.counter = 1;
    expect(pad.port, 0x0f);
  });

  test('polling beyond five controllers does not throw', () {
    final pad = Pad();
    for (var i = 0; i < Pad.controllerNum; i++) {
      pad.port = 0;
      pad.port = 1;
    }
    expect(() => pad.port, returnsNormally);
    expect(pad.port, 0);
  });

  test('controller scan advances only on a select rising edge', () {
    final pad = Pad();
    pad.port = 3;
    pad.port = 1;
    expect(pad.counter, 0);
    pad.port = 0;
    pad.port = 1;
    pad.port = 1;
    expect(pad.counter, 1);
  });

  test('clear can be asserted again after it is released', () {
    final pad = Pad();
    pad.port = 3;
    pad.port = 0;
    pad.port = 1;
    expect(pad.counter, 1);
    pad.port = 3;
    expect(pad.counter, 0);
  });

  test('all five controllers can be read through a port scan', () {
    final pad = Pad();
    pad.keyDown(2, pad.buttons[7]);
    pad.port = 3;
    for (var i = 0; i < Pad.controllerNum; i++) {
      pad.port = 0;
      expect(pad.port, i == 2 ? 0x0d : 0x0f);
      pad.port = 1;
    }
    expect(pad.port, 0);
  });

  test('core reset restores controller selection and clear state', () {
    final pce = Pce();
    pce.bus.joypad.port = 3;
    pce.bus.joypad.port = 0;
    pce.bus.joypad.port = 1;
    pce.reset();
    expect(pce.bus.joypad.counter, 0);
    expect(pce.bus.joypad.selectLRDU, isFalse);
    expect(pce.bus.joypad.clear, isFalse);
  });

  test('controller counter saturates safely during extended polling', () {
    final pad = Pad();
    for (var i = 0; i < 300; i++) {
      pad.port = 0;
      pad.port = 1;
    }
    expect(pad.counter, 0xff);
    expect(pad.port, 0);
  });

  test('acknowledged IRQ1 is absent from interrupt status', () {
    final bus = Bus();
    Cpu2(bus);
    final pic = Pic(bus);
    pic.holdIrq1();
    expect(pic.hold & 0x02, 0x02);
    pic.acknoledgeIrq1();
    expect(pic.hold & 0x02, 0);
  });

  for (final interrupt in [Interrupt.irq1, Interrupt.irq2, Interrupt.tirq]) {
    test('pending $interrupt survives masking and is delivered on unmask', () {
      final bus = Bus();
      final cpu = Cpu2(bus);
      final pic = Pic(bus);
      final mask = switch (interrupt) {
        Interrupt.irq1 => 2,
        Interrupt.irq2 => 1,
        _ => 4,
      };
      bool requested() => switch (interrupt) {
            Interrupt.irq1 => cpu.holdIrq1,
            Interrupt.irq2 => cpu.holdIrq2,
            _ => cpu.holdTirq,
          };
      pic.mask = mask;
      switch (interrupt) {
        case Interrupt.irq1:
          pic.holdIrq1();
        case Interrupt.irq2:
          pic.holdIrq2();
        default:
          pic.holdTirq();
      }
      expect(requested(), isFalse);
      expect(pic.hold & mask, mask);
      pic.mask = 0;
      expect(requested(), isTrue);
      pic.mask = mask;
      expect(requested(), isFalse);
      expect(pic.hold & mask, mask);
    });
  }

  test('masking a pending IRQ1 prevents CPU interrupt entry', () {
    final bus = Bus();
    final cpu = Cpu2(bus);
    final pic = Pic(bus);
    pic.holdIrq1();
    pic.mask = 0x02;
    cpu.regs.pc = 0x1234;
    cpu.handleIrq();
    expect(cpu.regs.pc, 0x1234);
  });

  test('timer accounts for every elapsed prescaler period', () {
    Timer makeTimer() {
      final bus = Bus();
      Cpu2(bus);
      Pic(bus);
      return Timer(bus)
        ..size = 10
        ..counter = 10
        ..enabled = true
        ..prescaler = Timer.prescalerSize;
    }

    final batched = makeTimer();
    final stepped = makeTimer();
    const periodClocks = Timer.prescalerSize * 3;
    batched.exec(periodClocks * 3 + 3);
    for (var i = 0; i < 3; i++) {
      stepped.exec(periodClocks);
    }
    stepped.exec(3);
    expect(batched.counter, stepped.counter);
    expect(batched.prescaler, stepped.prescaler);
  });

  test('timer decrements exactly at a full prescaler period', () {
    final timer = Timer(Bus())..size = 2;
    timer.trigger(true);
    timer.exec(Timer.prescalerSize * 3 - 3);
    expect(timer.counter, 2);
    timer.exec(3);
    expect(timer.counter, 1);
  });

  test('writing enabled again does not restart the timer', () {
    final timer = Timer(Bus())..size = 2;
    timer.trigger(true);
    timer.exec(Timer.prescalerSize * 3 + 3);
    final prescaler = timer.prescaler;
    timer.trigger(true);
    expect(timer.counter, 1);
    expect(timer.prescaler, prescaler);
  });

  test('enabling a stopped timer reloads a full period', () {
    final timer = Timer(Bus())..size = 2;
    timer.exec(300);
    timer.trigger(true);
    expect(timer.counter, 2);
    expect(timer.prescaler, Timer.prescalerSize);
  });

  test('large timer update reloads and raises the timer interrupt', () {
    final bus = Bus();
    final cpu = Cpu2(bus);
    final pic = Pic(bus);
    final timer = Timer(bus)..size = 1;
    timer.trigger(true);
    timer.exec(Timer.prescalerSize * 3 * 3);
    expect(timer.counter, 0);
    expect(timer.prescaler, Timer.prescalerSize);
    expect(pic.hold & 4, 4);
    expect(cpu.holdTirq, isTrue);
  });
}
