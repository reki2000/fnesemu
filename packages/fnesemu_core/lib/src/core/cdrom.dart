// The CD-ROM helpers of the CD cores, on the CdromDrive the app gives. Not
// exported to the app: the boundary is cdrom_drive.dart.
import 'dart:typed_data';

import 'cdrom_drive.dart';
import 'msf.dart';

export 'cdrom_drive.dart';
export 'msf.dart';

/// bytes of a raw sector: 24 bytes x 98 frames
const cdSectorSize = 2352;

/// the sync pattern at the start of a data sector
const cdSync = [
  0,
  0xff,
  0xff,
  0xff,
  0xff,
  0xff,
  0xff,
  0xff,
  0xff,
  0xff,
  0xff,
  0
];

/// Difference between the LBA origin and the absolute MSF time origin.
const cdLbaOffset = Msf.lbaOffset;

bool sectorContains(Uint8List bytes, String signature) =>
    String.fromCharCodes(bytes).contains(signature);

/// the disc in a [CdromDrive], as the CD cores see it
extension CdromAccess on CdromDrive {
  CdromToc get toc => status.toc;

  bool get isEmpty => !status.isReady;
  int get trackCount => toc.trackCount;
  int get totalSectors => toc.totalSectors;
  int startLba(int trackNo) => toc.startLba(trackNo);
  bool isAudio(int trackNo) => toc.isAudio(trackNo);

  /// [read] by an absolute sector (LBA + [cdLbaOffset]). returns empty data if
  /// it is not readable, null if it is not read yet.
  Uint8List? readAbsolute(int sector) => read(sector - cdLbaOffset);

  /// whether the absolute [sector] (LBA + [cdLbaOffset]) is in an audio track
  bool isAudioSector(int sector) {
    final lba = sector - cdLbaOffset;
    if (isEmpty || lba < 0 || lba >= totalSectors) return false;
    return toc.isAudioLba(lba);
  }

  /// the start of the first data track, or null if there is none
  int? get firstDataLba =>
      toc.tracks.where((track) => !track.isAudio).firstOrNull?.startLba;

  /// [read] waiting for the sector to be read, for identifying the disc
  /// outside of emulation. returns empty data if it is not readable.
  Future<Uint8List> readWhenReady(int lba) async {
    for (var attempt = 0; attempt < 5000; attempt++) {
      final data = read(lba);
      if (data != null) return data;
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    return Uint8List(0);
  }
}

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
