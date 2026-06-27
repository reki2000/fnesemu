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

  int status = 0x200; // 0x02xx means fifo is always empty
  static const bitVblankInt = 0x80;
  static const bitSpriteOverflow = 0x40;
  static const bitSpriteCollision = 0x20;
  static const bitOddFrame = 0x10;
  static const bitVBlank = 0x08;
  static const bitHBlank = 0x04;
  static const bitDmaRunning = 0x02;

  set vBlank(bool value) => value ? status |= bitVBlank : status &= ~bitVBlank;
  bool get vBlank => status & bitVBlank != 0;

  set hBlank(bool value) => value ? status |= bitHBlank : status &= ~bitHBlank;
  bool get hBlank => status & bitHBlank != 0;

  set oddFrame(bool value) =>
      value ? status |= bitOddFrame : status &= ~bitOddFrame;
  bool get oddFrame => status & bitOddFrame != 0;

  set spriteOverflow(bool value) =>
      value ? status |= bitSpriteOverflow : status &= ~bitSpriteOverflow;
  bool get spriteOverflow => status & bitSpriteOverflow != 0;

  // rendering

  Uint32List buffer = Uint32List(320 * 224);

  ImageBuffer get imageBuffer =>
      ImageBuffer(width, height, buffer.buffer.asUint8List(),
          displayWidth_: 320);

  bool h32 = true;
  bool ntsc = true; // false: pal
  bool pal30 = false;
  int interlaceMode = 0;

  get isInterlaced => interlaceMode == 3;

  int width = 256; // h32: 256, h40: 320
  static const height = 224; // ntsc 224, pal: 224, pal30: 240
  static const retrace = 38; // ntsc 38, pal: 98, pal30: 82

  int vCounter = 0;
  int hCounter = 0;

  int hIntCounter = 0;

  // reset
  void reset() {
    final rand = Random();
    // vram.fillRange(0, vram.length, 0);
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
    hIntCounter = 0;

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
      busZ80.deassertInt();
      return val;
    } else if (port == 0x08) {
      // print(
      //     "vdp hv couter read: ${vCounter.x4} ${hCounter.x4} pc:${bus.cpu.pc.x6}");
      return vCounter.shl8 | hCounter.shr1;
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
    _dmaLength = reg[0x13] | reg[0x14].shl8;

    if (_dmaLength == 0) {
      _dmaLength = 0x10000;
    }

    // print(
    //     "start dma: len:${_dmaLength.x6} src:${_dmaSrc.x6} mode:$_dmaMode pc:${bus.cpu.pc.x6}");
    status |= bitDmaRunning;
  }

  void execDma(int count) {
    while (count > 0 && _dmaLength > 0) {
      data = _dmaMode == _dmaModeM2V
          ? bus.read16(_dmaSrc)
          : _dmaMode == _dmaModeV2V
              ? vram[_dmaSrc].shl8 | vram[_dmaSrc.inc]
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
      //     "end dma: len:${_dmaLength.x4} src:${_dmaSrc.x4} mode:$_dmaMode pc:${bus.cpu.pc.x6}");
    }
  }

  set ctrl(int value) {
    // print(
    //     "vdp:ctrl=${value.x4} ram:${ram == 0 ? "v" : ram == 1 ? "c" : "vs"} is1st:$_is1st");
    if (value & 0xe000 == 0x8000) {
      final regNo = value.shr8 & 0x1f;
      reg[regNo] = value.mask8;

      switch (regNo) {
        case 12:
          h32 = value & 0x81 != 0x81;
          width = h32 ? 256 : 320;
          interlaceMode = value.shr1 & 0x03;
          break;
        case 0x17:
          if (!reg[0x17].bit7) {
            _dmaMode = _dmaModeM2V;
          } else if (!reg[0x17].bit6) {
            _dmaMode = _dmaModeFill;
          } else {
            _dmaMode = _dmaModeV2V;
          }
          break;
        // case 0x0a:
        //   print(
        //       "vdp[0x0a]:${value.x2} ${bus.cpu.clocks} ${bus.cpu.pc.x6} vcounter:${vCounter.x4}"); // debug
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

    _addr = value.shl14 & 0xc000 | _ctrl & 0x3fff;
    final cd = value.shr2 & 0x3c | _ctrl.shr14 & 0x03;

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
      // default:
      //   print("vdp: ignored access cd=${cd.x2} addr=${_addr.x4}");
    }

    if (enableDma && cd.bit5 && _dmaMode == _dmaModeM2V) {
      _dmaSrc = (reg[0x15] | reg[0x16].shl8 | (reg[0x17] & 0x7f).shl16).shl1;
      startDma();
      execDma(0x10000);
    } else if (enableDma && cd & 0x30 == 0x30 && _dmaMode == _dmaModeV2V) {
      _dmaSrc = (reg[0x15] | reg[0x16].shl8 | (reg[0x17] & 0x3f).shl16).shl1;
      startDma();
      //execDma(0x10000); // workaround
    }
  }

  int get data => ram == ramVram
      ? vram[_addr].shl8 | vram[postInc(1)]
      : ram == ramCram
          ? encodeCram(cram[postInc().shr1])
          : vsram[postInc().shr1];

  set data(int value) {
    // print(
    //     "${ram == 0 ? "v" : ram == 1 ? "c" : "vs"}ram[${_addr.x4}] = ${value.x4} pc:${bus.cpu.pc.x6}");
    if (ram == ramVram) {
      // if (_addr == 0xc350) {
      //   print(
      //       "vdp:debug: v:${value.x4} ${dump()} pc:${bus.cpu.pc}"); // debug
      // }
      vram[_addr] = value.shr8;
      vram[postInc(1)] = value.mask8;
    } else if (ram == ramCram) {
      cram[postInc().shr1] =
          value.shr3 & 0x1c0 | value.shr2 & 0x038 | value.shr1 & 0x07;
    } else {
      vsram[postInc().shr1] = value;
    }
  }

  int encodeCram(int val) =>
      val.shl3 & 0xf00 | val.shl2 & 0x0f0 | val.shl1 & 0x00f;

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
        .map((i) => reg.sublist(i, i + 4).map((e) => e.x2).join(" "))
        .join("  ");

    final bgSizeH = ["32", "64", "--", "128"][reg[16] & 0x03];
    final bgSizeV = ["32", "64", "--", "128"][reg[16].shr4 & 0x03];
    final nameA = reg[2].shl10 & 0xe000;
    final nameB = reg[4].shl13 & 0xe000;
    final win = reg[3].shl10 & 0xf800;
    final spr = reg[5].shl9 & 0xfc00;

    final hScrMode = ["f", "-", "8", "1"][reg[11] & 0x03];
    final vScrMode = reg[11].bit2 ? "16  " : vsram[0].x4;

    final dma =
        "dma:${enableDma ? "*" : "-"}${status & bitDmaRunning != 0 ? "r" : "-"} ${_dmaLength.x4}";

    final s =
        "${h32 ? "h32" : "h40"} ${bgSizeH}x$bgSizeV im:$interlaceMode a:${nameA.x4} b:${nameB.x4} w:${win.x4} s:${spr.x4} h:$hScrMode v:$vScrMode ${hIntCounter.x2}";

    return "vdp:$regStr\n  s:${status.x4} $s $dma";
  }
}
