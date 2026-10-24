// Uses production image, audio and game-view components for an onscreen probe.
// flutter build linux --release --target tool/controller_gui_bench.dart
// Run the bundle executable with the same arguments as controller_bench.dart.
import 'package:flutter/material.dart';

import 'package:fnesemu/gui/core_view.dart';
import 'package:fnesemu/gui/sound_player.dart';
import 'package:fnesemu/gui/ticker_image.dart';
import '../packages/fnesemu_core/tool/controller_bench.dart' as bench;

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final images = ImageContainer();
  final sound = SoundPlayer();
  runApp(const MaterialApp(
      home: Scaffold(body: Center(child: Text('Preparing benchmark')))));
  await bench.runControllerBench(args, onReady: (controller) async {
    await sound.resume();
    runApp(MaterialApp(
        home: Scaffold(
            appBar: AppBar(
                title: StreamBuilder<double>(
                    stream: controller.fpsStream,
                    builder: (context, snapshot) => Text(
                        'Controller benchmark  ${(snapshot.data ?? 0).toStringAsFixed(1).padLeft(4)} FPS'))),
            body: CoreView(controller: controller, container: images))));
    await WidgetsBinding.instance.endOfFrame;
  }, onAudio: (audio) {
    sound.push(audio.buffer, audio.sampleRate, audio.channels);
  }, onImage: (image) {
    images.push(image.buffer, image.width, image.height, image.displayWidth,
        displayHeight: image.displayHeight);
  });
}
