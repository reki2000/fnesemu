import 'package:fnesemu_core/src/core/pce/component/bus.dart';
import 'package:fnesemu_core/src/core/pce/component/cpu.dart';
import 'package:fnesemu_core/src/core/pce/component/pic.dart';
import 'package:fnesemu_core/src/core/pce/component/timer.dart';
import 'package:test/test.dart';

void main() {

  test('timer decrements exactly at a full prescaler period', () {
    final timer = Timer(Bus())..size = 2;
    timer.trigger(true);
    timer.exec(Timer.prescalerSize * 3 - 3);
    expect(timer.counter, 2);
    timer.exec(3);
    expect(timer.counter, 1);
  });

}
