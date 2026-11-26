import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_ssh/src/models/ssh_models.dart';
import 'package:nexus_ssh/src/rust/ssh_bridge.dart';
import 'package:nexus_ssh/src/state/app_controller.dart';
import 'package:nexus_ssh/src/ui/app_theme.dart';
import 'package:nexus_ssh/src/ui/app_update_dialog.dart';
import 'package:nexus_ssh/src/update/app_update_models.dart';
import 'package:nexus_ssh/src/update/app_update_service.dart';

class _StubSshBackend implements SshBackend {
  @override
  Stream<SessionOutputChunk> get outputStream => const Stream.empty();

  @override
  Stream<SessionStatusEvent> get statusStream => const Stream.empty();

  @override
  Future<List<HostProfile>> init(String dataDir) async => const [];

  @override
  Future<List<SnippetItem>> listSnippets() async => const [];

  @override
  Future<WebDavConfig> getWebDavConfig() async => const WebDavConfig();

  @override
  Future<AppLockConfig> getAppLockConfig() async => const AppLockConfig();

  @override
  Future<List<LocalShellOption>> listLocalShells() async => const [];

  @override
  void prepareShutdown() {}

  @override
  void dispose() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _DirectHttpOverrides extends HttpOverrides {}

class _FakeUpdateService extends AppUpdateService {
  _FakeUpdateService(this.manifest);

  final UpdateManifest manifest;

  @override
  Future<UpdateManifest> fetchLatestManifest({String mirrorPrefix = ''}) async {
    return manifest;
  }
}

void main() {
  test('AppVersionInfo fallback matches pubspec.yaml version', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(
      r'^\s*version:\s*([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?)\+([0-9]+)\s*$',
      multiLine: true,
    ).firstMatch(pubspec);
    expect(match, isNotNull);
    expect(AppUpdateConfig.fallbackVersion, equals(match!.group(1)));
    expect(
      AppUpdateConfig.fallbackBuildNumber,
      equals(int.parse(match.group(2)!)),
    );
  });

  test('AppVersionInfo compares SemVer, prereleases, and build numbers', () {
    const v100 = AppVersionInfo(version: '1.0.0', buildNumber: 1);
    const v100b2 = AppVersionInfo(version: '1.0.0', buildNumber: 2);
    const v101Beta1 = AppVersionInfo(version: '1.0.1-beta.1', buildNumber: 2);
    const v101Beta2 = AppVersionInfo(version: '1.0.1-beta.2', buildNumber: 3);
    const v101 = AppVersionInfo(version: '1.0.1', buildNumber: 1);
    const v110 = AppVersionInfo(version: '1.1.0', buildNumber: 1);

    expect(v100b2.isNewerThan(v100), isTrue);
    expect(v100.isNewerThan(v100b2), isFalse);
    expect(v101Beta1.isNewerThan(v100b2), isTrue);
    expect(v101Beta2.isNewerThan(v101Beta1), isTrue);
    expect(v101.isNewerThan(v101Beta2), isTrue);
    expect(v110.isNewerThan(v101), isTrue);
    expect(v100.isNewerThan(v100), isFalse);
  });

  test('AppUpdateService.applyMirrorPrefix normalizes valid prefixes only', () {
    const raw =
        'https://github.com/mox1206/NexusSSH/releases/latest/download/latest.json';
    expect(AppUpdateService.applyMirrorPrefix(raw, ''), equals(raw));
    expect(
      AppUpdateService.applyMirrorPrefix(raw, 'https://mirror.example.com'),
      equals('https://mirror.example.com/$raw'),
    );
    expect(
      AppUpdateService.applyMirrorPrefix(raw, 'https://mirror.example.com/'),
      equals('https://mirror.example.com/$raw'),
    );
    expect(
      AppUpdateService.applyMirrorPrefix(raw, 'ftp://invalid.example.com'),
      equals(raw),
    );
  });

  test('buildWindowsUpdaterScript escapes quotes and targets PID cleanly', () {
    final script = AppUpdateService.buildWindowsUpdaterScript(
      targetPid: 4321,
      zipPath: r"C:\Temp\it's\nexus.zip",
      stagingDir: r'C:\Temp\staging',
      installDir: r'D:\Software\NexusSSH',
      exePath: r'D:\Software\NexusSSH\nexus_ssh.exe',
    );
    expect(script, contains(r'$targetPid = 4321'));
    expect(script, contains(r"'C:\Temp\it''s\nexus.zip'"));
    expect(script, contains('Expand-Archive'));
    expect(script, contains('robocopy.exe'));
    expect(script, contains('Start-Process'));
    expect(
      AppUpdateService.buildWindowsVbsLauncher(),
      contains('WScript.Shell'),
    );
  });

  test(
    'AppUpdateService fetches manifest, verifies SHA-256, and rejects tampered downloads',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final tempDir = await Directory.systemTemp.createTemp('nexus_upd_test_');
        final payloadBytes = utf8.encode(
          'nexus-ssh-release-binary-payload-v1.2.0',
        );
        final validSha = sha256.convert(payloadBytes).toString();
        var tamperDownload = false;

        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final baseUrl = 'http://127.0.0.1:${server.port}';

        server.listen((HttpRequest req) async {
          if (req.uri.path == '/latest.json') {
            req.response.headers.contentType = ContentType.json;
            req.response.write(
              jsonEncode({
                'schemaVersion': 1,
                'version': '1.2.0',
                'buildNumber': 5,
                'tag': 'v1.2.0',
                'publishedAt': '2026-11-26T12:00:00Z',
                'releaseUrl':
                    'https://github.com/mox1206/NexusSSH/releases/tag/v1.2.0',
                'notes': '- Auto update support\n- Faster SFTP',
                'platforms': {
                  'windows-x64': {
                    'fileName': 'nexus_ssh-1.2.0-windows-x64.zip',
                    'url': '$baseUrl/nexus_ssh-1.2.0-windows-x64.zip',
                    'sha256': validSha,
                    'size': payloadBytes.length,
                    'kind': 'zip',
                  },
                  'linux-x64': {
                    'fileName': 'nexus_ssh-1.2.0-linux-x64.tar.gz',
                    'url': '$baseUrl/nexus_ssh-1.2.0-linux-x64.tar.gz',
                    'sha256': validSha,
                    'size': payloadBytes.length,
                    'kind': 'tar.gz',
                  },
                  'macos-universal': {
                    'fileName': 'nexus_ssh-1.2.0-macos-universal.zip',
                    'url': '$baseUrl/nexus_ssh-1.2.0-macos-universal.zip',
                    'sha256': validSha,
                    'size': payloadBytes.length,
                    'kind': 'zip',
                  },
                },
              }),
            );
            await req.response.close();
            return;
          }
          if (req.uri.path.endsWith('.zip') ||
              req.uri.path.endsWith('.tar.gz')) {
            final body = tamperDownload
                ? utf8.encode('tampered-malicious-bytes')
                : payloadBytes;
            req.response.headers.contentLength = body.length;
            req.response.add(body);
            await req.response.close();
            return;
          }
          req.response.statusCode = HttpStatus.notFound;
          await req.response.close();
        });

        try {
          final service = AppUpdateService(
            manifestUrl: '$baseUrl/latest.json',
            tempDirProvider: () async => tempDir,
          );

          final manifest = await service.fetchLatestManifest();
          expect(manifest.version, equals('1.2.0'));
          expect(manifest.buildNumber, equals(5));
          expect(manifest.platforms.length, equals(3));

          final asset = await service.selectAssetForCurrentPlatform(manifest);
          expect(asset, isNotNull);

          // 1. Tampered payload must be rejected and cleaned up
          tamperDownload = true;
          await expectLater(
            service.downloadAndVerifyAsset(asset!),
            throwsA(isA<StateError>()),
          );

          // 2. Valid payload downloads, verifies SHA-256, and persists in cache dir
          tamperDownload = false;
          var verifiedCalled = false;
          final savedPath = await service.downloadAndVerifyAsset(
            asset,
            onVerifying: () => verifiedCalled = true,
          );
          expect(verifiedCalled, isTrue);
          expect(File(savedPath).existsSync(), isTrue);
          expect(await File(savedPath).readAsBytes(), equals(payloadBytes));
        } finally {
          await server.close(force: true);
          if (tempDir.existsSync()) {
            await tempDir.delete(recursive: true);
          }
        }
      }, _DirectHttpOverrides());
    },
  );

  testWidgets(
    'AppUpdateDialog displays release notes, persists ignored version and mirror prefix',
    (tester) async {
      final tempDir = Directory.systemTemp.createTempSync('nexus_upd_ui_');
      final payloadBytes = utf8.encode('demo-zip');
      final validSha = sha256.convert(payloadBytes).toString();
      final fakeManifest = UpdateManifest.fromJson({
        'schemaVersion': 1,
        'version': '9.9.9',
        'buildNumber': 99,
        'tag': 'v9.9.9',
        'publishedAt': '2026-11-26T12:00:00Z',
        'releaseUrl': 'https://github.com/mox1206/NexusSSH/releases/tag/v9.9.9',
        'notes': '- Added cross-platform auto updater',
        'platforms': {
          'windows-x64': {
            'fileName': 'nexus_ssh-9.9.9-windows-x64.zip',
            'url': 'https://example.com/nexus.zip',
            'sha256': validSha,
            'size': payloadBytes.length,
            'kind': 'zip',
          },
          'linux-x64': {
            'fileName': 'nexus_ssh-9.9.9-linux-x64.tar.gz',
            'url': 'https://example.com/nexus.tar.gz',
            'sha256': validSha,
            'size': payloadBytes.length,
            'kind': 'tar.gz',
          },
          'macos-universal': {
            'fileName': 'nexus_ssh-9.9.9-macos-universal.zip',
            'url': 'https://example.com/nexus-mac.zip',
            'sha256': validSha,
            'size': payloadBytes.length,
            'kind': 'zip',
          },
        },
      });

      final controller = AppController(
        backend: _StubSshBackend(),
        updateService: _FakeUpdateService(fakeManifest),
      );
      await controller.initialize(tempDir.path);

      try {
        await controller.checkForUpdates();
        expect(controller.hasUnignoredUpdate, isTrue);

        await tester.pumpWidget(
          MaterialApp(
            theme: NexusTheme.dark(),
            home: Scaffold(body: AppUpdateDialog(controller: controller)),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('v9.9.9'), findsOneWidget);
        expect(
          find.textContaining('Added cross-platform auto updater'),
          findsOneWidget,
        );

        // Save mirror prefix and verify persistence
        controller.setUpdateMirrorPrefix('https://mirror.example.com/');
        controller.ignoreAvailableUpdate();
        expect(controller.hasUnignoredUpdate, isFalse);

        // Re-initialize a fresh controller on same dataDir to verify persistence
        final reloaded = AppController(backend: _StubSshBackend());
        await reloaded.initialize(tempDir.path);
        expect(reloaded.updateState.ignoredVersion, equals('9.9.9'));
        expect(
          reloaded.updateState.mirrorPrefix,
          equals('https://mirror.example.com/'),
        );
        reloaded.dispose();
      } finally {
        controller.dispose();
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      }
    },
  );
}
