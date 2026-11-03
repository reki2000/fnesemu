import 'dart:typed_data';

import 'package:fnesemu_core/src/core/pce/component/cpu_6280.dart';
import 'package:fnesemu_core/src/core/pce/component/vdc.dart';
import 'package:fnesemu_core/src/core/pce/component/vdc_render.dart';
import 'package:fnesemu_core/src/core/pce/pce.dart';
import 'package:fnesemu_core/src/util/int.dart';
import 'package:test/test.dart';

const hardware = 0xff << 13;

Pce machine() => Pce()..reset();

void main() {

  test('both VDCs keep sprite and background renderer state independent', () {
    final pce = machine();
    pce.vdc.spriteBufIndex = 5;
    pce.vdc.pattern01 = 0xffff;
    pce.vdc.sprite0[0] = true;
    expect(pce.vdc2.spriteBufIndex, 0);
    expect(pce.vdc2.pattern01, 0);
    expect(pce.vdc2.sprite0[0], isFalse);
  });

  test('two VDC frame completions count as one video frame', () {
    final pce = machine();
    VdcRenderer.frames = 0;
    pce.vdc.scanLine = pce.vdc2.scanLine = 262;
    pce.vdc.exec();
    pce.vdc2.exec();
    expect(VdcRenderer.frames, 1);
  });

}
