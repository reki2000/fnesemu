import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'types.dart';

// The H.264 decoder of Linux: a GStreamer pipeline that takes the access
// units from an appsrc, decodes them with the H.264 decoder of the highest
// rank among the plugins installed on the system, and converts the
// pictures to RGBA for an appsink. The
// package opens the shared GStreamer libraries (LGPL) at run time; which
// plugin decodes, and under what license, is the choice of the system.
// The pipeline runs on GStreamer's own threads and calls no Dart code.

typedef _InitCheckC =
    Int32 Function(Pointer<Void>, Pointer<Void>, Pointer<Pointer<Void>>);
typedef _InitCheck =
    int Function(Pointer<Void>, Pointer<Void>, Pointer<Pointer<Void>>);
typedef _ParseLaunchC =
    Pointer<Void> Function(Pointer<Utf8>, Pointer<Pointer<Void>>);
typedef _ParseLaunch =
    Pointer<Void> Function(Pointer<Utf8>, Pointer<Pointer<Void>>);
typedef _GetByNameC = Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>);
typedef _GetByName = Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>);
typedef _SetStateC = Int32 Function(Pointer<Void>, Int32);
typedef _SetState = int Function(Pointer<Void>, int);
typedef _VoidPtrC = Void Function(Pointer<Void>);
typedef _VoidPtr = void Function(Pointer<Void>);
typedef _PtrOfPtrC = Pointer<Void> Function(Pointer<Void>);
typedef _PtrOfPtr = Pointer<Void> Function(Pointer<Void>);
typedef _NewBufferC =
    Pointer<Void> Function(Pointer<Void>, Size, Pointer<Void>);
typedef _NewBuffer = Pointer<Void> Function(Pointer<Void>, int, Pointer<Void>);
typedef _FillC = Size Function(Pointer<Void>, Size, Pointer<Uint8>, Size);
typedef _Fill = int Function(Pointer<Void>, int, Pointer<Uint8>, int);
typedef _MapC = Int32 Function(Pointer<Void>, Pointer<Uint8>, Int32);
typedef _Map = int Function(Pointer<Void>, Pointer<Uint8>, int);
typedef _UnmapC = Void Function(Pointer<Void>, Pointer<Uint8>);
typedef _Unmap = void Function(Pointer<Void>, Pointer<Uint8>);
typedef _StructureC = Pointer<Void> Function(Pointer<Void>, Uint32);
typedef _Structure = Pointer<Void> Function(Pointer<Void>, int);
typedef _GetIntC = Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Int32>);
typedef _GetInt = int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Int32>);
typedef _PushC = Int32 Function(Pointer<Void>, Pointer<Void>);
typedef _Push = int Function(Pointer<Void>, Pointer<Void>);
typedef _PullC = Pointer<Void> Function(Pointer<Void>, Uint64);
typedef _Pull = Pointer<Void> Function(Pointer<Void>, int);
typedef _ListC = Pointer<Void> Function(Uint64, Int32);
typedef _List = Pointer<Void> Function(int, int);
typedef _FilterC =
    Pointer<Void> Function(Pointer<Void>, Pointer<Void>, Int32, Int32);
typedef _Filter =
    Pointer<Void> Function(Pointer<Void>, Pointer<Void>, int, int);
typedef _CapsC = Pointer<Void> Function(Pointer<Utf8>);
typedef _Caps = Pointer<Void> Function(Pointer<Utf8>);
typedef _NameC = Pointer<Utf8> Function(Pointer<Void>);
typedef _Name = Pointer<Utf8> Function(Pointer<Void>);
typedef _FreeC = Void Function(Pointer<Void>);
typedef _Free = void Function(Pointer<Void>);
typedef _FindPropertyC = Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>);
typedef _FindProperty = Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>);
typedef _SetIntC = Void Function(
    Pointer<Void>, Pointer<Utf8>, VarArgs<(Int32, Pointer<Void>)>);
typedef _SetInt = void Function(Pointer<Void>, Pointer<Utf8>, int, Pointer<Void>);

// GstState
const _stateNull = 1, _statePlaying = 4;

// GstStateChangeReturn
const _stateChangeFailure = 0;

// GstElementFactoryListType: decoders of video, and GstRank marginal
const _factoryDecoder = 1, _factoryMediaVideo = 1 << 49, _rankMarginal = 64;

// GstPadDirection
const _padSink = 2;

// GstMapInfo: memory, flags, data, size, maxsize, user_data[4],
// _gst_reserved[4]
const _mapInfoSize = 104, _mapData = 16, _mapSize = 24, _mapRead = 1;

const _caps = 'video/x-h264,stream-format=byte-stream,alignment=au';

/// The pipeline around the decoder element [decoder].
String _pipeline(String decoder) =>
    'appsrc name=src format=bytes caps="$_caps" '
    '! $decoder name=dec ! videoconvert ! video/x-raw,format=RGBA '
    '! appsink name=sink sync=false';

/// The shared GStreamer libraries.
class GStreamer {
  GStreamer._(DynamicLibrary core, DynamicLibrary app, DynamicLibrary glib,
      DynamicLibrary gobject)
    : _objectName = core.lookupFunction<_NameC, _Name>('gst_object_get_name'),
      _free = glib.lookupFunction<_FreeC, _Free>('g_free'),
      _findProperty = gobject.lookupFunction<_FindPropertyC, _FindProperty>(
        'g_object_class_find_property',
      ),
      _setInt = gobject.lookupFunction<_SetIntC, _SetInt>('g_object_set'),
      _parseLaunch = core.lookupFunction<_ParseLaunchC, _ParseLaunch>(
        'gst_parse_launch',
      ),
      _getByName = core.lookupFunction<_GetByNameC, _GetByName>(
        'gst_bin_get_by_name',
      ),
      _setState = core.lookupFunction<_SetStateC, _SetState>(
        'gst_element_set_state',
      ),
      _unrefObject = core.lookupFunction<_VoidPtrC, _VoidPtr>(
        'gst_object_unref',
      ),
      _unrefMiniObject = core.lookupFunction<_VoidPtrC, _VoidPtr>(
        'gst_mini_object_unref',
      ),
      _newBuffer = core.lookupFunction<_NewBufferC, _NewBuffer>(
        'gst_buffer_new_allocate',
      ),
      _fill = core.lookupFunction<_FillC, _Fill>('gst_buffer_fill'),
      _map = core.lookupFunction<_MapC, _Map>('gst_buffer_map'),
      _unmap = core.lookupFunction<_UnmapC, _Unmap>('gst_buffer_unmap'),
      _sampleBuffer = core.lookupFunction<_PtrOfPtrC, _PtrOfPtr>(
        'gst_sample_get_buffer',
      ),
      _sampleCaps = core.lookupFunction<_PtrOfPtrC, _PtrOfPtr>(
        'gst_sample_get_caps',
      ),
      _structure = core.lookupFunction<_StructureC, _Structure>(
        'gst_caps_get_structure',
      ),
      _getInt = core.lookupFunction<_GetIntC, _GetInt>('gst_structure_get_int'),
      _listFactories = core.lookupFunction<_ListC, _List>(
        'gst_element_factory_list_get_elements',
      ),
      _filterFactories = core.lookupFunction<_FilterC, _Filter>(
        'gst_element_factory_list_filter',
      ),
      _freeFactories = core.lookupFunction<_VoidPtrC, _VoidPtr>(
        'gst_plugin_feature_list_free',
      ),
      _capsFromString = core.lookupFunction<_CapsC, _Caps>(
        'gst_caps_from_string',
      ),
      _push = app.lookupFunction<_PushC, _Push>('gst_app_src_push_buffer'),
      _pull = app.lookupFunction<_PullC, _Pull>('gst_app_sink_try_pull_sample');

  final _ParseLaunch _parseLaunch;
  final _GetByName _getByName;
  final _SetState _setState;
  final _VoidPtr _unrefObject;
  final _VoidPtr _unrefMiniObject;
  final _NewBuffer _newBuffer;
  final _Fill _fill;
  final _Map _map;
  final _Unmap _unmap;
  final _PtrOfPtr _sampleBuffer;
  final _PtrOfPtr _sampleCaps;
  final _Structure _structure;
  final _GetInt _getInt;
  final _List _listFactories;
  final _Filter _filterFactories;
  final _VoidPtr _freeFactories;
  final _Caps _capsFromString;
  final _Push _push;
  final _Pull _pull;
  final _Name _objectName;
  final _Free _free;
  final _FindProperty _findProperty;
  final _SetInt _setInt;

  static GStreamer? _loaded;
  static bool _tried = false;

  /// The initialized GStreamer libraries, or null when they are missing.
  static GStreamer? load() {
    if (_tried) return _loaded;
    _tried = true;
    try {
      final core = DynamicLibrary.open('libgstreamer-1.0.so.0');
      final app = DynamicLibrary.open('libgstapp-1.0.so.0');
      final glib = DynamicLibrary.open('libglib-2.0.so.0');
      final gobject = DynamicLibrary.open('libgobject-2.0.so.0');
      final init = core.lookupFunction<_InitCheckC, _InitCheck>(
        'gst_init_check',
      );
      if (init(nullptr, nullptr, nullptr) == 0) return null;
      return _loaded = GStreamer._(core, app, glib, gobject);
    } on ArgumentError {
      return null;
    }
  }

  String? _decoder;
  bool _searched = false;

  /// Whether a decoder plugin takes H.264.
  bool get hasH264 => _h264Decoder != null;

  /// The name of the H.264 decoder element of the highest rank; the list
  /// of factories comes sorted by rank.
  String? get _h264Decoder {
    if (_searched) return _decoder;
    _searched = true;
    return _decoder = using<String?>((arena) {
    final all = _listFactories(
      _factoryDecoder | _factoryMediaVideo,
      _rankMarginal,
    );
    if (all == nullptr) return null;
    final caps = _capsFromString(_caps.toNativeUtf8(allocator: arena));
    final h264 = _filterFactories(all, caps, _padSink, 0);
    _unrefMiniObject(caps);
    _freeFactories(all);
    if (h264 == nullptr) return null;
    final name = _objectName(h264.cast<Pointer<Void>>().value);
    final decoder = name.toDartString();
    _free(name.cast());
    _freeFactories(h264);
    return decoder;
  });
  }

  /// An H.264 decoder; null when no plugin takes H.264 or the pipeline
  /// does not start.
  VideoDecoder? openH264() {
    final decoder = _h264Decoder;
    if (decoder == null) return null;
    return using((arena) {
      final pipeline = _parseLaunch(
        _pipeline(decoder).toNativeUtf8(allocator: arena),
        nullptr,
      );
      if (pipeline == nullptr) return null;
      // One thread, so that the decoder holds no pictures back for frame
      // threading; a decoder without the property keeps its own way.
      final dec = _getByName(pipeline, 'dec'.toNativeUtf8(allocator: arena));
      if (dec != nullptr) {
        final threads = 'max-threads'.toNativeUtf8(allocator: arena);
        if (_findProperty(dec.cast<Pointer<Void>>().value, threads) !=
            nullptr) {
          _setInt(dec, threads, 1, nullptr);
        }
        _unrefObject(dec);
      }
      final src = _getByName(pipeline, 'src'.toNativeUtf8(allocator: arena));
      final sink = _getByName(pipeline, 'sink'.toNativeUtf8(allocator: arena));
      if (src == nullptr ||
          sink == nullptr ||
          _setState(pipeline, _statePlaying) == _stateChangeFailure) {
        if (src != nullptr) _unrefObject(src);
        if (sink != nullptr) _unrefObject(sink);
        _setState(pipeline, _stateNull);
        _unrefObject(pipeline);
        return null;
      }
      return _GstVideoDecoder(this, pipeline, src, sink);
    });
  }
}

class _GstVideoDecoder implements VideoDecoder {
  _GstVideoDecoder(this._gst, this._pipeline, this._src, this._sink);

  final GStreamer _gst;
  Pointer<Void> _pipeline;
  final Pointer<Void> _src;
  final Pointer<Void> _sink;
  final _map = calloc<Uint8>(_mapInfoSize);
  final _int = calloc<Int32>();

  DecodedPicture? _latest;

  /// The units sent and the pictures taken since the last flush.
  int _sent = 0, _taken = 0;

  /// The number of units the decoder holds back for reordering, learned
  /// from the waits that ran out.
  int _delay = 0;

  /// How long a decode waits for the picture of the unit it was given.
  static const _wait = 30 * 1000 * 1000; // nanoseconds

  @override
  DecodedPicture? decode(Uint8List unit) {
    if (_pipeline == nullptr || unit.isEmpty) return _latest;
    final buffer = _gst._newBuffer(nullptr, unit.length, nullptr);
    if (buffer == nullptr) return _latest;
    final bytes = calloc<Uint8>(unit.length);
    bytes.asTypedList(unit.length).setAll(0, unit);
    _gst._fill(buffer, 0, bytes, unit.length);
    calloc.free(bytes);
    if (_gst._push(_src, buffer) != 0) return _latest;
    _sent++;
    // The pipeline decodes on its own threads. Take the pictures that are
    // ready, and wait for the one of this unit unless the decoder holds
    // that many units back; a wait that runs out means it holds one more.
    while (true) {
      final waiting = _sent - _taken > _delay;
      final sample = _gst._pull(_sink, waiting ? _wait : 0);
      if (sample == nullptr) {
        if (waiting) _delay++;
        break;
      }
      _taken++;
      _latest = _picture(sample) ?? _latest;
      _gst._unrefMiniObject(sample);
    }
    return _latest;
  }

  DecodedPicture? _picture(Pointer<Void> sample) {
    final caps = _gst._sampleCaps(sample);
    final buffer = _gst._sampleBuffer(sample);
    if (caps == nullptr || buffer == nullptr) return null;
    final structure = _gst._structure(caps, 0);
    final width = _field(structure, 'width');
    final height = _field(structure, 'height');
    if (width <= 0 || height <= 0) return null;
    if (_gst._map(buffer, _map, _mapRead) == 0) return null;
    try {
      final size = (_map + _mapSize).cast<Size>().value;
      if (size < width * height * 4) return null;
      final data = Pointer<Uint32>.fromAddress(
        (_map + _mapData).cast<IntPtr>().value,
      );
      return DecodedPicture(
        width,
        height,
        Uint32List.fromList(data.asTypedList(width * height)),
      );
    } finally {
      _gst._unmap(buffer, _map);
    }
  }

  int _field(Pointer<Void> structure, String name) => using(
    (arena) =>
        _gst._getInt(structure, name.toNativeUtf8(allocator: arena), _int) == 0
        ? 0
        : _int.value,
  );

  @override
  void flush() {
    if (_pipeline == nullptr) return;
    // Restarting the pipeline drops the units in flight and the state of
    // the decoder.
    _gst._setState(_pipeline, _stateNull);
    _gst._setState(_pipeline, _statePlaying);
    _sent = _taken = 0;
  }

  @override
  void close() {
    if (_pipeline == nullptr) return;
    _gst._setState(_pipeline, _stateNull);
    _gst._unrefObject(_src);
    _gst._unrefObject(_sink);
    _gst._unrefObject(_pipeline);
    _pipeline = nullptr;
    calloc.free(_map);
    calloc.free(_int);
  }
}
