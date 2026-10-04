import 'cdrom_drive.dart';

/// Detects disc changes of a [CdromDrive] for the cores.
///
/// A real console shows a disc change as "the tray is opened, then closed".
/// Whatever the speed of the drive, the core must see this: when the disc id
/// of the drive changes, [onRemoved] is always called (if a disc was present),
/// the removed state is kept for [holdClocks], then [onInserted] is called
/// once the drive has a disc ready.
class DiscSwapWatcher {
  final int holdClocks;
  final void Function() onRemoved;
  final void Function() onInserted;

  DiscSwapWatcher(this.holdClocks,
      {required this.onRemoved, required this.onInserted});

  CdromDrive? _drive;
  int _id = -1;
  bool _present = false;
  bool _pending = false;
  int _wait = 0;

  /// starts watching [drive]. the current disc is taken as the initial one:
  /// no callback is made for it.
  void attach(CdromDrive drive) {
    _drive = drive;
    final s = drive.status;
    _id = s.discId;
    _present = s.isReady;
    _pending = false;
  }

  /// the core is reset with the disc in the drive
  void sync() {
    final s = _drive?.status;
    if (s == null) return;
    _id = s.discId;
    _present = s.isReady;
    _pending = false;
  }

  /// call on each exec. [clocks] are in the unit of [holdClocks].
  void poll(int clocks) {
    final s = _drive?.status;
    if (s == null) return;

    if (s.discId != _id) {
      _id = s.discId;
      if (!_pending) _wait = holdClocks; // counted from the first removal
      _pending = true;
      if (_present) {
        _present = false;
        onRemoved();
      }
    }

    if (_pending) {
      _wait -= clocks;
      if (_wait <= 0 && s.isReady) {
        _pending = false;
        _present = true;
        onInserted();
      }
    }
  }
}
