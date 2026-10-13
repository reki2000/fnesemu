import 'dart:typed_data';

import '../../../types.dart';
import '../../../util/int.dart';
import '../../../video_debug.dart';
import 'gpu.dart';

extension GpuDebugger on Gpu {
  List<DebugVideoLayer> get debugVideoLayers => [
        DebugVideoLayer(
            'Framebuffer / VRAM', (map) => map ? _debugMap() : _debugScreen(),
            kind: DebugLayerKind.framebuffer, hasMap: true),
      ];
  DebugRaster _debugMap() {
    final canvas = DebugCanvas(1024, 512);
    for (var i = 0; i < canvas.pixels.length; i++) {
      canvas.pixels[i] = GpuRenderer.c15ToAbgr32[frameBuffer16[i].mask15];
    }
    canvas.viewport(
        startDisplayX,
        startDisplayY,
        isRgb24 ? width * 3 ~/ 2 : width,
        (displayY2 - displayY1).clamp(0, 512) * (height == 480 ? 2 : 1));
    return canvas.raster();
  }

  DebugRaster _debugScreen() {
    final canvas = DebugCanvas(width, height);
    final top = isPal ? 0 : displayY1 - 16;
    for (var y = 0; y < height; y++) {
      final scanline = height == 480 ? y ~/ 2 : y, relative = scanline - top;
      if (status.bit23 || relative < 0 || relative >= displayY2 - displayY1) {
        continue;
      }
      final sourceY = (startDisplayY +
              relative * (height == 480 ? 2 : 1) +
              (height == 480 ? y % 2 : 0)) &
          511;
      for (var x = 0; x < width; x++) {
        if (isRgb24) {
          final address = startDisplayX * 2 + x * 3;
          canvas.pixels[y * width + x] = 0xff000000 |
              frameBuffer[sourceY * 2048 + (address & 2047)] |
              frameBuffer[sourceY * 2048 + ((address + 1) & 2047)] << 8 |
              frameBuffer[sourceY * 2048 + ((address + 2) & 2047)] << 16;
        } else {
          canvas.pixels[y * width + x] = GpuRenderer.c15ToAbgr32[
              frameBuffer16[sourceY * 1024 + ((startDisplayX + x) & 1023)]
                  .mask15];
        }
      }
    }
    return canvas.raster();
  }

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
