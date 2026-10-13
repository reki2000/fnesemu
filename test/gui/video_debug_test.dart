import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_test/flutter_test.dart';
import 'package:fnesemu/gui/core_view.dart';
import 'package:fnesemu/gui/debug/debug_pane.dart';
import 'package:fnesemu/gui/debug/game_layout.dart';
import 'package:fnesemu/gui/debug/video.dart';
import 'package:fnesemu/gui/ticker_image.dart';
import 'package:fnesemu_core/app_api.dart';

class _VideoCore extends Core {
  final bool patterns, largeBitmap;
  _VideoCore({this.patterns = true, this.largeBitmap = false});
  @override
  List<CpuInfo> get cpuInfos => const [CpuInfo(7, 'Video CPU', 16)];
  @override
  bool get hasPatternTables => patterns;
  @override
  List<DebugVideoLayer> get videoLayers => [
        for (final name in ['BG layer', 'Second BG', 'Sprite layer'])
          DebugVideoLayer(
              name,
              (map) => DebugRaster(
                  ImageBuffer(
                      largeBitmap
                          ? 400
                          : map
                              ? 4
                              : 2,
                      largeBitmap ? 400 : 2,
                      Uint8List(
                          largeBitmap ? 400 * 400 * 4 : (map ? 4 : 2) * 2 * 4)),
                  patterns: [DebugOutline.rect(0, 0, 2, 2, label: '1')],
                  viewports: [DebugOutline.rect(0, 0, 1, 1)]),
              kind: name == 'Sprite layer'
                  ? DebugLayerKind.sprites
                  : DebugLayerKind.background,
              hasMap: name == 'BG layer',
              originalBackground: 0xff000000,
              alternativeBackground: 0xffffffff),
      ];
  @override
  List<DebugPatternTable> get patternTables => patterns
      ? [
          for (final name in ['BG patterns', 'Sprite patterns'])
            DebugPatternTable(name,
                kind: name == 'Sprite patterns'
                    ? DebugLayerKind.sprites
                    : DebugLayerKind.background,
                count: 1,
                colorCount: 4,
                readPixel: (_, x, y) => x % 4,
                palettes: [
                  DebugPalette('$name palette',
                      [0xff000000, 0xff0000ff, 0xff00ff00, 0xffff0000])
                ]),
        ]
      : [];
}

class _PatternLayoutCore extends _VideoCore {
  @override
  List<DebugPatternTable> get patternTables => [
        for (final entry in [
          ('BG A', 128),
          ('BG B', 128),
          ('BG C', 256),
          ('BG D', 128),
          ('OBJ', 128)
        ])
          DebugPatternTable(entry.$1,
              kind: entry.$1 == 'OBJ'
                  ? DebugLayerKind.sprites
                  : DebugLayerKind.background,
              width: entry.$2,
              count: 1,
              colorCount: 2,
              readPixel: (_, x, y) => 1),
      ];
}

class _PatternRowsCore extends _VideoCore {
  @override
  List<DebugPatternTable> get patternTables => [
        for (var bg = 0; bg < 4; bg++)
          DebugPatternTable('BG$bg',
              row: bg ~/ 2,
              width: 512,
              count: 1,
              colorCount: 2,
              readPixel: (_, x, y) => 1),
      ];
}

class _LayerRowsCore extends _VideoCore {
  @override
  List<DebugVideoLayer> get videoLayers => [
        for (final entry in [
          ('Top A', 0),
          ('Top B', 0),
          ('Middle A', 1),
          ('Middle B', 1),
          ('Rotation', 2),
          ('Sprites', 3)
        ])
          DebugVideoLayer(entry.$1,
              (_) => DebugRaster(ImageBuffer(8, 8, Uint8List(8 * 8 * 4))),
              row: entry.$2,
              kind: entry.$2 == 3
                  ? DebugLayerKind.sprites
                  : DebugLayerKind.background),
      ];
}

void main() {
  testWidgets(
      'tabs show all layers and both pattern sources with shared controls',
      (tester) async {
    final debugger = Debugger(_VideoCore())..setDebugView(true);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
                width: 440,
                height: 640,
                child: DebugPane(debugger: debugger)))));
    expect(find.text('ViewPort'), findsOneWidget);
    expect(find.text('Screen'), findsOneWidget);
    expect(tester.getCenter(find.text('Screen')).dy,
        tester.getCenter(find.text('ViewPort')).dy);
    await tester.tap(find.text('Screen'));
    await tester.pump();
    expect(debugger.state.view, DebugView.layers);
    expect(debugger.state.layerView, LayerView.map);
    await tester.tap(find.text('ViewPort'));
    await tester.pump();
    expect(find.text('BG layer'), findsOneWidget);
    expect(find.text('Sprite layer'), findsOneWidget);
    expect(tester.getTopLeft(find.text('BG layer')).dy,
        tester.getTopLeft(find.text('Second BG')).dy);
    expect(tester.getTopLeft(find.text('Second BG')).dx,
        greaterThan(tester.getTopLeft(find.text('BG layer')).dx));
    expect(
        tester.getRect(find.byKey(const ValueKey('debug-sprite-layers'))).top,
        greaterThanOrEqualTo(tester
            .getRect(find.byKey(const ValueKey('debug-background-layers')))
            .bottom));
    expect(find.byTooltip('Next palette'), findsNothing);
    await tester.tap(find.text('Live rendering'));
    await tester.pump();
    expect(debugger.state.videoLive, true);

    await tester.tap(find.text('Screen'));
    await tester.pump();
    expect(debugger.state.layerView, LayerView.map);
    expect(debugger.state.videoPanels.first.raster.image.width, 4);
    expect(debugger.state.videoPanels.last.raster.image.width, 2);
    await tester.tap(find.text('BG Color'));
    await tester.pump();
    expect(debugger.state.alternativeBackground, true);
    await tester.tap(find.text('No.'));
    await tester.pump();
    expect(debugger.state.patternNumbers, true);
    expect(find.byType(DropdownButton<double>), findsNothing);
    final slider =
        tester.widget<Slider>(find.byKey(const ValueKey('debug-video-scale')));
    slider.onChanged!(2);
    await tester.pump();
    final raster = find
        .descendant(
            of: find.byType(DebugVideoImages),
            matching: find.byType(CustomPaint))
        .first;
    expect(tester.getSize(raster).width,
        debugger.state.videoPanels.first.raster.image.width * 2);

    await tester.tap(find.text('Patterns'));
    await tester.pump();
    expect(find.text('BG patterns'), findsOneWidget);
    expect(find.text('Live rendering'), findsOneWidget);
    for (final size in [16, 32, 8]) {
      await tester.tap(find.text('$size×$size'));
      await tester.pump();
      expect(debugger.state.patternBlockSize, size);
    }

    expect(find.text('Sprite patterns'), findsOneWidget);
    await tester.tap(find.byTooltip('Next palette'));
    await tester.pump();
    expect(debugger.state.videoPanels.map((p) => p.paletteName),
        ['BG patterns palette', 'Sprite patterns palette']);
    await tester.tap(find.byTooltip('Previous palette'));
    await tester.pump();
    expect(debugger.state.videoPanels.map((p) => p.paletteName),
        ['Grayscale', 'Grayscale']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('framebuffer-only core retains CPU tab and hides pattern tab',
      (tester) async {
    final debugger = Debugger(_VideoCore(patterns: false))..setDebugView(true);
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: DebugPane(debugger: debugger))));
    expect(find.text('CPU'), findsOneWidget);
    expect(find.text('ViewPort'), findsOneWidget);
    expect(find.text('Patterns'), findsNothing);
    await tester.tap(find.text('ViewPort'));
    await tester.pump();
    expect(find.byTooltip('Next palette'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('divider retains absolute width after window resize',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final preference = ValueNotifier<double?>(null);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: DebugGameLayout(
                gameAspect: 4 / 3,
                paneWidth: preference,
                game: (_, showPad, maxWidth) => const SizedBox.expand(),
                panel: const Text('inspector'),
                dump: SingleChildScrollView(
                    key: const ValueKey('dump-scroll'),
                    child: SelectableText(
                        List.filled(100, 'register dump').join('\n')))))));
    await tester.pump();
    expect(preference.value, 640);
    await tester.drag(
        find.byKey(const ValueKey('debug-divider')), const Offset(-100, 0));
    await tester.pump();
    final scroll = find
        .descendant(
            of: find.byKey(const ValueKey('dump-scroll')),
            matching: find.byType(Scrollable))
        .first;
    final scrollState = tester.state<ScrollableState>(scroll);
    expect(scrollState.position.maxScrollExtent, greaterThan(0));
    await tester.drag(
        find.byKey(const ValueKey('dump-scroll')), const Offset(0, -60));
    await tester.pump();
    expect(scrollState.position.pixels, greaterThan(0));
    final width = preference.value!;
    expect(width, lessThan(640));
    tester.view.physicalSize = const Size(1000, 600);
    await tester.pump();
    expect(tester.getSize(find.byKey(const ValueKey('debug-game-area'))).width,
        width);
    expect(preference.value, width);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    preference.dispose();
  });

  testWidgets('hover magnifier is 300 pixels and uses the farthest corner',
      (tester) async {
    final debugger = Debugger(_VideoCore())
      ..setDebugView(true)
      ..selectView(DebugView.layers);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
                width: 440,
                height: 500,
                child: DebugPane(debugger: debugger)))));
    await tester.pump();
    final bitmap = find
        .descendant(
            of: find.byType(DebugVideoImages),
            matching: find.byType(CustomPaint))
        .first;
    final mouse = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getTopLeft(bitmap) + const Offset(0.5, 0.5));
    await tester.pump();
    final popup = find.byKey(const ValueKey('video-magnifier'));
    expect(popup, findsOneWidget);
    expect(tester.getSize(popup), const Size(300, 300));
    final area = tester.getRect(find.byType(DebugPane));
    final cursor = tester.getTopLeft(bitmap) + const Offset(0.5, 0.5);
    final corner = tester.getRect(popup).center;
    expect(corner.dx < area.center.dx, cursor.dx >= area.center.dx);
    expect(corner.dy < area.center.dy, cursor.dy >= area.center.dy);
    await mouse.moveTo(const Offset(700, 550));
    await tester.pump();
    expect(popup, findsNothing);
    expect(tester.takeException(), isNull);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'magnifier keeps its vertical corner and flips only when the cursor crosses to its side',
      (tester) async {
    final debugger = Debugger(_VideoCore(largeBitmap: true))
      ..setDebugView(true)
      ..selectView(DebugView.layers);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
                width: 440,
                height: 500,
                child: DebugPane(debugger: debugger)))));
    await tester.pump();
    final bitmap = find
        .descendant(
            of: find.byType(DebugVideoImages),
            matching: find.byType(CustomPaint))
        .first;
    final mouse = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    final source = tester.getRect(bitmap),
        area = tester.getRect(find.byType(DebugPane));
    await mouse.moveTo(source.topLeft + const Offset(10, 10));
    await tester.pumpAndSettle();
    final popup = find.byKey(const ValueKey('video-magnifier'));
    final first = tester.getRect(popup);
    final lowY = area.bottom - 15;
    await mouse.moveTo(Offset(source.left + 10, lowY));
    await tester.pumpAndSettle();
    expect(tester.getRect(popup), first);
    await mouse.moveTo(Offset(area.right - 60, lowY));
    await tester.pumpAndSettle();
    final flipped = tester.getRect(popup);
    expect(flipped.left, lessThan(first.left));
    expect(flipped.top, first.top);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'BG pattern tables fill rows up to 512 source pixels and sprites follow below',
      (tester) async {
    final debugger = Debugger(_PatternLayoutCore())
      ..setDebugView(true)
      ..selectView(DebugView.patterns);
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: DebugPane(debugger: debugger))));
    await tester.pump();
    final first = tester.getTopLeft(find.text('BG A'));
    expect(tester.getTopLeft(find.text('BG B')).dy, first.dy);
    expect(tester.getTopLeft(find.text('BG C')).dy, first.dy);
    expect(tester.getTopLeft(find.text('BG C')).dx,
        greaterThan(tester.getTopLeft(find.text('BG B')).dx));
    expect(tester.getTopLeft(find.text('BG D')).dy, greaterThan(first.dy));
    expect(tester.getTopLeft(find.text('OBJ')).dy,
        greaterThan(tester.getTopLeft(find.text('BG D')).dy));
    tester
        .widget<Slider>(find.byKey(const ValueKey('debug-video-scale')))
        .onChanged!(2);
    await tester.pump();
    expect(tester.getTopLeft(find.text('BG A')).dy,
        tester.getTopLeft(find.text('BG C')).dy);
    expect(tester.getTopLeft(find.text('BG D')).dy,
        greaterThan(tester.getTopLeft(find.text('BG C')).dy));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('pattern rows preserve core-owned BG pairs at every zoom',
      (tester) async {
    final debugger = Debugger(_PatternRowsCore())
      ..setDebugView(true)
      ..selectView(DebugView.patterns);
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: DebugPane(debugger: debugger))));
    void expectPairs() {
      final first = tester.getTopLeft(find.text('BG0'));
      final second = tester.getTopLeft(find.text('BG2'));
      expect(tester.getTopLeft(find.text('BG1')).dy, first.dy);
      expect(tester.getTopLeft(find.text('BG1')).dx, greaterThan(first.dx));
      expect(tester.getTopLeft(find.text('BG3')).dy, second.dy);
      expect(tester.getTopLeft(find.text('BG3')).dx, greaterThan(second.dx));
      expect(second.dy, greaterThan(first.dy));
    }

    expectPairs();
    tester
        .widget<Slider>(find.byKey(const ValueKey('debug-video-scale')))
        .onChanged!(2);
    await tester.pump();
    expectPairs();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'layer rows follow core metadata without system-specific GUI rules',
      (tester) async {
    final debugger = Debugger(_LayerRowsCore())
      ..setDebugView(true)
      ..selectView(DebugView.layers);
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: DebugPane(debugger: debugger))));
    await tester.pump();
    expect(tester.getTopLeft(find.text('Top A')).dy,
        tester.getTopLeft(find.text('Top B')).dy);
    expect(tester.getTopLeft(find.text('Middle A')).dy,
        tester.getTopLeft(find.text('Middle B')).dy);
    expect(tester.getTopLeft(find.text('Middle A')).dy,
        greaterThan(tester.getTopLeft(find.text('Top A')).dy));
    expect(tester.getTopLeft(find.text('Rotation')).dy,
        greaterThan(tester.getTopLeft(find.text('Middle A')).dy));
    expect(tester.getTopLeft(find.text('Sprites')).dy,
        greaterThan(tester.getTopLeft(find.text('Rotation')).dy));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('magnifier enlarges annotations already in the bitmap',
      (tester) async {
    final raster = DebugRaster(ImageBuffer(64, 64, Uint8List(64 * 64 * 4)),
            patterns: [DebugOutline.rect(16, 16, 8, 8, label: '7')],
            viewports: [DebugOutline.rect(32, 16, 8, 8)])
        .annotated(numbers: true, bounds: true, viewport: true);
    final hover = VideoHover(
        raster, 0xff000000, const Offset(32, 32), Offset.zero, () => null);
    const key = ValueKey('magnifier-render');
    Future<Uint8List> render() async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Align(
                  alignment: Alignment.topLeft,
                  child: RepaintBoundary(
                      key: key, child: VideoMagnifier(hover: hover))))));
      await tester.pump();
      final boundary =
          tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
      return (await tester.runAsync(() async {
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        final pixels = Uint8List.fromList(data!.buffer.asUint8List());
        image.dispose();
        return pixels;
      }))!;
    }

    final pixels = await render();
    expect(pixels.length, 300 * 300 * 4);
    final orange = (115 * 300 + 124) * 4;
    expect(pixels.sublist(orange, orange + 4), [127, 85, 0, 255]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final size in [
    const Size(320, 640),
    const Size(640, 320),
    const Size(1200, 700)
  ]) {
    testWidgets(
        'debug panel follows controls and scrolls without overflow at $size',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = CoreController((_) {}, (_) {}, (_) {}, Sram());
      controller.debugger.setCore(_VideoCore());
      controller.debugger.setDebugView(true);
      final image = ImageContainer();
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: DebugGameLayout(
                  gameAspect: 4 / 3,
                  game: (portrait, showPad, maxWidth) => CoreView(
                      controller: controller,
                      container: image,
                      portrait: portrait,
                      showPad: showPad,
                      maxImageWidth: maxWidth),
                  dump: const SelectableText('dump contents'),
                  panel: DebugPane(
                      debugger: controller.debugger,
                      controller: controller)))));
      final coreView = tester.widget<CoreView>(find.byType(CoreView));
      if (size.height > size.width) {
        expect(find.byKey(const ValueKey('debug-tabs-area')), findsNothing);
        expect(coreView.showPad, true);
        expect(find.text('dump contents'), findsNothing);
      } else {
        final game =
            tester.getRect(find.byKey(const ValueKey('debug-game-area')));
        final panel =
            tester.getRect(find.byKey(const ValueKey('debug-tabs-area')));
        expect(panel.left, greaterThanOrEqualTo(game.right));
        expect(coreView.showPad, false);
        expect(coreView.maxImageWidth, 640);
        expect(find.text('dump contents'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
