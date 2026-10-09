import 'package:fnesemu/core/pce/component/bus.dart';
import 'package:fnesemu/core/pce/component/cpu.dart';
import 'package:fnesemu/core/pce/component/pic.dart';
import 'package:fnesemu/core/pce/component/timer.dart';
import 'package:test/test.dart';

void main() {
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
