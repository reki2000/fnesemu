import 'dart:typed_data';

import 'package:fnesemu/util/uint8list.dart';

import '../types.dart';
import 'gpu.dart';

extension GpuDebugger on Gpu {
  ImageBuffer renderBg() {
    final buf = Uint32List(1024 * 512);
    for (var y = 0; y < 512; y++) {
      for (var x = 0; x < 1024; x++) {
        buf[y * 1024 + x] = GpuRenderer
            .c15ToAbgr32[frameBuffer.getUInt16LE(y * 2048 + x * 2) & 0x7fff];
      }
    }
    final bg =
        ImageBuffer(1024, 512, buf.buffer.asUint8List(), displayWidth_: 1024);
    return bg;
  }
}
