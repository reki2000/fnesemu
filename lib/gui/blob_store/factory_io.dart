import 'package:idb_shim/idb_io.dart';
import 'package:path_provider/path_provider.dart';

Future<IdbFactory> idbFactory() async =>
    getIdbFactorySembastIo((await getApplicationSupportDirectory()).path);
