import 'cdrom_drive.dart';

/// Detects disc changes of a [CdromDrive] for the cores.
///
/// A real console shows a disc change as "the tray is opened, then closed".
/// Whatever the speed of the drive, the core must see this: when the disc id
/// of the drive changes, [onTrayOpen] is always called (if the tray was
/// closed) and the tray is kept open for [holdClocks]. Then, according to the
/// drive, [onInserted] is called when a disc is ready, or [onClosedEmpty] when
/// the tray is closed without a disc. The tray stays open while the drive is
/// ejected.
class DiscSwapWatcher {
  final int holdClocks;

  /// the tray is opened (the disc is removed)
  final void Function() onTrayOpen;

  /// the tray is closed with a disc
  final void Function() onInserted;

  /// the tray is closed without a disc (or the disc is not readable)
  final void Function() onClosedEmpty;

  DiscSwapWatcher(this.holdClocks,
      {required this.onTrayOpen,
      required this.onInserted,
      required this.onClosedEmpty});

  CdromDrive? _drive;
  int _id = -1;
  bool _trayOpen = false; // as seen by the core
  bool _pending = false;
  int _wait = 0;

  /// starts watching [drive]. the current state is taken as the initial one:
  /// no callback is made for it.
  void attach(CdromDrive drive) {
    _drive = drive;
    sync();
  }

  /// the core is reset with the drive as it is
  void sync() {
    final s = _drive?.status;
    if (s == null) return;
    _id = s.discId;
    _trayOpen = s.isTrayOpen;
    _pending = false;
  }

  /// call on each exec. [clocks] are in the unit of [holdClocks].
  void poll(int clocks) {
    final s = _drive?.status;
    if (s == null) return;

    if (s.discId != _id) {
      _id = s.discId;
      if (!_pending) _wait = holdClocks; // counted from the first change
      _pending = true;
      if (!_trayOpen) {
        _trayOpen = true;
        onTrayOpen();
      }
    }

    if (!_pending) return;
    _wait -= clocks;
    if (_wait > 0) return;

    switch (s.state) {
      case CdromDriveState.ready:
        _pending = false;
        _trayOpen = false;
        onInserted();
      case CdromDriveState.empty || CdromDriveState.error:
        _pending = false;
        _trayOpen = false;
        onClosedEmpty();
      case CdromDriveState.trayOpen:
        _pending = false; // stays open until the drive changes again
      case CdromDriveState.loading:
        break; // wait for the TOC
    }
  }
}
