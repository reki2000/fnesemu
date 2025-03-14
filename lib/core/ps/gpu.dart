import 'dart:typed_data';

import 'package:fnesemu/util/int.dart';
import 'package:fnesemu/util/uint8list.dart';

import '../../util/debug.dart';
import '../types.dart';
import 'bus.dart';

part 'gpu_renderer.dart';

class Gpu {
  int status = 0;
  int gp0 = 0;
  int gp1 = 0;
  final Bus bus;

  int width = 320; //  256, 320, 368, 512, 640
  int height = 240; // 240p or 480i
  Uint32List buffer = Uint32List(320 * 240);

  ImageBuffer get imageBuffer =>
      ImageBuffer(width, height, buffer.buffer.asUint8List(),
          displayWidth_: 320);

  static const scanlinesInFrame = 240;
  int scanline = 0;

  bool cmdReady = true;

  Gpu(this.bus);

  int readReg() {
    debugLog("GPREAD: ${readValue.hex32}");
    return readValue;
  }

  int readStat() {
    const alwaysOn = 0x18000000; // dma is available
    final result = status.setBit(26, cmdReady) | alwaysOn;
    debugLog("GPSTAT: ${result.hex32}");
    return result;
  }

  void writeGp0(int value) {
    debugLog("GP0 command: ${value.hex32}");
    gp0 = value;

    final cmd = gp0 >> 24;
    switch (cmd) {
      case 0x01: // clear cache
        break;

      case 0x02: // fill rectangle
        break;

      case 0x20: // copy rectangle
        break;

      case 0x28: // copy rectangle to display area
        break;

      case 0x30: // draw mode setting
        break;

      case 0x40: // texture window setting
        break;

      case 0x60: // set drawing area top left
        break;

      case 0x61: // set drawing area bottom right
        break;

      case 0x62: // set drawing offset
        break;

      case 0x64: // set mask bit setting
        break;

      case 0xa0: // draw polygon
        break;

      case 0xc0: // draw sprite
        break;

      case 0xe1: // draw mode setting
        status = status.setMasked(0x7ff, value).setBit(15, value.bit11);

      default:
        debugLog("unknown GP0 command: ${value.hex32}");
    }
  }

  int startDisplayX = 0;
  int startDisplayY = 0;

  int displayMode = 0;
  bool get isH480 => displayMode.bit2;
  bool get isPal => displayMode.bit3;
  bool get isRgb24 => displayMode.bit4;
  bool get isInterlaced => displayMode.bit5;

  final frameBuffer = Uint8List(512 * 2048);

  int readValue = 0;

  void writeGp1(int value) {
    debugLog("GP1 command: ${value.hex32}");
    gp1 = value;

    final cmd = gp0 >> 24;
    switch (cmd & 0x3f) {
      case 0x00: // reset
        status = 0;
        readValue = 0;

      case 0x05: // set drawing area top left
        startDisplayX = gp0 & 0x3ff;
        startDisplayY = gp0 >> 10 & 0x3ff;

      case 0x08: // display mode
        displayMode = gp0 & 0x7f;
        status = status & ~0x7f40 |
            value << 9 & 0x7e00 |
            value << 10 & 0x0100 |
            value << 7 & 0x0040;
        width = [256, 320, 512, 640][displayMode & 0x03];

      case >= 0x10 && < 0x20: // read gpu internal register
        switch (value & 0x07) {
          case 0x02: //  Read Texture Window setting
            readValue = 0;
          case 0x03: // Read Draw area top left
            readValue = 0;
          case 0x04: // Read Draw area bottom right
            readValue = 0;
          case 0x05: //  Read Draw offset
            readValue = 0;
        }

      default:
        debugLog("unknown GP1 command: ${value.hex32}");
    }
  }

  String dump() => "GPU: ${status.hex32} $startDisplayX,$startDisplayY";
}
