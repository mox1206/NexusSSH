import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_ssh/src/models/ssh_models.dart';
import 'package:nexus_ssh/src/rust/ssh_bridge.dart';
import 'package:nexus_ssh/src/state/app_controller.dart';

void main() {
  test(
    'AppController + Rust FFI roundtrips encrypted host store, snippets, and quick-connect parser',
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      final tempDir = await Directory.systemTemp.createTemp('nexus_ffi_test_');
      final backend = RustSshBackend();
      final controller = AppController(backend: backend);

      try {
        await controller.initialize(tempDir.path);
        expect(controller.initialized, isTrue);
        expect(controller.allHosts, isEmpty);
        expect(controller.snippets, isNotEmpty);

        // Save host and verify secret is encrypted on disk & redacted across FFI
        final saved = await controller.saveHost(
          const HostProfile(
            name: 'Demo Server',
            host: '192.0.2.10',
            port: 2222,
            username: 'ops',
            password: 'demo-secret-password',
          ),
        );
        expect(saved.id, isNotEmpty);
        expect(saved.password, isEmpty);
        expect(saved.hasPassword, isTrue);
        expect(controller.allHosts.length, equals(1));
        expect(controller.allHosts.first.password, isEmpty);
        expect(controller.allHosts.first.hasStoredPassword, isTrue);

        // Editing host metadata with blank password keeps stored secret intact
        final renamed = await controller.saveHost(
          saved.copyWith(name: 'Demo Server Updated', password: ''),
        );
        expect(renamed.name, equals('Demo Server Updated'));
        expect(renamed.password, isEmpty);
        expect(renamed.hasStoredPassword, isTrue);

        final rawDisk = File(
          '${tempDir.path}${Platform.pathSeparator}hosts_v1.json',
        ).readAsStringSync();
        expect(rawDisk, contains('enc:v1:'));
        expect(rawDisk, isNot(contains('demo-secret-password')));

        // Quick-connect parser over Rust FFI
        final parsed = await controller.parseQuickConnect(
          'ssh -p 2200 ops@192.0.2.10',
        );
        expect(parsed.username, equals('ops'));
        expect(parsed.host, equals('192.0.2.10'));
        expect(parsed.port, equals(2200));

        // Snippet CRUD over Rust FFI
        final snip = await controller.saveSnippet(
          const SnippetItem(
            title: 'Test Snippet',
            command: 'echo {{msg:hello}}',
            category: 'Test',
          ),
        );
        expect(controller.snippets.any((s) => s.id == snip.id), isTrue);
        await controller.removeSnippet(snip.id);
        expect(controller.snippets.any((s) => s.id == snip.id), isFalse);

        // App Lock PBKDF2 roundtrip over Rust FFI
        expect(controller.appLockConfig.enabled, isFalse);
        await controller.enableOrChangeAppLock(
          passcode: '9527',
          biometricsEnabled: true,
          lockOnStartup: true,
          autoLockMinutes: 1,
        );
        expect(controller.appLockConfig.enabled, isTrue);
        expect(controller.appLockConfig.hasPasscode, isTrue);
        controller.lockNow();
        expect(controller.isAppLocked, isTrue);
        expect(await controller.unlockWithPasscode('0000'), isFalse);
        expect(controller.isAppLocked, isTrue);
        expect(await controller.unlockWithPasscode('9527'), isTrue);
        expect(controller.isAppLocked, isFalse);
        await controller.disableAppLock(currentPasscode: '9527');
        expect(controller.appLockConfig.enabled, isFalse);

        // Local Terminal shell discovery over Rust FFI (desktop platforms)
        if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
          expect(controller.localShells, isNotEmpty);
          expect(controller.isLocalTerminalSupported, isTrue);
        }

        // Regression test on Windows: PowerShell launched with measured viewport
        // dimensions (not hardcoded 100x30) keeps cursor aligned on prompt line
        // even after multi-line Chinese error output.
        if (Platform.isWindows) {
          final ps = controller.localShells
              .where((s) => s.id == 'powershell' || s.id == 'pwsh')
              .firstOrNull;
          if (ps != null) {
            final sid = await controller.openLocalSession(shell: ps);
            final session = controller.activeSession!;
            session.terminal.resize(95, 28);
            await Future<void>.delayed(const Duration(milliseconds: 1200));

            session.terminal.textInput('badcmd_align_check\r');
            await Future<void>.delayed(const Duration(milliseconds: 700));
            session.terminal.textInput('ALIGN_OK');
            await Future<void>.delayed(const Duration(milliseconds: 400));

            final buf = session.terminal.buffer;
            final curLine = buf.lines[buf.absoluteCursorY].getText().trimRight();
            expect(curLine, contains('PS '));
            expect(curLine, contains('ALIGN_OK'));
            controller.closeSessionTab(sid);
          }
        }
      } finally {
        controller.dispose();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (tempDir.existsSync()) {
          await tempDir.delete(recursive: true);
        }
      }
    },
  );
}
