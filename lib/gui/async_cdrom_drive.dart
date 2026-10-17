import 'dart:async';
import 'dart:typed_data';

import 'package:cdrom_image/cdrom_image.dart';
import 'package:fnesemu_core/app_api.dart';

final _log = DebugLog('app.cdrom');

class _CacheEntry {
  final Uint8List data; // empty if failed to read
  final DateTime loadedAt;
  _CacheEntry(this.data, this.loadedAt);
}

/// [CdromDrive] of the cores, which reads only the required sectors of a
/// [DiscImage] of cdrom_image in the background.
///
/// - the TOC is read when a disc is inserted by [insert], and kept on memory
/// - a missing sector is read with the [firstReadSectors] sectors from it
///   first, then [readAheadSectors] sectors are read ahead separately
/// - read sectors are cached for [cacheLifetime]
class AsyncCdromDrive implements CdromDrive {
  static const readAheadSectors = 75;

  /// a CD hunk of a CHD file has 8 sectors
  static const firstReadSectors = 8;
  static const cacheLifetime = Duration(seconds: 60);

  final DateTime Function() _now;

  AsyncCdromDrive({DateTime Function()? now}) : _now = now ?? DateTime.now;

  CdromDriveState _state = CdromDriveState.empty;
  DiscImage? _image;
  CdromToc _toc = CdromToc.empty;
  int _seekLba = 0;
  bool _seekRequested = false;

  /// the sector of the last [read] which returned null
  int? _waitLba;

  /// incremented on each disc change to discard the results of the old disc
  int _discId = 0;
  final _events = CdromDriveEvents();

  final _cache = <int, _CacheEntry>{};
  final _inflight = <int, Future<void>>{};
  DateTime _lastSweep = DateTime.fromMillisecondsSinceEpoch(0);

  /// for tests and debugging
  int get cachedSectors => _cache.length;

  /// true while the core waits for the drive: the TOC is being read, or the
  /// sector of the last seek or read is not available yet
  bool get isWaiting {
    if (_state == CdromDriveState.loading || _status.isSeeking) return true;
    final lba = _waitLba;
    return lba != null && _image != null && !_cache.containsKey(lba);
  }

  /// rebuilt on each change, as the core polls it on each exec
  CdromDriveStatus _status = CdromDriveStatus.empty;

  @override
  CdromDriveStatus get status => _status;

  @override
  CdromDriveEvent? takeEvent() => _events.take();

  @override
  void clearEvents() => _events.clear();

  void _updateStatus() {
    final image = _image;
    final readable = image != null && image.isReadable(_seekLba);
    final entry = _cache[_seekLba];

    _status = CdromDriveStatus(
      _state,
      _discId,
      _toc,
      seekLba: _seekLba,
      isSeeking: _seekRequested && readable && entry == null,
      seekError: _seekRequested &&
          (!readable || (entry != null && entry.data.isEmpty)),
    );
  }

  /// completes when all the reads in progress are done. for headless tools
  /// and tests which need the same result regardless of the speed of the
  /// files.
  Future<void> settle() async {
    while (_inflight.isNotEmpty) {
      await Future.wait(_inflight.values.toSet());
    }
  }

  /// opens the tray, and removes the disc. The tray stays open until
  /// [insert] is called.
  Future<void> eject() async {
    await _openTray();
  }

  /// closes the tray with the disc image [disc] (the arguments of
  /// [DiscImage.parse]: the image file and the files of its directory), or
  /// without a disc if null.
  /// The status changes to trayOpen first if the tray is not open, then to
  /// loading and ready (or error) when the TOC of [disc] is read.
  Future<void> insert([(DiscFile, Iterable<DiscFile>)? disc]) async {
    final discId =
        _state == CdromDriveState.trayOpen ? _discId : await _openTray();
    await _close(disc, discId);
  }

  /// opens the tray, returns the disc id of the status
  Future<int> _openTray() async {
    final discId = _changeDisc(CdromDriveState.trayOpen);
    _image = null;
    return discId;
  }

  Future<void> _close((DiscFile, Iterable<DiscFile>)? next, int discId) async {
    if (next == null) {
      if (discId == _discId) {
        _changeDisc(CdromDriveState.empty);
      }
      return;
    }

    if (discId != _discId) {
      return;
    }
    final loadingId = _changeDisc(CdromDriveState.loading);

    final watch = Stopwatch()..start();
    try {
      final (image, _) = await DiscImage.parse(next.$1, files: next.$2);
      if (loadingId != _discId) {
        return;
      }
      _image = image;
      _toc = CdromToc([
        for (final t in image.toc.tracks)
          CdromTrack(t.number, t.isAudio, t.startLba, t.sectors)
      ], image.totalSectors);
      _log.infoc(() => "inserted ${next.$1.path}: "
          "${image.toc.tracks.length} track(s) ${image.totalSectors} sectors "
          "in ${watch.elapsedMilliseconds}ms");
      for (final t in image.toc.tracks) {
        _log.infoc(() => "$t");
      }
      _changeDisc(CdromDriveState.ready);
    } catch (e) {
      _log.warnc(() => "failed to read TOC of ${next.$1.path}: $e");
      if (loadingId == _discId) {
        _changeDisc(CdromDriveState.error);
      }
    }
  }

  /// discards the state of the current disc, returns the new disc id
  int _changeDisc(CdromDriveState state) {
    _discId++;
    if (state != _state) _events.add(state, _discId);
    _state = state;
    if (state != CdromDriveState.ready) {
      _image = null;
      _toc = CdromToc.empty;
    }
    _cache.clear();
    _inflight.clear();
    _seekLba = 0;
    _seekRequested = false;
    _waitLba = null;
    _updateStatus();
    return _discId;
  }

  @override
  void seek(int lba) {
    _seekLba = lba;
    _seekRequested = true;
    final image = _image;
    if (image != null && image.isReadable(lba)) {
      _ensureLoaded(lba);
    }
    _updateStatus();
  }

  @override
  Uint8List? read(int lba) {
    final image = _image;
    if (image == null || !image.isReadable(lba)) {
      _waitLba = null;
      return Uint8List(0);
    }

    _ensureLoaded(lba);
    final data = _cache[lba]?.data;
    _waitLba = data == null ? lba : null;
    return data;
  }

  bool _isCached(int lba) {
    final e = _cache[lba];
    return e != null && _now().difference(e.loadedAt) < cacheLifetime;
  }

  /// starts reading [lba] if not cached, and reads ahead the following sectors
  void _ensureLoaded(int lba) {
    _sweep();

    if (!_isCached(lba)) {
      _cache.remove(lba);
      if (!_inflight.containsKey(lba)) {
        _load(lba, firstReadSectors);
      }
    }

    _readAhead(lba);
  }

  /// starts reading ahead when less than half of the read-ahead window is
  /// cached or being read
  void _readAhead(int lba) {
    final image = _image!;
    final end = (lba + 1 + readAheadSectors).clamp(0, image.totalSectors);

    for (int s = lba + 1; s < end; s++) {
      if (_isCached(s) || _inflight.containsKey(s)) continue;
      if (s - lba <= readAheadSectors ~/ 2) {
        _load(s, readAheadSectors);
      }
      return;
    }
  }

  /// reads [count] sectors from [lba] in the background, skipping the sectors
  /// already cached or being read
  void _load(int lba, int count) {
    final image = _image!;
    final discId = _discId;

    var end = (lba + count).clamp(0, image.totalSectors);
    for (int s = lba + 1; s < end; s++) {
      if (_isCached(s) || _inflight.containsKey(s)) {
        end = s;
        break;
      }
    }

    final watch = Stopwatch()..start();
    late final Future<void> future;
    future = image.readSectors(lba, end - lba).then((sectors) {
      _log.debugc(
          () => "read $lba-${end - 1} in ${watch.elapsedMilliseconds}ms");
      if (discId != _discId) return;
      final now = _now();
      for (int i = 0; i < sectors.length; i++) {
        _cache[lba + i] = _CacheEntry(sectors[i], now);
      }
    }).catchError((e) {
      _log.warnc(() => "read error at $lba-${end - 1}: $e");
      if (discId != _discId) return;
      // cached as unreadable, retried after the lifetime
      final now = _now();
      for (int s = lba; s < end; s++) {
        _cache[s] = _CacheEntry(Uint8List(0), now);
      }
    }).whenComplete(() {
      if (discId != _discId) return;
      for (int s = lba; s < end; s++) {
        if (identical(_inflight[s], future)) {
          _inflight.remove(s);
        }
      }
      _updateStatus();
    });

    for (int s = lba; s < end; s++) {
      _inflight[s] = future;
    }
  }

  /// removes expired sectors, at most once per second
  void _sweep() {
    final now = _now();
    if (now.difference(_lastSweep) < const Duration(seconds: 1)) {
      return;
    }
    _lastSweep = now;
    _cache.removeWhere((_, e) => now.difference(e.loadedAt) >= cacheLifetime);
  }
}
