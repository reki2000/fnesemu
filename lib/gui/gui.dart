// Dart imports:
import 'dart:typed_data';

// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:file_picker/file_picker.dart';
import 'util_web.dart';

// Project imports:
import '../cpu/cpu_debug.dart';
import '../cpu/nes.dart';
import 'debug/disasm.dart';
import 'debug/vram.dart';
import 'nes.dart';
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
  final _mPlayer = getSoundPlayerInstance();

  String _romName = "";
  bool _isRunning = false;

  final emulator = Nes();

  @override
  void initState() {
    super.initState();
    emulator.renderAudio = (Float32List buf) async => _mPlayer.push(buf);
  }

  void _reset() async {
    setState(() {
      _isRunning = false;
    });
    _mPlayer.stop();
    emulator.reset();
    CpuDebugger.clearDebugLog();
  }

  void _setFile() async {
    final picked = await FilePicker.platform.pickFiles(withData: true);
    if (picked != null) {
      _reset();
      if (emulator.setRom(picked.files.first.bytes!)) {
        setState(() {
          _romName = picked.files.first.name;
        });
      } else {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text("load error")));
      }
      ;
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
        NesWidget(emulator: emulator),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          _button(_isRunning ? "Stop" : "Run", () async {
            if (_isRunning) {
              _mPlayer.stop();
              emulator.stop();
              setState(() {
                _isRunning = false;
              });
            } else {
              await _mPlayer.resume();
              emulator.run();
              setState(() {
                _isRunning = true;
              });
            }
          }),
          _button("Reset", _reset),
          _button("File", _setFile),
          Text(_romName),
        ]),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          _button("Step", emulator.execStep),
          _button("Line", emulator.execLine),
          _button("Frame", emulator.execFrame),
          SizedBox(
              width: 50,
              child: TextField(onChanged: (v) {
                emulator.breakpoint =
                    (v.length == 4) ? int.parse(v, radix: 16) : 0;
              })),
          _button("Disasm", () => showDisasm(context, emulator)),
          _button("VRAM", () => showVram(context, emulator)),
          _button("Log", () => debugJsConsole(emulator.cpu.dumpDebugLog())),
          //showDebugLog(context, emulator)),
          Checkbox(
              value: emulator.enableDebugLog,
              onChanged: (on) => setState(() {
                    emulator.enableDebugLog = on ?? false;
                  })),
        ]),
      ],
    );
  }
}
