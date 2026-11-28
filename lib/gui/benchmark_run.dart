part of 'app.dart';

/// runs the scenes of a benchmark archive one after another on the page's
/// controller and drive
class _BenchmarkRun {
  final MainPageState page;
  final BenchArchive archive;
  final void Function(String status) onStatus;

  /// the OS, CPU and GPU of the machine, in each record
  final Map<String, Object?> host;
  bool _cancelled = false;

  // the files of the ROM directories, listed once per run
  List<(PickedDirectory, List<String>)>? _folders;

  _BenchmarkRun(this.page, this.archive, this.onStatus, this.host);


  // the setting that remembers where the disc of a media identity was found
  static String _discKey(int media) => 'benchmark_disc/$media';

  CoreController get _controller => page._controller;

  void cancel() {
    _cancelled = true;
    _controller.stop();
  }

  Future<List<BenchResult>> run(List<BenchScene> scenes) async {
    final results = <BenchResult>[];
    for (final (i, scene) in scenes.indexed) {
      if (_cancelled) {
        results.add(BenchResult(scene, error: 'cancelled'));
        continue;
      }
      final label = '${i + 1}/${scenes.length} ${scene.name}';
      onStatus('$label: loading');
      try {
        results.add(await _scene(scene, label));
      } catch (e, st) {
        _log.errorc(() => 'benchmark ${scene.name}: $e\n$st');
        results.add(BenchResult(scene, error: '$e'));
      }
    }
    return results;
  }

  Future<BenchResult> _scene(BenchScene scene, String label) async {
    final system = CoreFactory.systemOrNull(scene.core);
    if (system == null) return BenchResult(scene, error: 'unknown core');
    final state = await archive.read(scene.state);
    final media = StateHeader.of(state).media;
    final bios = [for (final b in scene.bios) await archive.read(b)];
    await _registerBios(system, scene, bios);
    final drive = page._drive;
    if (scene.disc case final disc?) {
      if (archive.names.contains(disc)) {
        final benchDrive = BenchDisc.decode(await archive.read(disc)).openDrive();
        await drive.insert();
        await _controller.init(system.id, bios: bios, drive: benchDrive);
      } else if (!await _loadDisc(system, bios, disc, media)) {
        return BenchResult(scene, error: 'disc not found');
      }
    } else {
      Uint8List? rom;
      if (scene.rom case final name?) {
        final bytes = await archive.read(name);
        (rom, _) = isZip(name)
            ? await compute(_unpackRomTask, (bytes, name))
            : unpackRom(bytes, name);
      }
      await drive.insert();
      await _controller.init(system.id, rom: rom, bios: bios, drive: drive);
    }
    drive.clearPendingWait();
    await _controller.loadState(state);
    if (_cancelled) return BenchResult(scene, error: 'cancelled');
    onStatus('$label: warmup');
    final timing = await _controller.benchmark(
        warmup: scene.warmup,
        measure: scene.measure,
        onProgress: (frames) {
          if (frames % 10 == 0) onStatus('$label: $frames/${scene.measure}');
        });
    final result = BenchResult(scene,
        timing: timing,
        jit: _controller.debugger.state.jitEnabled,
        cpuMHzEnd: await currentCpuMHz());
    final record = result.record(
        machine: benchPlatform,
        build: AppBuild.current,
        date: DateTime.now(),
        host: host);
    debugPrint('benchmark ${jsonEncode(record)}');
    return result;
  }

  /// Keeps the BIOS files of [scene] as those of [system] when the app has
  /// none, so that its games boot without the archive afterwards. The BIOS
  /// that the user set stays.
  Future<void> _registerBios(
      CoreSystem system, BenchScene scene, List<Uint8List> bios) async {
    final storage = page._storage;
    if (bios.isEmpty || storage.biosNames(system.id).isNotEmpty) return;
    final names = scene.biosNames;
    await storage.setBios(system.id, [
      for (final (i, data) in bios.indexed) (names[i], data)
    ]);
    _log.info('benchmark: set the BIOS of ${system.id}: ${names.join(', ')}');
  }

  /// boots [system] with each disc that may be [name] until one has the
  /// media identity [media]; the disc found is remembered for the next run
  Future<bool> _loadDisc(
      CoreSystem system, List<Uint8List> bios, String name, int media) async {
    final folders = _folders ??= await _listFolders();
    final key = _discKey(media);
    final known = page._storage.setting(key);
    final tried = <String>{};
    Future<bool> attempt(PickedDirectory folder, List<String> files,
        String path, String folderId) async {
      if (!tried.add('$folderId/$path') || _cancelled) return false;
      onStatus('looking for $name: $path');
      try {
        final drive = page._drive;
        await drive.insert(ScanResult(folder, files, const [], const [], false)
            .sourceOf(RomFile(path)));
        if (!drive.status.isReady) return false;
        if ((await CoreFactory.systemOfDisc(drive))?.id != system.id) {
          return false;
        }
        await _controller.init(system.id, bios: bios, drive: drive);
        if (await _controller.stateMedia() != media) return false;
      } catch (e) {
        _log.infoc(() => 'benchmark: skipped $path: $e');
        return false;
      }
      await page._storage.setSetting(key, jsonEncode([folderId, path]));
      return true;
    }

    String idOf(PickedDirectory folder) =>
        page._folderIds[folder] ?? folder.identityKey ?? folder.name;
    if (known != null) {
      final [folderId, path] = jsonDecode(known) as List;
      for (final (folder, files) in folders) {
        if (idOf(folder) == folderId && files.contains(path)) {
          if (await attempt(
              folder, files, path as String, folderId as String)) {
            return true;
          }
        }
      }
    }
    // the likeliest discs of all the folders first
    final candidates = [
      for (final (folder, files) in folders)
        for (final path in files)
          if (discRank(name, path) case final rank?) (rank, folder, files, path)
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    for (final (_, folder, files, path) in candidates) {
      if (await attempt(folder, files, path, idOf(folder))) return true;
    }
    return false;
  }

  Future<List<(PickedDirectory, List<String>)>> _listFolders() async {
    final folders = <PickedDirectory>[
      if (page._scan case final scan?) scan.folder,
    ];
    for (final directory in page._storage.romDirectories) {
      try {
        final folder = await page._restoreSavedDirectory(directory.id);
        if (folder != null && !folders.contains(folder)) folders.add(folder);
      } catch (e) {
        _log.infoc(() => 'benchmark: cannot open ${directory.path}: $e');
      }
    }
    return [
      for (final folder in folders) (folder, await folder.walk().toList())
    ];
  }
}

(Uint8List, String) _unpackRomTask((Uint8List, String) args) =>
    unpackRom(args.$1, args.$2);
