import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:fnesemu_core/app_api.dart';

import 'blob_store/blob_store.dart';
import 'recent_game.dart';
import 'rom_directory.dart';
import 'state_slot.dart';

class Storage extends Sram {
  static const int saveIntervalSec = 5;

  bool _dirty = false;

  Function(String) onEvent = (String s) {};

  /// called when the sram is written to the persistent store
  void Function() onSramSaved = () {};

  Timer? _worker;

  final BlobStore? _store;

  // sram entries are preloaded so that cores can call init() synchronously
  final Map<String, Uint8List> _cache;

  // application settings, preloaded as well
  final Map<String, String> _settings;

  // keys of the BIOS files. the data is read when a core is created
  final Set<String> _biosKeys;

  // BIOS files kept on memory when the persistent store is unavailable
  final Map<String, Uint8List> _biosData = {};

  Storage._(this._store, this._cache, this._settings, this._biosKeys) {
    _worker = Timer.periodic(const Duration(seconds: Storage.saveIntervalSec),
        (timer) => saveIfDirty());
  }

  static Future<Storage> open({BlobStore? store}) async {
    try {
      store ??= await BlobStore.open();

      final cache = <String, Uint8List>{};
      final settings = <String, String>{};
      final biosKeys = <String>{};
      for (final key in await store.keys()) {
        final kind = StorageKey.kindOf(key);
        if (kind == StorageKey.sram) {
          final data = await store.get(key);
          if (data != null) cache[key] = data;
        } else if (kind == StorageKey.settings) {
          final data = await store.get(key);
          if (data != null) settings[key] = utf8.decode(data);
        } else if (kind == StorageKey.bios) {
          biosKeys.add(key);
        }
      }
      return Storage._(store, cache, settings, biosKeys);
    } catch (e) {
      // run without persistence (e.g. storage is unavailable in the browser)
      return Storage._(null, {}, {}, {});
    }
  }

  /// returns the setting [name] saved before, or null
  String? setting(String name) => _settings[StorageKey.setting(name)];

  /// saves the setting [name]. the value can be read at once, and is kept
  /// across restarts if the persistent store is available.
  Future<void> setSetting(String name, String value) async {
    final key = StorageKey.setting(name);
    _settings[key] = value;
    try {
      await _store?.put(key, Uint8List.fromList(utf8.encode(value)));
    } catch (e) {
      onEvent("failed to save $name: $e");
    }
  }

  final _recentRomData = <String, Uint8List>{};

  List<RecentGame> get recentGames {
    try {
      final games = (jsonDecode(setting('recent_games') ?? '[]') as List)
          .map((json) => RecentGame.fromJson(json as Map<String, dynamic>))
          .toList();
      games.sort((a, b) => b.lastPlayed.compareTo(a.lastPlayed));
      return games;
    } catch (e) {
      onEvent('failed to load game history: $e');
      return [];
    }
  }

  Future<Uint8List?> recentRom(RecentGame game) async =>
      _recentRomData[game.blobKey] ?? await _store?.get(game.blobKey);

  /// the identity of a game in the recent list.
  /// ROM identity is independent of the directory, preserving old counts
  /// when switching from individual file selection to directory selection.
  /// the state slots of a game are keyed by the same identity, so they
  /// follow the game the recent list shows.
  static String gameId(String core, String name,
      {Uint8List? rom, String? folder}) {
    final identity = rom == null
        ? [core, name, folder]
        : [core, name, null, rom.length, getCrc32(rom)];
    return base64Url.encode(utf8.encode(jsonEncode(identity)));
  }

  Future<void> recordRecent(String core, String name,
      {Uint8List? rom, String? folder, String? path}) async {
    assert(rom != null || folder != null);
    final id = gameId(core, name, rom: rom, folder: folder);
    final games = recentGames;
    final matches = games.where((game) => game.id == id);
    final previous = matches.isEmpty ? null : matches.first;
    final now = DateTime.now().microsecondsSinceEpoch;
    final latest = games.fold<int>(
        0, (last, game) => game.lastPlayed > last ? game.lastPlayed : last);
    final entry = RecentGame(
        id: id,
        core: core,
        name: name,
        folder: folder,
        disc: rom == null,
        path: path,
        count: (previous?.count ?? 0) + 1,
        lastPlayed: now > latest ? now : latest + 1);
    try {
      if (rom != null) {
        final store = _store;
        if (store == null) {
          _recentRomData[entry.blobKey] = Uint8List.fromList(rom);
        } else {
          await store.put(entry.blobKey, rom);
        }
      }
      games.removeWhere((game) => game.id == id);
      games.add(entry);
      final metadata = jsonEncode(games.map((game) => game.toJson()).toList());
      final metadataKey = StorageKey.setting('recent_games');
      await _store?.put(metadataKey, Uint8List.fromList(utf8.encode(metadata)));
      _settings[metadataKey] = metadata;
    } catch (e) {
      onEvent('failed to save game history: $e');
    }
  }

  /// the number of state slots of a game
  static const stateSlotCount = 10;

  // state blobs kept on memory when the persistent store is unavailable
  final Map<String, Uint8List> _stateBlobs = {};

  static String _stateSlotKey(String core, String gameId, int slot) {
    if (slot < 0 || slot >= stateSlotCount) {
      throw RangeError.range(slot, 0, stateSlotCount - 1, 'slot');
    }
    return StorageKey.of(core, 'state', '$gameId/$slot');
  }

  Future<Uint8List?> _stateBlob(String key) async {
    final store = _store;
    return store == null ? _stateBlobs[key] : await store.get(key);
  }

  /// the saved state slots of the game [gameId] of [core]: one entry per
  /// slot, null for an empty slot. a blob which cannot be read is reported
  /// and treated as empty.
  Future<List<StateSlotInfo?>> stateSlots(String core, String gameId) async {
    final slots = List<StateSlotInfo?>.filled(stateSlotCount, null);
    for (var slot = 0; slot < stateSlotCount; slot++) {
      final blob = await _stateBlob(_stateSlotKey(core, gameId, slot));
      if (blob == null) continue;
      try {
        slots[slot] = StateSlotBlob.header(blob, slot);
      } catch (e) {
        onEvent('failed to read state slot $slot of $gameId: $e');
      }
    }
    return slots;
  }

  /// the metadata of slot [slot] of the game [gameId] of [core], or null
  /// if the slot is empty. throws a FormatException if the blob is corrupt.
  Future<StateSlotInfo?> stateSlot(String core, String gameId, int slot) async {
    final blob = await _stateBlob(_stateSlotKey(core, gameId, slot));
    return blob == null ? null : StateSlotBlob.header(blob, slot);
  }

  /// saves [state] in slot [slot] of the game [gameId] of [core],
  /// replacing a state saved before. [thumbnail] is a PNG image of the
  /// game screen at the save.
  Future<void> saveStateSlot(String core, String gameId, int slot,
      Uint8List state,
      {Uint8List? thumbnail, DateTime? savedAt}) async {
    final blob = StateSlotBlob.build(state,
        thumbnail: thumbnail, savedAt: savedAt ?? DateTime.now());
    final key = _stateSlotKey(core, gameId, slot);
    final store = _store;
    if (store == null) {
      _stateBlobs[key] = blob;
    } else {
      await store.put(key, blob);
    }
  }

  /// the state saved in slot [slot] of the game [gameId] of [core].
  /// throws a StateError if the slot is empty, and a FormatException if
  /// the saved blob is corrupt.
  Future<Uint8List> loadStateSlot(String core, String gameId, int slot) async {
    final blob = await _stateBlob(_stateSlotKey(core, gameId, slot));
    if (blob == null) {
      throw StateError('state slot $slot is empty');
    }
    return StateSlotBlob.state(blob);
  }

  // the directories, the last opened first. the older setting kept them the
  // last opened last.
  static const _directoriesKey = 'game_directories_recent_first';
  static const _oldDirectoriesKey = 'game_directories';

  /// the directories selected before, the last opened one first
  List<RomDirectory> get romDirectories {
    final saved = setting(_directoriesKey);
    try {
      final directories = (jsonDecode(
              saved ?? setting(_oldDirectoriesKey) ?? '[]') as List)
          .map((json) => RomDirectory.fromJson(json as Map<String, dynamic>))
          .toList();
      return saved == null ? directories.reversed.toList() : directories;
    } catch (e) {
      onEvent('failed to load game directories: $e');
      return [];
    }
  }

  Future<void> _saveDirectories(List<RomDirectory> directories) => setSetting(
      _directoriesKey,
      jsonEncode(directories.map((entry) => entry.toJson()).toList()));

  /// puts [directory] at the top, as the last opened one
  Future<void> rememberDirectory(RomDirectory directory) =>
      _saveDirectories(romDirectories
        ..removeWhere((entry) => entry.id == directory.id)
        ..insert(0, directory));

  /// updates [directory] (a renewed access key) where it is in the order
  Future<void> updateDirectory(RomDirectory directory) {
    final directories = romDirectories;
    final i = directories.indexWhere((entry) => entry.id == directory.id);
    if (i < 0) {
      directories.add(directory);
    } else {
      directories[i] = directory;
    }
    return _saveDirectories(directories);
  }

  /// removes the directory [id] from the list
  Future<void> forgetDirectory(String id) =>
      _saveDirectories(romDirectories..removeWhere((entry) => entry.id == id));

  List<String> _biosKeysOf(String system) {
    final prefix = StorageKey.of(system, StorageKey.bios, "");
    return _biosKeys.where((k) => k.startsWith(prefix)).toList()..sort();
  }

  /// returns the file names of the BIOS of [system]
  List<String> biosNames(String system) {
    final prefix = StorageKey.of(system, StorageKey.bios, "");
    return [for (final k in _biosKeysOf(system)) k.substring(prefix.length)];
  }

  /// returns the BIOS files of [system], in the order of the file names
  Future<List<Uint8List>> bios(String system) async {
    final files = <Uint8List>[];
    for (final key in _biosKeysOf(system)) {
      final data = _biosData[key] ?? await _store?.get(key);
      if (data != null) files.add(data);
    }
    return files;
  }

  /// replaces the BIOS files of [system] with [files] of (name, data)
  Future<void> setBios(String system, List<(String, Uint8List)> files) async {
    for (final key in _biosKeysOf(system)) {
      _biosKeys.remove(key);
      _biosData.remove(key);
      await _store?.delete(key);
    }

    final store = _store;
    for (final (name, data) in files) {
      final key = StorageKey.of(system, StorageKey.bios, name);
      _biosKeys.add(key);
      if (store == null) {
        _biosData[key] = data;
      } else {
        await store.put(key, data);
      }
    }
  }

  void dispose() {
    saveIfDirty();
    _worker?.cancel();
  }

  @override
  void reset() {
    super.reset();
    _dirty = false;
  }

  @override
  void init(String id, Uint8List initialData) {
    // flush the previous sram before switching
    saveIfDirty();

    final saved = _cache[id];
    super.init(id, saved ?? initialData);
  }

  @override
  void write8(int addr, int value) {
    if (read8(addr) != value) {
      super.write8(addr, value);
      _dirty = true;
    }
  }

  void saveIfDirty() {
    if (id.isNotEmpty && _dirty) {
      save();
      _dirty = false;
    }
  }

  void save() {
    final key = id;
    final bytes = Uint8List.fromList(data);
    _cache[key] = bytes;

    final store = _store;
    if (store == null) {
      return;
    }

    store
        .put(key, bytes)
        .then((_) => onSramSaved())
        .catchError((e) => onEvent("failed to save $key: $e"));
  }
}
