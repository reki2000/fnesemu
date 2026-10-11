import 'dart:typed_data';

import '../../../util/int.dart';
import '../../types.dart';
import 'gpu.dart';

extension GpuDebugger on Gpu {
  ImageBuffer renderBg() {
    final buf = Uint32List(1024 * 512);
    for (var y = 0; y < 512; y++) {
      for (var x = 0; x < 1024; x++) {
        final index = y * 1024 + x;
        buf[index] = GpuRenderer.c15ToAbgr32[frameBuffer16[index].mask15];
      }
    }
    final bg =
        ImageBuffer(1024, 512, buf.buffer.asUint8List(), displayWidth_: 1024);
    return bg;
  }
}
