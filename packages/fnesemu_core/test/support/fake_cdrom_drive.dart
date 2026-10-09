import 'dart:typed_data';

import 'package:fnesemu_core/core/cdrom_drive.dart';
import 'package:fnesemu_core/core/disc.dart';

/// [CdromDrive] holding raw sectors on memory. all sectors are always
/// available.
class FakeCdromDrive implements CdromDrive {
  final List<Uint8List> sectors;
  final List<int> starts;
  final Set<int> audioTracks;

  /// absolute sectors (LBA + 150) passed to [read]
  final reads = <int>[];

  late final CdromToc toc;

  FakeCdromDrive(this.sectors,
      {this.starts = const [0], this.audioTracks = const {}}) {
    toc = CdromToc([
      for (int i = 0; i < starts.length; i++)
        CdromTrack(
            i + 1,
            audioTracks.contains(i + 1),
            starts[i],
            (i + 1 < starts.length ? starts[i + 1] : sectors.length) -
                starts[i])
    ], sectors.length);
  }

  @override
  CdromDriveStatus get status => sectors.isEmpty
      ? CdromDriveStatus.empty
      : CdromDriveStatus(CdromDriveState.ready, 1, toc);

  @override
  void seek(int lba) {}

  @override
  Uint8List? read(int lba) {
    reads.add(lba + 150);
    return lba < 0 || lba >= sectors.length ? Uint8List(0) : sectors[lba];
  }
}

/// [Disc] on a [FakeCdromDrive]
class FakeDisc extends Disc {
  final FakeCdromDrive fake;

  FakeDisc(List<Uint8List> sectors,
      {List<int> starts = const [0], Set<int> audioTracks = const {}})
      : this._(FakeCdromDrive(sectors, starts: starts, audioTracks: audioTracks));

  FakeDisc._(this.fake) : super(fake);

  List<int> get reads => fake.reads;
}
