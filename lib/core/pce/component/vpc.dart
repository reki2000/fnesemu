import 'dart:typed_data';

import 'package:fnesemu/util/int.dart';

import 'vdc.dart';
import 'vdc_render.dart'; // rgba (512-entry VCE->RGBA table)

/// HuC6202 Video Priority Controller (SuperGrafx).
///
/// On a plain PC Engine this just converts VDC1's palette-index line buffer
/// through the (shared) VCE colour table into RGBA. On SuperGrafx it also
/// composes VDC1 (front) and VDC2 (back) according to the priority registers.
///
/// SuperGrafx mode is latched on first access to any VPC ($08-$0E) or VDC2
/// ($10-$17) register (see [Bus]); games that never touch those run unchanged.
class Vpc {
  bool enabled = false;

  // priority registers: two 4-bit nibbles each, one per window region.
  //   region index = (inWindow1 ? 0 : 1) | (inWindow2 ? 0 : 2)
  //     0: inside both windows          -> $08 low nibble
  //     1: inside window2 only          -> $08 high nibble
  //     2: inside window1 only          -> $09 low nibble
  //     3: outside both windows(default)-> $09 high nibble
  //   nibble bit0   : VDC1 enable
  //   nibble bit1   : VDC2 enable
  //   nibble bit2-3 : priority mode (see _mix)
  int priority0 = 0x11; // $08
  int priority1 = 0x11; // $09

  int window1 = 0; // $0A-$0B (10bit)
  int window2 = 0; // $0C-$0D (10bit)

  int vdcSelect = 0; // $0E bit0 : target VDC for ST0/1/2 and CPU $00-$07

  Uint32List frameBuffer = Uint32List(0);

  void reset() {
    enabled = false;
    priority0 = 0x11;
    priority1 = 0x11;
    window1 = 0;
    window2 = 0;
    vdcSelect = 0;
    frameBuffer = Uint32List(0);
  }

  int read(int reg) {
    enabled = true;
    return switch (reg & 0x0f) {
      0x08 => priority0,
      0x09 => priority1,
      0x0a => window1 & 0xff,
      0x0b => window1.shr8 & 0x03,
      0x0c => window2 & 0xff,
      0x0d => window2.shr8 & 0x03,
      0x0e => vdcSelect,
      _ => 0,
    };
  }

  void write(int reg, int data) {
    enabled = true;
    switch (reg & 0x0f) {
      case 0x08:
        priority0 = data;
        break;
      case 0x09:
        priority1 = data;
        break;
      case 0x0a:
        window1 = window1.setL8(data);
        break;
      case 0x0b:
        window1 = window1.setH8(data & 0x03);
        break;
      case 0x0c:
        window2 = window2.setL8(data);
        break;
      case 0x0d:
        window2 = window2.setH8(data & 0x03);
        break;
      case 0x0e:
        vdcSelect = data & 0x01;
        break;
    }
  }

  /// Build the RGBA frame from the VDC line buffers.
  void render(Vdc vdc1, Vdc vdc2) =>
      enabled ? _renderSgx(vdc1, vdc2) : _renderSingle(vdc1);

  void _renderSingle(Vdc vdc) {
    final buf = vdc.indexBuffer;
    final n = buf.length;
    if (frameBuffer.length != n) frameBuffer = Uint32List(n);
    final ct = vdc.colorTable;

    for (int i = 0; i < n; i++) {
      final idx = buf[i];
      frameBuffer[i] = idx == 0xffff ? 0xffffffff : rgba[ct[idx]];
    }
  }

  void _renderSgx(Vdc vdc1, Vdc vdc2) {
    final width = vdc1.hSize;
    final n = vdc1.indexBuffer.length;
    if (frameBuffer.length != n) frameBuffer = Uint32List(n);

    final b1 = vdc1.indexBuffer;
    final b2 = vdc2.indexBuffer;
    final width2 = vdc2.hSize;
    final ct = vdc1.colorTable; // VCE is shared; VDC1 owns the palette

    // per-x priority nibble. window value $40 = leftmost pixel; values
    // below $40 disable the window (no pixel is inside it).
    final regions = [
      priority0 & 0x0f,
      priority0.shr4 & 0x0f,
      priority1 & 0x0f,
      priority1.shr4 & 0x0f,
    ];
    final nibbles = Uint8List(width);
    for (int x = 0; x < width; x++) {
      final inW1 = window1 >= 0x40 && x <= window1 - 0x40;
      final inW2 = window2 >= 0x40 && x <= window2 - 0x40;
      nibbles[x] = regions[(inW1 ? 0 : 1) | (inW2 ? 0 : 2)];
    }

    for (int y = 0, i = 0; i < n; y++) {
      final row2 = y * width2;
      for (int x = 0; x < width; x++, i++) {
        final c1 = b1[i];
        if (c1 == 0xffff) {
          frameBuffer[i] = 0xffffffff; // debug overlay
          continue;
        }
        final i2 = row2 + x;
        final c2 = x < width2 && i2 < b2.length ? b2[i2] : 0;
        frameBuffer[i] = rgba[ct[_mix(nibbles[x], c1, c2)]];
      }
    }
  }

  // one pixel of priority mixing (HuC6202). c1/c2 are the 9-bit VCE indices
  // from VDC1/VDC2: bit8 set = sprite pixel, low nibble 0 = transparent.
  int _mix(int nibble, int c1, int c2) {
    final en1 = nibble & 0x01 != 0;
    final en2 = nibble & 0x02 != 0;

    if (!en1) return en2 ? c2 : 0;
    if (!en2) return c1;

    final op1 = c1 & 0x0f != 0; // vdc1 pixel is opaque
    final sp1 = c1 > 0x100; // vdc1 pixel is an opaque sprite
    final sp2 = c2 > 0x100; // vdc2 pixel is an opaque sprite

    return switch ((nibble >> 2) & 0x03) {
      // mode 1: SP1 > SP2 > BG1 > BG2 (sprites of both VDCs in front)
      1 => sp1 ? c1 : (sp2 ? c2 : (op1 ? c1 : c2)),
      // mode 2: SP1+SP2->SP1, BG1+SP2->BG1, SP1+BG2->BG2, BG1+BG2->BG1
      // (VDC1 sprites hide behind VDC2 BG, VDC2 sprites behind VDC1 BG)
      2 => sp2 ? (sp1 ? c1 : (op1 ? c1 : c2)) : (sp1 ? c2 : (op1 ? c1 : c2)),
      // modes 0/3: everything of VDC1 in front of VDC2
      _ => op1 ? c1 : c2,
    };
  }
}
