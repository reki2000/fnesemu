import 'dart:typed_data';

import 'package:fnesemu/util/int.dart';

import '../types.dart';

class Vdp {
  Vdp();

  final vram = Uint8List(0x10000);
  final cram = List<int>.filled(0x80, 0);
  final vsram = List<int>.filled(0x50, 0);

  int ram = 0; // 0:vram, 1:cram, 2:vsram
  static const ramVram = 0;
  static const ramCram = 1;
  static const ramVsram = 2;

  int ramSize = 0;

  int width = 256;
  int height = 240;

  int vCounter = 0;
  int hCounter = 0;

  List<int> reg = List<int>.filled(24, 0);
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

  int get dataL => ram == ramVram
      ? vram[postInc()]
      : ram == ramCram
          ? encodeCram(cram[postInc()]).mask8
          : vsram[postInc()].mask8;

  int get dataH => ram == ramVram
      ? vram[postInc()]
      : ram == ramCram
          ? encodeCram(cram[postInc()]) >> 8
          : vsram[postInc()] >> 8;

  set dataH(int value) {
    if (ram == ramVram) {
      vram[postInc()] = value;
    } else {
      final addr = postInc() >> 1;
      if (ram == ramCram) {
        cram[addr] = value << 5 & 0x1c0 | cram[addr] & 0x3f;
      } else {
        vsram[addr] = vsram[addr].setH8(value);
      }
    }
  }

  set dataL(int value) {
    if (ram == ramVram) {
      vram[postInc()] = value;
    } else {
      final addr = postInc() >> 1;
      if (ram == ramCram) {
        cram[addr] = cram[addr] & 0x1c0 | value >> 4 & 0x07 | value >> 1 & 0x07;
      } else {
        vsram[addr] = vsram[addr].setL8(value);
      }
    }
  }

  int _ctrl = 0;
  int _reg = -1;
  bool _is1st = false;
  int _addr = 0;

  int get ctrlL => _ctrl.mask8;
  int get ctrlH => _ctrl >> 8 & 0xff;

  set ctrlH(int value) {
    if (value & 0xe0 == 0x80) {
      _reg = value & 0x1f;
      return;
    }

    _reg = -1;

    if (_is1st) {
      _ctrl = value << 16 | _ctrl.mask16;
    }
  }

  set ctrlL(int value) {
    if (_reg >= 0) {
      reg[_reg] = value;
      return;
    }

    if (_is1st) {
      _ctrl = value;
      _is1st = false;
      return;
    }

    _is1st = true;

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
