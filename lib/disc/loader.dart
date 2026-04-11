import 'disc.dart';
import 'empty.dart';
import 'iso.dart';

class DiscLoader {
  static Disc load(String path) {
    if (path.isEmpty) {
      return EmptyDisc();
    } else {
      return IsoDisc(path);
    }
  }
}
