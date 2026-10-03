import 'dart:async';
import 'dart:typed_data';

import '../core/cdrom_drive.dart';
import '../core/disc.dart';
import '../util/debug.dart';
import 'disc_layout.dart';
import 'image_file.dart';

class _CacheEntry {
  final Uint8List data; // empty if failed to read
  final DateTime loadedAt;
  _CacheEntry(this.data, this.loadedAt);
}

/// [CdromDrive] which reads only the required sectors from the image files
/// in the background.
///
/// - the TOC is read when a disc is inserted by [eject], and kept on memory
/// - each read also reads ahead [readAheadSectors] sectors
/// - read sectors are cached for [cacheLifetime]
class AsyncCdromDrive implements CdromDrive {
  static const readAheadSectors = 75;
  static const cacheLifetime = Duration(seconds: 60);

  final DateTime Function() _now;

  AsyncCdromDrive({DateTime Function()? now}) : _now = now ?? DateTime.now;

  CdromDriveState _state = CdromDriveState.empty;
  DiscSource? _source;
  DiscLayout? _layout;
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
  CdromDriveStatus _status = CdromDriveStatus.empty;

  @override
  CdromDriveStatus get status => _status;

  void _updateStatus() {
    final layout = _layout;
    final readable = layout != null && layout.isReadable(_seekLba);
    final entry = _cache[_seekLba];

    _status = CdromDriveStatus(
      _state,
      _discId,
      layout?.toc ?? CdromToc.empty,
      seekLba: _seekLba,
      isSeeking: _seekRequested && readable && entry == null,
      seekError: _seekRequested &&
          (!readable || (entry != null && entry.data.isEmpty)),
    );
  }

  /// ejects the current disc and inserts [next] if specified. The status
  /// changes to trayOpen, then to loading and ready (or error) when the TOC
  /// of [next] is read.
  Future<void> eject([DiscSource? next]) async {
    final discId = _changeDisc(CdromDriveState.trayOpen);

    final old = _source;
    _source = null;
    await old?.close();

    if (next == null) {
      if (discId == _discId) {
        _changeDisc(CdromDriveState.empty);
      }
      return;
    }

    if (discId != _discId) {
      await next.close();
      return;
    }
    final loadingId = _changeDisc(CdromDriveState.loading);

    try {
      final layout = await DiscLayout.build(next);
      if (loadingId != _discId) {
        await next.close();
        return;
      }
      _source = next;
      _layout = layout;
      debugLog("cdrom: inserted ${next.name}: "
          "${layout.toc.trackCount} track(s) ${layout.totalSectors} sectors");
      for (final t in layout.toc.tracks) {
        debugLog("cdrom: $t");
      }
      _changeDisc(CdromDriveState.ready);
    } catch (e) {
      debugLog("cdrom: failed to read TOC of ${next.name}: $e");
      await next.close();
      if (loadingId == _discId) {
        _changeDisc(CdromDriveState.error);
      }
    }
  }

  /// discards the state of the current disc, returns the new disc id
  int _changeDisc(CdromDriveState state) {
    _discId++;
    _state = state;
    if (state != CdromDriveState.ready) {
      _layout = null;
    }
    _cache.clear();
    _inflight.clear();
    _seekLba = 0;
    _seekRequested = false;
    _updateStatus();
    return _discId;
  }

  @override
  void seek(int lba) {
    _seekLba = lba;
    _seekRequested = true;
    final layout = _layout;
    if (layout != null && layout.isReadable(lba)) {
      _ensureLoaded(lba);
    }
    _updateStatus();
  }

  @override
  Uint8List? read(int lba) {
    final layout = _layout;
    if (layout == null || !layout.isReadable(lba)) {
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
    final layout = _layout!;
    final end = (lba + 1 + readAheadSectors).clamp(0, layout.totalSectors);

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
    final layout = _layout!;
    final discId = _discId;

    var end = (lba + count).clamp(0, layout.totalSectors);
    for (int s = lba + 1; s < end; s++) {
      if (_isCached(s) || _inflight.containsKey(s)) {
        end = s;
        break;
      }
    }

    late final Future<void> future;
    future = _readRange(layout, lba, end - lba).then((sectors) {
      if (discId != _discId) return;
      final now = _now();
      for (int i = 0; i < sectors.length; i++) {
        _cache[lba + i] = _CacheEntry(sectors[i], now);
      }
    }).catchError((e) {
      debugLog("cdrom: read error at $lba-${end - 1}: $e");
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

  Future<List<Uint8List>> _readRange(
      DiscLayout layout, int lba, int count) async {
    final result = <Uint8List>[];
    for (final seg in layout.segments(lba, count)) {
      final file = seg.file;
      if (file == null) {
        result.addAll(
            List.generate(seg.count, (_) => Uint8List(Disc.sectorSize)));
        continue;
      }

      final bytes = await file.read(
          seg.fileSector * Disc.sectorSize, seg.count * Disc.sectorSize);
      for (int i = 0; i < seg.count; i++) {
        final sector = Uint8List(Disc.sectorSize); // zero padded at EOF
        final start = i * Disc.sectorSize;
        if (start < bytes.length) {
          final end = (start + Disc.sectorSize).clamp(0, bytes.length);
          sector.setRange(0, end - start, bytes, start);
        }
        result.add(sector);
      }
    }
    return result;
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
