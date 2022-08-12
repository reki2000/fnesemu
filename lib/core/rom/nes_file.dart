// Dart imports:
import 'dart:developer';
import 'dart:typed_data';

class NesFile {
  final program = <Uint8List>[];
  final character = <Uint8List>[];
  late final int mapper;

  bool mirrorVertical = false;
  bool hasBatteryBackup = false;

  /// throws exception when load failed
  void load(Uint8List body) {
    // check if enough length for iNES header
    if (body.length < 16) {
      throw Exception("too short iNES header");
    }

    // check if proper iNES header "NES[EOF]"
    if (!(body[0] == 0x4e &&
        body[1] == 0x45 &&
        body[2] == 0x53 &&
        body[3] == 0x1a)) {
      throw Exception("not iNES header");
    }

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

    log("loaded len:${body.length} "
        "mapper:$mapper "
        "prog:16k*$programRomLength "
        "char:8k*$characterRomLength "
        "vertical:$mirrorVertical "
        "ram:${ramSize}k/${nvramSize}k "
        "chrRam:${chrRamSize}k/${chrNvramSize}k");

    var offset = 16;
    if (has512trainer) {
      offset += 512;
    }

    // check if the file has enough size
    final requiredFileSize =
        offset + programRomLength * 16 * 1024 + characterRomLength * 8 * 1024;
    if (body.length < requiredFileSize) {
      throw Exception(
          "not enough file length: need $requiredFileSize but {body.length}");
    }

    // load rom data
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
