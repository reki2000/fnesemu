/// A development stop, not an emulated SH-4 exception.
class DcUnsupported implements Exception {
  const DcUnsupported(this.message);

  final String message;

  @override
  String toString() => 'DC: $message';
}

/// An architectural CPU exception, including faults detected by the MMU.
class DcCpuException implements Exception {
  const DcCpuException(this.event,
      {this.completed = false,
      this.address,
      this.trap,
      this.vector = 0x100,
      this.reset = false});
  final int event, vector;
  final bool completed, reset;
  final int? address, trap;
}
