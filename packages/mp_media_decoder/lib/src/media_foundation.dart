import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'types.dart';
import 'yuv.dart';

// The H.264 decoder of Windows: the H.264 decoder transform of Media
// Foundation, driven through its COM interfaces. The transform decodes on
// the calling thread, so a decode needs no wait. The pictures come out as
// NV12 and turn into RGBA here.
//
// The GUIDs, the method orders of the interfaces and the codes follow the
// headers of the Windows SDK (mfapi.h, mfobjects.h, mftransform.h,
// mferror.h, mfidl.h, codecapi.h).

final class _Guid extends Struct {
  @Uint32()
  external int data1;
  @Uint16()
  external int data2;
  @Uint16()
  external int data3;
  @Array(8)
  external Array<Uint8> data4;
}

/// Writes the GUID [text] (`xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`) into
/// memory of [allocator].
Pointer<_Guid> _guid(String text, Allocator allocator) {
  final hex = text.replaceAll('-', '');
  final guid = allocator<_Guid>();
  guid.ref
    ..data1 = int.parse(hex.substring(0, 8), radix: 16)
    ..data2 = int.parse(hex.substring(8, 12), radix: 16)
    ..data3 = int.parse(hex.substring(12, 16), radix: 16);
  for (var i = 0; i < 8; i++) {
    guid.ref.data4[i] = int.parse(
      hex.substring(16 + i * 2, 18 + i * 2),
      radix: 16,
    );
  }
  return guid;
}

const _clsidH264Decoder = '62ce7e72-4c71-4d20-b15d-452831a87d9d';
const _iidTransform = 'bf94c121-5b05-4e6f-8000-ba598961414d';
const _majorType = '48eba18e-f8c9-4687-bf11-0a74c9f96a8f';
const _subtype = 'f7e34c9a-42e8-4714-b74b-cb29d72c35e5';
const _frameSize = '1652c33d-d6b2-4012-b834-72030849a37d';
const _defaultStride = '644b4e48-1e02-4516-b0eb-c01ca9d49ac6';
const _displayAperture = 'd7388766-18fe-48c6-a177-ee894867c8c4';
const _lowLatency = '9c27891a-ed7a-40e1-88e8-b22727a024ee';
const _video = '73646976-0000-0010-8000-00aa00389b71';
const _h264 = '34363248-0000-0010-8000-00aa00389b71';
const _nv12 = '3231564e-0000-0010-8000-00aa00389b71';

const _mfVersion = 0x00020070;
const _coinitMultithreaded = 0;
const _clsctxInprocServer = 1;

const _notAccepting = 0xc00d36b5;
const _noMoreTypes = 0xc00d36b9;
const _streamChange = 0xc00d6d61;

const _messageFlush = 0;
const _messageBeginStreaming = 0x10000000;
const _messageStartOfStream = 0x10000003;

const _providesSamples = 0x100, _canProvideSamples = 0x200;

// The method indexes of the vtables: IUnknown, IMFAttributes (and so
// IMFMediaType and IMFSample), IMFSample, IMFMediaBuffer and IMFTransform.
const _release = 2;
const _getUint32 = 7, _getUint64 = 8, _getGuid = 10, _getBlob = 15;
const _setUint32 = 21, _setGuid = 24;
const _setSampleTime = 36, _contiguousBuffer = 41, _addBuffer = 42;
const _lock = 3, _unlock = 4, _setCurrentLength = 6;
const _outputStreamInfo = 7, _attributes = 8, _outputAvailableType = 14;
const _setInputType = 15, _setOutputType = 16, _processMessage = 23;
const _processInput = 24, _processOutput = 25;

/// The function at [index] of the vtable of the COM object [object].
Pointer<NativeFunction<T>> _method<T extends Function>(
  Pointer<Void> object,
  int index,
) => (object.cast<Pointer<Pointer<Void>>>().value + index).value.cast();

typedef _ReleaseC = Uint32 Function(Pointer<Void>);
typedef _Release = int Function(Pointer<Void>);
typedef _PtrC = Int32 Function(Pointer<Void>, Pointer<Void>);
typedef _Ptr = int Function(Pointer<Void>, Pointer<Void>);
typedef _PtrPtrC = Int32 Function(Pointer<Void>, Pointer<Void>, Pointer<Void>);
typedef _PtrPtr = int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>);
typedef _PtrU32C = Int32 Function(Pointer<Void>, Pointer<Void>, Uint32);
typedef _PtrU32 = int Function(Pointer<Void>, Pointer<Void>, int);
typedef _U32C = Int32 Function(Pointer<Void>, Uint32);
typedef _U32 = int Function(Pointer<Void>, int);
typedef _I64C = Int32 Function(Pointer<Void>, Int64);
typedef _I64 = int Function(Pointer<Void>, int);
typedef _U32PtrC = Int32 Function(Pointer<Void>, Uint32, Pointer<Void>);
typedef _U32Ptr = int Function(Pointer<Void>, int, Pointer<Void>);
typedef _MessageC = Int32 Function(Pointer<Void>, Uint32, UintPtr);
typedef _Message = int Function(Pointer<Void>, int, int);
typedef _U32PtrU32C =
    Int32 Function(Pointer<Void>, Uint32, Pointer<Void>, Uint32);
typedef _U32PtrU32 = int Function(Pointer<Void>, int, Pointer<Void>, int);
typedef _U32U32PtrC =
    Int32 Function(Pointer<Void>, Uint32, Uint32, Pointer<Void>);
typedef _U32U32Ptr = int Function(Pointer<Void>, int, int, Pointer<Void>);
typedef _OutputC =
    Int32 Function(
      Pointer<Void>,
      Uint32,
      Uint32,
      Pointer<Void>,
      Pointer<Uint32>,
    );
typedef _Output =
    int Function(Pointer<Void>, int, int, Pointer<Void>, Pointer<Uint32>);
typedef _BlobC =
    Int32 Function(
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Uint8>,
      Uint32,
      Pointer<Uint32>,
    );
typedef _Blob =
    int Function(
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Uint8>,
      int,
      Pointer<Uint32>,
    );
typedef _LockC =
    Int32 Function(
      Pointer<Void>,
      Pointer<Pointer<Uint8>>,
      Pointer<Uint32>,
      Pointer<Uint32>,
    );
typedef _Lock =
    int Function(
      Pointer<Void>,
      Pointer<Pointer<Uint8>>,
      Pointer<Uint32>,
      Pointer<Uint32>,
    );
typedef _UnlockC = Int32 Function(Pointer<Void>);
typedef _Unlock = int Function(Pointer<Void>);

typedef _StartupC = Int32 Function(Uint32, Uint32);
typedef _Startup = int Function(int, int);
typedef _CreateC = Int32 Function(Pointer<Pointer<Void>>);
typedef _Create = int Function(Pointer<Pointer<Void>>);
typedef _CreateBufferC = Int32 Function(Uint32, Pointer<Pointer<Void>>);
typedef _CreateBuffer = int Function(int, Pointer<Pointer<Void>>);
typedef _CoInitC = Int32 Function(Pointer<Void>, Uint32);
typedef _CoInit = int Function(Pointer<Void>, int);
typedef _CoCreateC =
    Int32 Function(
      Pointer<_Guid>,
      Pointer<Void>,
      Uint32,
      Pointer<_Guid>,
      Pointer<Pointer<Void>>,
    );
typedef _CoCreate =
    int Function(
      Pointer<_Guid>,
      Pointer<Void>,
      int,
      Pointer<_Guid>,
      Pointer<Pointer<Void>>,
    );

void _releaseObject(Pointer<Void> object) {
  if (object != nullptr) {
    _method<_ReleaseC>(object, _release).asFunction<_Release>()(object);
  }
}

bool _failed(int hresult) => hresult < 0;

/// Media Foundation, started.
class MediaFoundation {
  MediaFoundation._(DynamicLibrary mfplat, DynamicLibrary ole32)
    : _createMediaType = mfplat.lookupFunction<_CreateC, _Create>(
        'MFCreateMediaType',
      ),
      _createSample = mfplat.lookupFunction<_CreateC, _Create>(
        'MFCreateSample',
      ),
      _createBuffer = mfplat.lookupFunction<_CreateBufferC, _CreateBuffer>(
        'MFCreateMemoryBuffer',
      ),
      _coCreate = ole32.lookupFunction<_CoCreateC, _CoCreate>(
        'CoCreateInstance',
      );

  final _Create _createMediaType;
  final _Create _createSample;
  final _CreateBuffer _createBuffer;
  final _CoCreate _coCreate;

  static MediaFoundation? _loaded;
  static bool _tried = false;

  /// Media Foundation, or null when it is missing, as on the N editions
  /// of Windows without the media feature pack.
  static MediaFoundation? load() {
    if (_tried) return _loaded;
    _tried = true;
    try {
      final ole32 = DynamicLibrary.open('ole32.dll');
      final mfplat = DynamicLibrary.open('mfplat.dll');
      // A thread that has COM already, such as the UI thread of the app,
      // keeps its model; the error is harmless.
      ole32.lookupFunction<_CoInitC, _CoInit>('CoInitializeEx')(
        nullptr,
        _coinitMultithreaded,
      );
      final startup = mfplat.lookupFunction<_StartupC, _Startup>('MFStartup');
      if (_failed(startup(_mfVersion, 0))) return null;
      final mf = MediaFoundation._(mfplat, ole32);
      // The decoder can be missing although Media Foundation is there.
      final probe = mf._createDecoder();
      if (probe == null) return null;
      _releaseObject(probe);
      return _loaded = mf;
    } on ArgumentError {
      return null;
    }
  }

  Pointer<Void>? _createDecoder() => using((arena) {
    final out = arena<Pointer<Void>>();
    final result = _coCreate(
      _guid(_clsidH264Decoder, arena),
      nullptr,
      _clsctxInprocServer,
      _guid(_iidTransform, arena),
      out,
    );
    return _failed(result) ? null : out.value;
  });

  /// An H.264 decoder; null when the transform does not take the stream
  /// type.
  VideoDecoder? openH264() {
    final transform = _createDecoder();
    if (transform == null) return null;
    final decoder = _MfVideoDecoder(this, transform);
    if (!decoder._start()) {
      decoder.close();
      return null;
    }
    return decoder;
  }
}

class _MfVideoDecoder implements VideoDecoder {
  _MfVideoDecoder(this._mf, this._transform);

  final MediaFoundation _mf;
  Pointer<Void> _transform;

  /// the output sample of this side, when the transform does not
  /// allocate one
  Pointer<Void> _sample = nullptr, _sampleBuffer = nullptr;
  int _sampleSize = 0;
  bool _transformProvides = false;

  /// the size of the coded picture, the row stride of the planes and the
  /// size shown
  int _codedHeight = 0, _stride = 0, _width = 0, _height = 0;

  int _time = 0;
  DecodedPicture? _latest;

  bool _start() => using((arena) {
    // Low latency: the transform gives each picture as soon as the
    // order of display allows.
    final attributes = arena<Pointer<Void>>();
    if (!_failed(
      _method<_PtrC>(_transform, _attributes).asFunction<_Ptr>()(
        _transform,
        attributes.cast(),
      ),
    )) {
      _method<_PtrU32C>(attributes.value, _setUint32).asFunction<_PtrU32>()(
        attributes.value,
        _guid(_lowLatency, arena).cast(),
        1,
      );
      _releaseObject(attributes.value);
    }
    final type = arena<Pointer<Void>>();
    if (_failed(_mf._createMediaType(type))) return false;
    final setGuid = _method<_PtrPtrC>(
      type.value,
      _setGuid,
    ).asFunction<_PtrPtr>();
    setGuid(
      type.value,
      _guid(_majorType, arena).cast(),
      _guid(_video, arena).cast(),
    );
    setGuid(
      type.value,
      _guid(_subtype, arena).cast(),
      _guid(_h264, arena).cast(),
    );
    final result = _method<_U32PtrU32C>(
      _transform,
      _setInputType,
    ).asFunction<_U32PtrU32>()(_transform, 0, type.value, 0);
    _releaseObject(type.value);
    if (_failed(result) || !_chooseOutput()) return false;
    final message = _method<_MessageC>(
      _transform,
      _processMessage,
    ).asFunction<_Message>();
    message(_transform, _messageBeginStreaming, 0);
    message(_transform, _messageStartOfStream, 0);
    return true;
  });

  /// Sets the NV12 output type and reads its sizes; false when the
  /// transform offers none.
  bool _chooseOutput() => using((arena) {
    final type = arena<Pointer<Void>>();
    final subtype = arena<_Guid>();
    final nv12 = _guid(_nv12, arena);
    for (var i = 0; ; i++) {
      final result = _method<_U32U32PtrC>(
        _transform,
        _outputAvailableType,
      ).asFunction<_U32U32Ptr>()(_transform, 0, i, type.cast());
      if (result.toUnsigned(32) == _noMoreTypes || _failed(result)) {
        return false;
      }
      final t = type.value;
      final isNv12 =
          !_failed(
            _method<_PtrPtrC>(t, _getGuid).asFunction<_PtrPtr>()(
              t,
              _guid(_subtype, arena).cast(),
              subtype.cast(),
            ),
          ) &&
          _sameGuid(subtype, nv12);
      if (isNv12 &&
          !_failed(
            _method<_U32PtrU32C>(
              _transform,
              _setOutputType,
            ).asFunction<_U32PtrU32>()(_transform, 0, t, 0),
          )) {
        _readSizes(t, arena);
        _releaseObject(t);
        return _prepareSample();
      }
      _releaseObject(t);
    }
  });

  static bool _sameGuid(Pointer<_Guid> a, Pointer<_Guid> b) {
    final x = a.cast<Uint8>().asTypedList(16),
        y = b.cast<Uint8>().asTypedList(16);
    for (var i = 0; i < 16; i++) {
      if (x[i] != y[i]) return false;
    }
    return true;
  }

  void _readSizes(Pointer<Void> type, Arena arena) {
    final u64 = arena<Uint64>();
    final u32 = arena<Uint32>();
    _method<_PtrPtrC>(type, _getUint64).asFunction<_PtrPtr>()(
      type,
      _guid(_frameSize, arena).cast(),
      u64.cast(),
    );
    final codedWidth = u64.value >>> 32;
    _codedHeight = u64.value & 0xffffffff;
    u32.value = codedWidth;
    _method<_PtrPtrC>(type, _getUint32).asFunction<_PtrPtr>()(
      type,
      _guid(_defaultStride, arena).cast(),
      u32.cast(),
    );
    _stride = u32.value.toSigned(32).abs();
    _width = codedWidth;
    _height = _codedHeight;
    // MFVideoArea: OffsetX, OffsetY, then the width and height shown
    final area = arena<Uint8>(16);
    if (!_failed(
      _method<_BlobC>(type, _getBlob).asFunction<_Blob>()(
        type,
        _guid(_displayAperture, arena).cast(),
        area,
        16,
        u32,
      ),
    )) {
      final size = area.cast<Int32>();
      if (size[2] > 0 && size[3] > 0) {
        _width = size[2];
        _height = size[3];
      }
    }
  }

  /// Makes the output sample of this side unless the transform gives its
  /// own.
  bool _prepareSample() => using((arena) {
    // MFT_OUTPUT_STREAM_INFO: dwFlags, cbSize, cbAlignment
    final info = arena<Uint32>(3);
    if (_failed(
      _method<_U32PtrC>(_transform, _outputStreamInfo).asFunction<_U32Ptr>()(
        _transform,
        0,
        info.cast(),
      ),
    )) {
      return false;
    }
    _transformProvides = info[0] & (_providesSamples | _canProvideSamples) != 0;
    if (_transformProvides) return true;
    final size = info[1];
    if (_sample != nullptr && size <= _sampleSize) return true;
    _releaseObject(_sample);
    _releaseObject(_sampleBuffer);
    _sample = _sampleBuffer = nullptr;
    final sample = arena<Pointer<Void>>();
    final buffer = arena<Pointer<Void>>();
    if (_failed(_mf._createSample(sample))) return false;
    if (_failed(_mf._createBuffer(size, buffer))) {
      _releaseObject(sample.value);
      return false;
    }
    _method<_PtrC>(sample.value, _addBuffer).asFunction<_Ptr>()(
      sample.value,
      buffer.value,
    );
    _sample = sample.value;
    _sampleBuffer = buffer.value;
    _sampleSize = size;
    return true;
  });

  @override
  DecodedPicture? decode(Uint8List unit) {
    if (_transform == nullptr || unit.isEmpty) return _latest;
    final input = _inputSample(unit);
    if (input == null) return _latest;
    final processInput = _method<_U32PtrU32C>(
      _transform,
      _processInput,
    ).asFunction<_U32PtrU32>();
    var result = processInput(_transform, 0, input, 0);
    if (result.toUnsigned(32) == _notAccepting) {
      _drain();
      result = processInput(_transform, 0, input, 0);
    }
    _releaseObject(input);
    _drain();
    return _latest;
  }

  /// A sample holding [unit], timed one tick after the previous one.
  Pointer<Void>? _inputSample(Uint8List unit) => using((arena) {
    final sample = arena<Pointer<Void>>();
    final buffer = arena<Pointer<Void>>();
    if (_failed(_mf._createSample(sample))) return null;
    if (_failed(_mf._createBuffer(unit.length, buffer))) {
      _releaseObject(sample.value);
      return null;
    }
    final b = buffer.value;
    final data = arena<Pointer<Uint8>>();
    if (!_failed(
      _method<_LockC>(b, _lock).asFunction<_Lock>()(b, data, nullptr, nullptr),
    )) {
      data.value.asTypedList(unit.length).setAll(0, unit);
      _method<_UnlockC>(b, _unlock).asFunction<_Unlock>()(b);
      _method<_U32C>(b, _setCurrentLength).asFunction<_U32>()(b, unit.length);
    }
    final s = sample.value;
    _method<_PtrC>(s, _addBuffer).asFunction<_Ptr>()(s, b);
    _releaseObject(b);
    // in units of 100 ns, a picture of 1/30 s apart
    _method<_I64C>(s, _setSampleTime).asFunction<_I64>()(s, _time);
    _time += 333333;
    return s;
  });

  /// Takes the pictures that the transform has finished.
  void _drain() {
    final processOutput = _method<_OutputC>(
      _transform,
      _processOutput,
    ).asFunction<_Output>();
    // MFT_OUTPUT_DATA_BUFFER: dwStreamID, pSample, dwStatus, pEvents
    final output = calloc<Uint8>(32);
    final status = calloc<Uint32>();
    try {
      for (var i = 0; i < 16; i++) {
        output.asTypedList(32).fillRange(0, 32, 0);
        (output + 8).cast<Pointer<Void>>().value = _transformProvides
            ? nullptr
            : _sample;
        // The transform writes nothing into a buffer that holds data.
        if (!_transformProvides) {
          _method<_U32C>(
            _sampleBuffer,
            _setCurrentLength,
          ).asFunction<_U32>()(_sampleBuffer, 0);
        }
        final result = processOutput(
          _transform,
          0,
          1,
          output.cast(),
          status,
        ).toUnsigned(32);
        final sample = (output + 8).cast<Pointer<Void>>().value;
        final events = (output + 24).cast<Pointer<Void>>().value;
        _releaseObject(events);
        if (result == _streamChange) {
          if (!_chooseOutput()) return;
          continue;
        }
        if (_failed(result.toSigned(32))) return; // needs more input
        if (sample != nullptr) {
          _latest = _picture(sample) ?? _latest;
          if (_transformProvides) _releaseObject(sample);
        }
      }
    } finally {
      calloc.free(output);
      calloc.free(status);
    }
  }

  DecodedPicture? _picture(Pointer<Void> sample) => using((arena) {
    final buffer = arena<Pointer<Void>>();
    if (_failed(
      _method<_PtrC>(sample, _contiguousBuffer).asFunction<_Ptr>()(
        sample,
        buffer.cast(),
      ),
    )) {
      return null;
    }
    final b = buffer.value;
    try {
      final data = arena<Pointer<Uint8>>();
      final length = arena<Uint32>();
      if (_failed(
        _method<_LockC>(b, _lock).asFunction<_Lock>()(b, data, nullptr, length),
      )) {
        return null;
      }
      try {
        final stride = _stride > 0 ? _stride : _width;
        final chromaAt = stride * _codedHeight;
        final chromaRows = (_height + 1) >> 1;
        if (_width <= 0 ||
            _height <= 0 ||
            length.value < chromaAt + stride * chromaRows) {
          return null;
        }
        final bytes = data.value.asTypedList(length.value);
        final chroma = Uint8List.sublistView(bytes, chromaAt);
        return DecodedPicture(
          _width,
          _height,
          yuv420ToRgba(
            _width,
            _height,
            bytes,
            stride,
            chroma,
            Uint8List.sublistView(chroma, 1),
            stride,
            chromaStep: 2,
          ),
        );
      } finally {
        _method<_UnlockC>(b, _unlock).asFunction<_Unlock>()(b);
      }
    } finally {
      _releaseObject(b);
    }
  });

  @override
  void flush() {
    if (_transform == nullptr) return;
    _method<_MessageC>(_transform, _processMessage).asFunction<_Message>()(
      _transform,
      _messageFlush,
      0,
    );
  }

  @override
  void close() {
    if (_transform == nullptr) return;
    _releaseObject(_sample);
    _releaseObject(_sampleBuffer);
    _sample = _sampleBuffer = nullptr;
    _releaseObject(_transform);
    _transform = nullptr;
  }
}
