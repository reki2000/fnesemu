import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

typedef MAInitFunc = Int Function();
typedef MAInit = int Function();

typedef MAPushFunc = Void Function(Pointer<Float>, Int64);
typedef MAPush = void Function(Pointer<Float>, int);

typedef MAUninitFunc = Void Function();
typedef MAUninit = void Function();

class MAStream {
  static late MAPush _pushFfi;
  static late MAUninit _uninitFfi;

  static int init() {
    final dynLib = (Platform.isLinux || Platform.isAndroid)
        ? DynamicLibrary.open("libmastream.so")
        : Platform.isWindows
            ? DynamicLibrary.open("libmastream.dll")
            : Platform.isMacOS
                ? DynamicLibrary.open("libmastream.dynl")
                : DynamicLibrary.executable();

    final initFfi = dynLib
        .lookup<NativeFunction<MAInitFunc>>("ma_stream_init")
        .asFunction<MAInit>();

    _pushFfi = dynLib
        .lookup<NativeFunction<MAPushFunc>>("ma_stream_push")
        .asFunction<MAPush>();

    _uninitFfi = dynLib
        .lookup<NativeFunction<MAUninitFunc>>("ma_stream_uninit")
        .asFunction<MAUninit>();

    return initFfi();
  }

  static push(Float32List buf) {
    final ffiBuf = calloc<Float>(buf.length);
    for (int i = 0; i < buf.length; i++) {
      ffiBuf[i] = buf[i];
    }
    _pushFfi(ffiBuf, buf.length);
    calloc.free(ffiBuf);
  }

  static uninit() {
    _uninitFfi();
  }
}
