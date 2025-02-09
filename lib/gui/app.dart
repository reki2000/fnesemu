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

  String _romName = "";

  @override
  void initState() {
    super.initState();

    _controller = CoreController(
      _onStop,
      (buf) => _mPlayer.push(buf.buffer, buf.sampleRate, buf.channels),
      (buf) => _imageContainer.push(buf.buffer, buf.width, buf.height),
    );

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

  void _loadRomFile({String name = ""}) async {
    _mPlayer.resume(); // web platform requires this

    Uint8List file;
    if (name == "") {
      final picked = await FilePicker.platform.pickFiles(withData: true);
      if (picked == null) {
        return;
      }
      file = picked.files.first.bytes!;
      name = picked.files.first.name;
    } else {
      file = (await rootBundle.load('assets/roms/$name')).buffer.asUint8List();
    }

    String extension(String fileName) =>
        fileName.substring(fileName.lastIndexOf(".") + 1);

    bool found = true;

    // if zip, extract the first file with known extention
    if (extension(name) == "zip") {
      found = false;
      final archive = ZipDecoder().decodeBytes(file);

      for (final entry in archive) {
        if (["nes", "pce", "md", "gen"].contains(extension(entry.name))) {
          file = entry.content as Uint8List;
          name = entry.name;
          found = true;
          break;
        }
      }
    }

    try {
      if (!found) {
        throw Exception("No files in the zip");
      }

      setState(() {
        _controller.setRom(extension(name), file);
        _keyHandler.init();
        _romName = name;
      });
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.toString())));
    }

    // temporary debug options
    _controller.debugger.opt.showDebugView = true;
    // controller.debugger.debugOption.showVdc = true;
    _reset(run: false);

    // _reset(run: !controller.debugger.debugOption.showDebugView);
  }

  void _do(BuildContext ctx, Function() func) {
    try {
      func();
      setState(() {});
    } catch (e, st) {
      ScaffoldMessenger.of(ctx)
          .showSnackBar(SnackBar(content: Text(e.toString())));
      print(e);
      print(st);
    }
  }

  void _run() {
    _enableKeyHandler();

    _controller.run();
  }

  void _stop() {
    _disableKeyHandler();

    _controller.stop();
  }

  void _reset({bool run = false}) {
    _disableKeyHandler();

    () async {
      await _controller.stop();
      _controller.reset();

      if (run) {
        _run();
      }
    }();
  }

  void _debug(bool on) {
    _controller.debugger.setDebugView(on);
  }

  @override
  Widget build(BuildContext context) {
    bool showDebug = _controller.debugger.opt.showDebugView;

    return Scaffold(
      appBar: AppBar(title: Text(_romName), actions: [
        ...[
          for (var name in [
            "darius2.gen",
            "daimakai.gen",
            "sfzone.gen",
            "sphouse.gen",
            "sf2.gen",
            "outrun.gen",
            "sangokushi.gen",
            "sonic.gen",
          ])
            iconButton(Icons.file_open_outlined, name.split(".")[0],
                () => _loadRomFile(name: name))
        ],

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
        showDebug
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
                if (showDebug)
                  SizedBox(
                      width: 640,
                      child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: StreamBuilder<DebugOption>(
                              stream: _controller.debugger.debugStream,
                              builder: (ctx, snapshot) => Text(
                                  snapshot.data?.text ?? "",
                                  style: debugStyle)))),
                if (showDebug) DebugController(controller: _controller),
              ],
            ),
            if (showDebug) DebugPane(debugger: _controller.debugger),
          ]),
    );
  }
}
