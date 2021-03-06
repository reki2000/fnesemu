// Dart imports:
import 'dart:developer';
import 'dart:typed_data';

class NesFile {
  final program = List<Uint8List>.empty(growable: true);
  final character = List<Uint8List>.empty(growable: true);
  late final int mapper;

  bool mirrorVertical = false;
  bool hasBatteryBackup = false;

  Future<void> load(Uint8List body) async {
    final programRomLength = body[4];
    final characterRomLength = body[5];
    final flags1 = body[6];

    mirrorVertical = flags1 & 0x01 != 0;
    hasBatteryBackup = flags1 & 0x02 != 0;

    final has512trainer = flags1 & 0x04 != 0;

    mapper = ((body[8] & 0x0f) << 16) | body[7] & 0xf0 | (flags1 >> 4);

    final ramSize = body[10] == 0 ? 0 : (64 << (body[10] & 0x0f));
    final nvramSize = body[10] == 0 ? 0 : (64 << (body[10] >> 4));

    final chrRamSize = body[11] == 0 ? 0 : (64 << (body[11] & 0x0f));
    final chrNvramSize = body[11] == 0 ? 0 : (64 << (body[11] >> 4));

    log("loaded len:${body.length} mapper:$mapper prog:16*$programRomLength char:8*$characterRomLength vertical:$mirrorVertical ram:${ramSize}k/${nvramSize}k chrRam:${chrRamSize}k/${chrNvramSize}k");

    var offset = 16;
    if (has512trainer) {
      offset += 512;
    }
    for (var i = 0; i < programRomLength; i++) {
      program.add(body.sublist(offset, offset + 16 * 1024));
      offset += 16 * 1024;
    }

    for (var i = 0; i < characterRomLength; i++) {
      if (body.length < offset + 8 * 1024) {
        final padded = body.getRange(offset, body.length).toList();
        padded.addAll(List<int>.filled(offset + 8 * 1024 - body.length, 0xff));
        character.add(Uint8List.fromList(padded));
        break;
      }
      character.add(body.sublist(offset, offset + 8 * 1024));
      offset += 8 * 1024;
    }
  }
}

class Header {
  String magic;
  int programRomLength;
  int characterRomLength;

  Header(this.magic, this.programRomLength, this.characterRomLength);
}
