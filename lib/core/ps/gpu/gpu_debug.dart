import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../../types.dart';
import 'gpu.dart';

extension GpuDebugger on Gpu {
  ImageBuffer renderBg() {
    final buf = Uint32List(1024 * 512);
    for (var y = 0; y < 512; y++) {
      for (var x = 0; x < 1024; x++) {
        final index = y * 1024 + x;
        buf[index] = GpuRenderer.c15ToAbgr32[frameBuffer16[index] & 0x7fff];
      }
    }
    final bg =
        ImageBuffer(1024, 512, buf.buffer.asUint8List(), displayWidth_: 1024);
    return bg;
  }

  saveFrame() {
    const List<int> saveFrames = [];
    if (saveFrames.contains(frame)) {
      _saveFrameBufferPng(
          frameBuffer16, frame, debugCmdIndexInFrame, debugCmdLog);
    }
    debugCmdIndexInFrame++;
  }
}

Future<Uint8List?> _createFrameBufferPng(
    Uint16List frameBuffer16, String? description) async {
  // package:image/image.dart を使って PNG を生成
  // 依存: import 'package:image/image.dart' as img;

  final width = 640;
  final height = 224;
  final image = img.Image(width: width, height: height);

  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final c16 = frameBuffer16[y * 1024 + x];
      // 15bit BGR (PS1) → 8bit/channel RGBA
      final r = (c16 & 0x1f) << 3 | ((c16 >> 2) & 0x07);
      final g = ((c16 >> 5) & 0x1f) << 3 | ((c16 >> 7) & 0x07);
      final b = ((c16 >> 10) & 0x1f) << 3 | ((c16 >> 12) & 0x07);
      final a = 0xff;
      image.setPixelRgba(x, y, r, g, b, a);
    }
  }
  image.addTextData({"description": description ?? ""});

  // PNGエンコード
  final pngBytes = img.encodePng(image);
  return Uint8List.fromList(pngBytes);
}

Future<void> _saveFrameBufferPng(
    Uint16List frameBuffer16, int frame, int index, String? description) async {
  final pngBytes = await _createFrameBufferPng(frameBuffer16, description);
  if (pngBytes != null) {
    final dir = Directory("trace/vram/${frame.toString().padLeft(5, '0')}");
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    final filePath = "${dir.path}/${index.toString().padLeft(5, '0')}.png";
    await File(filePath).writeAsBytes(pngBytes);
  }
}
