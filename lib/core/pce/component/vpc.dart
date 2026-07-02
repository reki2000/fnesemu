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
///
/// NOTE: window support ($0A-$0D) is not yet modelled — the region-0 priority
/// nibble (low nibble of $08) is applied to the whole screen. Likewise priority
/// modes 2/3 (sprite-vs-bg cross-VDC mixing) are approximated as "VDC1 front".
class Vpc {
  bool enabled = false;

  // priority registers: two 4-bit nibbles each, one per window region.
  //   region index = (inWindow1 ? 1 : 0) | (inWindow2 ? 2 : 0)
  //   nibble bit0   : VDC1 (front) enable
  //   nibble bit1   : VDC2 (back)  enable
  //   nibble bit2-3 : priority mode (0: VDC1 front, 1: VDC2 front, 2/3: mixed)
  int priority0 = 0x11; // $08 : region0(low) / region1(high)
  int priority1 = 0x11; // $09 : region2(low) / region3(high)

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
    final n = vdc1.indexBuffer.length;
    if (frameBuffer.length != n) frameBuffer = Uint32List(n);

    final b1 = vdc1.indexBuffer;
    final b2 = vdc2.indexBuffer;
    final ct = vdc1.colorTable; // VCE is shared; VDC1 owns the palette

    final nibble = priority0 & 0x0f; // region 0 (whole screen for now)
    final vdc1en = nibble & 0x01 != 0;
    final vdc2en = nibble & 0x02 != 0;
    final vdc2Front = ((nibble >> 2) & 0x03) == 1;

    final m = b2.length < n ? b2.length : n; // guard size mismatch

    for (int i = 0; i < n; i++) {
      final c1 = b1[i];
      if (c1 == 0xffff) {
        frameBuffer[i] = 0xffffffff; // debug overlay
        continue;
      }
      final c2 = i < m ? b2[i] : 0;

      final op1 = vdc1en && (c1 & 0x0f) != 0;
      final op2 = vdc2en && (c2 & 0x0f) != 0;

      final int idx;
      if (vdc2Front) {
        idx = op2 ? c2 : (op1 ? c1 : 0);
      } else {
        idx = op1 ? c1 : (op2 ? c2 : 0);
      }
      frameBuffer[i] = rgba[ct[idx]];
    }
  }
}
