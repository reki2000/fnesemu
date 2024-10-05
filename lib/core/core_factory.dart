import 'core.dart';
import 'nes/nes.dart';
import 'pce/pce.dart';

class CoreFactory {
  static Core ofPce() {
    return Pce();
  }

  static Core ofNes() {
    return Nes();
  }
}
