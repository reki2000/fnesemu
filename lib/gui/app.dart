// Flutter imports:

// Package imports:
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
  final controller = CoreController();
  late final KeyHandler keyHandler;

  bool _running = false;

  String _romName = "";

  @override
  void initState() {
    super.initState();

    keyHandler = KeyHandler(controller: controller);

    controller.onAudio =
        (buf) => _mPlayer.push(buf.buffer, buf.sampleRate, buf.channels);
    controller.onImage =
        (buf) => _imageContainer.push(buf.buffer, buf.width, buf.height);
  }

  @override
  void dispose() {
    ServicesBinding.instance.keyboard.removeHandler(keyHandler.handle);
    _mPlayer.dispose();
    super.dispose();
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

    try {
      setState(() {
        controller.setCore(name.endsWith(".pce")
            ? "pce"
            : name.endsWith(".nes")
                ? "nes"
                : name.endsWith(".gen")
                    ? "gen"
                    : "unknown");
        controller.setRom(file);
        keyHandler.init();
        _romName = name;
      });
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.toString())));
    }

    // temporary debug options
    controller.debugger.debugOption.showDebugView = true;
    // controller.debugger.debugOption.showVdc = true;
    _reset(run: false);

    // _reset(run: !controller.debugger.debugOption.showDebugView);
  }

  void _run() {
    ServicesBinding.instance.keyboard.removeHandler(keyHandler.handle);
    ServicesBinding.instance.keyboard.addHandler(keyHandler.handle);
    setState(() {
      _running = true;
      controller.run();
    });
  }

  void _stop() {
    ServicesBinding.instance.keyboard.removeHandler(keyHandler.handle);
    setState(() {
      _running = false;
      controller.stop();
    });
  }

  void _reset({bool run = false}) {
    setState(() {
      () async {
        await controller.stop();
        controller.reset();
        if (run) {
          _run();
        }
      }();
    });
  }

  void _debug(bool on) {
    setState(() {
      controller.debugger.setDebugView(on);
    });
  }

  IconButton _iconButton(
      IconData icon, String tooltip, void Function() onPress) {
    return IconButton(icon: Icon(icon), tooltip: tooltip, onPressed: onPress);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_romName), actions: [
        ...[
          for (var name in [
            "test.gen",
            "test2.gen",
            "test3.gen",
            "tilescroll.gen",
            "daimakai.gen",
            "vracing.gen",
            "outrun.gen",
            "sonic.gen",
            "micky.gen",
            "ys3.gen",
            // "daimakai.pce",
            // "battleace.pce",
            // "powerdrift.pce",
            // "sf2d.pce",
            // "valkyrie.pce",
          ])
            _iconButton(Icons.file_open_outlined, name.split(".")[0],
                () => _loadRomFile(name: name))
        ],

        // file load button
        _iconButton(Icons.file_open_outlined, "Load ROM", _loadRomFile),

        // run / pause button
        _running
            ? _iconButton(Icons.pause, "Pause", _stop)
            : _iconButton(Icons.play_arrow, "Run", _run),

        // reset button
        _iconButton(Icons.restart_alt, "Reset", _reset),

        // debug on/off button
        controller.debugger.debugOption.showDebugView
            ? _iconButton(
                Icons.bug_report, "Disable Debug Options", () => _debug(false))
            : _iconButton(Icons.bug_report_outlined, "Enable Debug Options",
                () => _debug(true)),
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
                CoreView(controller: controller, container: _imageContainer),

                // debug view if enabled
                StreamBuilder<DebugOption>(
                    stream: controller.debugger.debugStream,
                    builder: (ctx, snapshot) =>
                        Text(snapshot.data?.text ?? "", style: debugStyle)),
                if (controller.debugger.debugOption.showDebugView)
                  DebugController(controller: controller),
              ],
            ),
            if (controller.debugger.debugOption.showDebugView)
              DebugPane(debugger: controller.debugger),
          ]),
    );
  }
}
