// Bindings of src/mp_compute.c, built by hook/build.dart.
// The Dart names follow the C names.
// ignore_for_file: non_constant_identifier_names
import 'dart:ffi';

final class MpcDevice extends Opaque {}

final class MpcProgram extends Opaque {}

@Native<Pointer<Uint8> Function(Pointer<MpcDevice>)>(isLeaf: true)
external Pointer<Uint8> mpc_error(Pointer<MpcDevice> device);

@Native<Int32 Function(Uint32, Pointer<Uint8>, Int32)>()
external int mpc_adapters(int backends, Pointer<Uint8> info, int length);

@Native<
  Pointer<MpcDevice> Function(Pointer<Uint8>, Uint32, Pointer<Uint8>, Int32)
>()
external Pointer<MpcDevice> mpc_device_open(
  Pointer<Uint8> name,
  int backends,
  Pointer<Uint8> info,
  int length,
);

@Native<
  Pointer<MpcProgram> Function(
    Pointer<MpcDevice>,
    Pointer<Uint8>,
    Pointer<Pointer<Uint8>>,
    Uint32,
    Pointer<Uint32>,
    Pointer<Uint64>,
    Uint32,
    Uint32,
    Uint32,
  )
>()
external Pointer<MpcProgram> mpc_program_create(
  Pointer<MpcDevice> device,
  Pointer<Uint8> wgsl,
  Pointer<Pointer<Uint8>> entries,
  int entryCount,
  Pointer<Uint32> kinds,
  Pointer<Uint64> sizes,
  int bindingCount,
  int paramStride,
  int maxDispatches,
);

@Native<
  Int32 Function(Pointer<MpcProgram>, Uint32, Uint64, Pointer<Void>, Uint64)
>(isLeaf: true)
external int mpc_write(
  Pointer<MpcProgram> program,
  int binding,
  int offset,
  Pointer<Void> source,
  int bytes,
);

@Native<
  Int32 Function(
    Pointer<MpcProgram>,
    Pointer<Uint32>,
    Uint32,
    Pointer<Void>,
    Uint32,
  )
>(isLeaf: true)
external int mpc_run(
  Pointer<MpcProgram> program,
  Pointer<Uint32> dispatches,
  int count,
  Pointer<Void> params,
  int wait,
);

@Native<
  Int32 Function(Pointer<MpcProgram>, Uint32, Uint64, Pointer<Void>, Uint64)
>(isLeaf: true)
external int mpc_read(
  Pointer<MpcProgram> program,
  int binding,
  int offset,
  Pointer<Void> target,
  int bytes,
);

@Native<Int32 Function(Pointer<MpcProgram>, Uint32, Uint64, Uint64)>(
  isLeaf: true,
)
external int mpc_prefetch(
  Pointer<MpcProgram> program,
  int binding,
  int offset,
  int bytes,
);

@Native<Void Function(Pointer<MpcProgram>)>()
external void mpc_program_destroy(Pointer<MpcProgram> program);

@Native<Void Function(Pointer<MpcDevice>)>()
external void mpc_device_close(Pointer<MpcDevice> device);

@Native<Pointer<Void> Function(Uint64)>(isLeaf: true)
external Pointer<Void> mpc_malloc(int bytes);

@Native<Void Function(Pointer<Void>)>(isLeaf: true)
external void mpc_free(Pointer<Void> pointer);

/// Releases memory from [malloc].
void free(Pointer<Void> pointer) => mpc_free(pointer);

/// [bytes] of native memory, released with [free]
Pointer<T> malloc<T extends NativeType>(int bytes) {
  final p = mpc_malloc(bytes);
  if (p == nullptr) throw StateError('out of native memory');
  return p.cast<T>();
}
