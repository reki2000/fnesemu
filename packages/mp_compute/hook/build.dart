// Builds the compute shim and links it with a pinned wgpu-native release,
// which this hook downloads and checks against its SHA-256.
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

const _version = 'v29.0.1.1';

/// The release archive of a target and its SHA-256, or null.
(String, String)? _release(CodeConfig code) => switch ((
  code.targetOS,
  code.targetArchitecture,
)) {
  (OS.linux, Architecture.x64) => (
    'linux-x86_64',
    '95a4d90c071005a98d03eab348beaa6b07e16eb00d1dcdb9f8348f75eb97ec5a',
  ),
  (OS.linux, Architecture.arm64) => (
    'linux-aarch64',
    '015fcdf1dbae82e614a783cc38017e5399ae0927a889fe9b69c9b664bc61b47a',
  ),
  (OS.windows, Architecture.x64) => (
    'windows-x86_64-msvc',
    '7e67d7445c42aeb85e30f88930fd8d7d83ee769e3390aeb1ada75ebf3cf78132',
  ),
  (OS.windows, Architecture.arm64) => (
    'windows-aarch64-msvc',
    '4a876421a8c1e5fe72f849b3722214280fe485cb1c56f77f8b0c82414be5b29f',
  ),
  (OS.macOS, Architecture.arm64) => (
    'macos-aarch64',
    'a5797a37b1adf720bcd5dcffb291edbbd5b7b14be0a3874c28e6393a655a7a3e',
  ),
  (OS.macOS, Architecture.x64) => (
    'macos-x86_64',
    '8e2f7378548ddd0e2cf21e7d864dda46e953f0af724855a33778b85ead206d41',
  ),
  (OS.iOS, Architecture.arm64) when code.iOS.targetSdk == IOSSdk.iPhoneOS => (
    'ios-aarch64',
    'e36c9913b9e5095a530fa9121c50b16a4e3dd020e1eebf601f2f47ce24d56941',
  ),
  (OS.iOS, Architecture.arm64) => (
    'ios-aarch64-simulator',
    '750e706765bef3744313745194774d095c916fc21d2a0e7d4d7b0bc4d0c92789',
  ),
  (OS.iOS, Architecture.x64) => (
    'ios-x86_64-simulator',
    '94f67e1b268e8dd31b8e59b32f211ac469f09ed7950fceee52bd84f0623da3d9',
  ),
  (OS.android, Architecture.arm64) => (
    'android-aarch64',
    '721741f1b05a20c1738166bedf7a5efb2ba4b382da689526d3fc33de22bdd573',
  ),
  (OS.android, Architecture.arm) => (
    'android-armv7',
    'f9d76c77b3fda3f7121476884eb16ec067f7dada83276298a3cc8bf6a8403d60',
  ),
  (OS.android, Architecture.x64) => (
    'android-x86_64',
    'ef16fc0644bf0e308a39ac4516742da8e22d8c201d3a542cc5baf533d272c491',
  ),
  (OS.android, Architecture.ia32) => (
    'android-i686',
    '593b94875bc4fcc1506ea0b6714dd12b96b7c852921caa63f45eb61517793312',
  ),
  _ => null,
};

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final code = input.config.code;
    final release = _release(code);
    // other targets get no shim, and the package reports compute as
    // unavailable
    if (release == null) return;
    final (target, sha256Hex) = release;
    final archiveName = 'wgpu-$target-release.zip';
    final os = code.targetOS;
    final libraryName = os == OS.windows
        ? 'lib/wgpu_native.lib'
        : 'lib/libwgpu_native.a';

    // the shared directory serves all targets
    final shared = input.outputDirectoryShared.resolve(
      'wgpu-$_version-$target/',
    );
    final staticLibrary = File.fromUri(shared.resolve(libraryName));
    if (!staticLibrary.existsSync()) {
      final bytes = await _download(
        Uri.parse(
          'https://github.com/gfx-rs/wgpu-native/releases/download/'
          '$_version/$archiveName',
        ),
      );
      final digest = sha256.convert(bytes).toString();
      if (digest != sha256Hex) {
        throw StateError('$archiveName: SHA-256 $digest, expected $sha256Hex');
      }
      final archive = ZipDecoder().decodeBytes(bytes);
      for (final file in archive) {
        if (file.isFile && file.name.startsWith('include/')) {
          _extract(shared, file);
        }
      }
      // the library last, so that its presence means a complete extraction
      _extract(shared, archive.findFile(libraryName)!);
    }

    await CBuilder.library(
      name: 'mp_compute',
      assetName: 'src/native.dart',
      sources: ['src/mp_compute.c'],
      includes: [shared.resolve('include/').toFilePath()],
      libraries: ['wgpu_native', ..._systemLibraries(os)],
      libraryDirectories: [shared.resolve('lib/').toFilePath()],
      frameworks: [
        'Foundation',
        'Metal',
        'QuartzCore',
        if (os == OS.macOS) 'IOKit',
      ],
      flags: switch (os) {
        // the release links the C runtime as a DLL
        OS.windows => ['/MD'],
        // export only the shim, not the symbols of the release
        OS.macOS || OS.iOS => ['-Wl,-exported_symbols_list,${_exports(input)}'],
        _ => ['-Wl,--exclude-libs,ALL'],
      },
    ).run(input: input, output: output);
  });
}

/// The system libraries that the release links against.
List<String> _systemLibraries(OS os) => switch (os) {
  OS.windows => [
    'advapi32',
    'bcrypt',
    'd3d12',
    'd3dcompiler',
    'dxgi',
    'kernel32',
    'ntdll',
    'ole32',
    'oleaut32',
    'opengl32',
    'propsys',
    'runtimeobject',
    'synchronization',
    'user32',
    'userenv',
    'ws2_32',
  ],
  OS.macOS || OS.iOS => ['objc'],
  OS.android => ['log', 'android', 'dl', 'm'],
  _ => ['m', 'dl', 'pthread'],
};

/// A linker file that lists the exported shim functions.
String _exports(BuildInput input) {
  final source = File.fromUri(
    input.packageRoot.resolve('src/mp_compute.c'),
  ).readAsStringSync();
  final names = RegExp(
    r'^EXPORT [^(]*?\b(mpc_\w+)\(',
    multiLine: true,
  ).allMatches(source).map((m) => '_${m[1]}');
  final file = File.fromUri(input.outputDirectory.resolve('exports.txt'))
    ..writeAsStringSync('${names.join('\n')}\n');
  return file.path;
}

void _extract(Uri directory, ArchiveFile file) {
  File.fromUri(directory.resolve(file.name))
    ..createSync(recursive: true)
    ..writeAsBytesSync(file.content as List<int>);
}

Future<List<int>> _download(Uri uri) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri);
    final response = await request.close();
    if (response.statusCode != 200) {
      throw HttpException('status ${response.statusCode}', uri: uri);
    }
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
    }
    return bytes;
  } finally {
    client.close();
  }
}
