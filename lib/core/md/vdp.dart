import 'dart:math';
import 'dart:typed_data';

import 'package:fnesemu/util/int.dart';

import '../types.dart';
import 'bus_m68.dart';

class Vdp {
  Vdp();

  late BusM68 bus;

  final vram = Uint8List(0x10000);
  final cram = List<int>.filled(0x80, 0); // bbbgggrrr
  final vsram = List<int>.filled(0x50, 0);

  int ram = 0; // 0:vram, 1:cram, 2:vsram
  static const ramVram = 0;
  static const ramCram = 1;
  static const ramVsram = 2;

  int ramSize = 0;

  List<int> reg = List<int>.filled(32, 0);

  bool get fillLeft8 => reg[0].bit5;
  bool get enableHInt => reg[0].bit4;
  bool get stopHCounter => reg[0].bit1;
  bool get disableDisplay => reg[0].bit0;
  bool get enableDisplay => reg[1].bit6;
  bool get enableVInt => reg[1].bit5;
  bool get enableDma => reg[1].bit4;
  bool get v30Mode => reg[1].bit3;

  bool get enableExtInt => reg[11].bit3;
  bool get vScr2Cell => reg[11].bit2;
  int get vScrMode => reg[11] & 0x03;

  int status = 0;

  // rendering

  Uint32List buffer = Uint32List(320 * 224);

  ImageBuffer get imageBuffer =>
      ImageBuffer(width, height, buffer.buffer.asUint8List());

  bool h32 = true;
  bool ntsc = true; // false: pal
  bool pal30 = false;
  int interlaceMode = 0;

  int width = 256; // h32: 256, h40: 320
  static const height = 224; // ntsc 224, pal: 224, pal30: 240
  static const retrace = 38; // ntsc 38, pal: 98, pal30: 82

  int vCounter = 0;
  int hCounter = 0;

  // reset
  void reset() {
    final rand = Random();
    vram.setRange(0, vram.length,
        Iterable.generate(0x10000, (i) => rand.nextInt(0x10000)));
    cram.setRange(
        0, cram.length, Iterable.generate(0x10000, (i) => rand.nextInt(0x200)));
    vsram.fillRange(0, vsram.length, 0);

    reg.fillRange(0, reg.length, 0);

    _is1st = true;
  }

  // i/o
  int read16(int addr) {
    final port = addr & 0x0c;
    if (port == 0x00) {
      return data;
    } else if (port == 0x04) {
      final val = status;
      status &= ~0x80;
      return val;
    } else if (port == 0x08) {
      return vCounter << 8 | hCounter >> 1;
    }
    return 0;
  }

  void write16(int addr, int value) {
    final port = addr & 0x0c;
    if (port == 0x00) {
      data = value; // data
    } else if (port == 0x04) {
      ctrl = value; // ctrl
    }
  }

  // ram access
  int _ctrl = 0;
  bool _is1st = true;
  int _addr = 0;

  set ctrl(int value) {
    // print(
    //     "vdp:ctrl=${value.hex16} ram:${ram == 0 ? "v" : ram == 1 ? "c" : "vs"} is1st:$_is1st");
    if (value & 0xe000 == 0x8000) {
      final regNo = value >> 8 & 0x1f;
      reg[regNo] = value.mask8;

      if (regNo == 12) {
        h32 = value & 0x81 != 0x81;
        width = h32 ? 256 : 320;
      }

      _is1st = true;
      return;
    }

    if (_is1st) {
      _ctrl = value;
      _is1st = false;
      return;
    }

    _is1st = true;

    _addr = value << 14 & 0xc000 | _ctrl & 0x3fff;
    final cd = value >> 2 & 0x3c | _ctrl >> 14 & 0x03;

    if (cd == 0x00 || cd == 0x01) {
      ram = ramVram;
      ramSize = vram.length;
    } else if (cd == 0x03 || cd == 0x08) {
      ram = ramCram;
      ramSize = cram.length;
    } else if (cd == 0x05 || cd == 0x04) {
      ram = ramVsram;
      ramSize = vsram.length;
    }
  }

  int get data => ram == ramVram
      ? vram[_addr] << 8 | vram[postInc(1)]
      : ram == ramCram
          ? encodeCram(cram[postInc()])
          : vsram[postInc()];

  set data(int value) {
    // print(
    //     "${ram == 0 ? "v" : ram == 1 ? "c" : "vs"}ram[${_addr.hex16}] = ${value.hex16}");
    if (ram == ramVram) {
      vram[_addr] = value >> 8;
      vram[postInc(1)] = value.mask8;
    } else {
      final addr = postInc() >> 1;
      if (ram == ramCram) {
        cram[addr] =
            value >> 3 & 0x1c0 | value >> 2 & 0x038 | value >> 1 & 0x07;
      } else {
        vsram[addr] = value;
      }
    }
  }

  int encodeCram(int val) =>
      val << 3 & 0xf00 | val << 2 & 0x0f0 | val << 1 & 0x00f;

  int postInc([int offset = 0]) {
    final ret = _addr + offset;
    _addr += reg[0x0f];
    if (_addr >= ramSize) {
      _addr -= ramSize;
    }
    return ret;
  }

  // debug

  String dump() {
    final regStr = [0, 4, 8, 12, 16, 20]
        .map((i) => reg.sublist(i, i + 4).map((e) => e.hex8).join(" "))
        .join("  ");
    return "vdp:$regStr";
  }
}
