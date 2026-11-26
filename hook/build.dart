import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:path/path.dart' as path;

const _assetName = 'src/rust/nexus_ffi.dart';
const _crateName = 'nexus_ssh_core';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) {
      return;
    }

    final codeConfig = input.config.code;
    final targetTriple = _resolveRustTargetTriple(codeConfig);
    final linkMode = _resolveLinkMode(codeConfig.linkModePreference);

    final packageRoot = path.fromUri(input.packageRoot);
    final crateDir = path.join(packageRoot, 'rust');
    final manifestPath = path.join(crateDir, 'Cargo.toml');
    final targetDir = path.join(crateDir, 'target');

    await _ensureRustTargetInstalled(targetTriple, crateDir);

    final env = <String, String>{
      ...Platform.environment,
      ..._platformBuildEnvironment(codeConfig, targetTriple),
    };

    final cargoResult = await Process.run(
      'cargo',
      [
        'build',
        '--release',
        '--manifest-path',
        manifestPath,
        '--target',
        targetTriple,
        '--target-dir',
        targetDir,
      ],
      workingDirectory: crateDir,
      environment: env,
    );

    if (cargoResult.exitCode != 0) {
      stderr.writeln(cargoResult.stdout);
      stderr.writeln(cargoResult.stderr);
      throw ProcessException(
        'cargo',
        ['build', '--release', '--target', targetTriple],
        'Cargo build failed with exit code ${cargoResult.exitCode}',
        cargoResult.exitCode,
      );
    }

    final binaryFileName = codeConfig.targetOS.libraryFileName(
      _crateName,
      linkMode,
    );
    final compiledLibPath = path.join(
      targetDir,
      targetTriple,
      'release',
      binaryFileName,
    );

    if (!File(compiledLibPath).existsSync()) {
      throw StateError(
        'Expected compiled Rust library not found at: $compiledLibPath',
      );
    }

    // Copy artifact into hook's isolated output directory as recommended by hooks
    final outLibPath = path.join(
      path.fromUri(input.outputDirectory),
      binaryFileName,
    );
    await File(compiledLibPath).copy(outLibPath);

    output.dependencies.addAll([
      path.toUri(manifestPath),
      for (final entity in Directory(path.join(crateDir, 'src'))
          .listSync(recursive: true)
          .whereType<File>())
        path.toUri(entity.path),
    ]);

    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: _assetName,
        linkMode: linkMode,
        file: path.toUri(outLibPath),
      ),
    );
  });
}

String _resolveRustTargetTriple(CodeConfig config) {
  return switch ((config.targetOS, config.targetArchitecture)) {
    // Android
    (OS.android, Architecture.arm64) => 'aarch64-linux-android',
    (OS.android, Architecture.arm) => 'armv7-linux-androideabi',
    (OS.android, Architecture.x64) => 'x86_64-linux-android',
    (OS.android, Architecture.ia32) => 'i686-linux-android',

    // iOS
    (OS.iOS, Architecture.arm64)
        when config.iOS.targetSdk == IOSSdk.iPhoneSimulator =>
      'aarch64-apple-ios-sim',
    (OS.iOS, Architecture.arm64) => 'aarch64-apple-ios',
    (OS.iOS, Architecture.x64) => 'x86_64-apple-ios',

    // Windows
    (OS.windows, Architecture.x64) => 'x86_64-pc-windows-msvc',
    (OS.windows, Architecture.arm64) => 'aarch64-pc-windows-msvc',

    // Linux
    (OS.linux, Architecture.x64) => 'x86_64-unknown-linux-gnu',
    (OS.linux, Architecture.arm64) => 'aarch64-unknown-linux-gnu',

    // macOS
    (OS.macOS, Architecture.arm64) => 'aarch64-apple-darwin',
    (OS.macOS, Architecture.x64) => 'x86_64-apple-darwin',

    (final os, final arch) => throw UnsupportedError(
      'Unsupported Rust target for OS=$os, Arch=$arch',
    ),
  };
}

LinkMode _resolveLinkMode(LinkModePreference preference) {
  return switch (preference) {
    LinkModePreference.static ||
    LinkModePreference.preferStatic => StaticLinking(),
    _ => DynamicLoadingBundled(),
  };
}

Future<void> _ensureRustTargetInstalled(
  String targetTriple,
  String workingDir,
) async {
  final listResult = await Process.run(
    'rustup',
    ['target', 'list', '--installed'],
    workingDirectory: workingDir,
  );
  if (listResult.exitCode != 0) {
    return;
  }
  final installed = (listResult.stdout as String)
      .split('\n')
      .map((s) => s.trim())
      .toSet();
  if (!installed.contains(targetTriple)) {
    final addResult = await Process.run(
      'rustup',
      ['target', 'add', targetTriple],
      workingDirectory: workingDir,
    );
    if (addResult.exitCode != 0) {
      stderr.writeln(addResult.stderr);
    }
  }
}

Map<String, String> _platformBuildEnvironment(
  CodeConfig codeConfig,
  String targetTriple,
) {
  final env = <String, String>{};

  // Clean Xcode PATH overrides that can interfere with host build scripts on macOS
  if (Platform.isMacOS && Platform.environment['PATH'] != null) {
    env['PATH'] = Platform.environment['PATH']!
        .split(':')
        .where((segment) => !segment.contains('Contents/Developer/'))
        .join(':');
  }

  if (codeConfig.targetOS == OS.android) {
    final cCompiler = codeConfig.cCompiler;
    if (cCompiler == null) {
      throw StateError(
        'Android CCompilerConfig is required to link Rust for $targetTriple',
      );
    }
    final compilerBinDir = path.dirname(path.fromUri(cCompiler.compiler));
    final ndkTriple = switch (targetTriple) {
      'armv7-linux-androideabi' => 'armv7a-linux-androideabi',
      _ => targetTriple,
    };
    final apiLevel = codeConfig.android.targetNdkApi;
    final clangExt = Platform.isWindows ? '.cmd' : '';
    final exeExt = Platform.isWindows ? '.exe' : '';

    final clangPath = path.join(
      compilerBinDir,
      '$ndkTriple$apiLevel-clang$clangExt',
    );
    final clangPpPath = path.join(
      compilerBinDir,
      '$ndkTriple$apiLevel-clang++$clangExt',
    );
    final ranlibPath = path.join(compilerBinDir, 'llvm-ranlib$exeExt');
    final envTriple = targetTriple.replaceAll('-', '_');
    final upperTriple = envTriple.toUpperCase();

    env['AR_$envTriple'] = path.fromUri(cCompiler.archiver);
    env['CC_$envTriple'] = clangPath;
    env['CXX_$envTriple'] = clangPpPath;
    env['RANLIB_$envTriple'] = ranlibPath;
    env['CARGO_TARGET_${upperTriple}_LINKER'] = clangPath;

    // Support 16 KB page alignment on 64-bit Android targets (Android 15+ Play requirement)
    if (targetTriple == 'aarch64-linux-android' ||
        targetTriple == 'x86_64-linux-android') {
      final flagKey = 'CARGO_TARGET_${upperTriple}_RUSTFLAGS';
      if (!Platform.environment.containsKey(flagKey) &&
          !Platform.environment.containsKey('RUSTFLAGS')) {
        env[flagKey] = '-C link-arg=-Wl,-z,max-page-size=16384';
      }
    }
  }

  return env;
}
