import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:fnesemu_core/app_api.dart';
import 'package:mp_gpu/mp_gpu.dart';
import 'package:render_frame_gpu/frame_renderer.dart';
import 'package:render_frame_gpu/render_frame_gpu.dart';

/// Draws a captured render frame on the GPU of the platform, times it and
/// compares it with the colors of the core's own renderer.
///
/// Arguments: the .rframe file, then optionally the number of timed draws
/// and an output directory for gpu.png. With --exit the app quits after the
/// report.
void main(List<String> args) {
  runApp(MaterialApp(home: FrameView(args)));
}

class FrameView extends StatefulWidget {
  const FrameView(this.args, {super.key});
  final List<String> args;

  @override
  State<FrameView> createState() => _FrameViewState();
}

class _FrameViewState extends State<FrameView> {
  ui.Image? _gpu, _reference;
  String _report = 'loading';

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final args = widget.args.where((a) => !a.startsWith('--')).toList();
    final path = args.isNotEmpty ? args[0] : Platform.environment['RFRAME'];
    if (path == null) {
      setState(
        () => _report = 'usage: <file.rframe> [draws] [out dir] [--exit]',
      );
      return;
    }
    final rounds = args.length > 1 ? int.parse(args[1]) : 100;
    final out = args.length > 2 ? args[2] : null;
    final frame = RenderFrame.decode(File(path).readAsBytesSync());
    final device = await GpuDevice.create();
    if (device == null) {
      stdout.writeln('no GPU');
      if (widget.args.contains('--exit')) exit(1);
      setState(() => _report = 'no GPU');
      return;
    }
    final renderer = await FrameRenderer.create(device);
    final target = device.target(frame.width, frame.height);

    final prepare = Stopwatch()..start();
    renderer.prepare(frame);
    final prepareMs = prepare.elapsedMicroseconds / 1000;

    // Each draw waits for the previous one, so the latency is per frame.
    final encode = <double>[], complete = <double>[];
    for (var i = 0; i < rounds + 10; i++) {
      final done = Completer<void>();
      final sw = Stopwatch()..start();
      renderer.draw(frame, target, onComplete: (_) => done.complete());
      final encoded = sw.elapsedMicroseconds / 1000;
      await done.future;
      if (i >= 10) {
        encode.add(encoded);
        complete.add(sw.elapsedMicroseconds / 1000);
      }
      await device.settle();
    }
    // Draws without waiting in between, then reads the last one back: the
    // time per draw when the GPU work overlaps the next encoding, with the
    // device settling at the end.
    final pipelined = Stopwatch()..start();
    for (var i = 0; i < rounds; i++) {
      renderer.draw(frame, target);
    }
    await device.settle();
    await device.read(target);
    final pipelinedMs = pipelined.elapsedMicroseconds / 1000 / rounds;

    // The pixels to compare and save come through a queue, which checks
    // that a read shows this draw: a plain read after many draws may show
    // an older state of the target on the GLES backend.
    final queue = await GpuQueue.create(device);
    Uint8List? pixels;
    for (var i = 0; i < 10 && queue != null && pixels == null; i++) {
      pixels = await queue.render(
        frame.width,
        frame.height,
        (target) => renderer.draw(frame, target),
      );
    }
    if (pixels == null) {
      stdout.writeln('cannot read the target');
      if (widget.args.contains('--exit')) exit(1);
      return;
    }

    final report = StringBuffer()
      ..writeln(device.name)
      ..writeln(
        '${frame.width}x${frame.height}, ${frame.triangleCount} triangles, '
        '${frame.batches.length} batches, ${frame.textures.length} textures',
      )
      ..writeln('texture upload ${prepareMs.toStringAsFixed(2)} ms')
      ..writeln('encode ms ${_stats(encode)}')
      ..writeln('submit to completion ms ${_stats(complete)}')
      ..writeln(
        'pipelined ms per draw, readback included ${pipelinedMs.toStringAsFixed(2)}',
      );
    final reference = frame.reference;
    if (reference != null) {
      var differing = 0, over16 = 0, maximum = 0;
      final rgba = Uint8List(reference.length * 4);
      for (var i = 0; i < reference.length; i++) {
        final c = reference[i];
        rgba[i * 4] = (c >> 16) & 255;
        rgba[i * 4 + 1] = (c >> 8) & 255;
        rgba[i * 4 + 2] = c & 255;
        rgba[i * 4 + 3] = 255;
        var d = 0;
        for (var k = 0; k < 3; k++) {
          final e = (pixels[i * 4 + k] - rgba[i * 4 + k]).abs();
          if (e > d) d = e;
        }
        if (d > 0) differing++;
        if (d > 16) over16++;
        if (d > maximum) maximum = d;
      }
      report.writeln(
        'versus the core renderer: $differing pixels differ, '
        '$over16 by more than 16, max $maximum',
      );
      _reference = await _decode(rgba, frame.width, frame.height);
    }
    // The path of a core that leaves its renders to the host: the sink
    // draws each frame and returns its pixels through onDrawn.
    final sink = await GpuFrameSink.create();
    if (sink != null) {
      final bytes = File(path).readAsBytesSync();
      final over = <int>[];
      var late = 0, dropped = 0;
      final roundTrip = Stopwatch()..start();
      for (var i = 0; i < rounds; i++) {
        // A new frame each time, as from a core: every tenth one with new
        // texel lists, the others with the lists of the first frame. Every
        // other frame draws nothing, so that pixels that come late show up.
        final blank = i.isOdd;
        final f = blank
            ? _copy(frame, batches: const [])
            : i % 20 == 0
            ? RenderFrame.decode(bytes)
            : _copy(frame);
        final drawn = Completer<Uint8List>();
        f.onDrawn = drawn.complete;
        sink.submit(f);
        // The sink drops a frame whose read shows an older one.
        final rgba = await drawn.future.timeout(
          const Duration(seconds: 1),
          onTimeout: () => Uint8List(0),
        );
        if (rgba.isEmpty) {
          dropped++;
        } else if (blank) {
          final c = frame.clearColor;
          if (rgba[0] != ((c >> 16) & 255) ||
              rgba[rgba.length - 2] != (c & 255)) {
            late++;
          }
        } else if (reference != null) {
          over.add(_over16(rgba, reference));
        }
      }
      over.sort();
      report.writeln(
        'sink ${(roundTrip.elapsedMicroseconds / 1000 / rounds).toStringAsFixed(2)} ms per frame, '
        'submit to pixels; $late blank frames read as drawn, $dropped dropped',
      );
      if (over.isNotEmpty) {
        report.writeln(
          'sink pixels off by more than 16 from the core renderer: '
          'min ${over.first} median ${over[over.length ~/ 2]} max ${over.last}, '
          '${over.where((n) => n > over.first * 1.2).length} of ${over.length} frames 20% above the minimum',
        );
      }
    }
    // The target keeps the blended alpha, which the PNG encoder would
    // divide the colors by; the colors are shown and saved as they are.
    final opaque = Uint8List.fromList(pixels);
    for (var i = 3; i < opaque.length; i += 4) {
      opaque[i] = 255;
    }
    final image = await _decode(opaque, frame.width, frame.height);
    if (out != null) {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$out/gpu.png').writeAsBytesSync(png!.buffer.asUint8List());
    }
    stdout.write(report);
    if (widget.args.contains('--exit')) exit(0);
    setState(() {
      _gpu = image;
      _report = report.toString();
    });
  }

  /// The pixels of [rgba] that differ from the ARGB [reference] by more
  /// than 16 in a channel.
  static int _over16(Uint8List rgba, Uint32List reference) {
    var count = 0;
    for (var i = 0; i < reference.length; i++) {
      final c = reference[i];
      if ((rgba[i * 4] - ((c >> 16) & 255)).abs() > 16 ||
          (rgba[i * 4 + 1] - ((c >> 8) & 255)).abs() > 16 ||
          (rgba[i * 4 + 2] - (c & 255)).abs() > 16) {
        count++;
      }
    }
    return count;
  }

  static RenderFrame _copy(RenderFrame f, {List<RenderBatch>? batches}) =>
      RenderFrame(
    width: f.width,
    height: f.height,
    clearColor: f.clearColor,
    clearDepth: f.clearDepth,
    depthScale: f.depthScale,
    vertices: f.vertices,
    batches: batches ?? f.batches,
    textures: f.textures,
    fogTable: f.fogTable,
    fogScale: f.fogScale,
    fogColor: f.fogColor,
    vertexFogColor: f.vertexFogColor,
    alphaReference: f.alphaReference,
  );

  static String _stats(List<double> values) {
    final sorted = [...values]..sort();
    final mean = values.reduce((a, b) => a + b) / values.length;
    return 'min ${sorted.first.toStringAsFixed(2)} median '
        '${sorted[sorted.length ~/ 2].toStringAsFixed(2)} mean ${mean.toStringAsFixed(2)}';
  }

  static Future<ui.Image> _decode(Uint8List rgba, int width, int height) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      width,
      height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        Text(_report),
        Expanded(
          child: Row(
            children: [
              for (final image in [_gpu, _reference])
                Expanded(
                  child: image == null
                      ? const SizedBox()
                      : RawImage(image: image),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}
