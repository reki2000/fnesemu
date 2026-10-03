part of 'cdrom.dart';

/// connects [Cdrom] to [CdromDrive] (async-cdrom).
///
/// Sectors are requested ahead of the reading position and kept until the
/// core consumes them. Sector numbers here include 2 seconds of lead-in as
/// [Cdrom.readingSector] does, while [CdromDrive] uses LBA.
class _AsyncPort implements CdromDriveListener {
  /// number of sectors requested ahead of the reading position, enough to
  /// cover the latency of the notification (about 1 frame at 2x speed)
  static const window = 32;

  static const _leadIn = 2 * 75;

  final Cdrom _cdrom;
  CdromDrive? _drive;

  _AsyncPort(this._cdrom);

  CdromDriveStatus _status =
      const CdromDriveStatus(CdromDriveState.empty, CdromToc.empty, 0, false);

  /// TOC kept from the last notification
  CdromToc get toc => _status.toc;
  bool get isReady => _status.isReady;

  final _requested = <int>{};
  final _received = <int, Uint8List>{};
  int _windowStart = -1;

  int _seekTarget = -1; // waiting seek, in sector
  int _seekIssuedAt = 0; // clock when the seek is issued

  void attach(CdromDrive drive) {
    _drive?.listener = null;
    _drive = drive;
    drive.listener = this;
    onDiscChanged(drive.status);
  }

  void clear() {
    _requested.clear();
    _received.clear();
    _windowStart = -1;
    _seekTarget = -1;
  }

  /// returns true if [sector] has arrived. requests it and the following
  /// sectors if not yet.
  bool has(int sector) {
    _request(sector);
    return _received.containsKey(sector);
  }

  /// consumes [sector] which [has] returned true
  Uint8List take(int sector) {
    final data = _received.remove(sector) ?? Uint8List(0);
    _requested.remove(sector);
    _request(sector + 1);
    return data;
  }

  void _request(int sector) {
    final drive = _drive;
    if (drive == null) {
      return;
    }

    if (sector != _windowStart) {
      if (sector < _windowStart || sector > _windowStart + window) {
        // jumped: drop all
        _requested.clear();
        _received.clear();
      } else {
        _requested.removeWhere((s) => s < sector);
        _received.removeWhere((s, _) => s < sector);
      }
      _windowStart = sector;
    }

    for (int s = sector; s < sector + window; s++) {
      if (_requested.add(s)) {
        drive.read(s - _leadIn); // may be notified synchronously
      }
    }
  }

  /// starts seeking to [sector]. [Cdrom.onSeekComplete] is called later.
  void seek(int sector, int clock) {
    _seekTarget = sector;
    _seekIssuedAt = clock;
    final drive = _drive;
    if (drive == null) {
      onSeekComplete(sector - _leadIn, false);
    } else {
      drive.seek(sector - _leadIn);
    }
  }

  @override
  void onSectorRead(int lba, Uint8List data) {
    final sector = lba + _leadIn;
    if (_requested.contains(sector)) {
      _received[sector] = data;
    }
  }

  @override
  void onSeekComplete(int lba, bool ok) {
    final sector = lba + _leadIn;
    if (sector != _seekTarget) {
      return; // overridden by another seek
    }
    _seekTarget = -1;
    _cdrom._onSeekComplete(ok, _seekIssuedAt);
  }

  @override
  void onDiscChanged(CdromDriveStatus status) {
    _status = status;
    if (_seekTarget >= 0) {
      final issuedAt = _seekIssuedAt;
      _seekTarget = -1;
      _cdrom._onSeekComplete(false, issuedAt);
    }
    clear();
    _cdrom._onDiscChanged(status.isReady);
  }
}
