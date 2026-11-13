import 'package:fnesemu_core/app_api.dart';

/// The Web has no compute GPU for the cores yet.
List<String> computeAdapters() => const [];

/// The Web has no compute GPU for the cores yet.
ComputeSink? openComputeSink(
    {String adapter = '', void Function(String reason)? onError}) {
  onError?.call('not available on the Web');
  return null;
}

void closeComputeSink(ComputeSink sink) {}
