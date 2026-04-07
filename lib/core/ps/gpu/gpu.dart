import 'dart:typed_data';

import 'package:fnesemu/util/int.dart';
import 'package:fnesemu/util/uint8list.dart';

import '../../../util/debug.dart';
import '../../types.dart';
import '../bus.dart';
import '../interrupt.dart';
import 'point_color.dart';

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
  int frame = 0;
  bool isOddFrame = false;

  // GP1 status register
  final cmd = List<int>.filled(16, 0);
  int cmdSize = 0;
  bool get cmdReady => cmdSize == 0;
  bool get dmaReceiveReady =>
      cmdReady ||
      cmdSize == 3 && cmd[0] >> 29 == 0x05; // GP0 DMA receive command
  bool vramToCpuReady = false; // GP0 VRAM to CPU command

  bool irq1 = false;

  int textureMaskX = 0;
  int textureMaskY = 0;
  int textureOffsetX = 0;
  int textureOffsetY = 0;
  int textureMaskX2 = 0xff;
  int textureMaskY2 = 0xff;
  int textureOffsetX2 = 0;
  int textureOffsetY2 = 0;

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
    vramToCpuReady = false;

    width = 320;
    height = 240;
    dotClockDivider = 7 * 8;
    buffer = Uint32List(320 * 240);

    textureMaskX = 0;
    textureMaskY = 0;
    textureOffsetX = 0;
    textureOffsetY = 0;
    textureMaskX2 = 0xff;
    textureMaskY2 = 0xff;
    textureOffsetX2 = 0;
    textureOffsetY2 = 0;

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
    frame = 0;
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
    // debugLog("GPREAD: ${readValue.hex32} ${dumpCmd()}");
    final result = readValue;
    postRead();

    return result;
  }

  int readStat() {
    final b25 = switch (status >> 29 & 0x03) {
      0 => false,
      1 => cmdSize > 0, // fifo not empty
      2 => true, // dma is always available
      _ => true, // vram to cpu transfer is always available
    };

    final result = status
        .setBit(13, isOddFrame)
        .setBit(24, irq1)
        .setBit(25, b25)
        .setBit(26, cmdReady)
        .setBit(27, vramToCpuReady)
        .setBit(28, dmaReceiveReady);
    // debugLog("GPSTAT: ${result.hex32}  ${dumpCmd()}");
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
  late final frameBuffer16 = frameBuffer.buffer.asUint16List();

  int readValue = 0;

  writeFrameBuffer16(int x, int y, int u16) {
    final offset = y * 1024 + x;
    // if ((offset >= 32 * 1024 && offset < 33 * 1024)) {
    //   debugLog(
    //       "writeFrameBuffer16: ${u16.hex16} at ($x, $y) offset:${offset.hex32} ${dumpCmd()}");
    // }
    frameBuffer16[offset] = u16;
  }

  int readFrameBuffer16(int x, int y) {
    final offset = y * 1024 + x;
    // if ((offset >= 32 * 1024 && offset < 33 * 1024)) {
    //   final result = frameBuffer.getUInt16LE(offset);
    //   debugLog(
    //       "readFrameBuffer16: value ${result.hex16} at ($x, $y) offset:${offset.hex32} ${dumpCmd()}");
    // }
    return frameBuffer16[offset];
  }

  int getTextureColor(int u, int v, int clut, int page, {bool debug = false}) {
    final uu = u & textureMaskX2 | textureOffsetX2;
    final vv = v & textureMaskY2 | textureOffsetY2;

    final baseX = page << 6 & 0x3c0;
    final baseY = page << 4 & 0x100;
    final base = (baseY + vv.mask8) * 1024;

    final clutMode = page >> 7 & 3;
    if (clutMode == 2) {
      final result = frameBuffer16[base + ((baseX + uu.mask8) & 0x3ff)];
      if (debug) {
        debugLog(
            "getTexureColor($u, $v, ${clut.hex32}, ${page.hex32}) mode:$clutMode "
            "baseX:$baseX baseY:$baseY base:${base.hex32} c:${result.hex16}");
      }
      return result;
    }

    final clutBase = (clut >> 6 & yMask) * 1024 + ((clut & 0x3f) << 4);
    try {
      final clutIndex = (clutMode == 1)
          ? frameBuffer[(base + baseX) * 2 + uu.mask8]
          : (u.bit0)
              ? frameBuffer[(base + baseX) * 2 + uu.mask8 ~/ 2] >> 4
              : frameBuffer[(base + baseX) * 2 + uu.mask8 ~/ 2] & 0x0f;

      final result = frameBuffer16[clutBase + clutIndex];

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

  pset24(int x, int y, int c24,
      {bool ignoreWindow = false,
      bool transparent = false,
      bool dither = false}) {
    var c = Color.ofC24(c24);

    if (status.bit9 && dither) {
      // dithering
      const dither = [
        [0, 8, 2, 10],
        [12, 4, 14, 6],
        [3, 11, 1, 9],
        [15, 7, 13, 5]
      ];
      final d = dither[y & 3][x & 3];
      c = Color(c.r + d, c.g + d, c.b + d);
    }

    pset16(x, y, c.c15 | (transparent ? 0x8000 : 0),
        ignoreWindow: ignoreWindow);
  }

  pset16(int x, int y, int c16, {bool ignoreWindow = false}) {
    if (!ignoreWindow) {
      x += drawingOffsetX;
      y += drawingOffsetY;
      if ((x < drawingX1 || x > drawingX2 || y < drawingY1 || y > drawingY2)) {
        return;
      }
    } else {
      if (x < 0 || x >= 1024 || y < 0 || y >= 512) {
        return;
      }
    }

    final old = frameBuffer16[y * 1024 + x];

    // write protected
    if (status.bit12 && old.bit15) {
      // if (x == 11 && y == 136) {
      //   debugLog(
      //       "gpu: write protected old:${old.hex16} status:${status.hex16} ");
      // }
      return;
    }

    // semi-transparency
    if (c16.bit15) {
      final (r0, g0, b0) = (old & 0x1f, old >> 5 & 0x1f, old >> 10 & 0x1f);
      final (r1, g1, b1) = (c16 & 0x1f, c16 >> 5 & 0x1f, c16 >> 10 & 0x1f);
      // if (x == 11 && y == 136) {
      //   debugLog("gpu: semi transparency old:${old.hex16} new:${c16.hex16} "
      //       "r0:$r0 g0:$g0 b0:$b0 r1:$r1 g1:$g1 b1:$b1 "
      //       "mode:${status >> 5 & 0x03}");
      // }
      c16 = switch (status >> 5 & 0x03) {
        0 => ((b0 + b1) >> 1) << 10 |
            ((g0 + g1) >> 1) << 5 |
            ((r0 + r1) >> 1), // B/2+F/2
        1 => (b0 + b1).min(31) << 10 |
            (g0 + g1).min(31) << 5 |
            (r0 + r1).min(31), // B+F
        2 => (b0 - b1).max(0) << 10 |
            (g0 - g1).max(0) << 5 |
            (r0 - r1).max(0), // B-F
        _ => (b0 + (b1 >> 2)).min(31) << 10 |
            (g0 + (g1 >> 2)).min(31) << 5 |
            (r0 + (r1 >> 2)).min(31) // B+F/4
      };
    }

    final forceBit15 = status.bit11 ? 0x8000 : 0;

    writeFrameBuffer16(x, y, c16 | forceBit15);
  }

  String dump() =>
      "GPU: stat:${status.hex32} ${width}x$height (${startDisplayX.decimal3},${startDisplayY.decimal3}) "
      "(${drawingX1.decimal3},${drawingY1.decimal3})-(${drawingX2.decimal3},${drawingY2.decimal3}) "
      "offset:(${drawingOffsetX.decimal4},${drawingOffsetY.decimal3}) frame:$frame ${scanline.decimal3}";

  String dumpCmd() =>
      "cmd: ${cmd.sublist(0, cmdSize).map((d) => d.hex32).join(" ")}";
}
