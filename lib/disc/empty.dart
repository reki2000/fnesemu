import 'dart:typed_data';

import 'disc.dart';

class EmptyDisc extends Disc {
  @override
  Uint8List read(int sector) => Disc.empty;
}
