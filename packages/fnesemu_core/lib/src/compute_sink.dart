import 'dart:typed_data';

/// How a compute program binds a buffer.
enum ComputeBindingKind {
  /// `var<storage, read_write>`
  storage,

  /// `var<storage, read>`
  readOnlyStorage,

  /// a `var<uniform>` block per dispatch, bound with a dynamic offset; at
  /// most one binding of a program
  params,
}

/// A buffer of a compute program at the binding of its index in group 0.
/// For [ComputeBindingKind.params], [bytes] is the size of the block that a
/// dispatch sees.
class ComputeBinding {
  const ComputeBinding(this.kind, this.bytes);

  final ComputeBindingKind kind;
  final int bytes;
}

/// Compiled WGSL entry points that share the buffers of their bindings.
abstract interface class ComputeProgram {
  /// Writes [words] from [start] to [end] at [byteOffset] of [binding], in
  /// queue order before the next [run].
  void write(int binding, int byteOffset, Uint32List words,
      [int start = 0, int? end]);

  /// Runs [count] dispatches of 4 words in [dispatches]: the entry point
  /// index and the workgroup counts x, y and z, in order. Dispatch k sees the
  /// parameter block k of [params]. Unless [wait], the run is only
  /// submitted, and later writes still take effect after it.
  void run(Uint32List dispatches, int count, Uint32List params,
      {bool wait = true});

  /// Copies [bytes] at [byteOffset] of [binding] after the runs so far
  /// without waiting, so that a following [read] of the same range waits
  /// less.
  void prefetch(int binding, int byteOffset, int bytes);

  /// The ranges of the prefetches while they are not on the host, when
  /// [ComputeSink.waits] is false; null when [read] can take them.
  Future<void>? get fetching;

  /// Waits for the program and reads [target].length words at [byteOffset]
  /// of [binding]. When [ComputeSink.waits] is false, it reads only from
  /// the range of the last [prefetch] of [binding], after [fetching] has
  /// completed.
  void read(int binding, int byteOffset, Uint32List target);

  void dispose();
}

/// Runs compute programs on the host GPU. A core that supports it moves the
/// work of its video chip there; the other cores ignore it.
abstract interface class ComputeSink {
  /// the GPU, for the GUI
  String get name;

  /// Whether a read and a run with `wait` wait for the GPU. False on the
  /// Web, where a core stops at a point where it can and awaits
  /// [ComputeProgram.fetching] instead.
  bool get waits;

  /// Compiles the [entryPoints] of [wgsl] with [bindings]. The parameter
  /// blocks of a run are [paramStride] bytes apart, for up to
  /// [maxDispatches] dispatches per run. Throws if the program cannot be
  /// created.
  ComputeProgram program(
      String wgsl, List<String> entryPoints, List<ComputeBinding> bindings,
      {required int paramStride, required int maxDispatches});
}
