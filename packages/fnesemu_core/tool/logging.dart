import 'dart:io';

import 'package:fnesemu_core/src/util/debug.dart';

void configureLogging() {
  logs.sink = (event) => stderr.writeln(event);
}
