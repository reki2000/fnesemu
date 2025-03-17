import 'bus.dart';
import 'gpu.dart';

main() {
  final bus = Bus();
  final gpu = Gpu(bus);

  // gpu.writeGp0(00000000);
  // gpu.writeGp0(0x01000000);

  // cpu to vram
  // gpu.writeGp0(0xa0000000);
  // gpu.writeGp0(0x01ff0000);
  // gpu.writeGp0(0x00010002);
  // gpu.writeGp0(0xffffffff);

  // rectangle
  for (var e in [0x68000000, 0]) {
    gpu.writeGp0(e);
  }
}
