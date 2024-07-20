// Flutter imports:
// Package imports:
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Project imports:
import 'debug/debug_controller.dart';
import 'key_handler.dart';
import 'nes_controller.dart';
import 'nes_view.dart';
import 'sound_player.dart';

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
  _MainPageState createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  final _mPlayer = SoundPlayer();
  final controller = NesController();
  late final KeyHandler keyHandler;

  String _romName = "";
  bool _isRunning = false;

  @override
  void initState() {
    super.initState();

    keyHandler = KeyHandler(controller: controller);

    ServicesBinding.instance.keyboard.addHandler(keyHandler.handle);

    // start automatic playback the emulator's audio output
    (() async {
      await for (final buf in controller.audioStream) {
        _mPlayer.push(buf, controller.apuClock);
      }
    })();
  }

  @override
  void dispose() {
    ServicesBinding.instance.keyboard.removeHandler(keyHandler.handle);
    _mPlayer.dispose();
    super.dispose();
  }

  void _loadRomFile() async {
    _mPlayer.resume(); // web platform requires this

    final picked = await FilePicker.platform.pickFiles(withData: true);
    if (picked == null) {
      return;
    }

    try {
      controller.setRom(picked.files.first.bytes!);
      setState(() {
        _romName = picked.files.first.name;
      });
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.toString())));
    }
    _reset();
    if (!controller.debugOption.showDebugView) {
      _run();
    }
  }

  void _run() {
    controller.run();
    setState(() {
      _isRunning = true;
    });
  }

  void _stop() {
    controller.stop();
    setState(() {
      _isRunning = false;
    });
  }

  void _reset() {
    controller.reset();
  }

  void _debug(bool on) {
    setState(() {
      controller.debugOption =
          controller.debugOption.copyWith(showDebugView: on);
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
        // file load button
        _iconButton(Icons.file_open_outlined, "Load ROM", _loadRomFile),

        // run / pause button
        _isRunning
            ? _iconButton(Icons.pause, "Pause", _stop)
            : _iconButton(Icons.play_arrow, "Run", _run),

        // reset button
        _iconButton(Icons.restart_alt, "Reset", _reset),

        // debug on/off button
        controller.debugOption.showDebugView
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
