import 'package:flutter/material.dart';

// Package imports:
import 'package:file_picker/file_picker.dart';

// Project imports:
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
        home: const Scaffold(
          body: MainView(),
        ));
  }
}

class MainView extends StatefulWidget {
  const MainView({Key? key}) : super(key: key);

  @override
  State<MainView> createState() => _MainViewState();
}

class _MainViewState extends State<MainView> {
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
    setState(() {
      _isRunning = false;
    });
    _mPlayer.stop();
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
        });
      } catch (e) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Widget _button(String text, void Function() func) => Container(
      margin:
          const EdgeInsets.only(top: 5.0, bottom: 5.0, left: 2.0, right: 2.0),
      child: ElevatedButton(child: Text(text), onPressed: func));

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        // main view
        NesView(controller: controller),

        // controllers
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Checkbox(
              value: controller.debugOption.showDebugView,
              onChanged: (on) => setState(() {
                    controller.debugOption =
                        DebugOption(showDebugView: on ?? false);
                  })),
          _button(_isRunning ? "Stop" : "Run", () async {
            if (_isRunning) {
              controller.stop();
              setState(() {
                _isRunning = false;
              });
            } else {
              await _mPlayer.resume();
              controller.run();
              setState(() {
                _isRunning = true;
              });
            }
          }),
          _button("Reset", _reset),
          _button("File", _setFile),
          Text(_romName),
        ]),

        // debug view if enabled
        if (controller.debugOption.showDebugView)
          DebugControl(controller: controller),
      ],
    );
  }
}

class DebugControl extends StatelessWidget {
  final NesController controller;

  const DebugControl({Key? key, required this.controller}) : super(key: key);

  Widget _button(String text, void Function() func) => Container(
      margin:
          const EdgeInsets.only(top: 5.0, bottom: 5.0, left: 2.0, right: 2.0),
      child: ElevatedButton(child: Text(text), onPressed: func));

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      _button("Step", controller.runStep),
      _button("Line", controller.runScanLine),
      _button("Frame", controller.runFrame),
      SizedBox(width: 50, child: TextField(onChanged: (v) {})),
      _button("Disasm", () => {}),
      _button("VRAM", () => {}),
      _button("Log", () => {}),
    ]);
  }
}
