import 'dart:async';
import 'dart:typed_data';

import 'disc_image.dart';
import 'disc_source.dart';

enum DiscDriveState {
  /// no disc in the drive
  empty,

  /// the tray is open
  trayOpen,

  /// a disc is inserted and the TOC is being read
  loading,

  /// the TOC is read and the sectors are readable
  ready,

  /// failed to read the TOC
  error,
}

/// a snapshot of [DiscDrive]. a new one is made on each change.
class DiscDriveStatus {
  final DiscDriveState state;

  /// incremented on each disc change (eject, insert, TOC read)
  final int discId;

  final DiscToc toc;

  /// LBA of the last [DiscDrive.seek]
  final int seekLba;

  /// true while the sector at [seekLba] is being read
  final bool isSeeking;

  /// true if [seekLba] is not readable
  final bool seekError;

  const DiscDriveStatus(this.state, this.discId, this.toc,
      {this.seekLba = 0, this.isSeeking = false, this.seekError = false});

  static const empty = DiscDriveStatus(DiscDriveState.empty, 0, DiscToc.empty);

  bool get isReady => state == DiscDriveState.ready;
  bool get isTrayOpen => state == DiscDriveState.trayOpen;
}

class _CacheEntry {
  final Uint8List data; // empty if failed to read
  final DateTime loadedAt;
  _CacheEntry(this.data, this.loadedAt);
}

/// a drive which reads only the required sectors of a [DiscImage] in the
/// background. All accesses are synchronous: [read] returns null until the
/// sector is read, for an emulator which polls it.
///
/// - the TOC is read when a disc is inserted by [eject], and kept on memory
/// - each read also reads ahead [readAheadSectors] sectors
/// - read sectors are cached for [cacheLifetime]
class DiscDrive {
  static const readAheadSectors = 75;
  static const cacheLifetime = Duration(seconds: 60);

  final DateTime Function() _now;

  final void Function(String message) _log;

  DiscDrive({DateTime Function()? now, void Function(String message)? log})
      : _now = now ?? DateTime.now,
        _log = log ?? ((_) {});

  DiscDriveState _state = DiscDriveState.empty;
  DiscImage? _image;
  int _seekLba = 0;
  bool _seekRequested = false;

  /// incremented on each disc change to discard the results of the old disc
  int _discId = 0;

  final _cache = <int, _CacheEntry>{};
  final _inflight = <int, Future<void>>{};
  DateTime _lastSweep = DateTime.fromMillisecondsSinceEpoch(0);

  /// for tests and debugging
  int get cachedSectors => _cache.length;

  /// rebuilt on each change, as the core polls it on each exec
  DiscDriveStatus _status = DiscDriveStatus.empty;

  DiscDriveStatus get status => _status;

  void _updateStatus() {
    final image = _image;
    final readable = image != null && image.isReadable(_seekLba);
    final entry = _cache[_seekLba];

    _status = DiscDriveStatus(
      _state,
      _discId,
      image?.toc ?? DiscToc.empty,
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

  /// closes the tray with the disc [source], or without a disc if null.
  /// The status changes to trayOpen first if the tray is not open, then to
  /// loading and ready (or error) when the TOC of [source] is read.
  Future<void> insert([DiscSource? source]) async {
    final discId =
        _state == DiscDriveState.trayOpen ? _discId : await _openTray();
    await _close(source, discId);
  }

  /// opens the tray, returns the disc id of the status
  Future<int> _openTray() async {
    final discId = _changeDisc(DiscDriveState.trayOpen);
    final old = _image;
    _image = null;
    await old?.close();
    return discId;
  }

  Future<void> _close(DiscSource? next, int discId) async {
    if (next == null) {
      if (discId == _discId) {
        _changeDisc(DiscDriveState.empty);
      }
      return;
    }

    if (discId != _discId) {
      await next.close();
      return;
    }
    final loadingId = _changeDisc(DiscDriveState.loading);

    try {
      final image = await DiscImage.open(next);
      if (loadingId != _discId) {
        await image.close();
        return;
      }
      _image = image;
      _log("cdrom: inserted ${next.name}: "
          "${image.toc.tracks.length} track(s) ${image.totalSectors} sectors");
      for (final t in image.toc.tracks) {
        _log("cdrom: $t");
      }
      _changeDisc(DiscDriveState.ready);
    } catch (e) {
      _log("cdrom: failed to read TOC of ${next.name}: $e");
      await next.close();
      if (loadingId == _discId) {
        _changeDisc(DiscDriveState.error);
      }
    }
  }

  /// discards the state of the current disc, returns the new disc id
  int _changeDisc(DiscDriveState state) {
    _discId++;
    _state = state;
    if (state != DiscDriveState.ready) {
      _image = null;
    }
    _cache.clear();
    _inflight.clear();
    _seekLba = 0;
    _seekRequested = false;
    _updateStatus();
    return _discId;
  }

  void seek(int lba) {
    _seekLba = lba;
    _seekRequested = true;
    final image = _image;
    if (image != null && image.isReadable(lba)) {
      _ensureLoaded(lba);
    }
    _updateStatus();
  }

  Uint8List? read(int lba) {
    final image = _image;
    if (image == null || !image.isReadable(lba)) {
      return Uint8List(0);
    }

    _ensureLoaded(lba);
    return _cache[lba]?.data;
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
        _load(lba, readAheadSectors + 1);
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

    late final Future<void> future;
    future = image.readSectors(lba, end - lba).then((sectors) {
      if (discId != _discId) return;
      final now = _now();
      for (int i = 0; i < sectors.length; i++) {
        _cache[lba + i] = _CacheEntry(sectors[i], now);
      }
    }).catchError((e) {
      _log("cdrom: read error at $lba-${end - 1}: $e");
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
