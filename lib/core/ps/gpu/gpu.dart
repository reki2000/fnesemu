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
  bool isVblank = false;

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

  int debugCmdIndexInFrame = 0;
  String debugCmdLog = "";

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
    displayX1 = 0;
    displayY1 = 0;
    displayX2 = 0;
    displayY2 = 0;

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
        .setBit(13, true)
        .setBit(24, irq1)
        .setBit(25, b25)
        .setBit(26, cmdReady)
        .setBit(27, vramToCpuReady)
        .setBit(28, dmaReceiveReady)
        .setBit(31, isOddFrame & !isVblank);
    // debugLog("GPSTAT: ${result.hex32}  ${dumpCmd()}");
    return result;
  }

  // GP1 status register
  int startDisplayX = 0;
  int startDisplayY = 0;
  int displayX1 = 0;
  int displayY1 = 0;
  int displayX2 = 0;
  int displayY2 = 0;

  int displayMode = 0;
  bool get isH480 => displayMode.bit2;
  bool get isPal => displayMode.bit3;
  bool get isRgb24 => displayMode.bit4;
  bool get isInterlaced => displayMode.bit5;

  final frameBuffer = Uint8List(512 * 2048);
  late final frameBuffer16 = frameBuffer.buffer.asUint16List();

  int readValue = 0;

  @pragma('vm:prefer-inline')
  writeFrameBuffer16(int x, int y, int u16) {
    final offset = y * 1024 + x;
    // if ((offset >= 32 * 1024 && offset < 33 * 1024)) {
    //   debugLog(
    //       "writeFrameBuffer16: ${u16.hex16} at ($x, $y) offset:${offset.hex32} ${dumpCmd()}");
    // }
    frameBuffer16[offset] = u16;
  }

  @pragma('vm:prefer-inline')
  int readFrameBuffer16(int x, int y) {
    final offset = y * 1024 + x;
    // if ((offset >= 32 * 1024 && offset < 33 * 1024)) {
    //   final result = frameBuffer.getUInt16LE(offset);
    //   debugLog(
    //       "readFrameBuffer16: value ${result.hex16} at ($x, $y) offset:${offset.hex32} ${dumpCmd()}");
    // }
    return frameBuffer16[offset];
  }

  @pragma('vm:prefer-inline')
  @pragma('vm:no-bounds-check')
  int getTextureColor2(
      int u, int v, int baseX, int baseY, int clutBase, int clutMode,
      {bool debug = false}) {
    final uu = u & textureMaskX2 | textureOffsetX2;
    final vv = v & textureMaskY2 | textureOffsetY2;

    final base = (baseY + vv) << 10;

    final int addr;
    switch (clutMode) {
      case 0:
        final clutByteIndex = base + baseX + uu.shr2;
        final clutByte = frameBuffer16[clutByteIndex & 0x7ffff];
        final clutIndex = clutByte >> (uu & 3).shl2;
        addr = clutBase + (clutIndex & 0x0f);

      case 1:
        final clutIndex = frameBuffer[(base + baseX).shl1 + uu];
        addr = clutBase + clutIndex;

      default:
        addr = base + (baseX + uu).mask10;
    }
    final result = frameBuffer16[addr & 0x7ffff];

    if (debug) {
      debugLog(
          "getTexureColor($u+$textureOffsetX2/${textureMaskX2.hex8}, $v+$textureOffsetY2/${textureMaskY2.hex8}, "
          "$baseX, $baseY, ${clutBase.hex24}, $clutMode) -> ${result.hex16}");
    }

    return result;
  }

  static const _ditherV = [
    //
    0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5
  ];
  static final _ditherV10 = _ditherV.map((i) => i << 10).toList();

  @pragma('vm:prefer-inline')
  @pragma('vm:no-bounds-check')
  int ditherAndModulate(int x, int y, int c16, Color m24) {
    int d = 0;
    if (status.bit9) {
      final xy = x & 3 | (y & 3).shl2;
      d = _ditherV10[xy & 15];
    }

    final r5 = c16 & 0x1f;
    final g5 = c16 >> 5 & 0x1f;
    final b5 = c16 >> 10 & 0x1f;
    final r = (((r5 << 5) + r5) * m24.r + d) >> 12;
    final g = (((g5 << 5) + g5) * m24.g + d) >> 12;
    final b = (((b5 << 5) + b5) * m24.b + d) >> 12;
    final r2 = r > 31 ? 31 : r;
    final g2 = g > 31 ? 31 : g;
    final b2 = b > 31 ? 31 : b;

    return b2.shl10 | g2.shl5 | r2 | c16 & 0x8000;
  }

  @pragma('vm:prefer-inline')
  @pragma('vm:no-bounds-check')
  int dither(int x, int y, Color c) {
    int c15 = 0;
    if (status.bit9) {
      // dithering
      final xy = x & 3 | (y & 3).shl2;
      final d = _ditherV[xy & 15];
      c15 = (c.r + d).shr3.min(31) |
          (c.g + d).shr3.min(31).shl5 |
          (c.b + d).shr3.min(31).shl10;
    } else {
      c15 = c.c15;
    }

    return c15;
  }

  @pragma('vm:prefer-inline')
  @pragma('vm:no-bounds-check')
  pset16(int x, int y, int c16,
      {bool ignoreWindow = false, int? semiTransparent}) {
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
      final r0 = old & 0x1f;
      final g0 = old >> 5 & 0x1f;
      final b0 = old >> 10 & 0x1f;
      final r1 = c16 & 0x1f;
      final g1 = c16 >> 5 & 0x1f;
      final b1 = c16 >> 10 & 0x1f;
      // if (x == 11 && y == 136) {
      //   debugLog("gpu: semi transparency old:${old.hex16} new:${c16.hex16} "
      //       "r0:$r0 g0:$g0 b0:$b0 r1:$r1 g1:$g1 b1:$b1 "
      //       "mode:${status >> 5 & 0x03}");
      // }
      c16 = 0x8000 |
          switch (semiTransparent ?? status >> 5 & 0x03) {
            0 => ((b0 + b1) >> 1) << 10 |
                ((g0 + g1) >> 1) << 5 |
                ((r0 + r1) >> 1), // B/2+F/2
            1 => 31.min(b0 + b1) << 10 |
                31.min(g0 + g1) << 5 |
                31.min(r0 + r1), // B+F
            2 => 0.max(b0 - b1) << 10 |
                0.max(g0 - g1) << 5 |
                0.max(r0 - r1), // B-F
            _ => 31.min(b0 + (b1 >> 2)) << 10 |
                31.min(g0 + (g1 >> 2)) << 5 |
                31.min(r0 + (r1 >> 2)), // B+F/4
          };
    }

    final forceBit15 = status.bit11 ? 0x8000 : 0;

    writeFrameBuffer16(x, y, c16 | forceBit15);
  }

  String dump() => "GPU: stat:${status.hex32} "
      "${width}x$height "
      "(${displayX1.decimal3},${displayY1.decimal3}) ${(displayX2 - displayX1).decimal4}x${(displayY2 - displayY1).decimal3} "
      "(${startDisplayX.decimal3},${startDisplayY.decimal3}) "
      "(${drawingX1.decimal3},${drawingY1.decimal3})-(${drawingX2.decimal3},${drawingY2.decimal3}) "
      "offset:(${drawingOffsetX.decimal4},${drawingOffsetY.decimal3}) frame:$frame ${scanline.decimal3}";

  String dumpCmd() =>
      "cmd[${cmd.sublist(0, cmdSize).map((d) => d.hex32).join(" ")}]";
}
