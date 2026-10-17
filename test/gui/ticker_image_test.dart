import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fnesemu/gui/ticker_image.dart';

ui.Image _image() {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder);
  final picture = recorder.endRecording();
  final image = picture.toImageSync(1, 1);
  picture.dispose();
  return image;
}

void main() {
  testWidgets('replaced frame lives until repaint and is then released',
      (tester) async {
    final callbacks = <ui.ImageDecoderCallback>[];
    final container = ImageContainer(
        decoder: (pixels, width, height, callback) => callbacks.add(callback));
    await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: imageListener(
            notifier: container.imageNotifier, width: 100, height: 100)));
    final first = _image(), second = _image();
    container.push(Uint32List(1), 1, 1, 320);
    callbacks.removeAt(0)(first);
    await tester.pump();
    container.push(Uint32List(1), 1, 1, 256);
    callbacks.removeAt(0)(second);
    expect(first.debugDisposed, isFalse);
    expect(container.imageNotifier.value, same(second));
    await tester.pump();
    expect(first.debugDisposed, isTrue);
    expect(second.debugDisposed, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    expect(second.debugDisposed, isTrue);
  });

  testWidgets('late frame cannot replace the newer image or its dimensions',
      (tester) async {
    final callbacks = <ui.ImageDecoderCallback>[];
    final container = ImageContainer(
        decoder: (pixels, width, height, callback) => callbacks.add(callback));
    container.push(Uint32List(1), 1, 1, 320, displayHeight: 242);
    container.push(Uint32List(1), 1, 1, 256, displayHeight: 224);
    final older = _image(), newer = _image();
    callbacks[1](newer);
    callbacks[0](older);
    expect(older.debugDisposed, isTrue);
    expect(container.imageNotifier.value, same(newer));
    expect(container.displayWidthNotifier.value, 256);
    expect(container.displayHeightNotifier.value, 224);
    container.dispose();
  });

  testWidgets('completion after disposal releases the pending image',
      (tester) async {
    late ui.ImageDecoderCallback callback;
    final container =
        ImageContainer(decoder: (pixels, width, height, cb) => callback = cb);
    container.push(Uint32List(1), 1, 1, 320);
    container.dispose();
    final pending = _image();
    callback(pending);
    expect(pending.debugDisposed, isTrue);
    expect(container.image, isNull);
  });
}
