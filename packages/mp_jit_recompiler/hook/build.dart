import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final os = input.config.code.targetOS;
    if (![OS.linux, OS.macOS, OS.windows, OS.android].contains(os)) return;
    await CBuilder.library(
      name: 'mp_jit_memory',
      assetName: 'src/native_memory.dart',
      sources: ['src/native_memory.c'],
    ).run(input: input, output: output);
  });
}
