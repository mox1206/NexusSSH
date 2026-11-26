import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:nexus_ssh/src/update/app_update_models.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

typedef UpdateDownloadProgressCallback = void Function(
  int receivedBytes,
  int totalBytes,
);

/// Handles GitHub Releases `latest.json` lookup, SHA-256 verified downloads,
/// and platform-specific install handoff (Windows portable self-replace & Android APK).
class AppUpdateService {
  AppUpdateService({
    this.manifestUrl = AppUpdateConfig.defaultManifestUrl,
    HttpClient Function()? httpClientFactory,
    Future<Directory> Function()? tempDirProvider,
    MethodChannel? nativeChannel,
  }) : _httpClientFactory = httpClientFactory ?? HttpClient.new,
       _tempDirProvider = tempDirProvider ?? getTemporaryDirectory,
       _nativeChannel =
           nativeChannel ??
           const MethodChannel('dev.nexusssh.nexus_ssh/updater');

  final String manifestUrl;
  final HttpClient Function() _httpClientFactory;
  final Future<Directory> Function() _tempDirProvider;
  final MethodChannel _nativeChannel;

  static const Duration _connectTimeout = Duration(seconds: 15);
  static const Duration _requestTimeout = Duration(seconds: 25);

  /// Normalizes an optional mirror prefix and prepends it to GitHub URLs.
  /// Example: `https://gh-proxy.com/` + `https://github.com/a/b` -> `https://gh-proxy.com/https://github.com/a/b`.
  static String applyMirrorPrefix(String rawUrl, String mirrorPrefix) {
    final trimmedPrefix = mirrorPrefix.trim();
    if (trimmedPrefix.isEmpty) return rawUrl;
    final prefixUri = Uri.tryParse(trimmedPrefix);
    if (prefixUri == null ||
        (prefixUri.scheme != 'https' && prefixUri.scheme != 'http')) {
      return rawUrl;
    }
    final normalized = trimmedPrefix.endsWith('/')
        ? trimmedPrefix
        : '$trimmedPrefix/';
    return '$normalized$rawUrl';
  }

  /// Resolves the running application's version & build number.
  Future<AppVersionInfo> getCurrentVersion() async {
    if (!kIsWeb && Platform.isAndroid) {
      try {
        final raw = await _nativeChannel.invokeMapMethod<String, dynamic>(
          'getAppVersion',
        );
        if (raw != null) {
          final version = (raw['version'] as String? ?? '').trim();
          final buildNumber = (raw['buildNumber'] as num?)?.toInt() ?? 0;
          if (version.isNotEmpty) {
            return AppVersionInfo(
              version: version,
              buildNumber: buildNumber > 0
                  ? buildNumber
                  : AppUpdateConfig.fallbackBuildNumber,
            );
          }
        }
      } catch (_) {}
    }
    return const AppVersionInfo(
      version: AppUpdateConfig.fallbackVersion,
      buildNumber: AppUpdateConfig.fallbackBuildNumber,
    );
  }

  /// Whether the current platform supports automated in-app download & install handoff.
  bool get supportsInAppInstall =>
      !kIsWeb && (Platform.isWindows || Platform.isAndroid);

  /// Fetches and parses `latest.json` from GitHub Releases (or via optional mirror).
  Future<UpdateManifest> fetchLatestManifest({String mirrorPrefix = ''}) async {
    final targetUrl = applyMirrorPrefix(manifestUrl, mirrorPrefix);
    final uri = Uri.parse(targetUrl);
    final client = _httpClientFactory()..connectionTimeout = _connectTimeout;
    try {
      final request = await client.getUrl(uri).timeout(_requestTimeout);
      request.headers.set(HttpHeaders.userAgentHeader, 'NexusSSH-Updater/1.0');
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(_requestTimeout);

      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw HttpException(
          '检查更新失败（HTTP ${response.statusCode}）',
          uri: uri,
        );
      }

      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(_requestTimeout);
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('更新清单格式无效');
      }
      return UpdateManifest.fromJson(decoded);
    } finally {
      client.close(force: true);
    }
  }

  /// Picks the best matching artifact for the current OS / CPU architecture.
  Future<UpdateAsset?> selectAssetForCurrentPlatform(
    UpdateManifest manifest,
  ) async {
    if (kIsWeb) return null;
    if (Platform.isWindows) {
      return manifest.platforms['windows-x64'];
    }
    if (Platform.isLinux) {
      return manifest.platforms['linux-x64'];
    }
    if (Platform.isMacOS) {
      return manifest.platforms['macos-universal'];
    }
    if (Platform.isAndroid) {
      final abis = await _getAndroidSupportedAbis();
      for (final abi in abis) {
        final match = manifest.platforms['android-$abi'];
        if (match != null) return match;
      }
      return manifest.platforms['android-arm64-v8a'] ??
          manifest.platforms['android-armeabi-v7a'] ??
          manifest.platforms['android-x86_64'];
    }
    return null;
  }

  Future<List<String>> _getAndroidSupportedAbis() async {
    try {
      final raw = await _nativeChannel.invokeListMethod<String>(
        'getSupportedAbis',
      );
      if (raw != null && raw.isNotEmpty) {
        return raw;
      }
    } catch (_) {}
    return const ['arm64-v8a', 'armeabi-v7a', 'x86_64'];
  }

  /// Downloads [asset] to `<tempDir>/nexus_ssh_updates/<fileName>` while streaming
  /// progress and verifying its SHA-256 digest before returning the final path.
  Future<String> downloadAndVerifyAsset(
    UpdateAsset asset, {
    String mirrorPrefix = '',
    UpdateDownloadProgressCallback? onProgress,
    VoidCallback? onVerifying,
  }) async {
    final safeName = p.basename(asset.fileName);
    if (safeName.isEmpty || safeName == '.' || safeName == '..') {
      throw const FormatException('更新包文件名非法');
    }

    final baseTemp = await _tempDirProvider();
    final updateDir = Directory(p.join(baseTemp.path, 'nexus_ssh_updates'));
    if (!updateDir.existsSync()) {
      await updateDir.create(recursive: true);
    }

    final finalFile = File(p.join(updateDir.path, safeName));
    final partFile = File(p.join(updateDir.path, '$safeName.part'));

    // Reuse an already downloaded file if its SHA-256 matches exactly.
    if (finalFile.existsSync() && asset.sha256.isNotEmpty) {
      onVerifying?.call();
      final existingHash = await computeFileSha256(finalFile);
      if (existingHash == asset.sha256.toLowerCase()) {
        final existingSize = await finalFile.length();
        onProgress?.call(existingSize, existingSize);
        return finalFile.path;
      }
      await finalFile.delete();
    }

    if (partFile.existsSync()) {
      await partFile.delete();
    }

    final targetUrl = applyMirrorPrefix(asset.url, mirrorPrefix);
    final uri = Uri.parse(targetUrl);
    final client = _httpClientFactory()..connectionTimeout = _connectTimeout;
    IOSink? sink;

    try {
      final request = await client.getUrl(uri).timeout(_requestTimeout);
      request.headers.set(HttpHeaders.userAgentHeader, 'NexusSSH-Updater/1.0');
      final response = await request.close().timeout(_requestTimeout);

      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw HttpException(
          '下载更新包失败（HTTP ${response.statusCode}）',
          uri: uri,
        );
      }

      final totalBytes = response.contentLength > 0
          ? response.contentLength
          : asset.size;
      var receivedBytes = 0;

      final digestSink = _SingleDigestSink();
      final shaInput = sha256.startChunkedConversion(digestSink);
      sink = partFile.openWrite();

      var lastReportMs = 0;
      await for (final chunk in response) {
        sink.add(chunk);
        shaInput.add(chunk);
        receivedBytes += chunk.length;
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        if (nowMs - lastReportMs >= 80 ||
            (totalBytes > 0 && receivedBytes >= totalBytes)) {
          lastReportMs = nowMs;
          onProgress?.call(receivedBytes, totalBytes);
        }
      }

      await sink.flush();
      await sink.close();
      sink = null;
      shaInput.close();

      onVerifying?.call();
      final actualHash = digestSink.digest.toString().toLowerCase();
      final expectedHash = asset.sha256.trim().toLowerCase();
      if (expectedHash.isNotEmpty && actualHash != expectedHash) {
        if (partFile.existsSync()) {
          await partFile.delete();
        }
        throw StateError(
          '更新包 SHA-256 校验失败，已自动丢弃（预期 ${expectedHash.substring(0, 12)}...，实际 ${actualHash.substring(0, 12)}...）',
        );
      }

      if (finalFile.existsSync()) {
        await finalFile.delete();
      }
      await partFile.rename(finalFile.path);
      return finalFile.path;
    } catch (_) {
      try {
        await sink?.close();
      } catch (_) {}
      try {
        if (partFile.existsSync()) {
          await partFile.delete();
        }
      } catch (_) {}
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  /// Computes the lowercase hex SHA-256 digest of [file] using streaming chunks.
  static Future<String> computeFileSha256(File file) async {
    final digestSink = _SingleDigestSink();
    final shaInput = sha256.startChunkedConversion(digestSink);
    await for (final chunk in file.openRead()) {
      shaInput.add(chunk);
    }
    shaInput.close();
    return digestSink.digest.toString().toLowerCase();
  }

  /// Launches the Windows detached updater script that waits for the current
  /// `nexus_ssh.exe` PID to exit, extracts the verified ZIP into the app folder,
  /// and relaunches the new binary.
  Future<void> launchWindowsSelfUpdate({
    required String zipFilePath,
    required VoidCallback onRequestExit,
  }) async {
    if (kIsWeb || !Platform.isWindows) {
      throw UnsupportedError('Windows self-update is only supported on Windows');
    }
    final zipFile = File(zipFilePath);
    if (!zipFile.existsSync()) {
      throw StateError('未找到已下载的更新压缩包');
    }

    final exePath = Platform.resolvedExecutable;
    final installDir = File(exePath).parent.path;
    final exeName = p.basename(exePath);
    if (!exeName.toLowerCase().endsWith('.exe')) {
      throw StateError('当前运行路径不支持自动覆盖更新');
    }

    final scriptDir = zipFile.parent;
    final scriptFile = File(p.join(scriptDir.path, 'apply_nexus_update.ps1'));
    final stagingDir = p.join(
      scriptDir.path,
      'staging_${DateTime.now().millisecondsSinceEpoch}',
    );

    await scriptFile.writeAsString(
      buildWindowsUpdaterScript(
        targetPid: pid,
        zipPath: zipFile.path,
        stagingDir: stagingDir,
        installDir: installDir,
        exePath: exePath,
      ),
      encoding: utf8,
    );

    await Process.start(
      'powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        scriptFile.path,
      ],
      mode: ProcessStartMode.detached,
    );

    onRequestExit();
  }

  /// Generates the PowerShell self-update script for Windows portable releases.
  @visibleForTesting
  static String buildWindowsUpdaterScript({
    required int targetPid,
    required String zipPath,
    required String stagingDir,
    required String installDir,
    required String exePath,
  }) {
    String psQuote(String value) => "'${value.replaceAll("'", "''")}'";
    return '''
\$ErrorActionPreference = 'Stop'
\$targetPid = $targetPid
\$zipPath = ${psQuote(zipPath)}
\$stagingDir = ${psQuote(stagingDir)}
\$installDir = ${psQuote(installDir)}
\$exePath = ${psQuote(exePath)}

# Wait up to 30 seconds for Nexus SSH to exit cleanly
for (\$i = 0; \$i -lt 120; \$i++) {
  if (-not (Get-Process -Id \$targetPid -ErrorAction SilentlyContinue)) {
    break
  }
  Start-Sleep -Milliseconds 250
}

try {
  if (Test-Path \$stagingDir) {
    Remove-Item -Recurse -Force \$stagingDir
  }
  New-Item -ItemType Directory -Force -Path \$stagingDir | Out-Null
  Expand-Archive -Path \$zipPath -DestinationPath \$stagingDir -Force

  # Retry copy briefly in case Windows AV / Defender holds a DLL handle
  \$copied = \$false
  for (\$attempt = 0; \$attempt -lt 10; \$attempt++) {
    try {
      Copy-Item -Path (Join-Path \$stagingDir '*') -Destination \$installDir -Recurse -Force
      \$copied = \$true
      break
    } catch {
      Start-Sleep -Milliseconds 400
    }
  }
  if (-not \$copied) {
    throw 'Failed to copy updated files into install directory.'
  }

  Start-Process -FilePath \$exePath -WorkingDirectory \$installDir
} finally {
  Remove-Item -Recurse -Force \$stagingDir -ErrorAction SilentlyContinue
  Remove-Item -Force \$zipPath -ErrorAction SilentlyContinue
}
''';
  }

  /// Hands off a verified Android APK file to the system package installer.
  /// Returns `'launched'` or `'permission_required'`.
  Future<String> launchAndroidApkInstall(String apkFilePath) async {
    if (kIsWeb || !Platform.isAndroid) {
      throw UnsupportedError('APK install is only supported on Android');
    }
    final result = await _nativeChannel.invokeMethod<String>('installApk', {
      'path': apkFilePath,
    });
    return result ?? 'launched';
  }
}

class _SingleDigestSink implements Sink<Digest> {
  Digest? _digest;

  Digest get digest => _digest!;

  @override
  void add(Digest data) {
    _digest = data;
  }

  @override
  void close() {}
}
