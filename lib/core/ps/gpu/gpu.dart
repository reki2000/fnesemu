import 'dart:typed_data';

import 'package:fnesemu/util/int.dart';
import 'package:fnesemu/util/uint8list.dart';

import '../../../util/debug.dart';
import '../../types.dart';
import '../bus.dart';
import '../interrupt.dart';
import '../point_color.dart';

part 'gpu0.dart';
part 'gpu0_renderer.dart';
part 'gpu1.dart';
part 'renderer.dart';

class Gpu {
  final Bus bus;

  Gpu(this.bus) {
    reset();
  }

  static const xMask = 0x3ff;
  static const yMask = 0x1ff;

  int status = 0;
  int gp0 = 0;
  int gp1 = 0;

  // rendering status
  int width = 320; //  256, 320, 368, 512, 640
  int dotClockDivider =
      7 * 8; // 7* 10:256pix 8:320pix 7:368pix 5:512pix 4:640pix
  int height = 240; // 240p or 480i
  Uint32List buffer = Uint32List(320 * 240);

  ImageBuffer get imageBuffer =>
      ImageBuffer(width, height, buffer.buffer.asUint8List(),
          displayWidth_: 320);

  static const scanlinesInFrame = 262; // ntsc

  int scanline = 0;
  bool isOddFrame = false;

  // GP1 status register
  final cmd = List<int>.filled(16, 0);
  int cmdSize = 0;
  bool get cmdReady => cmdSize == 0;

  bool irq1 = false;

  int textureMaskX = 0;
  int textureMaskY = 0;
  int textureOffsetX = 0;
  int textureOffsetY = 0;

  int drawingX1 = 0;
  int drawingY1 = 0;
  int drawingX2 = 0;
  int drawingY2 = 0;

  int drawingOffsetX = 0;
  int drawingOffsetY = 0;

  int bltSizeX = 0;
  int bltSizeY = 0;
  int bltPosX = 0;
  int bltPosY = 0;
  int bltFromX = 0;
  int bltFromY = 0;

  void reset() {
    status = 0.setBit(23, true);
    gp0 = 0;
    gp1 = 0;
    cmd.fillRange(0, cmd.length, 0);
    cmdSize = 0;
    irq1 = false;

    width = 320;
    height = 240;
    dotClockDivider = 7 * 8;
    buffer = Uint32List(320 * 240);

    textureMaskX = 0;
    textureMaskY = 0;
    textureOffsetX = 0;
    textureOffsetY = 0;

    drawingX1 = 0;
    drawingY1 = 0;
    drawingX2 = 0;
    drawingY2 = 0;

    drawingOffsetX = 0;
    drawingOffsetY = 0;

    bltSizeX = 0;
    bltSizeY = 0;
    bltPosX = 0;
    bltPosY = 0;
    bltFromX = 0;
    bltFromY = 0;

    scanline = 0;
    isOddFrame = false;

    cmd.fillRange(0, cmd.length, 0);
    cmdSize = 0;
    readValue = 0;

    irq1 = false;

    startDisplayX = 0;
    startDisplayY = 0;
    displayMode = 0;
    frameBuffer.fillRange(0, frameBuffer.length, 0);
  }

  int readReg() {
    // debugLog("GPREAD: ${readValue.hex32}");
    final result = readValue;
    postRead();

    return result;
  }

  int readStat() {
    const alwaysOn = 0x18000000; // dma is available
    final result =
        status.setBit(26, cmdReady).setBit(13, isOddFrame).setBit(24, irq1) |
            alwaysOn;
    // debugLog("GPSTAT: ${result.hex32}");
    return result;
  }

  // GP1 status register
  int startDisplayX = 0;
  int startDisplayY = 0;

  int displayMode = 0;
  bool get isH480 => displayMode.bit2;
  bool get isPal => displayMode.bit3;
  bool get isRgb24 => displayMode.bit4;
  bool get isInterlaced => displayMode.bit5;

  final frameBuffer = Uint8List(512 * 2048);

  int readValue = 0;

  writeFrameBuffer32(int x, int y, int u32) {
    final offset = y * 2048 + x * 2;
    frameBuffer.setUInt32LE(offset, u32);
  }

  int readFrameBuffer32(int x, int y) {
    final offset = y * 2048 + x * 2;
    return frameBuffer.getUInt32LE(offset);
  }

  int getTextureColor(int u, int v, int clut, int page, {bool debug = false}) {
    final baseX = page << 6 & 0x3c0;
    final baseY = page << 4 & 0x100;
    final base = baseX * 2 + (baseY + v.mask8) * 2048;

    final clutMode = page >> 7 & 3;
    if (clutMode == 2) {
      return frameBuffer.getUInt16LE(base + u.mask8 * 2);
    }

    final clutBase = (clut >> 6 & yMask) * 2048 + (clut << 5 & 0x3e0);
    try {
      final clutIndex = (clutMode == 1)
          ? frameBuffer[base + u.mask8]
          : (u.bit0)
              ? frameBuffer[base + u.mask8 ~/ 2] >> 4
              : frameBuffer[base + u.mask8 ~/ 2] & 0x0f;

      final result = frameBuffer.getUInt16LE(clutBase + clutIndex * 2);

      if (debug) {
        debugLog(
            "getTexureColor($u, $v, ${clut.hex32}, ${page.hex32}) mode:$clutMode "
            "baseX:$baseX baseY:$baseY base:${base.hex32} "
            "clutX:${clut << 5 & 0x3e0} clutY:${clut >> 6 & yMask} clutBase:${clutBase.hex32} "
            "index:$clutIndex result:${result.hex24}");
      }

      return result;
    } catch (e) {
      debugLog(
          "getTexureColor($u, $v, ${clut.hex32}, ${page.hex32}) $baseX $baseY ${clutBase.hex32} ${base.hex32} $e");
      rethrow;
    }
  }

  pset24(int x, int y, int c24, {bool ignoreWindow = false}) {
    if (status.bit9) {
      // dithering
      const dither = [
        [0, 8, 2, 10],
        [12, 4, 14, 6],
        [3, 11, 1, 9],
        [15, 7, 13, 5]
      ];
      final d = dither[y & 3][x & 3];
      final c = Color.ofC24(c24);
      final c2 = Color(c.r + d, c.g + d, c.b + d);
      pset16(x, y, c2.c15, ignoreWindow: ignoreWindow);
      return;
    }
    pset16(x, y, Color.ofC24(c24).c15, ignoreWindow: ignoreWindow);
  }

  pset16(int x, int y, int c16, {bool ignoreWindow = false}) {
    x += drawingOffsetX;
    y += drawingOffsetY;

    if (!ignoreWindow &&
        (x < drawingX1 || x >= drawingX2 || y < drawingY1 || y >= drawingY2)) {
      return;
    }
    final old = frameBuffer.getUInt16LE(y * 2048 + x * 2);

    if (status.bit12 && old.bit15) {
      return;
    }

    frameBuffer.setUInt16LE(
        y * 2048 + x * 2, c16 | (status.bit13 ? (1 << 15) : 0));
  }

  String dump() =>
      "GPU: ${status.hex32} ${width}x$height $startDisplayX,$startDisplayY";
}
