import 'package:flutter/material.dart';

// Package imports:
import 'package:file_picker/file_picker.dart';

// Project imports:
import 'debug/debug_controller.dart';
import 'nes_controller.dart';
import 'nes_view.dart';
import 'sound_player.dart';

class MyApp extends StatelessWidget {
  final String title;
  const MyApp({Key? key, required this.title}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
        title: title,
        theme: ThemeData(
          primarySwatch: Colors.blue,
        ),
        home: const MainPage());
  }
}

class MainPage extends StatefulWidget {
  const MainPage({Key? key}) : super(key: key);

  @override
  _MainPageState createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  final _mPlayer = SoundPlayer();
  final controller = NesController();

  String _romName = "";
  bool _isRunning = false;

  @override
  void initState() {
    super.initState();
    (() async {
      await for (final buf in controller.audioStream) {
        _mPlayer.push(buf, controller.apuClock);
      }
    })();
  }

  @override
  void dispose() {
    _mPlayer.dispose();
    super.dispose();
  }

  void _reset() async {
    controller.reset();
  }

  void _setFile() async {
    _mPlayer.resume();
    final picked = await FilePicker.platform.pickFiles(withData: true);
    if (picked != null) {
      _reset();
      try {
        controller.setRom(picked.files.first.bytes!);
        setState(() {
          _romName = picked.files.first.name;
          _isRunning = true;
        });
        controller.run();
      } catch (e) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar:
          AppBar(leading: const SizedBox(), title: Text(_romName), actions: [
        // file load button
        IconButton(
            icon: const Icon(Icons.file_open_outlined),
            tooltip: "Load ROM",
            onPressed: _setFile),

        // run / pause button
        _isRunning
            ? IconButton(
                icon: const Icon(Icons.pause),
                tooltip: "Pause",
                onPressed: () async {
                  controller.stop();
                  setState(() {
                    _isRunning = false;
                  });
                })
            : IconButton(
                icon: const Icon(Icons.play_arrow),
                tooltip: "Run",
                onPressed: () async {
                  controller.run();
                  setState(() {
                    _isRunning = true;
                  });
                }),
        // reset button
        IconButton(
            icon: const Icon(Icons.restart_alt),
            tooltip: "Reset",
            onPressed: _reset),
        // debug on/off button
        controller.debugOption.showDebugView
            ? IconButton(
                icon: const Icon(Icons.bug_report_outlined),
                tooltip: "Disable Debug Options",
                onPressed: () => setState(() {
                      controller.debugOption =
                          controller.debugOption.copyWith(showDebugView: false);
                    }))
            : IconButton(
                icon: const Icon(Icons.bug_report),
                tooltip: "Enable Debug Options",
                onPressed: () => setState(() {
                      controller.debugOption =
                          controller.debugOption.copyWith(showDebugView: true);
                    })),
      ]),
      body: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          // main view
          NesView(controller: controller),

          // debug view if enabled
          if (controller.debugOption.showDebugView)
            DebugController(controller: controller),
        ],
      ),
    );
  }
}
