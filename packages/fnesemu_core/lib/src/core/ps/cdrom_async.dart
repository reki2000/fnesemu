part of 'cdrom.dart';

/// connects [Cdrom] to [CdromDrive] (async-cdrom).
///
/// The drive is polled synchronously: [Cdrom.exec] checks disc changes and
/// seek completion, and sectors are read when they are available. Sector
/// numbers here include 2 seconds of lead-in as [Cdrom.readingSector] does,
/// while [CdromDrive] uses LBA.
class _DrivePort {
  static const _leadIn = 2 * 75;

  final Cdrom _cdrom;
  CdromDrive? _drive;

  _DrivePort(this._cdrom);

  CdromDriveStatus get status => _drive?.status ?? CdromDriveStatus.empty;

  CdromToc get toc => status.toc;
  bool get isReady => status.isReady;

  int _discId = -1; // disc id seen by the core
  bool _isSeeking = false; // waiting for the drive to complete a seek
  int _seekIssuedAt = 0; // clock when the seek is issued

  void attach(CdromDrive drive) {
    _drive = drive;
    _discId = drive.status.discId;
    _isSeeking = false;
    drive.clearEvents();
    _applyState();
  }

  void clear() {
    _isSeeking = false;
    _drive?.clearEvents();
    _applyState();
  }

  /// sets the shell of the core from the state of the drive
  void _applyState() {
    final s = status;
    _cdrom._onTray(open: s.isTrayOpen, hasDisc: s.isReady);
  }

  /// returns [sector], or null if the drive has not read it yet
  Uint8List? read(int sector) {
    final drive = _drive;
    return drive == null ? Uint8List(0) : drive.read(sector - _leadIn);
  }

  /// starts seeking to [sector]. completion is checked by [poll]
  void seek(int sector, int clock) {
    _isSeeking = true;
    _seekIssuedAt = clock;
    _drive?.seek(sector - _leadIn);
  }

  /// Checks the drive and consumes one event on each exec.
  void poll() {
    final s = status;

    if (s.discId != _discId) {
      _discId = s.discId;
      if (_isSeeking) {
        _isSeeking = false;
        _cdrom._onSeekComplete(false, _seekIssuedAt);
      }
    } else if (_isSeeking && (s.seekError || !s.isSeeking)) {
      _isSeeking = false;
      _cdrom._onSeekComplete(!s.seekError, _seekIssuedAt);
    }

    final event = _drive?.takeEvent();
    switch (event?.type) {
      case CdromDriveEventType.trayOpened:
        _cdrom._onTray(open: true, hasDisc: false);
      case CdromDriveEventType.trayClosed:
        _cdrom._onTray(open: false, hasDisc: false);
      case CdromDriveEventType.discReady || CdromDriveEventType.discError:
        if (event!.discId != s.discId) return;
        _cdrom._onTray(
            open: false, hasDisc: event.type == CdromDriveEventType.discReady);
      case null:
        break;
    }
  }
}
