import 'gpu.dart';

/// No GPU on this platform.
Future<GpuDevice?> createDevice() async => null;
