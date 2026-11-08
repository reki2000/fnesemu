import 'package:fnesemu_core/app_api.dart';

/// Flutter GPU is not available on this platform: [create] returns null.
abstract final class GpuFrameSink implements RenderFrameSink {
  static const name = 'Flutter GPU';

  static Future<GpuFrameSink?> create() async => null;
}
