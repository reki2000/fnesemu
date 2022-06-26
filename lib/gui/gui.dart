// Dart imports:
import 'dart:typed_data';

// Flutter imports:
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Package imports:
import 'package:file_picker/file_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';

// Project imports:
import '../cpu/bus_debug.dart';
import '../cpu/cpu_debug.dart';
import '../cpu/joypad.dart';
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
  final _focusNode = FocusNode();

  final _mPlayer = getSoundPlayerInstance();

  String _romName = "";

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

  static final keys = <LogicalKeyboardKey, PadButton>{
    LogicalKeyboardKey.arrowDown: PadButton.down,
    LogicalKeyboardKey.arrowUp: PadButton.up,
    LogicalKeyboardKey.arrowLeft: PadButton.left,
    LogicalKeyboardKey.arrowRight: PadButton.right,
    LogicalKeyboardKey.keyX: PadButton.a,
    LogicalKeyboardKey.keyZ: PadButton.b,
    LogicalKeyboardKey.keyA: PadButton.select,
    LogicalKeyboardKey.keyS: PadButton.start,
  };

  void showVram(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) {
          final vramDump = nes.bus.debug(showVram: true);
          final charDump = nes.bus.debug(showChar: true);
          const margin10 = EdgeInsets.all(10.0);
          return Scaffold(
            appBar: AppBar(title: const Text('VRAM')),
            body: Container(
              alignment: Alignment.center,
              // child: const Expanded(
              child: SingleChildScrollView(
                  scrollDirection: Axis.vertical,
                  child: Row(
                    children: [
                      Column(children: [
                        Container(
                            margin: margin10,
                            child: Text(vramDump, style: debugStyle))
                      ]),
                      Column(children: [
                        Container(
                            margin: margin10,
                            child: Text(charDump, style: debugStyle))
                      ]),
                    ],
                  )),
            ),
          );
        },
      ),
    );
  }

  void showDisasm(BuildContext context, int addr) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) {
          final asm = nes.cpu.dumpDisasm(addr);
          const margin10 = EdgeInsets.all(10.0);
          return Scaffold(
            appBar: AppBar(title: const Text('Disaseembler')),
            body: Container(
              alignment: Alignment.center,
              // child: const Expanded(
              child: SingleChildScrollView(
                  scrollDirection: Axis.vertical,
                  child: Row(
                    children: [
                      Column(children: [
                        Container(
                            margin: margin10,
                            child: SelectableText(
                              asm,
                              style: debugStyle,
                              toolbarOptions: const ToolbarOptions(
                                copy: true,
                                selectAll: true,
                              ),
                              showCursor: true,
                            ))
                      ]),
                    ],
                  )),
            ),
          );
        },
      ),
    );
  }

  Widget _button(String text, void Function() func) => Container(
      margin: const EdgeInsets.all(5.0),
      child: ElevatedButton(child: Text(text), onPressed: func));

  @override
  Widget build(BuildContext context) {
    FocusScope.of(context).requestFocus(_focusNode);

    return RawKeyboardListener(
      child: Scaffold(
        appBar: AppBar(
          title: Row(children: [Text(widget.title), _versionText()]),
        ),
        body: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Text(_romName),
              _button("File", () async {
                final picked = await FilePicker.platform.pickFiles();
                if (picked != null) {
                  nes.setRom(picked.files.first.bytes!);
                  setState(() {
                    _romName = picked.files.first.name;
                  });
                }
              }),
              _button("Run", () async {
                await _mPlayer.resume();
                nes.run();
              }),
              _button("Stop", () async {
                _mPlayer.stop();
                nes.stop();
              }),
              _button("Reset", () async {
                _mPlayer.stop();
                nes.reset();
              }),
            ]),
            const NesWidget(),
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
            ]),
          ],
        ),
      ),
      focusNode: _focusNode,
      onKey: (e) {
        switch (e.runtimeType) {
          case RawKeyDownEvent:
            for (final entry in keys.entries) {
              if (entry.key == e.data.logicalKey) {
                nes.bus.joypad.keyDown(entry.value);
                break;
              }
            }
            break;
          case RawKeyUpEvent:
            for (final entry in keys.entries) {
              if (entry.key == e.data.logicalKey) {
                nes.bus.joypad.keyUp(entry.value);
                break;
              }
            }
            break;
        }
      },
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
