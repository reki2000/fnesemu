// Flutter imports:

// Package imports:
import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/core_controller.dart';
import '../core/debugger.dart';
import '../styles.dart';
import 'core_view.dart';
import 'debug/debug_controller.dart';
// Project imports:
import 'debug/debug_pane.dart';
import 'key_handler.dart';
import 'sound_player.dart';
import 'ticker_image.dart';

part 'loader.dart';

const _isDebug = bool.fromEnvironment("DEBUG", defaultValue: false);
const _roms = String.fromEnvironment("ROMS", defaultValue: "");

class MyApp extends StatelessWidget {
  final String title;
  const MyApp({super.key, required this.title});

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
  const MainPage({super.key});

  @override
  MainPageState createState() => MainPageState();
}

class MainPageState extends State<MainPage> {
  final _mPlayer = SoundPlayer();
  final _imageContainer = ImageContainer();
  late final KeyHandler _keyHandler;
  late final CoreController _controller;

  bool get _running => _controller.isRunning();
  bool get _debugging => _controller.debugger.opt.showDebugView;

  String _romName = "";

  @override
  void initState() {
    super.initState();

    _controller = CoreController(
      _onStop,
      (buf) => _mPlayer.push(buf.buffer, buf.sampleRate, buf.channels),
      (buf) => _imageContainer.push(buf.buffer, buf.width, buf.height),
    );

    _controller.debugger.opt.showDebugView = _isDebug;

    _keyHandler = KeyHandler(controller: _controller);
  }

  @override
  void dispose() {
    ServicesBinding.instance.keyboard.removeHandler(_keyHandler.handle);
    _mPlayer.dispose();
    super.dispose();
  }

  void _onStop() {
    setState(() {});
  }

  void _disableKeyHandler() {
    ServicesBinding.instance.keyboard.removeHandler(_keyHandler.handle);
  }

  void _enableKeyHandler() {
    _disableKeyHandler();
    ServicesBinding.instance.keyboard.addHandler(_keyHandler.handle);
  }

  // action wrapper for state refresh
  void _do(BuildContext ctx, Function() action) {
    try {
      action();
      setState(() {});
    } catch (e, st) {
      ScaffoldMessenger.of(ctx)
          .showSnackBar(SnackBar(content: Text(e.toString())));
      print(e);
      print(st);
    }
  }

  _loadRomFile({String fileName = ""}) async {
    final (file, name) = await _pickFile(name: fileName);
    final (extractedFile, extractedName) = _extractIfZip(file, name);

    _controller.init(_fileExtension(extractedName), extractedFile);
    _keyHandler.init();
    _mPlayer.resume(); // web platform requires this
    _romName = extractedName;

    await _reset();

    if (!_isDebug) {
      await _run();
    }
  }

  _run() async {
    _enableKeyHandler();
    await _controller.run();
  }

  _stop() async {
    _disableKeyHandler();
    await _controller.stop();
  }

  _reset() async {
    await _controller.reset();
  }

  _debug(bool onoff) {
    _controller.debugger.setDebugView(onoff);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(_romName), actions: [
          // shortcuts from environment variables
          for (var name in _roms.split(",").where((s) => s.isNotEmpty))
            iconButton(Icons.file_open_outlined, name.split(".")[0],
                () => _loadRomFile(fileName: name)),

          // file load button
          iconButton(Icons.file_open_outlined, "Load ROM",
              () => _do(context, _loadRomFile)),

          // run / pause button
          _running
              ? iconButton(Icons.pause, "Pause", () => _do(context, _stop))
              : iconButton(Icons.play_arrow, "Run", () => _do(context, _run)),

          // reset button
          iconButton(Icons.restart_alt, "Reset", () => _do(context, _reset)),

          // debug on/off button
          _debugging
              ? iconButton(Icons.bug_report, "Disable Debug Options",
                  () => _do(context, () => _debug(false)))
              : iconButton(Icons.bug_report_outlined, "Enable Debug Options",
                  () => _do(context, () => _debug(true))),
        ]),
        drawer: Drawer(
            child: ListView(children: [
          ListTile(
            title: const Text("License"),
            trailing: const Icon(Icons.arrow_forward),
            onTap: () => showLicensePage(context: context),
          ),
        ])),
        body: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Column(
                mainAxisAlignment: MainAxisAlignment.start,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  // main view
                  CoreView(controller: _controller, container: _imageContainer),

                  // debug view if enabled
                  if (_debugging) ...[
                    SizedBox(
                        width: 640,
                        child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: StreamBuilder<DebugOption>(
                                stream: _controller.debugger.debugStream,
                                builder: (ctx, snapshot) => Text(
                                    snapshot.data?.text ?? "",
                                    style: debugStyle)))),
                    DebugController(controller: _controller),
                  ],
                ],
              ),
              if (_debugging) DebugPane(debugger: _controller.debugger),
            ]),
      );
}
