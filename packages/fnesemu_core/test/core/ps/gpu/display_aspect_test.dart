import 'package:fnesemu_core/src/core/ps/bus.dart';
import 'package:fnesemu_core/src/core/ps/gpu/gpu.dart';
import 'package:test/test.dart';

void main() {
  for (final mode in [0, 1, 2, 3, 0x40]) {
    for (final interlaced in [false, true]) {
      test('display mode $mode keeps 4:3 aspect (480i: $interlaced)', () {
        final gpu = Gpu(Bus());
        gpu.writeGp1(0x08000000 | mode | (interlaced ? 0x24 : 0));
        final image = gpu.imageBuffer;
        expect(image.width, mode == 0x40 ? 368 : [256, 320, 512, 640][mode]);
        expect(image.height, interlaced ? 480 : 240);
        expect(image.buffer.length, image.width * image.height * 4);
        expect(image.displayWidth / (image.displayHeight ?? image.height),
            closeTo(4 / 3, 1e-10));
      });
    }
  }

  test('switching between progressive and interlaced preserves display size',
      () {
    final gpu = Gpu(Bus());
    for (final mode in [0x03, 0x27, 0x01, 0x25, 0x40, 0x64]) {
      gpu.writeGp1(0x08000000 | mode);
      final image = gpu.imageBuffer;
      expect(image.displayWidth, 320);
      expect(image.displayHeight, 240);
      expect(image.height, mode & 0x24 == 0x24 ? 480 : 240);
      expect(image.buffer.length, image.width * image.height * 4);
    }
  });
}
