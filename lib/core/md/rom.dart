import 'dart:typed_data';

class Rom {
  var rom = Uint8List(0);

  Rom();

  void load(Uint8List body) {
    rom = body.buffer.asUint8List();
    // print(
    //     "loaded rom: ${rom.length} 0:${rom[0].hex8} 1:${rom[1].hex8} 2:${rom[2].hex8} 3:${rom[3].hex8}");
  }
}
