import 'dart:io';

/// Writes [lines] to the file named by `MP_GPU_PROBE_OUT`, when it is set
/// and can be written, and ends the process. A Windows release build has no
/// console to log to.
void finishProbe(List<String> lines) {
  final out = Platform.environment['MP_GPU_PROBE_OUT'];
  try {
    if (out != null) File(out).writeAsStringSync('${lines.join('\n')}\n');
  } on FileSystemException catch (e) {
    stderr.writeln('MP_GPU_PROBE cannot write $out: $e');
  }
  exit(0);
}
