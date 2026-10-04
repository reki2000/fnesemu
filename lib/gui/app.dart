// Dart imports:
// Flutter imports:
import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Project imports:
import '../cdrom/async_cdrom_drive.dart';
import '../cdrom/disc_source.dart';
import '../core/core_controller.dart';
import '../core/debugger.dart';
import '../core/gba/gba.dart';
import '../cdrom/disc_folder.dart';
import '../styles.dart';
import 'package:fnesemu/util/debug.dart';
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
  const Config({
    this.debug = false,
    this.roms = const [],
    this.disc = "",
    this.rom = "",
  });

  String dump() {
    return "debug: $debug, roms: $roms, disc: $disc, rom: $rom";
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
  final Storage storage;
  const MyApp(
      {super.key,
      required this.title,
      required this.storage,
      this.config = const Config()});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
        title: title,
        scaffoldMessengerKey: AppSnackBar.messengerKey,
        theme: ThemeData(
          primarySwatch: Colors.blue,
        ),
        home: MainPage(storage: storage, config: config));
  }
}

class MainPage extends StatefulWidget {
  final Config config;
  final Storage storage;
  const MainPage(
      {super.key, required this.storage, this.config = const Config()});

  @override
  MainPageState createState() => MainPageState();
}

enum _DiscAction { eject, empty, select, rescan }

class MainPageState extends State<MainPage> {
  final _mPlayer = SoundPlayer();
  final _imageContainer = ImageContainer();
  late final KeyHandler _keyHandler;
  late final CoreController _controller;
  late final Storage _storage;

  bool _running = false;
  bool get _debugging => _controller.debugger.opt.showDebugView;

  String _romName = "";

  // disc images found in the directory selected from the disc menu
  ScanResult? _scan;
  ScanProgress? _progress; // not null while scanning
  bool _cancelScan = false;

  // shared by cores, the disc is kept across ROM loading
  final _drive = AsyncCdromDrive();

  @override
  void initState() {
    super.initState();

    _storage = widget.storage..onEvent = AppSnackBar.show;

    _controller = CoreController(
        _onCoreStateChange,
        (buf) => _mPlayer.push(buf.buffer, buf.sampleRate, buf.channels),
        (buf) => _imageContainer.push(
            buf.buffer, buf.width, buf.height, buf.displayWidth,
            displayHeight: buf.displayHeight),
        _storage);

    _controller.debugger.opt.showDebugView = widget.config.debug;

    _keyHandler = KeyHandler(controller: _controller);

    _restoreDiscFolder();

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
    _storage.dispose();
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
    await _drive.insert(discSourceFromPath(fileName));

    await _reset();

    AppSnackBar.show("loaded: $fileName");

    if (!widget.config.debug) {
      _run();
    }
  }

  _loadRomFile({String fileName = ""}) async {
    final (file, name) = await _pickFile(name: fileName);
    final (extractedFile, extractedName) = _extractIfZip(file, name);

    // a file named gba_bios.bin is the GBA BIOS image, not a cartridge ROM
    if (extractedName.toLowerCase().endsWith("gba_bios.bin")) {
      Gba.biosImage = extractedFile;
      AppSnackBar.show("gba bios loaded: $name");
      return;
    }

    final ext = _fileExtension(extractedName);

    if (ext == "exe") {
      final (bios, _) = await _pickFile(name: "scph1001.ps");
      _controller.init("ps", bios.buffer.asUint8List(), extRom: extractedFile);
    } else {
      _controller.init(ext, extractedFile);
    }
    _controller.setCdromDrive(_drive);

    _keyHandler.init();
    _mPlayer.resume(); // web platform requires this
    _romName = extractedName;

    await _reset();

    AppSnackBar.show("loaded: $name");

    if (!widget.config.debug) {
      _run();
    }
  }

  static const _lastDiscDirKey = "disc_dir";

  /// scans the directory selected last time, if it can be opened again
  _restoreDiscFolder() async {
    final path = _storage.setting(_lastDiscDirKey);
    final folder = path == null ? null : await openDiscFolderAt(path);
    if (folder != null) {
      await _scanFolder(folder);
    }
  }

  _selectDiscFolder() async {
    final folder = await pickDiscFolder();
    if (folder != null) {
      await _scanFolder(folder);
    }
  }

  /// lists the disc images in [folder], with the progress
  _scanFolder(DiscFolder folder) async {
    if (_progress != null) return;
    _cancelScan = false;
    setState(() {
      _scan = null;
      _progress = const ScanProgress(true, 0, 0, 0, 0);
    });

    try {
      final result = await DiscScanner.scan(folder,
          onProgress: (p) => setState(() => _progress = p),
          isCancelled: () => _cancelScan);
      if (!result.cancelled) {
        _scan = result;
        final path = folder.persistentPath;
        if (path != null) {
          await _storage.setSetting(_lastDiscDirKey, path);
        }
        AppSnackBar.show(
            "${result.items.length} disc image(s) in ${folder.name}"
            "${result.skipped.isEmpty ? "" : ", ${result.skipped.length} cue file(s) skipped (missing files)"}");
      }
    } finally {
      setState(() => _progress = null);
    }
  }

  /// inserts the image selected from the list and starts it
  _insertItem(DiscItem item) async {
    final scan = _scan;
    if (scan == null) return;

    await _drive.insert(scan.sourceOf(item));
    if (!_drive.status.isReady) {
      AppSnackBar.show("failed to read: ${item.path}");
      return;
    }

    await _reset();
    AppSnackBar.show("loaded: ${item.path}");
    if (!widget.config.debug) {
      _run();
    }
  }

  _discMenuAction(Object action) async {
    switch (action) {
      case DiscItem():
        await _insertItem(action);
      case _DiscAction.eject:
        await _drive.eject(); // the tray stays open
      case _DiscAction.empty:
        await _drive.insert(); // the tray is closed without a disc
      case _DiscAction.select:
        await _selectDiscFolder();
      case _DiscAction.rescan:
        final folder = _scan?.folder;
        if (folder != null) await _scanFolder(folder);
    }
    setState(() {});
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
        appBar: AppBar(
            title: Text(_romName),
            bottom: _progress == null
                ? null
                : PreferredSize(
                    preferredSize: const Size.fromHeight(40),
                    child: Row(children: [
                      const SizedBox(width: 16),
                      Expanded(
                          child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            Text("Scanning: $_progress"),
                            const SizedBox(height: 4),
                            LinearProgressIndicator(
                                // known only while checking the cue files
                                value: _progress!.isListing ||
                                        _progress!.cues == 0
                                    ? null
                                    : _progress!.checkedCues / _progress!.cues),
                          ])),
                      IconButton(
                          icon: const Icon(Icons.close),
                          tooltip: "Cancel scan",
                          onPressed: () => _cancelScan = true),
                    ])),
            actions: [
              PopupMenuButton<Object>(
                icon: const Icon(Icons.album),
                tooltip: "Disc",
                onSelected: (action) => _do(() => _discMenuAction(action)),
                itemBuilder: (_) => [
                  const PopupMenuItem(
                      value: _DiscAction.eject,
                      child: Text("Eject (open tray)")),
                  const PopupMenuItem(
                      value: _DiscAction.empty,
                      child: Text("Empty (closed, no disc)")),
                  const PopupMenuItem(
                      value: _DiscAction.select,
                      child: Text("Select image file directory...")),
                  if (_scan != null)
                    PopupMenuItem(
                        value: _DiscAction.rescan,
                        child: Text("Rescan ${_scan!.folder.name}")),
                  if (_scan != null && _scan!.items.isNotEmpty)
                    const PopupMenuDivider(),
                  for (final item in _scan?.items ?? const <DiscItem>[])
                    PopupMenuItem(value: item, child: Text(item.path)),
                ],
              ),

              if (widget.config.roms.isNotEmpty)
                PopupMenuButton<String>(
                  icon: const Icon(Icons.file_open_outlined),
                  tooltip: "Select ROM",
                  onSelected: (name) =>
                      _do(() async => await _loadRomFile(fileName: name)),
                  itemBuilder: (_) => widget.config.roms
                      .map((name) => PopupMenuItem(
                          value: name, child: Text(name.split(".")[0])))
                      .toList(),
                ),

              // file load button
              iconButton(Icons.file_open_outlined, "Load ROM",
                  () => _do(_loadRomFile)),

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
                  : iconButton(Icons.bug_report_outlined,
                      "Enable Debug Options", () => _do(() => _debug(true))),
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
