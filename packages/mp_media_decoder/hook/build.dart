// Builds the VideoToolbox shim (src/videotoolbox.c) for macOS and iOS.
// The other platforms decode without native code of this package.
import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final os = input.config.code.targetOS;
    if (os != OS.macOS && os != OS.iOS) return;
    await CBuilder.library(
      name: 'mp_media_decoder',
      assetName: 'src/videotoolbox.dart',
      sources: ['src/videotoolbox.c'],
      frameworks: ['CoreFoundation', 'CoreMedia', 'CoreVideo', 'VideoToolbox'],
    ).run(input: input, output: output);
  });
}
