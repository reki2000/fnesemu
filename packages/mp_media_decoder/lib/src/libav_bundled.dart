// The functions of mmd_libav, the ATRAC-only LGPL libavcodec that the build
// hook bundles as a code asset (tool/build_libav_atrac.sh builds it). The
// Dart runtime opens the asset at the first call; a build without it, such
// as one that turned the bundling off, has no asset, and the calls throw.
// ignore_for_file: non_constant_identifier_names
@DefaultAsset('package:mp_media_decoder/src/libav_bundled.dart')
library;

import 'dart:ffi';

/// the name of the bundled library, for the GUI
const bundledLibavName = 'mmd_libav (bundled)';

@Native<Pointer<Void> Function()>()
external Pointer<Void> avcodec_license();
@Native<Pointer<Void> Function()>()
external Pointer<Void> avutil_license();
@Native<Pointer<Void> Function(Pointer<Void>)>()
external Pointer<Void> avcodec_find_decoder_by_name(Pointer<Void> name);
@Native<Pointer<Void> Function(Pointer<Void>)>()
external Pointer<Void> avcodec_alloc_context3(Pointer<Void> codec);
@Native<Int32 Function(Pointer<Void>, Pointer<Void>, Pointer<Void>)>()
external int avcodec_open2(
    Pointer<Void> context, Pointer<Void> codec, Pointer<Void> options);
@Native<Int32 Function(Pointer<Void>, Pointer<Void>)>()
external int avcodec_send_packet(Pointer<Void> context, Pointer<Void> packet);
@Native<Int32 Function(Pointer<Void>, Pointer<Void>)>()
external int avcodec_receive_frame(Pointer<Void> context, Pointer<Void> frame);
@Native<Void Function(Pointer<Void>)>()
external void avcodec_flush_buffers(Pointer<Void> context);
@Native<Void Function(Pointer<Pointer<Void>>)>()
external void avcodec_free_context(Pointer<Pointer<Void>> context);
@Native<Pointer<Void> Function()>()
external Pointer<Void> av_packet_alloc();
@Native<Void Function(Pointer<Pointer<Void>>)>()
external void av_packet_free(Pointer<Pointer<Void>> packet);
@Native<Int32 Function(Pointer<Void>, Int32)>()
external int av_new_packet(Pointer<Void> packet, int size);
@Native<Void Function(Pointer<Void>)>()
external void av_packet_unref(Pointer<Void> packet);
@Native<Pointer<Void> Function()>()
external Pointer<Void> av_frame_alloc();
@Native<Void Function(Pointer<Pointer<Void>>)>()
external void av_frame_free(Pointer<Pointer<Void>> frame);
@Native<Int32 Function(Pointer<Void>, Pointer<Void>, Int64, Int32)>()
external int av_opt_set_int(
    Pointer<Void> object, Pointer<Void> name, int value, int flags);
@Native<Int32 Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Int32)>()
external int av_opt_set(
    Pointer<Void> object, Pointer<Void> name, Pointer<Void> value, int flags);

/// The address of each function by its name; null when the build has no
/// bundled library.
Pointer<Void> Function(String)? bundledLibavSymbols() {
  final Map<String, Pointer<Void>> symbols;
  try {
    symbols = {
      'avcodec_license': Native.addressOf<
              NativeFunction<Pointer<Void> Function()>>(avcodec_license)
          .cast(),
      'avutil_license': Native.addressOf<
              NativeFunction<Pointer<Void> Function()>>(avutil_license)
          .cast(),
      'avcodec_find_decoder_by_name': Native.addressOf<
                  NativeFunction<Pointer<Void> Function(Pointer<Void>)>>(
              avcodec_find_decoder_by_name)
          .cast(),
      'avcodec_alloc_context3': Native.addressOf<
              NativeFunction<
                  Pointer<Void> Function(Pointer<Void>)>>(avcodec_alloc_context3)
          .cast(),
      'avcodec_open2': Native.addressOf<
              NativeFunction<
                  Int32 Function(Pointer<Void>, Pointer<Void>,
                      Pointer<Void>)>>(avcodec_open2)
          .cast(),
      'avcodec_send_packet': Native.addressOf<
              NativeFunction<
                  Int32 Function(
                      Pointer<Void>, Pointer<Void>)>>(avcodec_send_packet)
          .cast(),
      'avcodec_receive_frame': Native.addressOf<
              NativeFunction<
                  Int32 Function(
                      Pointer<Void>, Pointer<Void>)>>(avcodec_receive_frame)
          .cast(),
      'avcodec_flush_buffers': Native.addressOf<
              NativeFunction<Void Function(Pointer<Void>)>>(
              avcodec_flush_buffers)
          .cast(),
      'avcodec_free_context': Native.addressOf<
              NativeFunction<Void Function(Pointer<Pointer<Void>>)>>(
              avcodec_free_context)
          .cast(),
      'av_packet_alloc': Native.addressOf<
              NativeFunction<Pointer<Void> Function()>>(av_packet_alloc)
          .cast(),
      'av_packet_free': Native.addressOf<
              NativeFunction<
                  Void Function(Pointer<Pointer<Void>>)>>(av_packet_free)
          .cast(),
      'av_new_packet': Native.addressOf<
              NativeFunction<Int32 Function(Pointer<Void>, Int32)>>(
              av_new_packet)
          .cast(),
      'av_packet_unref': Native.addressOf<
              NativeFunction<Void Function(Pointer<Void>)>>(av_packet_unref)
          .cast(),
      'av_frame_alloc': Native.addressOf<
              NativeFunction<Pointer<Void> Function()>>(av_frame_alloc)
          .cast(),
      'av_frame_free': Native.addressOf<
              NativeFunction<Void Function(Pointer<Pointer<Void>>)>>(
              av_frame_free)
          .cast(),
      'av_opt_set_int': Native.addressOf<
              NativeFunction<
                  Int32 Function(Pointer<Void>, Pointer<Void>, Int64,
                      Int32)>>(av_opt_set_int)
          .cast(),
      'av_opt_set': Native.addressOf<
              NativeFunction<
                  Int32 Function(Pointer<Void>, Pointer<Void>, Pointer<Void>,
                      Int32)>>(av_opt_set)
          .cast(),
    };
  } on ArgumentError {
    return null;
  }
  return (name) => symbols[name]!;
}
