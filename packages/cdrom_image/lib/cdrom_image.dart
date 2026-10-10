/// CD-ROM disc images (.cue/.iso/.bin) on a virtual file system: give the
/// files by [DiscFile] and [DiscDirectory], and read the TOC and the sectors
/// by LBA with [DiscImage].
library;

export 'disc_folder.dart';
export 'disc_image.dart' show parseSource;
export 'disc_source.dart';
export 'filesystem_api.dart';
export 'image_api.dart';
