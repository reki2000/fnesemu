import 'dart:io';
import 'dart:typed_data';

import 'package:fnesemu_core/src/core/ps/memory_card.dart';
import 'package:fnesemu_core/src/core/ps/ps.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

import '../../tool/ps_io.dart';

int readCardByte(MemoryCard card, int sector) {
  card.reset();
  for (final byte in [
    0x81,
    0x52,
    0,
    0,
    sector >> 8,
    sector & 255,
    0,
    0,
    0,
    0
  ]) {
    card.notify(byte);
  }
  return card.notify(0).rxData;
}

void main() {
  test('PS accepts memory card contents without doing file I/O', () {
    final bytes = Uint8List.fromList(MemoryCard.blankImage)..[128] = 0x76;
    final core = Ps(memoryCard2Image: bytes);
    expect(readCardByte(core.memoryCard2, 1), 0x76);
    bytes[128] = 0x89;
    expect(readCardByte(core.memoryCard2, 1), 0x89);
  });

  test('CLI loads the specified card into slot two', () async {
    final directory = await Directory.systemTemp.createTemp('fnesemu-ps-io');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/card.bin');
    final bytes = Uint8List.fromList(MemoryCard.blankImage)..[128] = 0x54;
    await file.writeAsBytes(bytes);
    final core = createPsForTools(memoryCardPath: file.path);
    expect(readCardByte(core.memoryCard2, 1), 0x54);
  });

  test(
      'GPU snapshot keeps dimensions, BGR conversion, metadata and file naming',
      () async {
    final directory = await Directory.systemTemp.createTemp('fnesemu-ps-png');
    addTearDown(() => directory.delete(recursive: true));
    final core = Ps();
    core.gpu.frameBuffer16[0] = 0x001f;
    core.gpu.frameBuffer16[1] = 0x7c00;
    core.gpu.debugCmdLog = 'fixture command';
    core.gpu.debugCmdIndexInFrame = 12;
    await savePsGpuFrame(core.gpu, directory.path);
    final file = File(
        '${directory.path}/${core.gpu.frame.toString().padLeft(5, '0')}/00012.png');
    final decoded = img.decodePng(await file.readAsBytes())!;
    expect(decoded.width, 640);
    expect(decoded.height, 224);
    expect(decoded.getPixel(0, 0).r, 255);
    expect(decoded.getPixel(0, 0).b, 0);
    expect(decoded.getPixel(1, 0).b, 255);
    expect(decoded.textData!['description'], 'fixture command');
    expect(core.gpu.debugCmdIndexInFrame, 13);
  });
}
