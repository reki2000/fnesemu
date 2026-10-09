import 'dart:io';
import 'dart:typed_data';

import 'package:fnesemu_core/core/ps/gpu/gpu.dart';
import 'package:fnesemu_core/core/ps/ps.dart';
import 'package:fnesemu_core/util/int.dart';
import 'package:image/image.dart' as img;

/// CLI configuration and file access stay outside the PS core.
Ps createPsForTools(
        {String memoryCardPath = const String.fromEnvironment('MEMCARD')}) =>
    Ps(
        memoryCard2Image: memoryCardPath.isEmpty
            ? null
            : File(memoryCardPath).readAsBytesSync());

Uint8List createPsFramePng(Uint16List frameBuffer16, String? description) {
  final width = 640;
  final height = 224;
  final image = img.Image(width: width, height: height);

  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final c16 = frameBuffer16[y * 1024 + x];
      // 15bit BGR (PS1) → 8bit/channel RGBA
      final r = (c16 & 0x1f).shl3 | (c16.shr2 & 0x07);
      final g = (c16.shr5 & 0x1f).shl3 | (c16.shr7 & 0x07);
      final b = (c16.shr10 & 0x1f).shl3 | (c16.shr12 & 0x07);
      final a = 0xff;
      image.setPixelRgba(x, y, r, g, b, a);
    }
  }
  image.addTextData({"description": description ?? ""});

  // PNGエンコード
  final pngBytes = img.encodePng(image);
  return Uint8List.fromList(pngBytes);
}

/// Saves a GPU command snapshot under directory/frame/command.png.
Future<void> savePsGpuFrame(Gpu gpu, String directory) async {
  final frame = gpu.frame;
  final index = gpu.debugCmdIndexInFrame++;
  final png = createPsFramePng(gpu.frameBuffer16, gpu.debugCmdLog);
  final dir = Directory('$directory/${frame.toString().padLeft(5, '0')}');
  await dir.create(recursive: true);
  await File('${dir.path}/${index.toString().padLeft(5, '0')}.png')
      .writeAsBytes(png);
}
