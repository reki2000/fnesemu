import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fnesemu/core/ps/bus.dart';
import 'package:fnesemu/core/ps/gpu/gpu.dart';
import 'package:fnesemu/util/uint8list.dart';

import '../core/ps/r3000/r3000.dart';

Uint8List getARGBImageData(Uint8List frameBuffer) {
  final result = Uint8List(1024 * 512 * 4);

  for (int y = 0; y < 512; y++) {
    for (int x = 0; x < 1024; x++) {
      final offset = y * 2048 + x * 2;
      final c16 = frameBuffer.getUInt16LE(offset);

      // Convert 15-bit color to RGB
      final r = (c16 & 0x1F) << 3;
      final g = ((c16 >> 5) & 0x1F) << 3;
      final b = ((c16 >> 10) & 0x1F) << 3;

      // Set ARGB bytes
      final destOffset = (y * 1024 + x) * 4;
      result[destOffset + 0] = r; // B
      result[destOffset + 1] = g; // G
      result[destOffset + 2] = b; // R
      result[destOffset + 3] = 255; // A (fully opaque)
    }
  }

  return result;
}

// Main application class
class PSGpuApp extends StatefulWidget {
  const PSGpuApp({super.key});

  @override
  State<PSGpuApp> createState() => _PSGpuAppState();
}

class _PSGpuAppState extends State<PSGpuApp> {
  late Gpu gpu;
  late Uint8List imageData;
  ui.Image? renderedImage;

  // Test parameters
  int cmd = 0x30; // Gouraud polygon command

  // Triangle vertices (x,y coordinates, packed as y<<16|x)
  int v0 = 100 | (100 << 16); // Top left
  int v1 = 500 | (100 << 16); // Top right
  int v2 = 300 | (400 << 16); // Bottom center

  // Colors for each vertex (RGB format)
  int c0 = 0xFF0000; // Red
  int c1 = 0x00FF00; // Green
  int c2 = 0x0000FF; // Blue

  @override
  void initState() {
    super.initState();
    // Initialize GPU
    final bus = Bus();
    bus.cpu = R3000(bus);
    gpu = Gpu(bus);

    initGpu();

    const log = """
flutter: GPU0:renderGouraud (0,0:00fffff), (640,0:00ffffff), (640,480:00ffffff) offset:0,0 area:0,0-839,479  pc:80050b20 clk:391:111:259364618
flutter: GPU0:renderGouraud (672,32:00ff2599), (726,35:002d0517), (727,44:002d0517) offset:0,0 area:0,0-839,479  pc:80050b20 clk:391:111:259364618
flutter: GPU0:renderGouraud (723,27:002d0517), (672,32:00ff2599), (726,35:002d0517) offset:0,0 area:0,0-839,479  pc:80050b20 clk:391:111:259364912
flutter: GPU0:renderGouraud (719,20:002d0517), (723,27:002d0517), (672,32:00ff2599) offset:0,0 area:0,0-839,479  pc:80050b20 clk:391:111:259365206
flutter: GPU0:renderGouraud (714,13:002d0517), (719,20:002d0517), (672,32:00ff2599) offset:0,0 area:0,0-839,479  pc:80050b20 clk:391:112:259365500
flutter: GPU0:renderGouraud (707,8:002d0517), (714,13:002d0517), (672,32:00ff2599) offset:0,0 area:0,0-839,479  pc:80050b20 clk:391:112:259365794
flutter: GPU0:renderGouraud (700,4:002d0517), (707,8:002d0517), (672,32:00ff2599) offset:0,0 area:0,0-839,479  pc:80050b20 clk:391:112:259366088
flutter: GPU0:renderGouraud (692,1:002d0517), (700,4:002d0517), (672,32:00ff2599) offset:0,0 area:0,0-839,479  pc:80050b20 clk:391:112:259366382
flutter: GPU0:renderGouraud (692,1:002d0517), (684,1:002d0517), (672,32:00ff2599) offset:0,0 area:0,0-839,479  pc:80050b20 clk:391:112:259366676
flutter: GPU0:renderGouraud (684,1:002d0517), (675,1:002d0517), (672,32:00ff2599) offset:0,0 area:0,0-839,479  pc:80050b20 clk:391:112:259366970
flutter: GPU0:renderGouraud (675,1:002d0517), (667,4:002d0517), (672,32:00ff2599) offset:0,0 area:0,0-839,479  pc:80050b20 clk:391:112:259367264
flutter: GPU0:renderGouraud (667,4:002d0517), (660,8:002d0517), (672,32:00ff2599) offset:0,0 area:0,0-839,479  pc:80050b20 clk:391:113:259367558
flutter: GPU0:renderGouraud (660,8:002d0517), (653,13:002d0517), (672,32:00ff2599) offset:0,0 area:0,0-839,479  pc:80050b20 clk:391:113:259367852
flutter: GPU0:renderGouraud (653,13:002d0517), (648,20:002d0517), (672,32:00ff2599) offset:0,0 area:0,0-839,479  pc:80050b20 clk:391:113:259368146
flutter: GPU0:renderGouraud (648,20:002d0517), (644,27:002d0517), (672,32:00ff2599) offset:0,0 area:0,0-839,479  pc:80050b20 clk:391:113:259368440
flutter: GPU0:renderGouraud (644,27:002d0517), (672,32:00ff2599), (641,35:002d0517) offset:0,0 area:0,0-839,479  pc:80050b20 clk:391:113:259368734
flutter: GPU0:renderGouraud (672,32:00ff2599), (641,35:002d0517), (641,44:002d0517) offset:0,0 area:0,0-839,479  pc:80050b20 clk:391:113:259369028
flutter: GPU0:renderGouraud (672,32:00ff2599), (641,44:002d0517), (641,52:002d0517) offset:0,0 area:0,0-839,479  pc:80050b20 clk:391:113:259369322
flutter: GPU0:renderGouraud (672,32:00ff2599), (641,52:002d0517), (644,60:002d0517) offset:0,0 area:0,0-839,479  pc:80050b20 clk:391:114:259369616
flutter: GPU0:renderGouraud (672,32:00ff2599), (644,60:002d0517), (648,67:002d0517) offset:0,0 area:0,0-839,479  pc:80050b20 clk:391:114:259369910
flutter: GPU0:renderGouraud (672,32:00ff2599), (648,67:002d0517), (653,74:002d0517) offset:0,0 area:0,0-839,479  pc:80050b20 clk:391:114:259370204
flutter: GPU0:renderGouraud (672,32:00ff2599), (653,74:002d0517), (660,79:002d0517) offset:0,0 area:0,0-839,479  pc:80050b20 clk:391:114:259370498
flutter: GPU0:renderGouraud (672,32:00ff2599), (660,79:002d0517), (667,83:002d0517) offset:0,0 area:0,0-839,479  pc:80050b20 clk:391:114:259370792
flutter: GPU0:renderGouraud (672,32:00ff2599), (667,83:002d0517), (675,86:002d0517) offset:0,0 area:0,0-839,479  pc:80050b20 clk:391:114:259371086 
flutter: GPU0:renderGouraud (672,32:00ff2599), (675,86:002d0517), (684,87:002d0517) offset:0,0 area:0,0-839,479  pc:80050b20 clk:391:114:259371380
flutter: GPU0:renderGouraud (672,32:00ff2599), (692,86:002d0517), (684,87:002d0517) offset:0,0 area:0,0-839,479  pc:80050b20 clk:391:114:259371674
flutter: GPU0:renderGouraud (672,32:00ff2599), (700,83:002d0517), (692,86:002d0517) offset:0,0 area:0,0-839,479  pc:80050b20 clk:391:115:259371968
flutter: GPU0:renderGouraud (672,32:00ff2599), (707,79:002d0517), (700,83:002d0517) offset:0,0 area:0,0-839,479  pc:80050b20 clk:391:115:259372262
flutter: GPU0:renderGouraud (672,32:00ff2599), (714,74:002d0517), (707,79:002d0517) offset:0,0 area:0,0-839,479  pc:80050b20 clk:391:115:259372556
flutter: GPU0:renderGouraud (672,32:00ff2599), (719,67:002d0517), (714,74:002d0517) offset:0,0 area:0,0-839,479  pc:80050b20 clk:391:115:259372850
flutter: GPU0:renderGouraud (672,32:00ff2599), (723,60:002d0517), (719,67:002d0517) offset:0,0 area:0,0-839,479  pc:80050b20 clk:391:115:259373144
flutter: GPU0:renderGouraud (672,32:00ff2599), (726,52:002d0517), (723,60:002d0517) offset:0,0 area:0,0-839,479  pc:80050b20 clk:391:115:259373438
flutter: GPU0:renderGouraud (672,32:00ff2599), (727,44:002d0517), (726,52:002d0517) offset:0,0 area:0,0-839,479  pc:80050b20 clk:391:115:259373732
""";

    // Parse log and extract triangle data
    final logLines = log.split('\n');

    for (var line in logLines) {
      if (!line.contains('renderGouraud')) continue;
      if (line.startsWith('#')) continue; // Skip commented lines"))

      // Extract values using regular expression
      final regex =
          r'renderGouraud\s+\((\d+),(\d+):([0-9a-f]+)\),\s+\((\d+),(\d+):([0-9a-f]+)\),\s+\((\d+),(\d+):([0-9a-f]+)\)';
      final match = RegExp(regex).firstMatch(line);

      if (match != null) {
        v0 = int.parse(match.group(1)!) | (int.parse(match.group(2)!) << 16);
        c0 = int.parse(match.group(3)!, radix: 16);
        v1 = int.parse(match.group(4)!) | (int.parse(match.group(5)!) << 16);
        c1 = int.parse(match.group(6)!, radix: 16);
        v2 = int.parse(match.group(7)!) | (int.parse(match.group(8)!) << 16);
        c2 = int.parse(match.group(9)!, radix: 16);
        renderPolygon();
      }
    }
  }

  void initGpu() {
    // Reset GPU state
    gpu.reset();
    gpu.drawingX1 = 0;
    gpu.drawingX2 = 1024;
    gpu.drawingY1 = 0;
    gpu.drawingY2 = 512;
  }

  void renderPolygon() {
    // Render the Gouraud polygon
    gpu.renderGouraudPolygon(cmd, c0, v0, c1, v1, c2, v2);

    imageData = getARGBImageData(gpu.frameBuffer);

    ui.decodeImageFromPixels(
      imageData,
      1024,
      512,
      ui.PixelFormat.rgba8888,
      (ui.Image img) {
        if (mounted) {
          setState(() {
            renderedImage = img;
          });
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('PS GPU Gouraud Polygon Renderer Test'),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Text('Rendering Gouraud triangle with vertices:'),
          ),
          Padding(
              padding: const EdgeInsets.all(8.0),
              child: Text(
                  'V0: (${v0 & 0x3ff}, ${v0 >> 16 & 0x1ff}) - Color: 0x${c0.toRadixString(16)}\n'
                  'V1: (${v1 & 0x3ff}, ${v1 >> 16 & 0x1ff}) - Color: 0x${c1.toRadixString(16)}\n'
                  'V2: (${v2 & 0x3ff}, ${v2 >> 16 & 0x1ff}) - Color: 0x${c2.toRadixString(16)}')),
          InteractiveViewer(
            boundaryMargin: EdgeInsets.all(20.0),
            minScale: 0.1,
            maxScale: 4.0,
            child: renderedImage != null
                ? RawImage(
                    image: renderedImage,
                    width: 1024.0,
                    height: 512.0,
                  )
                : const Center(child: CircularProgressIndicator()),
          ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton(
                  onPressed: () {
                    // Create a new random triangle
                    setState(() {
                      v0 = (100 +
                              (DateTime.now().millisecondsSinceEpoch % 300)) |
                          ((100 +
                                  (DateTime.now().millisecondsSinceEpoch %
                                      100)) <<
                              16);
                      v1 = (400 +
                              (DateTime.now().millisecondsSinceEpoch % 200)) |
                          ((100 +
                                  (DateTime.now().millisecondsSinceEpoch %
                                      50)) <<
                              16);
                      v2 = (250 +
                              (DateTime.now().millisecondsSinceEpoch % 200)) |
                          ((350 +
                                  (DateTime.now().millisecondsSinceEpoch %
                                      50)) <<
                              16);
                      renderPolygon();
                    });
                  },
                  child: Text('Random Triangle'),
                ),
                ElevatedButton(
                  onPressed: () {
                    // Cycle through some predefined color schemes
                    setState(() {
                      c0 = 0xFF0000;
                      c1 = 0x00FF00;
                      c2 = 0x0000FF;
                      renderPolygon();
                    });
                  },
                  child: Text('RGB Colors'),
                ),
                ElevatedButton(
                  onPressed: () {
                    setState(() {
                      c0 = 0xFF00FF;
                      c1 = 0xFFFF00;
                      c2 = 0x00FFFF;
                      renderPolygon();
                    });
                  },
                  child: Text('CMY Colors'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  runApp(MaterialApp(
    title: 'PS GPU Gouraud Polygon Renderer',
    theme: ThemeData(
      primarySwatch: Colors.blue,
      visualDensity: VisualDensity.adaptivePlatformDensity,
    ),
    home: const PSGpuApp(),
  ));
}
