import 'dart:ffi';

@Native<IntPtr Function()>(symbol: 'mp_jit_page_size')
external int nativePageSize();

@Native<Pointer<Uint8> Function(IntPtr, Int32)>(symbol: 'mp_jit_alloc')
external Pointer<Uint8> nativeAlloc(int size, int code);

@Native<Void Function(Pointer<Uint8>, IntPtr)>(symbol: 'mp_jit_free')
external void nativeFree(Pointer<Uint8> address, int size);

@Native<Int32 Function(Pointer<Uint8>, Pointer<Uint8>, IntPtr)>(
  symbol: 'mp_jit_write',
)
external int nativeWrite(
  Pointer<Uint8> target,
  Pointer<Uint8> source,
  int size,
);
