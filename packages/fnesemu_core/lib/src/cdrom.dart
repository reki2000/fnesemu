// The CD-ROM helpers of the CD cores, on the CdromDrive the app gives. Not
// exported to the app: the boundary is cdrom_drive.dart.
import 'dart:typed_data';

import 'cdrom_drive.dart';
import 'util/int.dart';

export 'cdrom_drive.dart';

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

/// CD time expressed as a nonnegative number of 1/75-second frames.
/// A track-relative duration uses [Msf.ofFrames]; disc time uses [Msf.ofLba].
class Msf {
  static const framesPerSecond = 75;
  static const lbaOffset = 2 * framesPerSecond;

  final int _frames;

  Msf.ofFrames(int frames)
      : _frames = RangeError.checkNotNegative(frames, 'frames');

  /// LBA zero corresponds to 00:02:00; the first pregap can use negative LBAs.
  Msf.ofLba(int lba) : this.ofFrames(lba + lbaOffset);

  /// Numeric time fields. Command validation remains the caller's job.
  Msf.ofParts(int minute, int second, int frame)
      : this.ofFrames((minute * 60 + second) * framesPerSecond + frame);

  Msf.ofBcd(int minute, int second, int frame)
      : this.ofParts(_decodeBcd(minute), _decodeBcd(second), _decodeBcd(frame));

  int frames() => _frames;

  (int, int, int) parts() => (
        _frames ~/ (60 * framesPerSecond),
        _frames ~/ framesPerSecond % 60,
        _frames % framesPerSecond,
      );

  String format() {
    final (minute, second, frame) = parts();
    return '${minute.d2z}:${second.d2z}:${frame.d2z}';
  }

  (int, int, int) bcd() {
    final (minute, second, frame) = parts();
    return (_encodeBcd(minute), _encodeBcd(second), _encodeBcd(frame));
  }

  static int _encodeBcd(int value) => (value ~/ 10).shl4 | value % 10;
  static int _decodeBcd(int value) => value.shr4 * 10 + value.mask4;
}
