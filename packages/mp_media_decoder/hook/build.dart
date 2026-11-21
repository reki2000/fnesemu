// Bundles the native code of the package:
//
// - mmd_libav, the ATRAC-only LGPL libavcodec of
//   tool/build_libav_atrac.sh, downloaded from the GitHub Release that the
//   libav-atrac workflow made and checked against the SHA-256 below. The
//   user-defines of this package change it: `libav_file: <path>` bundles a
//   library built with the script instead, and `bundle_libav: false`
//   builds without one.
// - the VideoToolbox shim (src/videotoolbox.c) for macOS and iOS. The
//   other platforms decode H.264 without native code of this package.
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

/// the release that holds the libraries
const _release =
    'https://github.com/reki2000/fnesemu/releases/download/libav-atrac-7.1.1-1';

/// the SHA-256 of the library of each target of the build script
const _sha256 = <String, String>{};

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final code = input.config.code;
    if (input.userDefines['bundle_libav'] != false) {
      await _bundleLibav(input, output, code);
    }
    final os = code.targetOS;
    if (os != OS.macOS && os != OS.iOS) return;
    await CBuilder.library(
      name: 'mp_media_decoder',
      assetName: 'src/videotoolbox.dart',
      sources: ['src/videotoolbox.c'],
      frameworks: ['CoreFoundation', 'CoreMedia', 'CoreVideo', 'VideoToolbox'],
    ).run(input: input, output: output);
  });
}

/// The target of the build script for [code]; null when there is no
/// library for it.
String? _target(CodeConfig code) {
  final arch = switch (code.targetArchitecture) {
    Architecture.x64 => 'x64',
    Architecture.arm64 => 'arm64',
    Architecture.arm => 'arm',
    _ => null,
  };
  if (arch == null) return null;
  final os = switch (code.targetOS) {
    OS.linux => 'linux',
    OS.android => 'android',
    OS.windows => 'windows',
    OS.macOS => 'macos',
    OS.iOS =>
      code.iOS.targetSdk == IOSSdk.iPhoneSimulator ? 'iossim' : 'ios',
    _ => null,
  };
  return os == null ? null : '$os-$arch';
}

Future<void> _bundleLibav(
    BuildInput input, BuildOutputBuilder output, CodeConfig code) async {
  final os = code.targetOS;
  final fileName = os.dylibFileName('mmd_libav');
  if (input.userDefines.path('libav_file') case final local?) {
    // under the file name of the platform, which Android requires
    output.dependencies.add(local);
    final file = File.fromUri(input.outputDirectory.resolve(fileName));
    File.fromUri(local).copySync(file.path);
    _add(input, output, file.uri);
    return;
  }
  final target = _target(code);
  final sha256 = _sha256[target];
  if (target == null || sha256 == null) return;
  final ext = switch (os) {
    OS.windows => 'dll',
    OS.linux || OS.android => 'so',
    _ => 'dylib',
  };
  // The shared directory keeps the download across builds; the hash in the
  // path tells the versions apart.
  final dir = Directory.fromUri(
      input.outputDirectoryShared.resolve('libav/${sha256.substring(0, 16)}/'));
  final file = File.fromUri(dir.uri.resolve(fileName));
  if (!file.existsSync() || !_matches(file.readAsBytesSync(), sha256)) {
    final bytes = await _download(Uri.parse('$_release/mmd_libav-$target.$ext'));
    if (!_matches(bytes, sha256)) {
      throw StateError('mmd_libav-$target.$ext does not match its SHA-256');
    }
    dir.createSync(recursive: true);
    final part = File('${file.path}.part')..writeAsBytesSync(bytes);
    part.renameSync(file.path);
  }
  _add(input, output, file.uri);
}

void _add(BuildInput input, BuildOutputBuilder output, Uri file) =>
    output.assets.code.add(CodeAsset(
      package: input.packageName,
      name: 'src/libav_bundled.dart',
      linkMode: DynamicLoadingBundled(),
      file: file,
    ));

bool _matches(List<int> bytes, String hash) =>
    sha256.convert(bytes).toString() == hash;

Future<List<int>> _download(Uri uri) async {
  final client = HttpClient();
  try {
    final response = await (await client.getUrl(uri)).close();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('HTTP ${response.statusCode}', uri: uri);
    }
    return [for (final chunk in await response.toList()) ...chunk];
  } finally {
    client.close();
  }
}
