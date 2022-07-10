// Dart imports:
import 'dart:typed_data';

// Flutter imports:
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Package imports:
import 'package:file_picker/file_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';

// Project imports:
import '../cpu/cpu_debug.dart';
import 'debug/debug_log.dart';
import 'debug/disasm.dart';
import 'debug/vram.dart';
import 'nes.dart';
import 'sound_player.dart';

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'fnesemu',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: const MainView(title: 'fnesemu'),
    );
  }
}

class MainView extends StatefulWidget {
  const MainView({Key? key, required this.title}) : super(key: key);
  final String title;

  @override
  State<MainView> createState() => _MainViewState();
}

class _MainViewState extends State<MainView> {
  final _mPlayer = getSoundPlayerInstance();

  String _romName = "";

  bool showDebugView = false;

  @override
  void initState() {
    super.initState();
    nes.renderAudio = (Float32List buf) async => _mPlayer.push(buf);
    //setRomFile("hello.nes");
  }

  void setRomFile(String rom) async {
    nes.stop();
    _romName = rom;
    final body = await rootBundle.load("rom/$rom");
    nes.setRom(Uint8List.sublistView(body));

    setState(() {});
  }

  void _reset() async {
    _mPlayer.stop();
    nes.reset();
    CpuDebugger.clearDebugLog();
  }

  void _setFile() async {
    final picked = await FilePicker.platform.pickFiles();
    if (picked != null) {
      _reset();
      nes.setRom(picked.files.first.bytes!);
      setState(() {
        _romName = picked.files.first.name;
      });
    }
  }

  Widget _button(String text, void Function() func) => Container(
      margin:
          const EdgeInsets.only(top: 5.0, bottom: 5.0, left: 2.0, right: 2.0),
      child: ElevatedButton(child: Text(text), onPressed: func));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [Text(widget.title), _versionText()]),
      ),
      body: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          const NesWidget(),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            _button("Run", () async {
              await _mPlayer.resume();
              nes.run();
            }),
            _button("Stop", () async {
              _mPlayer.stop();
              nes.stop();
            }),
            _button("Reset", _reset),
            _button("File", _setFile),
            Text(_romName),
          ]),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            _button("Step", nes.execStep),
            _button("Line", nes.execLine),
            _button("Frame", nes.execFrame),
            SizedBox(
                width: 50,
                child: TextField(onChanged: (v) {
                  nes.breakpoint = int.parse(v, radix: 16);
                })),
            _button("Disasm", () => showDisasm(context, nes.breakpoint)),
            _button("VRAM", () => showVram(context)),
            _button("Log", () => showDebugLog(context)),
            Checkbox(
                value: nes.enableDebugLog,
                onChanged: (on) => setState(() {
                      nes.enableDebugLog = on ?? false;
                    })),
          ]),
        ],
      ),
    );
  }
}

Widget _versionText() => FutureBuilder<PackageInfo>(
      future: PackageInfo.fromPlatform(),
      builder: (context, snapshot) {
        switch (snapshot.connectionState) {
          case ConnectionState.done:
            return Align(
              alignment: Alignment.bottomCenter,
              child: Text(
                ' ${snapshot.data!.version}-${snapshot.data!.buildNumber}',
              ),
            );
          default:
            return const SizedBox();
        }
      },
    );
