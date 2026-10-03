import 'dart:typed_data';

/// build-time switch: `--dart-define=ASYNC_CDROM=true` enables async-cdrom.
///
/// - false (default): the whole disc image is loaded into memory as [Disc]
///   and the core reads sectors synchronously.
/// - true: the core accesses the disc through [CdromDrive], which reads only
///   the required sectors asynchronously.
const asyncCdrom = bool.fromEnvironment("ASYNC_CDROM", defaultValue: false);

enum CdromDriveState {
  /// no disc in the drive
  empty,

  /// tray is open (during eject)
  trayOpen,

  /// a disc is inserted and the TOC is being read
  loading,

  /// TOC is read and sectors are readable
  ready,

  /// failed to read the TOC
  error,
}

class CdromTrack {
  final int number; // 1..
  final bool isAudio;
  final int startLba; // LBA of INDEX 01, without 2 seconds of lead-in
  final int sectors;

  const CdromTrack(this.number, this.isAudio, this.startLba, this.sectors);

  @override
  String toString() =>
      "track $number ${isAudio ? "audio" : "data"} lba:$startLba sectors:$sectors";
}

class CdromToc {
  final List<CdromTrack> tracks;

  /// number of sectors of the disc, from LBA 0 (without lead-in)
  final int totalSectors;

  const CdromToc(this.tracks, this.totalSectors);

  static const empty = CdromToc([], 0);

  bool get isEmpty => tracks.isEmpty;
  int get trackCount => tracks.length;

  int startLba(int trackNo) {
    if (trackNo < 1 || trackNo > tracks.length) {
      throw RangeError("cdrom: invalid track number $trackNo");
    }
    return tracks[trackNo - 1].startLba;
  }

  bool isAudio(int trackNo) => tracks[trackNo - 1].isAudio;

  /// returns true if [lba] (without lead-in) is in an audio track
  bool isAudioLba(int lba) {
    for (int i = tracks.length - 1; i >= 0; i--) {
      if (lba >= tracks[i].startLba) {
        return tracks[i].isAudio;
      }
    }
    return false;
  }
}

/// synchronous snapshot of the drive
class CdromDriveStatus {
  final CdromDriveState state;

  /// incremented on each disc change (eject, insert, TOC read)
  final int discId;

  final CdromToc toc;

  /// LBA of the last [CdromDrive.seek]
  final int seekLba;

  /// true while the sector at [seekLba] is being read
  final bool isSeeking;

  /// true if [seekLba] is not readable
  final bool seekError;

  const CdromDriveStatus(this.state, this.discId, this.toc,
      {this.seekLba = 0, this.isSeeking = false, this.seekError = false});

  static const empty =
      CdromDriveStatus(CdromDriveState.empty, 0, CdromToc.empty);

  bool get isReady => state == CdromDriveState.ready;
}

/// A CD-ROM drive seen from the emulator core.
///
/// All accesses are synchronous: the drive reads the image files in the
/// background, and the core polls [status] and [read] until the result is
/// available. All LBAs are without 2 seconds of lead-in.
abstract class CdromDrive {
  /// returns the current status. cheap enough to be polled on each exec.
  CdromDriveStatus get status;

  /// moves the head to [lba]. the core polls [CdromDriveStatus.isSeeking]
  /// and [CdromDriveStatus.seekError] for the result.
  void seek(int lba);

  /// returns the raw sector (2352 bytes) at [lba], or null if it has not been
  /// read yet (the drive starts reading it). returns empty data if [lba] is
  /// not readable.
  Uint8List? read(int lba);
}

/// implemented by cores which have a CD-ROM drive
abstract class CdromHost {
  void setCdromDrive(CdromDrive drive);
}
