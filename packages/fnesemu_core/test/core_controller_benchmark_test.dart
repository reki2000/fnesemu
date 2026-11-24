import 'dart:typed_data';

import 'package:fnesemu_core/app_api.dart';
import 'package:test/test.dart';

// a ROM whose entry point loops on itself
Uint8List _rom() => Uint8List(0x8000)..setAll(0x100, [0, 0xc3, 0, 1]);

void main() {
  test('a benchmark measures frames without audio and stays stopped', () async {
    var audio = 0, images = 0;
    final running = <bool>[];
    final controller = CoreController((CoreControllerState s) {
      running.add(s.running);
    }, (_) => audio++, (_) => images++, Sram());
    await controller.init('gb', rom: _rom());
    final progress = <int>[];
    final timing = await controller.benchmark(
        warmup: 3, measure: 10, onProgress: progress.add);
    expect(timing.frames, 10);
    expect(progress, List.generate(10, (i) => i + 1));
    expect(timing.wallUs, greaterThanOrEqualTo(timing.coreUs));
    expect(timing.fps, greaterThan(0));
    expect(images, greaterThanOrEqualTo(13));
    expect(audio, 0);
    expect(running.last, isFalse);
  });

  test('a benchmark ends at its time limit', () async {
    final controller = CoreController((_) {}, (_) {}, (_) {}, Sram());
    await controller.init('gb', rom: _rom());
    final timing = await controller.benchmark(
        warmup: 0, measure: 1000000, limit: const Duration(milliseconds: 50));
    expect(timing.frames, lessThan(1000000));
    expect(timing.wallUs, greaterThanOrEqualTo(50000));
  });

  test('stateMedia is the media of the saved state', () async {
    final controller = CoreController((_) {}, (_) {}, (_) {}, Sram());
    await controller.init('gb', rom: _rom());
    final header = StateHeader.of(await controller.saveState());
    expect(await controller.stateMedia(), header.media);
  });
}
