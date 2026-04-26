// Dart imports:
import 'dart:io';

// Flutter imports:
import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fnesemu/core/disc.dart';
import 'package:fnesemu/disc/empty.dart';

// Project imports:
import '../core/core_controller.dart';
import '../core/debugger.dart';
import '../disc/loader.dart';
import '../styles.dart';
import '../util/debug.dart';
import 'core_view.dart';
import 'debug/debug_controller.dart';
import 'debug/debug_pane.dart';
import 'key_handler.dart';
import 'sound_player.dart';
import 'storage.dart';
import 'ticker_image.dart';

part 'loader.dart';

class Config {
  final bool debug;
  final List<String> roms;
  final String disc;
  final String rom;
  final String discDir;
  const Config({
    this.debug = false,
    this.roms = const [],
    this.disc = "",
    this.rom = "",
    this.discDir = "",
  });

  String dump() {
    return "debug: $debug, roms: $roms, disc: $disc, rom: $rom, discDir: $discDir";
  }
}

class AppSnackBar {
  static final messengerKey = GlobalKey<ScaffoldMessengerState>();

  static void show(String message) {
    if (message.isEmpty) {
      return;
    }
    final messenger = messengerKey.currentState;
    if (messenger == null) {
      return;
    }
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 2)));
  }
}

class MyApp extends StatelessWidget {
  final String title;
  final Config config;
  const MyApp({super.key, required this.title, this.config = const Config()});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
        title: title,
        scaffoldMessengerKey: AppSnackBar.messengerKey,
        theme: ThemeData(
          primarySwatch: Colors.blue,
        ),
        home: MainPage(config: config));
  }
}

class MainPage extends StatefulWidget {
  final Config config;
  const MainPage({super.key, this.config = const Config()});

  @override
  MainPageState createState() => MainPageState();
}

class MainPageState extends State<MainPage> {
  final _mPlayer = SoundPlayer();
  final _imageContainer = ImageContainer();
  late final KeyHandler _keyHandler;
  late final CoreController _controller;
  late final Storage _storage;

  bool _running = false;
  bool get _debugging => _controller.debugger.opt.showDebugView;

  String _romName = "";
  List<String> _discs = [];

  Disc _disc = EmptyDisc();

  @override
  void initState() {
    super.initState();

    _storage = Storage.of(onEvent: (s) {
      AppSnackBar.show(s);
    });

    _controller = CoreController(
        _onCoreStateChange,
        (buf) => _mPlayer.push(buf.buffer, buf.sampleRate, buf.channels),
        (buf) => _imageContainer.push(
            buf.buffer, buf.width, buf.height, buf.displayWidth),
        _storage);

    _controller.debugger.opt.showDebugView = widget.config.debug;

    _keyHandler = KeyHandler(controller: _controller);

    // scan disc dir if set in environment variables
    final dir = widget.config.discDir;
    if (dir.isNotEmpty && Directory(dir).existsSync()) {
      _discs = Directory(dir)
          .listSync()
          .whereType<File>()
          .where((f) {
            final lower = f.path.toLowerCase();
            return lower.endsWith('.iso') || lower.endsWith('.bin');
          })
          .map((f) => f.path)
          .toList();
    }

    if (widget.config.disc.isNotEmpty) {
      _setDiscFile(widget.config.disc);
    }

    if (widget.config.rom.isNotEmpty) {
      _loadRomFile(fileName: widget.config.rom);
    }

    debugLog("initialized: ${widget.config.dump()}");
  }

  @override
  void dispose() {
    ServicesBinding.instance.keyboard.removeHandler(_keyHandler.handle);
    _mPlayer.dispose();
    super.dispose();
  }

  void _onCoreStateChange(CoreControllerState state) {
    if (state.running) {
      _running = true;
      _enableKeyHandler();
    } else {
      _running = false;
      _disableKeyHandler();
    }

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
  void _do(Function() action) {
    // wrap both of async or sync function to catch error
    Future.microtask(action).catchError((e, st) {
      AppSnackBar.show(e.toString());
      throw e;
    });

    setState(() {});
  }

  _setDiscFile(String fileName) async {
    _disc = DiscLoader.load(fileName);
    _controller.setDisc(_disc);

    await _reset();

    AppSnackBar.show("loaded: $fileName");

    if (!widget.config.debug) {
      _run();
    }
  }

  _loadRomFile({String fileName = ""}) async {
    final (file, name) = await _pickFile(name: fileName);
    final (extractedFile, extractedName) = _extractIfZip(file, name);
    final ext = _fileExtension(extractedName);

    if (ext == "exe") {
      final (bios, _) = await _pickFile(name: "scph1001.ps");
      _controller.init("ps", bios.buffer.asUint8List(), extRom: extractedFile);
    } else {
      _controller.init(ext, extractedFile);
    }
    _controller.setDisc(_disc);

    _keyHandler.init();
    _mPlayer.resume(); // web platform requires this
    _romName = extractedName;

    await _reset();

    AppSnackBar.show("loaded: $name");

    if (!widget.config.debug) {
      _run();
    }
  }

  _run() {
    _controller.run();
  }

  _stop() async {
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
          for (var name in _discs)
            iconButton(Icons.album_outlined, name.split(".")[0],
                () => _do(() async => await _setDiscFile(name))),

          // shortcuts from environment variables
          for (var name in widget.config.roms)
            iconButton(Icons.file_open_outlined, name.split(".")[0],
                () => _do(() async => await _loadRomFile(fileName: name))),

          // file load button
          iconButton(
              Icons.file_open_outlined, "Load ROM", () => _do(_loadRomFile)),

          // run / pause button
          _running
              ? iconButton(Icons.pause, "Pause", () => _do(_stop))
              : iconButton(Icons.play_arrow, "Run", () => _do(_run)),

          // reset button
          iconButton(Icons.restart_alt, "Reset", () => _do(_reset)),

          // debug on/off button
          _debugging
              ? iconButton(Icons.bug_report, "Disable Debug Options",
                  () => _do(() => _debug(false)))
              : iconButton(Icons.bug_report_outlined, "Enable Debug Options",
                  () => _do(() => _debug(true))),
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
                    DebugController(controller: _controller),
                    SizedBox(
                        width: 640,
                        child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: StreamBuilder<DebugOption>(
                                stream: _controller.debugger.debugStream,
                                builder: (ctx, snapshot) => SelectableText(
                                      snapshot.data?.text ?? "",
                                      style: debugStyle,
                                      showCursor: true,
                                    )))),
                  ],
                ],
              ),
              if (_debugging) DebugPane(debugger: _controller.debugger),
            ]),
      );
}
