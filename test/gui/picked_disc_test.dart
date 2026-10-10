import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fnesemu/gui/picked_disc.dart';
import 'package:mp_bigfile_picker/api.dart';

class TrackedFile extends RandomReadFile {
  bool closed = false;
  bool busy = false;
  final bool failLength;
  TrackedFile({this.failLength = false});
  @override
  String get name => 'track.bin';
  @override
  Future<int> length() async {
    if (failLength) throw StateError('metadata failed');
    return 4;
  }

  @override
  Future<Uint8List> read(int offset, int length) async {
    if (busy || closed) throw StateError('shared handle');
    busy = true;
    await Future<void>.delayed(Duration.zero);
    if (offset < 0) throw StateError('read failed');
    busy = false;
    return Uint8List.fromList([offset]);
  }

  @override
  Future<void> close() async => closed = true;
}

class TrackedDirectory extends PickedDirectory {
  final opened = <TrackedFile>[];
  bool failLength = false;
  @override
  String get name => 'fixtures';
  @override
  String? get restoreKey => null;
  @override
  Stream<String> walk() => Stream.value('nested/track.bin');
  @override
  RandomReadFile open(String path) {
    final file = TrackedFile(failLength: failLength);
    opened.add(file);
    return file;
  }
}

void main() {
  test(
      'walk yields lazy descriptors and each read releases a fresh picker file',
      () async {
    final picker = TrackedDirectory();
    final files = await PickedDiscDirectory(picker).walk().toList();
    expect(files.single.path, 'nested/track.bin');
    expect(picker.opened, isEmpty);
    expect(await files.single.length(), 4);
    final bytes =
        await Future.wait([files.single.read(0, 1), files.single.read(2, 1)]);
    expect(bytes, [
      [0],
      [2]
    ]);
    expect(picker.opened.length, 3);
    expect(picker.opened.every((file) => file.closed), isTrue);
  });

  test('metadata and read failures still release picker resources', () async {
    final picker = TrackedDirectory()..failLength = true;
    final file = (await PickedDiscDirectory(picker).walk().toList()).single;
    await expectLater(file.length(), throwsStateError);
    picker.failLength = false;
    await expectLater(file.read(-1, 1), throwsStateError);
    expect(picker.opened.every((file) => file.closed), isTrue);
    expect(await file.read(1, 1), [1]);
    expect(picker.opened.last.closed, isTrue);
  });
}
