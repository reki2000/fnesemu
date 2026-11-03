// One workload entry of tool/bench.dart.
//
// The run factory performs one measured run and returns the checksum function and the count of operations it performed. The harness calls the checksum function after it stops the timer, so work a workload defers to the checksum, such as hashing a framebuffer, stays outside the measured time.
typedef BenchWorkload = ({
  (int Function(), int) Function() run,
  String unit,
});
