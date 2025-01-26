import 'dart:math';
import 'dart:typed_data';

import 'package:fnesemu/util/int.dart';

import '../types.dart';
import 'bus_m68.dart';
import 'bus_z80.dart';

class Vdp {
  Vdp();

  late BusM68 bus;
  late BusZ80 busZ80;

  final vram = Uint8List(0x10000);
  final cram = List<int>.filled(0x40, 0); // bbbgggrrr
  final vsram = List<int>.filled(0x40, 0);

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

  int status = 0x200;
  static const bitDmaRunning = 0x02;
  static const bitVBlank = 0x08;
  static const bitHBlank = 0x04;
  static const bitVblankInt = 0x80;

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

  int hSyncCounter = 0;

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
    _ctrl = 0;
    _addr = 0;

    status = 0x200;

    h32 = true;
    width = 256;

    vCounter = 0;
    hCounter = 0;
    hSyncCounter = 0;

    _dmaMode = _dmaModeNone;
    _dmaSrc = 0;
    _dmaLength = 0;
    _dmaFillValue = 0;
  }

  // i/o
  int read16(int addr) {
    final port = addr & 0x0c;
    if (port == 0x00) {
      return data;
    } else if (port == 0x04) {
      final val = status;
      status &= ~bitVblankInt;
      return val;
    } else if (port == 0x08) {
      return vCounter << 8 | hCounter >> 1;
    }
    return 0;
  }

  void write16(int addr, int value) {
    final port = addr & 0x0c;
    if (port == 0x00) {
      if (enableDma && _dmaMode == _dmaModeFill) {
        _dmaFillValue = value;
        startDma();
      } else {
        data = value; // data
      }
    } else if (port == 0x04) {
      ctrl = value; // ctrl
    }
  }

  // ram access
  int _ctrl = 0;
  bool _is1st = true;
  int _addr = 0;

  // dma
  int _dmaMode = _dmaModeNone; // 0:none, 1:mem2vram, 2:fill, 3:vram2vram
  static const _dmaModeNone = 0;
  static const _dmaModeM2V = 1;
  static const _dmaModeFill = 2;
  static const _dmaModeV2V = 3;

  int _dmaSrc = 0;
  int _dmaLength = 0;
  int _dmaFillValue = 0;

  bool get isDmaRunning => _dmaLength > 0;

  void startDma() {
    _dmaLength = reg[0x13] | reg[0x14] << 8;
    // print(
    //     "start dma: len:${_dmaLength.hex16} src:${_dmaSrc.hex16} mode:$_dmaMode pc:${bus.cpu.pc.hex24}");
    status |= bitDmaRunning;
  }

  void execDma(int count) {
    while (count > 0 && _dmaLength > 0) {
      data = _dmaMode == _dmaModeM2V
          ? bus.read16(_dmaSrc)
          : _dmaMode == _dmaModeV2V
              ? vram[_dmaSrc] << 8 | vram[_dmaSrc.inc]
              : _dmaFillValue;

      _dmaSrc += 2;
      _dmaLength--;
      count--;
    }

    if (_dmaLength <= 0) {
      _dmaMode = _dmaModeNone;
      _dmaSrc = 0;
      _dmaFillValue = 0;
      _dmaLength = 0;
      status &= ~bitDmaRunning;
      // print(
      //     "end dma: len:${_dmaLength.hex16} src:${_dmaSrc.hex16} mode:$_dmaMode pc:${bus.cpu.pc.hex24}");
    }
  }

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

      if (regNo == 0x17) {
        if (!reg[0x17].bit7) {
          _dmaMode = _dmaModeM2V;
        } else if (!reg[0x17].bit6) {
          _dmaMode = _dmaModeFill;
        } else {
          _dmaMode = _dmaModeV2V;
        }
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

    //print("vdp:cd=${cd.hex8} addr=${_addr.hex16}");
    switch (cd & 0x0f) {
      case 0x00:
      case 0x01:
        ram = ramVram;
        ramSize = vram.length;
        break;
      case 0x03:
      case 0x08:
        ram = ramCram;
        ramSize = 128;
        _addr &= 0x7f;
        break;
      case 0x05:
      case 0x04:
        ram = ramVsram;
        ramSize = 80;
        _addr &= 0x7f;
        break;
    }

    if (enableDma && cd.bit5 && _dmaMode == _dmaModeM2V) {
      _dmaSrc = (reg[0x15] | reg[0x16] << 8 | (reg[0x17] & 0x7f) << 16) << 1;
      startDma();
      execDma(0x10000);
    } else if (enableDma && cd & 0x30 == 0x30 && _dmaMode == _dmaModeV2V) {
      _dmaSrc = (reg[0x15] | reg[0x16] << 8 | (reg[0x17] & 0x3f) << 16) << 1;
      startDma();
      //execDma(0x10000); // workaround
    }
  }

  int get data => ram == ramVram
      ? vram[_addr] << 8 | vram[postInc(1)]
      : ram == ramCram
          ? encodeCram(cram[postInc() >> 1])
          : vsram[postInc() >> 1];

  set data(int value) {
    // print(
    //     "${ram == 0 ? "v" : ram == 1 ? "c" : "vs"}ram[${_addr.hex16}] = ${value.hex16} pc:${bus.cpu.pc.hex24}");
    if (ram == ramVram) {
      vram[_addr] = value >> 8;
      vram[postInc(1)] = value.mask8;
    } else if (ram == ramCram) {
      cram[postInc() >> 1] =
          value >> 3 & 0x1c0 | value >> 2 & 0x038 | value >> 1 & 0x07;
    } else {
      vsram[postInc() >> 1] = value;
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
    return ret.mask16;
  }

  // debug

  String dump() {
    final regStr = [0, 4, 8, 12, 16, 20]
        .map((i) => reg.sublist(i, i + 4).map((e) => e.hex8).join(" "))
        .join("  ");

    final bgSizeH = ["32", "64", "--", "128"][reg[16] & 0x03];
    final bgSizeV = ["32", "64", "--", "128"][reg[16] >> 4 & 0x03];
    final nameA = reg[2] << 10 & 0xe000;
    final nameB = reg[4] << 13 & 0xe000;
    final win = reg[3] << 10 & 0xf800;

    final hScrMode = ["f", "-", "8", "1"][reg[11] & 0x03];
    final vScrMode = reg[11].bit2 ? "16" : "f ";

    final dma = "dma:${enableDma ? "*" : "-"} ${_dmaLength.hex16}";

    final s =
        "${h32 ? "h32" : "h40"} ${bgSizeH}x$bgSizeV im:$interlaceMode a:${nameA.hex16} b:${nameB.hex16} w:${win.hex16} hscr:$hScrMode vscr:$vScrMode";

    return "vdp:$regStr\n    s:${status.hex16} $s $dma";
  }
}
