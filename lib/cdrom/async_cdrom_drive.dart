import 'dart:async';
import 'dart:typed_data';

import '../core/cdrom_drive.dart';
import '../core/disc.dart';
import '../util/debug.dart';
import 'disc_layout.dart';
import 'image_file.dart';

class _CacheEntry {
  final Uint8List data;
  final DateTime loadedAt;
  _CacheEntry(this.data, this.loadedAt);
}

/// [CdromDrive] which reads only the required sectors from the image files
/// asynchronously.
///
/// - the TOC is read when a disc is inserted by [eject], and kept on memory
/// - each read also reads ahead [readAheadSectors] sectors
/// - read sectors are cached for [cacheLifetime]
class AsyncCdromDrive implements CdromDrive {
  static const readAheadSectors = 75;
  static const cacheLifetime = Duration(seconds: 60);

  final DateTime Function() _now;

  AsyncCdromDrive({DateTime Function()? now}) : _now = now ?? DateTime.now;

  CdromDriveListener? _listener;

  @override
  set listener(CdromDriveListener? listener) => _listener = listener;

  CdromDriveState _state = CdromDriveState.empty;
  DiscSource? _source;
  DiscLayout? _layout;
  int _headLba = 0;
  int _seekingLba = -1;

  /// incremented on each disc change to discard the results of the old disc
  int _generation = 0;

  final _cache = <int, _CacheEntry>{};
  final _inflight = <int, Future<void>>{};
  DateTime _lastSweep = DateTime.fromMillisecondsSinceEpoch(0);

  /// for tests and debugging
  int get cachedSectors => _cache.length;

  @override
  CdromDriveStatus get status => CdromDriveStatus(
      _state, _layout?.toc ?? CdromToc.empty, _headLba, _seekingLba >= 0);

  /// ejects the current disc and inserts [next] if specified. The listener is
  /// notified when the tray is opened, and when the TOC of [next] is read.
  Future<void> eject([DiscSource? next]) async {
    final generation = ++_generation;

    final old = _source;
    _source = null;
    _layout = null;
    _cache.clear();
    _inflight.clear();
    _seekingLba = -1;
    _headLba = 0;
    _setState(CdromDriveState.trayOpen);
    await old?.close();

    if (next == null) {
      if (generation == _generation) {
        _setState(CdromDriveState.empty);
      }
      return;
    }

    if (generation != _generation) {
      await next.close();
      return;
    }
    _setState(CdromDriveState.loading);

    try {
      final layout = await DiscLayout.build(next);
      if (generation != _generation) {
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
      _setState(CdromDriveState.ready);
    } catch (e) {
      debugLog("cdrom: failed to read TOC of ${next.name}: $e");
      await next.close();
      if (generation == _generation) {
        _setState(CdromDriveState.error);
      }
    }
  }

  void _setState(CdromDriveState state) {
    _state = state;
    _listener?.onDiscChanged(status);
  }

  @override
  void seek(int lba) {
    _headLba = lba;
    final layout = _layout;
    if (layout == null || !layout.isReadable(lba)) {
      _deliverLater(() => _listener?.onSeekComplete(lba, false));
      return;
    }

    _seekingLba = lba;
    final generation = _generation;
    _ensureLoaded(lba).then((_) {
      if (generation != _generation) return;
      if (_seekingLba == lba) {
        _seekingLba = -1;
      }
      _listener?.onSeekComplete(lba, true);
    });
  }

  @override
  void read(int lba) {
    _headLba = lba;
    final layout = _layout;
    if (layout == null || !layout.isReadable(lba)) {
      _deliverLater(() => _listener?.onSectorRead(lba, Uint8List(0)));
      return;
    }

    final generation = _generation;
    _ensureLoaded(lba).then((_) {
      if (generation != _generation) return;
      _listener?.onSectorRead(lba, _cache[lba]?.data ?? Uint8List(0));
    });
  }

  void _deliverLater(void Function() f) {
    final generation = _generation;
    scheduleMicrotask(() {
      if (generation == _generation) f();
    });
  }

  bool _isCached(int lba) {
    final e = _cache[lba];
    return e != null && _now().difference(e.loadedAt) < cacheLifetime;
  }

  /// makes [lba] available in the cache, and reads ahead the following sectors
  Future<void> _ensureLoaded(int lba) {
    _sweep();

    final Future<void> result;
    if (_isCached(lba)) {
      result = Future.value();
    } else {
      result = _inflight[lba] ?? _load(lba, readAheadSectors + 1);
    }

    _readAhead(lba);
    return result;
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

  /// reads [count] sectors from [lba], skipping the sectors already cached or
  /// being read
  Future<void> _load(int lba, int count) {
    final layout = _layout!;
    final generation = _generation;

    var end = (lba + count).clamp(0, layout.totalSectors);
    for (int s = lba + 1; s < end; s++) {
      if (_isCached(s) || _inflight.containsKey(s)) {
        end = s;
        break;
      }
    }

    late final Future<void> future;
    future = _readRange(layout, lba, end - lba).then((sectors) {
      if (generation != _generation) return;
      final now = _now();
      for (int i = 0; i < sectors.length; i++) {
        _cache[lba + i] = _CacheEntry(sectors[i], now);
      }
    }).catchError((e) {
      debugLog("cdrom: read error at $lba-${end - 1}: $e");
    }).whenComplete(() {
      if (generation != _generation) return;
      for (int s = lba; s < end; s++) {
        if (identical(_inflight[s], future)) {
          _inflight.remove(s);
        }
      }
    });

    for (int s = lba; s < end; s++) {
      _inflight[s] = future;
    }

    return future;
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
