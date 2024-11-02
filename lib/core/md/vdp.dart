import 'dart:typed_data';

import 'package:fnesemu/util/int.dart';

import '../types.dart';

class Vdp {
  Vdp();

  int read16(int addr) {
    return switch (addr) {
      0x00 || 0x02 => data, // data
      0x02 || 0x04 => ctrl, // ctrl
      0x08 => vCounter << 8 |
          hCounter >> 1, // hv counter, when interlace, VC0 is replaced by VC8
      _ => 0x00,
    };
  }

  void write16(int addr, int value) {
    final _ = switch (addr) {
      0x00 || 0x02 => data = value, // data
      0x04 || 0x06 => ctrl = value, // ctrl
      0x08 => 0x00, // hv counter
      0x09 => 0x00, // hv counter
      _ => 0x00,
    };
  }

  final vram = Uint8List(0x10000);
  final cram = List<int>.filled(0x80, 0); // bbbgggrrr
  final vsram = List<int>.filled(0x50, 0);

  int ram = 0; // 0:vram, 1:cram, 2:vsram
  static const ramVram = 0;
  static const ramCram = 1;
  static const ramVsram = 2;

  int ramSize = 0;

  bool h32 = true;
  bool ntsc = true; // false: pal
  bool pal30 = false;
  int interlaceMode = 0;

  int width = 256; // h32: 256, h40: 320
  int height = 224; // ntsc 224, pal: 224, pal30: 240
  int retrace = 38; // ntsc 38, pal: 98, pal30: 82

  int vCounter = 0;
  int hCounter = 0;

  List<int> reg = List<int>.filled(24, 0);

  bool get enabeHInt => reg[0].bit5;
  bool get stopHCounter => reg[0].bit1;
  bool get enableDisplay => reg[1].bit6;
  bool get enableVInt => reg[1].bit5;
  bool get enableDma => reg[1].bit4;
  bool get v30Mode => reg[1].bit3;

  bool get enableExtInt => reg[11].bit3;
  bool get vScr2Cell => reg[11].bit2;
  int get vScrMode => reg[11] & 0x03;

  int status = 0;

  Uint8List buffer = Uint8List(256 * 240 * 4);
  ImageBuffer get imageBuffer => ImageBuffer(width, height, buffer);

  int postInc() {
    final ret = _addr;
    _addr += reg[0x0f];
    if (_addr > ramSize) {
      _addr -= ramSize;
    }
    return ret;
  }

  int encodeCram(int val) =>
      val << 3 & 0xf00 | val << 2 & 0x0f0 | val << 1 & 0x00f;

  int get data => ram == ramVram
      ? vram[_addr++] << 16 | vram[postInc()]
      : ram == ramCram
          ? encodeCram(cram[postInc()])
          : vsram[postInc()];

  set data(int value) {
    if (ram == ramVram) {
      vram[_addr++] = value >> 16;
      vram[postInc()] = value.mask8;
    } else {
      final addr = postInc() >> 1;
      if (ram == ramCram) {
        cram[addr] = value << 5 & 0x1c0 | value >> 4 & 0x07 | value >> 1 & 0x07;
      } else {
        vsram[addr] = value;
      }
    }
  }

  int _ctrl = 0;
  bool _is1st = false;
  int _addr = 0;

  int get ctrl => _ctrl;

  set ctrl(int value) {
    if (value & 0xe000 == 0x8000) {
      final regNo = value >> 8 & 0x1f;
      reg[regNo] = value.mask8;

      if (regNo == 12) {
        h32 = value & 0x81 != 0x11;
        width = h32 ? 256 : 320;
      }
      return;
    }

    if (_is1st) {
      _ctrl = value;
      _is1st = false;
      return;
    }

    _addr = value << 14 & 0xc000 | _ctrl & 0x3fff;
    final cd = value >> 2 & 0x3c | _ctrl >> 14 & 0x02;

    final _ = switch (cd) {
      0x01 || 0x00 => (ram, ramSize = ramVram, vram.length),
      0x03 || 0x80 => (ram, ramSize = ramCram, cram.length),
      0x05 || 0x40 => (ram, ramSize = ramVsram, vsram.length),
      _ => 0,
    };
  }
}
