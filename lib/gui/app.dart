import 'dart:async';
import 'dart:convert';

import 'package:archive/archive.dart' show getCrc32;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fnesemu/util/debug.dart';
import 'package:mp_bigfile_picker/mp_bigfile_picker.dart';

import '../cdrom/async_cdrom_drive.dart';
import '../cdrom/disc_folder.dart';
import '../core/core_api.dart';
import '../styles.dart';
import 'core_view.dart';
import 'debug/debug_controller.dart';
import 'debug/debug_pane.dart';
import 'floating_game_menu.dart';
import 'game_directory.dart';
import 'game_list.dart';
import 'key_handler.dart';
import 'pad_input.dart';
import 'picked_disc.dart';
import 'recent_game.dart';
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
  final _progress =
      ValueNotifier<ScanProgress?>(null); // not null while scanning
  bool _cancelScan = false;

  // shared by cores, the disc is kept across ROM loading
  final _drive = AsyncCdromDrive();

  final _coreSetupKey = GlobalKey<PopupMenuButtonState>();

  @override
  void initState() {
    super.initState();

    _mPlayer = widget.soundPlayer ?? SoundPlayer();

    _storage = widget.storage
      ..onEvent = AppSnackBar.show
      ..onSramSaved = _showSramSaved;

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
    _sramSavedTimer?.cancel();
    _sramSaved.dispose();
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
        _progress.value != null ||
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
    if (_menuBusy || _menuTransition || _progress.value != null) return;
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
    final isDisc =
        await CoreFactory.isDiscImage(item.path, scan.sourceOf(item));
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
    final (rom, name) = CoreFactory.unpackRom(data, item.path);
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
  _selectBios(BiosSetup setup) async {
    final files = await _pickBiosFiles(
        multiple: setup.maxFiles > 1,
        dialogTitle: 'Select the BIOS of ${setup.name}');
    if (files == null) return;
    final existing = <String, List<BiosFile>>{};
    for (final system in setup.systems) {
      final data = await _storage.bios(system.id);
      final names = _storage.biosNames(system.id);
      existing[system.id] = [
        for (var i = 0; i < data.length && i < names.length; i++)
          (names[i], data[i])
      ];
    }
    final updates = setup.prepare(
        [for (final (data, name) in files) (name, data)],
        existing: existing);
    for (final update in updates.entries) {
      await _storage.setBios(update.key, update.value);
    }
    AppSnackBar.show('BIOS of ${setup.name}: ${_biosSummary(setup)}');
  }

  String _biosSummary(BiosSetup setup) => setup.summary({
        for (final system in setup.systems)
          system.id: _storage.biosNames(system.id),
      });

  // the directories selected last time, where the pickers open next time
  static const _lastBiosDirKey = "last_bios_dir";
  static const _lastGameDirKey = "last_game_dir";

  Future<List<(Uint8List, String)>?> _pickBiosFiles(
          {required bool multiple, required String dialogTitle}) =>
      _pickFiles(
          multiple: multiple,
          dialogTitle: dialogTitle,
          initialDirectory: _storage.setting(_lastBiosDirKey),
          onDirectory: (dir) => _storage.setSetting(_lastBiosDirKey, dir));

  /// plays the disc in the drive. the running system keeps running if it
  /// plays the disc (the disc is changed as on the real console), otherwise
  /// the system of the disc boots.
  Future<bool> _startDisc(String name) async {
    final system = await CoreFactory.systemOfDisc(_drive);
    if (system == null) {
      AppSnackBar.show("unknown disc: $name");
      return false;
    }

    if (_controller.acceptsDisc(system)) {
      AppSnackBar.show("inserted: $name");
      _romName = name;
      _resumeAfterAction = !widget.config.debug;
      return true;
    }

    return await _boot(system, name: name);
  }

  static const _lastDiscDirKey = "disc_dir";

  // set once the directories of older histories are in the directory list
  static const _directoriesImportedKey = "directories_imported";

  /// scans the directory selected last time, if it can be opened again
  _restoreDiscFolder() async {
    final directories = _storage.gameDirectories;
    final known = directories.map((entry) => entry.id).toSet();
    // Preserve directories of histories written before the directory registry,
    // once: a directory removed later must not come back from the histories.
    final legacy = _storage.setting(_directoriesImportedKey) != null
        ? <String?>[]
        : [
            _storage.setting(_lastDiscDirKey),
            ..._storage.recentGames.map((game) => game.folder),
          ];
    for (final key in legacy.whereType<String>()) {
      if (!known.add(key) || key.startsWith('web:')) continue;
      directories.add(GameDirectory(key, key.split('/').last, key, path: key));
    }
    for (final directory in directories) {
      try {
        final token = directory.restoreKey;
        final folder = token == null ? null : await openDiscFolderAt(token);
        if (!mounted) return;
        if (folder != null) {
          _openedFolders[directory.id] = folder;
          _folderIds[folder] = directory.id;
          await _storage.updateDirectory(GameDirectory(
              directory.id, folder.name, folder.persistentPath,
              path: folder.displayPath));
        }
      } catch (_) {
        // Keep the saved token so the user can retry restoring access.
      }
    }
    await _storage.setSetting(_directoriesImportedKey, "1");
    if (!mounted) return;
    setState(() {});
  }

  /// removes the directory of [folder] from the menu, and gives back the
  /// access to it kept to open it again
  Future<void> _removeDirectory(DiscFolder folder) async {
    final id = _folderIds[folder];
    if (id == null) return;
    final saved =
        _storage.gameDirectories.where((entry) => entry.id == id).firstOrNull;
    final key = saved?.restoreKey ?? folder.persistentPath;
    if (key != null) await releaseDirectory(key);
    await _storage.forgetDirectory(id);
    _openedFolders.remove(id);
    _folderIds[folder] = null;
    if (!mounted) return;
    setState(() {});
    AppSnackBar.show("removed: ${folder.name}");
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

  /// scans [folder] and lets the user select a game from it. the dialog
  /// shows the progress until the list is ready, and closing it stops the scan
  Future<void> _scanAndShowGames(DiscFolder folder) async {
    if (!mounted) return;
    final scan = ValueNotifier<ScanResult?>(null);
    var dialogOpen = true;
    final scanning = _scanFolder(folder).then((result) => scan.value = result,
        onError: (Object e, StackTrace st) {
      if (dialogOpen && mounted) Navigator.of(context).pop();
      Error.throwWithStackTrace(e, st);
    });
    final selected = await showDialog<DiscItem>(
        context: context,
        builder: (_) => GameListDialog(
            title: folder.name,
            scan: scan,
            progress: _progress,
            onRemove: () => _removeDirectory(folder)));
    dialogOpen = false;
    _cancelScan = true;
    await scanning;
    if (selected != null && mounted) await _openGameItem(selected);
  }

  Future<void> _openSavedDirectory(String id) async {
    final folder = await _restoreSavedDirectory(id);
    if (folder == null) {
      throw StateError('Directory unavailable; select it again');
    }
    await _scanAndShowGames(folder);
  }

  _selectDiscFolder() async {
    final folder = await pickDiscFolder(
        initialDirectory: _storage.setting(_lastGameDirKey));
    if (folder != null && mounted) {
      final path = _localPath(folder.displayPath);
      if (path != null) await _storage.setSetting(_lastGameDirKey, path);
      await _scanAndShowGames(folder);
    }
  }

  /// Cue references are excluded; every other file is shown in the game list.
  Future<ScanResult?> _scanFolder(DiscFolder folder) async {
    if (_progress.value != null || !mounted) return null;
    _cancelScan = false;
    _scan = null;
    _progress.value = const ScanProgress(true, 0, 0, 0, 0);
    try {
      final result = await DiscScanner.scan(folder,
          includeAllFiles: true,
          onProgress: (p) => _progress.value = p,
          isCancelled: () => _cancelScan || !mounted);
      if (result.cancelled || !mounted) return null;
      _scan = result;
      final id = _folderHistoryKey(result);
      _folderIds[folder] = id;
      _openedFolders[id] = folder;
      await _storage.rememberDirectory(GameDirectory(
          id, folder.name, folder.persistentPath,
          path: folder.displayPath));
      await _storage.setSetting(_lastDiscDirKey, id);
      return result;
    } finally {
      _progress.value = null;
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
    if (CoreFactory.systemOrNull(game.core) == null) return false;
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

  PopupMenuItem<BiosSetup> _coreSetupItem(BiosSetup setup) => PopupMenuItem(
      value: setup,
      child: ListTile(
          title: Text(setup.name),
          subtitle: Text(_biosSummary(setup)),
          trailing: const Icon(Icons.file_open_outlined)));

  Widget _menuToolbar() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          IgnorePointer(
              ignoring: _menuBusy || _menuTransition || _progress.value != null,
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  PopupMenuButton<BiosSetup>(
                    key: _coreSetupKey,
                    icon: const Icon(Icons.settings),
                    tooltip: "Core setup",
                    enabled: CoreFactory.biosSetups.isNotEmpty,
                    onSelected: (system) =>
                        _menuAction(() async => _selectBios(system)),
                    itemBuilder: (_) => [
                      for (final setup in CoreFactory.biosSetups)
                        _coreSetupItem(setup),
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
                            value: directory.id, child: Text(directory.path)),
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
                                '${(CoreFactory.systemOrNull(game.core)?.name ?? game.core).toUpperCase()} ${game.name}')),
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
          if (_debugging) _registerDump(height: 160),
          if (_romName.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child:
                  Text(_romName, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
        ],
      );

  // true for a moment when the sram is saved
  final _sramSaved = ValueNotifier<bool>(false);
  Timer? _sramSavedTimer;

  void _showSramSaved() {
    _sramSaved.value = true;
    _sramSavedTimer?.cancel();
    _sramSavedTimer = Timer(
        const Duration(milliseconds: 1500), () => _sramSaved.value = false);
  }

  // the same look as the fps indicator
  static Widget _badge(Widget child, {Key? key}) => DecoratedBox(
        key: key,
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: child,
        ),
      );

  Widget _fpsIndicator() => Row(mainAxisSize: MainAxisSize.min, children: [
        // shown for a moment when the sram is saved
        ValueListenableBuilder<bool>(
          valueListenable: _sramSaved,
          builder: (context, lit, _) => AnimatedOpacity(
            opacity: lit ? 1 : 0,
            duration: const Duration(milliseconds: 300),
            child: _badge(
                const Text('saved', style: TextStyle(color: Colors.white)),
                key: const ValueKey('sram-saved')),
          ),
        ),
        const SizedBox(width: 6),
        StreamBuilder<double>(
          stream: _controller.fpsStream,
          builder: (context, snapshot) => _badge(
              Text('${(snapshot.data ?? 0.0).toStringAsFixed(1)} fps',
                  style: const TextStyle(color: Colors.white)),
              key: const ValueKey('fps-indicator')),
        ),
      ]);

  Widget _registerDump({required double height}) => SizedBox(
        height: height,
        child: SingleChildScrollView(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: StreamBuilder<DebugOption>(
              stream: _controller.debugger.debugStream,
              initialData: _controller.debugger.opt,
              builder: (context, snapshot) => SelectableText(
                snapshot.data?.text ?? '',
                style: debugStyle,
              ),
            ),
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
                _registerDump(height: 100),
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
          busy: _menuBusy || _menuTransition || _progress.value != null,
          onToggle: _toggleMenu,
          onResume: () => _do(_resumeFromMenu),
          toolbar: _menuToolbar(),
          topRight: _fpsIndicator(),
          child: SafeArea(child: _gameContent()),
        )),
      );
}
