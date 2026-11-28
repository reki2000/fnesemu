/// How a program binds a buffer.
enum ComputeBindingKind {
  /// `var<storage, read_write>`
  storage,

  /// `var<storage, read>`
  readOnlyStorage,

  /// a `var<uniform>` block per dispatch, bound with a dynamic offset; at
  /// most one binding of a program
  params,
}

/// A buffer of a program at the binding of its index. For
/// [ComputeBindingKind.params], [bytes] is the size of the block that a
/// dispatch sees.
class ComputeBinding {
  const ComputeBinding(this.kind, this.bytes);

  final ComputeBindingKind kind;
  final int bytes;
}

class ComputeException implements Exception {
  ComputeException(this.message);

  final String message;

  @override
  String toString() => 'ComputeException: $message';
}
