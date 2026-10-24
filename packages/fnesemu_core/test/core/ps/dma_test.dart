import 'package:fnesemu_core/src/core/ps/ps.dart';
import 'package:fnesemu_core/src/sram.dart';
import 'package:test/test.dart';

void main() {
  test('register writes wake an idle DMA controller once per pending tick', () {
    final core = Ps()..setSram(Sram());
    addTearDown(core.dispose);
    core.reset();
    final dma = core.dma;
    var wakes = 0;
    dma.onActivate = () => wakes++;
    dma.exec(24);
    expect(dma.active, isFalse);
    dma.setChannelCtrl(6, 0);
    expect(dma.active, isTrue);
    expect(wakes, 1);
    dma.control = 0;
    expect(wakes, 1);
    dma.exec(24);
    expect(dma.active, isFalse);
    dma.control = 0;
    expect(dma.active, isTrue);
    expect(wakes, 2);
  });
}
