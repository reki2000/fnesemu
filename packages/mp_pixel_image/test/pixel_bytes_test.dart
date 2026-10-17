import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:mp_pixel_image/mp_pixel_image.dart';
import 'package:mp_pixel_image/src/pixel_bytes_io.dart'
    if (dart.library.js_interop) 'package:mp_pixel_image/src/pixel_bytes_web.dart';

void main() {
  test('pixels keep their memory byte order', () {
    final pixels = Uint32List.fromList([0x04030201, 0x08070605]);
    expect(pixelBytes(pixels), [1, 2, 3, 4, 5, 6, 7, 8]);
  });

  test('a view covers only its own pixels', () {
    final frame = Uint32List.fromList([0x04030201, 0x08070605, 0x0c0b0a09]);
    final view = Uint32List.sublistView(frame, 1, 2);
    expect(pixelBytes(view), [5, 6, 7, 8]);
  });

  testWidgets('a decoded image has the given size', (tester) async {
    final image = await tester.runAsync(() {
      final completer = Completer<ui.Image>();
      decodePixelImage(Uint32List(6), 3, 2, completer.complete);
      return completer.future;
    });
    expect(image!.width, 3);
    expect(image.height, 2);
    image.dispose();
  });
}
