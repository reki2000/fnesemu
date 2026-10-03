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
  final CdromToc toc;

  /// LBA of the last seek or read request
  final int headLba;

  /// true while a seek is in progress
  final bool isSeeking;

  const CdromDriveStatus(this.state, this.toc, this.headLba, this.isSeeking);

  bool get isReady => state == CdromDriveState.ready;
}

/// receives asynchronous results from [CdromDrive]
abstract class CdromDriveListener {
  /// called when a disc is ejected/inserted or the TOC has been read
  void onDiscChanged(CdromDriveStatus status);

  /// called when the seek requested by [CdromDrive.seek] is completed.
  /// [ok] is false if [lba] is not readable
  void onSeekComplete(int lba, bool ok);

  /// called when the sector requested by [CdromDrive.read] is available.
  /// [data] is a raw sector (2352 bytes), or empty if it is not readable.
  void onSectorRead(int lba, Uint8List data);
}

/// A CD-ROM drive seen from the emulator core.
///
/// All LBAs are without 2 seconds of lead-in. Requests return immediately and
/// the results are notified to [listener] later.
abstract class CdromDrive {
  set listener(CdromDriveListener? listener);

  /// returns the current status synchronously
  CdromDriveStatus get status;

  /// moves the head to [lba], then calls [CdromDriveListener.onSeekComplete]
  void seek(int lba);

  /// requests the sector at [lba], then calls
  /// [CdromDriveListener.onSectorRead]
  void read(int lba);
}

/// implemented by cores which have a CD-ROM drive
abstract class CdromHost {
  void setCdromDrive(CdromDrive drive);
}
