import 'dart:js_interop';

import 'package:idb_shim/idb_client_native.dart';
import 'package:web/web.dart' as web;

Future<IdbFactory> idbFactory() async {
  // ask the browser not to evict the data under storage pressure
  try {
    await web.window.navigator.storage.persist().toDart;
  } catch (_) {}

  return idbFactoryNative;
}
