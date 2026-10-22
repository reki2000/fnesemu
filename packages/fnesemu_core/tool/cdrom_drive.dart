// a CD-ROM drive for the headless runner and the tests of the cores, on the disc
// images of cdrom_image. The app has its own drive with read-ahead and cache.
import 'dart:async';
import 'dart:typed_data';

import 'package:cdrom_image/cdrom_image.dart';
import 'package:fnesemu_core/src/cdrom_drive.dart';

/// [CdromDrive] which starts reading [chunkSectors] sectors when the core asks
/// for a sector not read yet, and keeps all the sectors read. [settle] waits
/// for the reads, to give the same result regardless of the speed of the
/// files.
class SimpleCdromDrive implements CdromDrive {
  static const chunkSectors = 75;

  CdromDriveState _state = CdromDriveState.empty;
  DiscImage? _image;
  CdromToc _toc = CdromToc.empty;
  int _discId = 0;
  final _events = CdromDriveEvents();
  int _seekLba = 0;
  bool _seekRequested = false;

  final _sectors = <int, Uint8List>{}; // empty if failed to read
  final _inflight = <int, Future<void>>{};

  CdromDriveStatus _status = CdromDriveStatus.empty;

  @override
  CdromDriveStatus get status => _status;

  @override
  CdromDriveEvent? takeEvent() => _events.take();

  @override
  void clearEvents() => _events.clear();

  void _updateStatus() {
    final readable = _isReadable(_seekLba);
    final data = _sectors[_seekLba];
    _status = CdromDriveStatus(_state, _discId, _toc,
        seekLba: _seekLba,
        isSeeking: _seekRequested && readable && data == null,
        seekError: _seekRequested && (!readable || (data?.isEmpty ?? false)));
  }

  bool _isReadable(int lba) =>
      _image != null && lba >= 0 && lba < _toc.totalSectors;

  /// completes when all the reads in progress are done
  Future<void> settle() async {
    while (_inflight.isNotEmpty) {
      await Future.wait(_inflight.values.toSet());
    }
  }

  /// opens the tray, and removes the disc
  Future<void> eject() async {
    _change(CdromDriveState.trayOpen);
    _image = null;
  }

  /// closes the tray with the disc image [disc] (the arguments of
  /// [DiscImage.parse]), or without a disc if null
  Future<void> insert([(DiscFile, Iterable<DiscFile>)? disc]) async {
    if (_state != CdromDriveState.trayOpen) await eject();
    if (disc == null) {
      _change(CdromDriveState.empty);
      return;
    }

    final discId = _change(CdromDriveState.loading);
    try {
      final (image, _) = await DiscImage.parse(disc.$1, files: disc.$2);
      if (discId != _discId) {
        return;
      }
      _image = image;
      _toc = CdromToc([
        for (final t in image.toc.tracks)
          CdromTrack(t.number, t.isAudio, t.startLba, t.sectors)
      ], image.totalSectors);
      _change(CdromDriveState.ready);
    } catch (e) {
      if (discId == _discId) _change(CdromDriveState.error);
    }
  }

  /// discards the state of the current disc, returns the new disc id
  int _change(CdromDriveState state) {
    _discId++;
    if (state != _state) _events.add(state, _discId);
    _state = state;
    if (state != CdromDriveState.ready) {
      _image = null;
      _toc = CdromToc.empty;
    }
    _sectors.clear();
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
    if (_isReadable(lba)) _load(lba);
    _updateStatus();
  }

  @override
  Uint8List? read(int lba) {
    if (!_isReadable(lba)) return Uint8List(0);
    final data = _sectors[lba];
    if (data == null) _load(lba);
    return data;
  }

  /// starts reading from [lba] up to [chunkSectors] sectors, if not read yet
  void _load(int lba) {
    if (_sectors.containsKey(lba) || _inflight.containsKey(lba)) return;
    final image = _image!;
    final discId = _discId;

    var end = (lba + chunkSectors).clamp(0, _toc.totalSectors);
    for (int s = lba + 1; s < end; s++) {
      if (_sectors.containsKey(s) || _inflight.containsKey(s)) {
        end = s;
        break;
      }
    }

    late final Future<void> future;
    future = image.readSectors(lba, end - lba).then((sectors) {
      if (discId != _discId) return;
      for (int i = 0; i < sectors.length; i++) {
        _sectors[lba + i] = sectors[i];
      }
    }, onError: (_) {
      if (discId != _discId) return;
      for (int s = lba; s < end; s++) {
        _sectors[s] = Uint8List(0);
      }
    }).whenComplete(() {
      if (discId != _discId) return;
      for (int s = lba; s < end; s++) {
        if (identical(_inflight[s], future)) _inflight.remove(s);
      }
      _updateStatus();
    });

    for (int s = lba; s < end; s++) {
      _inflight[s] = future;
    }
  }
}
