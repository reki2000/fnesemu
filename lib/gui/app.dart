// Dart imports:
import 'dart:async';
import 'dart:convert';
// Flutter imports:
import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mp_bigfile_picker/mp_bigfile_picker.dart';

// Project imports:
import '../cdrom/async_cdrom_drive.dart';
import '../cdrom/disc_source.dart';
import '../core/core_controller.dart';
import '../core/debugger.dart';
import '../core/core_factory.dart';
import '../cdrom/disc_folder.dart';
import '../styles.dart';
import 'package:fnesemu/util/debug.dart';
import 'core_view.dart';
import 'floating_game_menu.dart';
import 'debug/debug_controller.dart';
import 'debug/debug_pane.dart';
import 'key_handler.dart';
import 'pad_input.dart';
import 'recent_game.dart';
import 'game_directory.dart';
import 'game_list.dart';
import 'sound_player.dart';
import 'storage.dart';
import 'ticker_image.dart';

part 'loader.dart';

class Config {
  final bool debug;
  const Config({
    this.debug = false,
  });

  String dump() {
    return "debug: $debug";
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
  final SoundPlayer? soundPlayer;
  const MainPage(
      {super.key,
      required this.storage,
      this.config = const Config(),
      this.soundPlayer});

  @override
  MainPageState createState() => MainPageState();
}

enum _DiscAction { eject, empty, select }

class MainPageState extends State<MainPage> {
  late final SoundPlayer _mPlayer;
  final _imageContainer = ImageContainer();
  late final KeyHandler _keyHandler;
  late final PadInput _padInput;
  late final AppLifecycleListener _inputLifecycle;
  late final CoreController _controller;
  late final Storage _storage;

  bool _menuOpen = true;
  bool _menuBusy = false;
  bool _menuTransition = false;
  bool _resumeAfterAction = false;
  bool get _hasGame => _controller.system.isNotEmpty;
  bool get _debugging => _controller.debugger.opt.showDebugView;

  String _romName = "";

  // disc images found in the directory selected from the disc menu
  final _openedFolders = <String, DiscFolder>{};
  final _folderIds = Expando<String>();
  ScanResult? _scan;
  ScanProgress? _progress; // not null while scanning
  bool _cancelScan = false;

  // shared by cores, the disc is kept across ROM loading
  final _drive = AsyncCdromDrive();

  final _coreSetupKey = GlobalKey<PopupMenuButtonState>();

  @override
  void initState() {
    super.initState();

    _mPlayer = widget.soundPlayer ?? SoundPlayer();

    _storage = widget.storage..onEvent = AppSnackBar.show;

    _controller = CoreController(
        _onCoreStateChange,
        (buf) => _mPlayer.push(buf.buffer, buf.sampleRate, buf.channels),
        (buf) => _imageContainer.push(
            buf.buffer, buf.width, buf.height, buf.displayWidth,
            displayHeight: buf.displayHeight),
        _storage);

    _controller.debugger.opt.showDebugView = widget.config.debug;

    _padInput = PadInput(
        onDown: (button) => _controller.padDown(0, button),
        onUp: (button) => _controller.padUp(0, button))
      ..enabled = false;
    _keyHandler = KeyHandler(controller: _controller, input: _padInput);
    _inputLifecycle = AppLifecycleListener(
        onInactive: _padInput.clear,
        onHide: _padInput.clear,
        onPause: _padInput.clear);

    _restoreDiscFolder();

    debugLog("initialized: ${widget.config.dump()}");
  }

  @override
  void dispose() {
    unawaited(_controller.stop());
    ServicesBinding.instance.keyboard.removeHandler(_keyHandler.handle);
    _inputLifecycle.dispose();
    _padInput.clear();
    _padInput.dispose();
    _mPlayer.dispose();
    _storage.dispose();
    super.dispose();
  }

  void _onCoreStateChange(CoreControllerState state) {
    if (!mounted) return;
    if (state.running) {
      if (!_menuOpen && !_menuBusy) _enableKeyHandler();
    } else {
      _menuOpen = true;
      _mPlayer.pause();
      _disableKeyHandler();
    }

    if (mounted) setState(() {});
  }

  void _disableKeyHandler() {
    _padInput.enabled = false;
    _padInput.clear();
    ServicesBinding.instance.keyboard.removeHandler(_keyHandler.handle);
  }

  void _enableKeyHandler() {
    _disableKeyHandler();
    _padInput.enabled = true;
    ServicesBinding.instance.keyboard.addHandler(_keyHandler.handle);
  }

  // action wrapper for state refresh
  void _do(Function() action) {
    // wrap both of async or sync function to catch error
    Future.microtask(action).catchError((e, st) {
      AppSnackBar.show(e.toString());
      debugPrint("$e\n$st");
    });

    setState(() {});
  }

  Future<void> _openMenu() async {
    if (_menuBusy || _menuTransition) return;
    setState(() {
      _menuOpen = true;
      _menuTransition = true;
    });
    _disableKeyHandler();
    try {
      await _stop();
    } finally {
      if (mounted) setState(() => _menuTransition = false);
    }
  }

  Future<void> _resumeFromMenu() async {
    if (!_hasGame ||
        _menuBusy ||
        _menuTransition ||
        _progress != null ||
        !(ModalRoute.of(context)?.isCurrent ?? false)) {
      return;
    }
    setState(() => _menuTransition = true);
    try {
      await _mPlayer.resume();
      if (!mounted) return;
      setState(() => _menuOpen = false);
      _controller.run();
    } finally {
      if (mounted) setState(() => _menuTransition = false);
    }
  }

  void _toggleMenu() => _do(_menuOpen ? _resumeFromMenu : _openMenu);

  // File pickers and nested settings keep the background resume gesture
  // disabled until the entire action has completed, including cancellation.
  void _menuAction(Future<void> Function() action) {
    if (_menuBusy || _menuTransition || _progress != null) return;
    setState(() => _menuBusy = true);
    _do(() async {
      try {
        await action();
      } catch (_) {
        _resumeAfterAction = false;
        rethrow;
      } finally {
        if (mounted) setState(() => _menuBusy = false);
      }
      if (!mounted) return;
      if (_resumeAfterAction) {
        _resumeAfterAction = false;
        await _resumeFromMenu();
      }
    });
  }

  Future<void> _openGameItem(DiscItem item) async {
    final scan = _scan;
    if (scan == null) return;
    final extension = _fileExtension(item.path);
    var isDisc = extension == 'cue' || extension == 'iso';
    if (extension == 'bin') {
      // A .bin may be a cartridge or an unreferenced disc image.
      final probe = AsyncCdromDrive();
      try {
        await probe.insert(scan.sourceOf(item));
        isDisc = probe.status.isReady &&
            await CoreFactory.systemOfDisc(probe) != null;
      } finally {
        await probe.eject();
      }
    }
    if (isDisc) {
      await _insertItem(item);
      return;
    }
    final file = scan.folder.file(item.path);
    late Uint8List data;
    try {
      data = await file.read(0, await file.length());
    } finally {
      await file.close();
    }
    final (rom, name) = _extractIfZip(data, item.path);
    await _boot(CoreFactory.systemOfFile(name, rom),
        rom: rom, name: name, folder: _folderHistoryKey(scan), path: item.path);
  }

  /// replaces the running core with [system] booted with its BIOS and [rom].
  /// without [rom], the system boots its BIOS (and the disc in the drive).
  Future<bool> _boot(CoreSystem system,
      {Uint8List? rom,
      required String name,
      String? folder,
      String? path}) async {
    final bios = await _storage.bios(system.id);
    if (!mounted) return false;
    if (system.biosRequired && bios.isEmpty) {
      AppSnackBar.show("set the BIOS of ${system.name} from Core setup");
      _coreSetupKey.currentState?.showButtonMenu();
      return false;
    }

    await _controller.init(system.id, rom: rom, bios: bios, drive: _drive);

    _keyHandler.init();
    _romName = name;
    if (rom != null) {
      await _storage.recordRecent(system.id, name,
          rom: rom, folder: folder, path: path);
    }

    AppSnackBar.show("loaded: $name");

    if (!widget.config.debug) {
      if (_menuBusy) {
        _resumeAfterAction = true;
      } else {
        await _resumeFromMenu();
      }
    }
    return true;
  }

  /// lets the user select the BIOS files of [system] and saves them
  _selectBios(CoreSystem system) async {
    final files = await _pickFiles(
        multiple: system.biosFiles > 1,
        dialogTitle: "Select the BIOS of ${system.name}");
    if (files == null) {
      return;
    }

    if (files.length != system.biosFiles) {
      throw Exception("${system.name} requires ${system.biosFiles} BIOS "
          "files: ${files.length} selected");
    }

    await _storage
        .setBios(system.id, [for (final (data, name) in files) (name, data)]);
    AppSnackBar.show("BIOS of ${system.name}: "
        "${_storage.biosNames(system.id).join(", ")}");
  }

  /// plays the disc in the drive. the running system keeps running if it
  /// plays the disc (the disc is changed as on the real console), otherwise
  /// the system of the disc boots.
  Future<bool> _startDisc(String name) async {
    final system = await CoreFactory.systemOfDisc(_drive);
    if (system == null) {
      AppSnackBar.show("unknown disc: $name");
      return false;
    }

    final running = _controller.system;
    if (running.isNotEmpty && CoreFactory.system(running).disc == system.id) {
      AppSnackBar.show("inserted: $name");
      _romName = name;
      _resumeAfterAction = !widget.config.debug;
      return true;
    }

    return await _boot(system, name: name);
  }

  static const _lastDiscDirKey = "disc_dir";

  /// scans the directory selected last time, if it can be opened again
  _restoreDiscFolder() async {
    final directories = _storage.gameDirectories;
    final known = directories.map((entry) => entry.id).toSet();
    // Preserve directories of histories written before the directory registry.
    final legacy = [
      _storage.setting(_lastDiscDirKey),
      ..._storage.recentGames.map((game) => game.folder),
    ];
    for (final key in legacy.whereType<String>()) {
      if (!known.add(key) || key.startsWith('web:')) continue;
      directories.add(GameDirectory(key, key.split('/').last, key));
    }
    for (final directory in directories) {
      try {
        final token = directory.restoreKey;
        final folder = token == null ? null : await openDiscFolderAt(token);
        if (!mounted) return;
        if (folder != null) {
          _openedFolders[directory.id] = folder;
          _folderIds[folder] = directory.id;
          await _storage.rememberDirectory(
              GameDirectory(directory.id, folder.name, folder.persistentPath));
        }
      } catch (_) {
        // Keep the saved token so the user can retry restoring access.
      }
    }
    if (!mounted) return;
    setState(() {});
  }

  Future<DiscFolder?> _restoreSavedDirectory(String id) async {
    final saved =
        _storage.gameDirectories.where((entry) => entry.id == id).firstOrNull;
    final token = saved?.restoreKey;
    if (token == null) return _openedFolders[id];
    final folder = await openDiscFolderAt(token, requestPermission: true);
    if (folder != null) {
      _openedFolders[id] = folder;
      _folderIds[folder] = id;
    } else {
      _openedFolders.remove(id);
    }
    return folder;
  }

  Future<void> _showGames() async {
    final scan = _scan;
    if (scan == null || !mounted) return;
    final selected = await showDialog<DiscItem>(
        context: context, builder: (_) => GameListDialog(scan: scan));
    if (selected != null && mounted) await _openGameItem(selected);
  }

  Future<void> _openSavedDirectory(String id) async {
    final folder = await _restoreSavedDirectory(id);
    if (folder == null) {
      throw StateError('Directory unavailable; select it again');
    }
    await _scanFolder(folder);
    await _showGames();
  }

  _selectDiscFolder() async {
    final folder = await pickDiscFolder();
    if (folder != null && mounted) {
      await _scanFolder(folder);
      await _showGames();
    }
  }

  /// Cue references are excluded; every other file is shown in the game list.
  _scanFolder(DiscFolder folder) async {
    if (_progress != null || !mounted) return;
    _cancelScan = false;
    setState(() {
      _scan = null;
      _progress = const ScanProgress(true, 0, 0, 0, 0);
    });
    try {
      final result = await DiscScanner.scan(folder,
          includeAllFiles: true,
          onProgress: (p) {
            if (mounted) setState(() => _progress = p);
          },
          isCancelled: () => _cancelScan || !mounted);
      if (!result.cancelled && mounted) {
        _scan = result;
        final id = _folderHistoryKey(result);
        _folderIds[folder] = id;
        _openedFolders[id] = folder;
        await _storage.rememberDirectory(
            GameDirectory(id, folder.name, folder.persistentPath));
        await _storage.setSetting(_lastDiscDirKey, id);
        AppSnackBar.show('${result.items.length} file(s) in ${folder.name}');
      }
    } finally {
      if (mounted) setState(() => _progress = null);
    }
  }

  /// inserts the image selected from the list and starts it
  _insertItem(DiscItem item, {ScanResult? sourceScan}) async {
    final scan = sourceScan ?? _scan;
    if (scan == null) return;

    await _drive.insert(scan.sourceOf(item));
    if (!_drive.status.isReady) {
      AppSnackBar.show("failed to read: ${item.path}");
      return;
    }

    if (await _startDisc(item.path)) {
      await _storage.recordRecent(_controller.system, item.path,
          folder: _folderHistoryKey(scan));
    }
  }

  String _folderHistoryKey(ScanResult scan) =>
      _folderIds[scan.folder] ??
      _openedFolders.entries
          .where((entry) =>
              scan.folder.identityKey != null &&
              entry.value.identityKey == scan.folder.identityKey)
          .firstOrNull
          ?.key ??
      scan.folder.identityKey ??
      'web:${scan.folder.name}:${getCrc32(utf8.encode(jsonEncode(scan.files.map((file) => file.path).toList()..sort())))}';

  bool _historyAvailable(RecentGame game) {
    if (!game.isDisc) return true;
    final id = game.folder;
    final scan = _scan;
    if (scan != null && id == _folderHistoryKey(scan)) {
      return scan.items.any((item) => item.path == game.sourcePath) &&
          !scan.skipped.contains(game.sourcePath);
    }
    return _openedFolders.containsKey(id) ||
        _storage.gameDirectories.any((directory) =>
            directory.id == id &&
            (directory.restoreKey?.startsWith('fs-access:') ?? false));
  }

  Future<void> _launchHistory(RecentGame game) async {
    final id = game.folder;
    if (id != null) {
      final folder = await _restoreSavedDirectory(id);
      if (game.isDisc) {
        if (folder == null) {
          throw StateError('Directory unavailable; select it again');
        }
        // Resolve the saved disc directly, without rebuilding the game list.
        final files = await folder.list().toList();
        if (!files.any((file) => file.path == game.sourcePath)) {
          throw StateError('Game is no longer available in the directory');
        }
        await _insertItem(DiscItem(game.sourcePath),
            sourceScan: ScanResult(folder, files, const [], const [], false));
        return;
      }
    }
    final rom = await _storage.recentRom(game);
    if (rom == null) throw StateError('Saved ROM is unavailable');
    await _boot(CoreFactory.system(game.core),
        rom: rom, name: game.name, folder: game.folder, path: game.path);
  }

  _discMenuAction(Object action) async {
    switch (action) {
      case DiscItem():
        await _openGameItem(action);
      case String():
        await _openSavedDirectory(action);
      case _DiscAction.eject:
        await _drive.eject(); // the tray stays open
      case _DiscAction.empty:
        await _drive.insert(); // the tray is closed without a disc
      case _DiscAction.select:
        await _selectDiscFolder();
    }
    setState(() {});
  }

  _stop() async {
    _mPlayer.pause();
    await _controller.stop();
  }

  _reset() async {
    await _controller.reset();
  }

  _debug(bool onoff) {
    _controller.debugger.setDebugView(onoff);
  }

  PopupMenuItem<CoreSystem> _coreSetupItem(CoreSystem s) {
    final names = _storage.biosNames(s.id);
    return PopupMenuItem(
        value: s,
        child: ListTile(
            title: Text(s.name),
            subtitle: Text(names.isEmpty
                ? "BIOS not set${s.biosRequired ? "" : " (optional)"}"
                : names.join(", ")),
            trailing: const Icon(Icons.file_open_outlined)));
  }

  Widget _menuToolbar() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          IgnorePointer(
              ignoring: _menuBusy || _menuTransition || _progress != null,
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  PopupMenuButton<CoreSystem>(
                    key: _coreSetupKey,
                    icon: const Icon(Icons.settings),
                    tooltip: "Core setup",
                    onSelected: (system) =>
                        _menuAction(() async => _selectBios(system)),
                    itemBuilder: (_) => [
                      for (final s
                          in CoreFactory.systems.where((s) => s.hasBios))
                        _coreSetupItem(s),
                    ],
                  ),

                  PopupMenuButton<Object>(
                    icon: const Icon(Icons.folder_open),
                    tooltip: "CD / ROM",
                    onSelected: (action) =>
                        _menuAction(() async => _discMenuAction(action)),
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                          value: _DiscAction.eject,
                          child: Text("Eject (open tray)")),
                      const PopupMenuItem(
                          value: _DiscAction.empty,
                          child: Text("Empty (closed, no disc)")),
                      const PopupMenuItem(
                          value: _DiscAction.select,
                          child: Text("Select directory...")),
                      if (_storage.gameDirectories.isNotEmpty)
                        const PopupMenuDivider(),
                      for (final directory in _storage.gameDirectories)
                        PopupMenuItem(
                            value: directory.id, child: Text(directory.name)),
                    ],
                  ),

                  PopupMenuButton<RecentGame>(
                    icon: const Icon(Icons.history),
                    tooltip: 'History',
                    onSelected: (game) =>
                        _menuAction(() => _launchHistory(game)),
                    itemBuilder: (_) => [
                      if (_storage.recentGames.isEmpty)
                        const PopupMenuItem(
                            enabled: false, child: Text('No history')),
                      for (final game in _storage.recentGames)
                        PopupMenuItem(
                            value: game,
                            enabled: _historyAvailable(game),
                            child: Text(
                                '${CoreFactory.system(game.core).name.toUpperCase()} ${game.name}')),
                    ],
                  ),

                  IconButton(
                    tooltip: 'Resume',
                    onPressed: _hasGame ? () => _do(_resumeFromMenu) : null,
                    icon: const Icon(Icons.play_arrow),
                  ),

                  // reset button
                  iconButton(Icons.restart_alt, "Reset",
                      () => _menuAction(() async => _reset())),

                  // debug on/off button
                  _debugging
                      ? iconButton(Icons.bug_report, "Disable Debug Options",
                          () => _do(() => _debug(false)))
                      : iconButton(
                          Icons.bug_report_outlined,
                          "Enable Debug Options",
                          () => _do(() => _debug(true))),
                  IconButton(
                    tooltip: 'License',
                    onPressed: () => _menuAction(() async {
                      await Navigator.of(context).push(MaterialPageRoute<void>(
                          builder: (_) => const LicensePage()));
                    }),
                    icon: const Icon(Icons.info_outline),
                  ),
                ],
              )),
          if (_debugging)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DebugController(controller: _controller),
            ),
          if (_romName.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child:
                  Text(_romName, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          if (_menuBusy || _menuTransition) const LinearProgressIndicator(),
          if (_progress != null) ...[
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text('Scanning: $_progress',
                  maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
            LinearProgressIndicator(
              value: _progress!.isListing || _progress!.cues == 0
                  ? null
                  : _progress!.checkedCues / _progress!.cues,
            ),
            IconButton(
              tooltip: 'Cancel scan',
              onPressed: () => _cancelScan = true,
              icon: const Icon(Icons.close),
            ),
          ],
        ],
      );

  Widget _fpsIndicator() => StreamBuilder<double>(
        stream: _controller.fpsStream,
        builder: (context, snapshot) => DecoratedBox(
          key: const ValueKey('fps-indicator'),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Text('${(snapshot.data ?? 0.0).toStringAsFixed(1)} fps',
                style: const TextStyle(color: Colors.white)),
          ),
        ),
      );

  Widget _gameContent() => LayoutBuilder(builder: (context, constraints) {
        final wideDebug = _debugging && constraints.maxWidth >= 1000;
        return Row(children: [
          Expanded(
            child: Column(children: [
              Expanded(
                  child: CoreView(
                      controller: _controller,
                      container: _imageContainer,
                      input: _padInput)),
              if (_debugging) ...[
                SizedBox(
                  height: 100,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: StreamBuilder<DebugOption>(
                      stream: _controller.debugger.debugStream,
                      builder: (ctx, snapshot) => SelectableText(
                          snapshot.data?.text ?? '',
                          style: debugStyle,
                          showCursor: true),
                    ),
                  ),
                ),
              ],
            ]),
          ),
          if (wideDebug)
            SizedBox(
              width: 400,
              child: SingleChildScrollView(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DebugPane(debugger: _controller.debugger),
                ),
              ),
            ),
        ]);
      });

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !(_menuOpen && _hasGame),
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop && _menuOpen) _do(_resumeFromMenu);
        },
        child: Scaffold(
            body: FloatingGameMenu(
          expanded: _menuOpen,
          canResume: _hasGame,
          busy: _menuBusy || _menuTransition || _progress != null,
          onToggle: _toggleMenu,
          onResume: () => _do(_resumeFromMenu),
          toolbar: _menuToolbar(),
          topRight: _fpsIndicator(),
          child: SafeArea(child: _gameContent()),
        )),
      );
}
