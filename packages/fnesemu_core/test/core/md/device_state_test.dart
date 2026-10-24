@TestOn('vm')
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:fnesemu_core/src/core/md/vdp.dart';
import 'package:fnesemu_core/src/core/md/vdp_renderer.dart';
import 'package:fnesemu_core/src/core/md/ym2612.dart';
import 'package:fnesemu_core/src/util/state.dart';
import 'package:test/test.dart';

Uint8List _save(void Function(StateWriter) save) {
  final w = StateWriter('md-devices', 1, 0);
  save(w);
  return w.take();
}

void _load(Uint8List state, void Function(StateReader) load) {
  final r = StateReader(state, 'md-devices', 1, 0);
  load(r);
  r.end();
}

void _reg(Ym2612 fm, int part, int reg, int value) {
  fm.writePort8(part, reg);
  fm.writeData8(part, value);
}

/// Channel 1 with every operator audible, LFO and both timers running.
Ym2612 _fm() {
  final fm = Ym2612();
  _reg(fm, 0, 0x22, 0x0b); // LFO on
  _reg(fm, 0, 0x24, 0x80);
  _reg(fm, 0, 0x26, 0x40);
  _reg(fm, 0, 0x27, 0x0f); // timers on with flags
  _reg(fm, 0, 0xb0, 0x3f); // feedback 7, algorithm 7
  _reg(fm, 0, 0xb4, 0xf7); // both outputs, AMS/FMS
  for (final op in [0, 4, 8, 12]) {
    _reg(fm, 0, 0x30 + op, 0x71 + op);
    _reg(fm, 0, 0x40 + op, op);
    _reg(fm, 0, 0x50 + op, 0x1f);
    _reg(fm, 0, 0x60 + op, 0x85);
    _reg(fm, 0, 0x70 + op, 0x03);
    _reg(fm, 0, 0x80 + op, 0x2f);
  }
  _reg(fm, 0, 0xa4, 0x22);
  _reg(fm, 0, 0xa0, 0x69);
  _reg(fm, 0, 0x28, 0xf0); // key on
  return fm;
}

void _ctrl(Vdp vdp, int value) => vdp.write16(4, value);

/// A display with random patterns, colors, scroll values and sprites.
Vdp _vdp() {
  final rnd = Random(5);
  final vdp = Vdp();
  for (var i = 0; i < vdp.vram.length; i++) {
    vdp.vram[i] = rnd.nextInt(256);
  }
  for (var i = 0; i < vdp.cram.length; i++) {
    vdp.cram[i] = rnd.nextInt(0x200);
  }
  for (var i = 0; i < vdp.vsram.length; i++) {
    vdp.vsram[i] = rnd.nextInt(0x400);
  }
  for (final (reg, value) in [
    (0, 0x04), (1, 0x44), (2, 0x30), (3, 0x2c), (4, 0x07), (5, 0x5c), //
    (7, 0x13), (11, 0x03), (12, 0x81), (13, 0x2f), (15, 0x02), (16, 0x11),
  ]) {
    _ctrl(vdp, 0x8000 | reg << 8 | value);
  }
  // a short sprite link list at 0xb800
  for (var i = 0; i < 12; i++) {
    final at = 0xb800 + i * 8;
    final y = 0x80 + rnd.nextInt(200), x = 0x80 + rnd.nextInt(300);
    vdp.vram.setAll(at, [
      y >> 8, y & 0xff, 0x05, i + 1 < 12 ? i + 1 : 0, //
      rnd.nextInt(256), rnd.nextInt(256), x >> 8, x & 0xff
    ]);
  }
  vdp.vCounter = 4;
  return vdp;
}

void _lines(Vdp vdp, int n) {
  for (var i = 0; i < n; i++) {
    vdp.renderLine();
  }
}

void main() {
  test('a restored YM2612 renders the same continuation', () {
    final original = _fm();
    original.render(400);
    final state = _save(original.saveState);
    final expected = original.render(700);
    expect(expected.any((v) => v != 0), isTrue);

    final restored = Ym2612();
    _load(state, restored.loadState);
    expect(restored.render(700), expected);
    expect(_save(restored.saveState), _save(original.saveState));
  });

  test('a restored VDP renders the same continuation', () {
    final original = _vdp();
    _lines(original, 40);
    final state = _save(original.saveState);
    _lines(original, 120);

    final restored = Vdp();
    _load(state, restored.loadState);
    _lines(restored, 120);
    expect(original.buffer.toSet().length, greaterThan(8));
    expect(restored.buffer, original.buffer);
    expect(restored.status, original.status);
    expect(_save(restored.saveState), _save(original.saveState));
  });

  test('a restored VDP keeps a pending sprite dot overflow', () {
    final vdp = _vdp()..line.spriteDotOverflow = true;
    final copy = Vdp();
    _load(_save(vdp.saveState), copy.loadState);
    expect(copy.line.spriteDotOverflow, isTrue);
  });

  test('the opacity buffer round trips when tracked', () {
    final vdp = _vdp()
      ..trackOpacity = true
      ..opaque[10] = 1;
    final copy = Vdp();
    _load(_save(vdp.saveState), copy.loadState);
    expect(copy.opaque[10], 1);
    expect(copy.trackOpacity, isTrue);
    final plain = _save(Vdp().saveState);
    _load(plain, copy.loadState);
    expect(_save(copy.saveState), plain);
    expect(copy.trackOpacity, isFalse);
  });
}
