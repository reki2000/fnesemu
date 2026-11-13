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

  /// Waits for the program and reads [target].length words at [byteOffset]
  /// of [binding].
  void read(int binding, int byteOffset, Uint32List target);

  void dispose();
}

/// Runs compute programs on the host GPU. A core that supports it moves the
/// work of its video chip there; the other cores ignore it.
abstract interface class ComputeSink {
  /// the GPU, for the GUI
  String get name;

  /// Compiles the [entryPoints] of [wgsl] with [bindings]. The parameter
  /// blocks of a run are [paramStride] bytes apart, for up to
  /// [maxDispatches] dispatches per run. Throws if the program cannot be
  /// created.
  ComputeProgram program(
      String wgsl, List<String> entryPoints, List<ComputeBinding> bindings,
      {required int paramStride, required int maxDispatches});
}
