import 'dart:async';
import 'dart:typed_data';

import 'package:fnesemu_core/app_api.dart';
import 'package:fnesemu_core/src/core/ps2/gs/gs.dart';
import 'package:fnesemu_core/src/core/ps2/gs/gs_memory.dart';
import 'package:fnesemu_core/src/core/ps2/ps2.dart';
import 'package:test/test.dart';

class _Sink implements Ps2RenderFrameSink {
  Ps2RenderFrame? frame;
  final result = Completer<Uint8List?>();

  @override
  void submit(RenderFrame frame) {}

  @override
  Future<Uint8List?> drawPs2(Ps2RenderFrame frame) {
    this.frame = frame;
    return result.future;
  }

  void finish() {
    final frame = this.frame!;
    final rgba = Uint8List(frame.width * frame.height * 4);
    for (final (i, rect) in frame.rectangles.indexed) {
      for (var y = rect.top; y < rect.bottom; y++) {
        for (var x = rect.left; x < rect.right; x++) {
          rgba[(y * frame.width + x) * 4] = i + 1;
        }
      }
    }
    result.complete(rgba);
  }
}

Gs _gs([_Sink? sink]) => Gs()
  ..renderFrameSink = sink
  ..writePrivileged(0, 1)
  ..writeRegister(0x4c, 1 << 16)
  ..writeRegister(0x4e, 1 << 32)
  ..writeRegister(0x40, 63 << 16 | 95 << 48)
  ..writeRegister(0x00, Gs.primSprite);

void _sprite(Gs gs, int x0, int y0, int x1, int y1, int color) {
  gs.writeRegister(0x01, color);
  gs.writeRegister(0x05, x0 | y0 << 16);
  gs.writeRegister(0x05, x1 | y1 << 16);
}

void _draw(Gs gs) {
  _sprite(gs, 0, 0, 64 * 16, 64 * 16, 0x00554433);
  gs.writeRegister(0x4a, 1);
  _sprite(gs, 4 * 16 + 1, 4 * 16, 80 * 16, 80 * 16, 0x11bbaa99);
}

void _drawTexture(Gs gs) {
  gs.mem.write(GsPsm.ct32, 0, 1, 0, 0, 0x71123456);
  gs.mem.write(GsPsm.ct32, 0x100, 1, 0, 0, 0x80554433);
  gs
    ..writeRegister(0x4c, 1 << 16 | 0x7f000008 << 32)
    ..writeRegister(0x4e, 16 | 1 << 24)
    ..writeRegister(0x06, 0x100 | 1 << 14 | 1 << 34 | 1 << 35)
    ..writeRegister(0x00, 0x116)
    ..writeRegister(0x01, 0x80808080)
    ..writeRegister(0x03, 0)
    ..writeRegister(0x05, 0)
    ..writeRegister(0x03, 0)
    ..writeRegister(0x05, 1024 | 1024 << 16 | 123 << 32);
}

void main() {
  test('textured sprite readback applies color masks and depth flags', () async {
    final sink = _Sink();
    final gs = _gs(sink);
    _drawTexture(gs);
    expect(gs.prepareImage(), isTrue);
    await Future<void>.delayed(Duration.zero);
    final frame = sink.frame! as Ps2SpriteFrame;
    expect(frame.width, 128);
    expect(frame.height, 64);
    expect(frame.input.take(4), [0x33, 0x44, 0x55, 0x80]);
    final pixels = Uint8List(frame.width * frame.height * 4)
      ..setAll(0, [0x33, 0x44, 0x55, 255])
      ..setAll(64 * 4, [0x80, 1, 1, 255]);
    sink.result.complete(pixels);
    await Future<void>.delayed(Duration.zero);
    expect(gs.mem.read(GsPsm.ct32, 0, 1, 0, 0), 0xf1554433);
    expect(gs.mem.read(GsPsm.z24, 16 * 32, 1, 0, 0), 123);
    expect(gs.mem.read(GsPsm.z24, 16 * 32, 1, 1, 0), 0);
  });

  test('texture-dependent draws resolve before subsequent raster setup', () {
    final gs = _gs(_Sink());
    final software = _gs();
    _drawTexture(gs);
    _drawTexture(software);
    for (final target in [gs, software]) {
      target
        ..writeRegister(0x4c, 1 | 1 << 16)
        ..writeRegister(0x4e, 1 << 32);
      _sprite(target, 0, 0, 16, 16, 0x12345678);
    }
    expect(gs.mem.bytes, orderedEquals(software.mem.bytes));
  });

  test('GPU coverage preserves swizzled memory, order and GS alpha', () async {
    final sink = _Sink();
    final gs = _gs(sink);
    final software = _gs();
    _draw(gs);
    _draw(software);
    expect(gs.prepareImage(), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(
        sink.frame!.rectangles.last, (left: 5, top: 4, right: 64, bottom: 80));
    sink.finish();
    await Future<void>.delayed(Duration.zero);
    expect(gs.mem.bytes, orderedEquals(software.mem.bytes));
    expect(gs.mem.read(GsPsm.ct32, 0, 1, 4, 4), 0x00554433);
    expect(gs.mem.read(GsPsm.ct32, 0, 1, 5, 4), 0x91bbaa99);
    expect(gs.prepareImage(), isFalse);
  });

  test('read transfer preserves existing pixels and discards pending sprites',
      () async {
    final sink = _Sink();
    final gs = _gs(sink);
    gs.mem.write(GsPsm.ct32, 0, 1, 0, 0, 0x00123456);
    _draw(gs);
    expect(gs.prepareImage(), isTrue);
    await Future<void>.delayed(Duration.zero);
    gs
      ..writeRegister(0x50, 1 << 16)
      ..writeRegister(0x52, 4 | 1 << 32)
      ..writeRegister(0x53, 1);
    final words = Int64List(2);
    gs.readQuad(words);
    expect(words[0], 0x00123456);
    gs.mem.write(GsPsm.ct32, 0, 1, 0, 0, 0xff);
    sink.finish();
    await Future<void>.delayed(Duration.zero);
    expect(gs.mem.read(GsPsm.ct32, 0, 1, 0, 0), 0xff);
  });

  test('scanout discards sprites while GPU readback is pending', () async {
    final sink = _Sink();
    final gs = _gs(sink);
    gs.mem.write(GsPsm.ct32, 0, 1, 0, 0, 0x00123456);
    _draw(gs);
    expect(gs.prepareImage(), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(sink.frame, isNotNull);
    expect(gs.image().buffer[0], 0xff123456);
    expect(gs.mem.read(GsPsm.ct32, 0, 1, 5, 4), 0);

    _draw(gs);
    expect(gs.prepareImage(), isFalse);
    expect(gs.image().buffer[0], 0xff123456);

    sink.finish();
    await Future<void>.delayed(Duration.zero);
    expect(gs.image().buffer[0], 0xff123456);
    expect(gs.prepareImage(), isFalse);
  });

  test('a VRAM write captures the field before modifying existing pixels',
      () async {
    final sink = _Sink();
    final gs = _gs(sink)
      ..writePrivileged(0x20, 3)
      ..writePrivileged(0x70, 1 << 9)
      ..writePrivileged(0x80, 63 << 32 | 63 << 44);
    gs.mem.write(GsPsm.ct32, 0, 1, 0, 0, 0x00654321);
    _draw(gs);
    gs.vblank();
    expect(gs.prepareImage(), isTrue);

    gs.mem.write(GsPsm.ct32, 0, 1, 0, 0, 0x00123456);
    expect(gs.image().buffer[0], 0xff654321);
    expect(gs.prepareImage(), isFalse);
    await Future<void>.delayed(Duration.zero);
    expect(sink.frame, isNull);

    gs.vblank();
    expect(gs.image().buffer[0], 0xff654321);
    expect(gs.image().buffer[64], 0xff123456);
  });

  test('invalid GPU coverage leaves the whole batch untouched', () async {
    final sink = _Sink();
    final gs = _gs(sink);
    _draw(gs);
    expect(gs.prepareImage(), isTrue);
    await Future<void>.delayed(Duration.zero);
    sink.result.complete(Uint8List(64 * 80 * 4)
      ..[0] = 1
      ..[4] = 3);
    await Future<void>.delayed(Duration.zero);
    expect(gs.mem.read(GsPsm.ct32, 0, 1, 0, 0), 0);
    expect(gs.mem.read(GsPsm.ct32, 0, 1, 1, 0), 0);
  });

  test('display runner advances past vblank while a field render is pending',
      () async {
    final core = Ps2();
    addTearDown(core.dispose);
    final sink = _Sink();
    core.renderFrameSink = sink;
    final gs = core.io.gs
      ..writePrivileged(0, 1)
      ..writePrivileged(0x20, 3)
      ..writePrivileged(0x70, 1 << 9)
      ..writePrivileged(0x80, 63 << 32 | 63 << 44)
      ..writeRegister(0x4c, 1 << 16)
      ..writeRegister(0x4e, 1 << 32)
      ..writeRegister(0x40, 63 << 16 | 63 << 48)
      ..writeRegister(0x00, Gs.primSprite);
    _sprite(gs, 0, 0, 64 * 16, 64 * 16, 0x00554433);

    final frame = core.runFrame(core.scanlinesInFrame);
    expect(frame.stopped, isFalse);
    expect(gs.csr & Gs.csrVsint, Gs.csrVsint);
    expect(gs.prepareImage(), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(sink.frame, isNotNull);
    // Give the GPU result distinct coverage so software replay is detectable.
    sink.result.complete(Uint8List(64 * 64 * 4)..[0] = 1);
    await Future<void>.delayed(Duration.zero);
    final image = core.imageBuffer();
    expect(image.buffer[0], 0xff554433);
    expect(image.buffer[1], 0xff000000);
    expect(image.buffer[64], 0xff000000);

    gs.mem.write(GsPsm.ct32, 0, 1, 0, 0, 0x00123456);
    core.runFrame(core.scanlinesInFrame);
    expect(core.imageBuffer().buffer[0], 0xff554433);
    expect(core.imageBuffer().buffer[64], 0xff123456);
  });
}
