/// CD-ROM disc images (.cue/.iso/.bin) on a virtual file system: give the
/// files by [DiscFile] and [DiscDirectory], and read the TOC and the sectors
/// by LBA with [DiscImage] or [DiscDrive].
library;

export 'disc_drive.dart';
export 'disc_folder.dart';
export 'disc_image.dart';
export 'disc_source.dart';
