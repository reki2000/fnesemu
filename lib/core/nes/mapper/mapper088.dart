// Dart imports:

// Project imports:
import 'namco118.dart';

// https://www.nesdev.org/wiki/INES_Mapper_088
class Mapper088 extends MapperNamco118 {
  @override
  void init() {
    super.init();
    chrRomA16 = 0x40;
  }
}
