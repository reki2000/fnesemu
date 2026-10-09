// gives the files of mp_bigfile_picker to the cdrom. no dependency on flutter,
// for the command line tools.
import 'dart:typed_data';

import 'package:mp_bigfile_picker/api.dart';

import '../cdrom/disc_source.dart';

class PickedDiscFile extends DiscFile {
  final RandomReadFile file;

  PickedDiscFile(this.file);

  @override
  String get name => file.name;

  @override
  Future<int> length() => file.length();

  @override
  Future<Uint8List> read(int offset, int length) => file.read(offset, length);

  @override
  Future<void> close() => file.close();
}

class PickedDiscDirectory extends DiscDirectory {
  final PickedDirectory dir;

  PickedDiscDirectory(this.dir);

  @override
  String get name => dir.name;

  @override
  Stream<String> walk() => dir.walk();

  @override
  DiscFile open(String path) => PickedDiscFile(dir.open(path));
}

/// the .cue/.iso/.bin file [main] of [dir]. the files referred from a .cue
/// file are opened by the names in [dir], relative to [main].
DiscSource pickedDiscIn(PickedDirectory dir, String main) =>
    DiscSource(PickedDiscFile(dir.open(main)), (name) {
      final i = main.lastIndexOf('/');
      final base = i < 0 ? '' : main.substring(0, i + 1);
      return PickedDiscFile(dir.open('$base${name.replaceAll('\\', '/')}'));
    });
