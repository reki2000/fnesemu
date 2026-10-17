/// Creates Flutter images from 32-bit RGBA pixel buffers.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'src/pixel_bytes_io.dart'
    if (dart.library.js_interop) 'src/pixel_bytes_web.dart';

/// Decodes [pixels], one pixel per element with bytes in memory order R, G,
/// B, A, into an image of [width] x [height].
void decodePixelImage(Uint32List pixels, int width, int height,
        ui.ImageDecoderCallback callback) =>
    ui.decodeImageFromPixels(
        pixelBytes(pixels), width, height, ui.PixelFormat.rgba8888, callback);
