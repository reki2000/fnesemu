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
    _discId = -1;
    _isSeeking = false;
    poll(0);
  }

  void clear() => _isSeeking = false;

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

  /// checks the drive, called on each exec
  void poll(int clock) {
    final s = status;

    if (s.discId != _discId) {
      _discId = s.discId;
      if (_isSeeking) {
        _isSeeking = false;
        _cdrom._onSeekComplete(false, _seekIssuedAt);
      }
      _cdrom._onDiscChanged(s.isReady);
      return;
    }

    if (_isSeeking && (s.seekError || !s.isSeeking)) {
      _isSeeking = false;
      _cdrom._onSeekComplete(!s.seekError, _seekIssuedAt);
    }
  }
}
