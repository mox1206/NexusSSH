import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_ssh/main.dart';
import 'package:nexus_ssh/src/desktop/desktop_shortcuts.dart';
import 'package:nexus_ssh/src/desktop/desktop_tray_service.dart';
import 'package:nexus_ssh/src/models/ssh_models.dart';
import 'package:nexus_ssh/src/rust/ssh_bridge.dart';
import 'package:nexus_ssh/src/state/app_controller.dart';

class _ShortcutTestBackend implements SshBackend {
  final List<Uint8List> writtenChunks = [];

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
  Future<List<LocalShellOption>> listLocalShells() async => const [
    LocalShellOption(
      id: 'pwsh',
      name: 'PowerShell 7',
      program: 'pwsh.exe',
      isDefault: true,
    ),
  ];

  @override
  Future<String> connectLocalSession({
    required String sessionId,
    String shellProgram = '',
    String cwd = '',
    required int cols,
    required int rows,
  }) async => 'PowerShell 7';

  @override
  void resizeSession(
    String sessionId, {
    required int cols,
    required int rows,
    int pixelWidth = 0,
    int pixelHeight = 0,
  }) {}

  @override
  void writeSession(String sessionId, Uint8List data) {
    writtenChunks.add(data);
  }

  @override
  void disconnectSession(String sessionId) {}

  @override
  void prepareShutdown() {}

  @override
  void dispose() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeDesktopAdapter implements DesktopWindowAdapter {
  @override
  bool get isSupported => true;

  @override
  void initialize({
    required VoidCallback onCloseRequested,
    required VoidCallback onTrayShow,
    required VoidCallback onTrayExit,
  }) {}

  @override
  void showAndFocusWindow() {}

  @override
  void hideToTray() {}

  @override
  void exitApp() {}

  @override
  void dispose() {}
}

void main() {
  test('DesktopShortcutConfig presets and JSON roundtrip work cleanly', () {
    final standardWin = DesktopShortcutConfig.defaults(
      preset: ShortcutPreset.standard,
      isMacOs: false,
    );
    expect(
      standardWin.bindingFor(ShortcutAction.closeTab)?.displayLabel,
      equals('Ctrl + W'),
    );
    expect(
      standardWin.bindingFor(ShortcutAction.newLocalTerminal)?.displayLabel,
      equals('Ctrl + T'),
    );
    expect(standardWin.quickTabSwitchLabel(isMacOs: false), equals('Ctrl + 1~9'));

    final safeWin = DesktopShortcutConfig.defaults(
      preset: ShortcutPreset.terminalSafe,
      isMacOs: false,
    );
    expect(
      safeWin.bindingFor(ShortcutAction.closeTab)?.displayLabel,
      equals('Ctrl + Shift + W'),
    );
    expect(safeWin.quickTabSwitchLabel(isMacOs: false), equals('Alt + 1~9'));

    final custom = standardWin.copyWith(
      smartCtrlCCopy: false,
      rightClickQuickPaste: false,
      bindings: {
        ...standardWin.bindings,
        ShortcutAction.closeTab: ShortcutBinding(
          keyId: LogicalKeyboardKey.f4.keyId,
          ctrl: true,
        ),
        ShortcutAction.toggleSidebar: null,
      },
    );
    final restored = DesktopShortcutConfig.fromJson(
      custom.toJson(),
      isMacOs: false,
    );
    expect(restored.preset, equals(ShortcutPreset.standard));
    expect(restored.smartCtrlCCopy, isFalse);
    expect(restored.rightClickQuickPaste, isFalse);
    expect(
      restored.bindingFor(ShortcutAction.closeTab)?.displayLabel,
      equals('Ctrl + F4'),
    );
    expect(restored.bindingFor(ShortcutAction.toggleSidebar), isNull);
  });

  testWidgets(
    'Workspace global shortcuts open/close tabs, toggle sidebar, zoom font, and record custom keys in Settings',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 820);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final tempDir = Directory.systemTemp.createTempSync('nexus_shortcuts_');
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });

      final backend = _ShortcutTestBackend();
      final controller = AppController(
        backend: backend,
        desktopAdapter: _FakeDesktopAdapter(),
      );
      await controller.initialize(tempDir.path);
      addTearDown(controller.dispose);

      await tester.pumpWidget(NexusSshApp(controller: controller));
      await tester.pumpAndSettle();

      // 1. Ctrl+T opens a new local terminal tab
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyT);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyT);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(controller.sessions.length, equals(1));

      // 2. Ctrl+B collapses sidebar, Ctrl+= zooms in, Ctrl+0 resets zoom
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyB);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyB);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.equal);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.equal);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(controller.sidebarCollapsed, isTrue);
      expect(controller.fontSize, equals(15.0));

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.digit0);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.digit0);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(controller.fontSize, equals(14.0));

      // 3. Ctrl+W closes active tab and leaks zero control bytes to the shell
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyW);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyW);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(controller.sessions, isEmpty);
      expect(backend.writtenChunks, isEmpty);

      // 4. Ctrl+, opens Settings Center, switch to Shortcuts, record Ctrl+F4 for closeTab
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.comma);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.comma);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.text('关闭窗口行为'), findsOneWidget);

      await tester.tap(find.text('快捷键'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('shortcut_keycap_close_tab')));
      await tester.pump();
      expect(find.text('请按键...'), findsOneWidget);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.f4);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.f4);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(
        controller.shortcutConfig.bindingFor(ShortcutAction.closeTab)?.displayLabel,
        equals('Ctrl + F4'),
      );

      // 5. Verify persistence across fresh AppController reload
      final reloaded = AppController(
        backend: _ShortcutTestBackend(),
        desktopAdapter: _FakeDesktopAdapter(),
      );
      await reloaded.initialize(tempDir.path);
      addTearDown(reloaded.dispose);
      expect(
        reloaded.shortcutConfig.bindingFor(ShortcutAction.closeTab)?.displayLabel,
        equals('Ctrl + F4'),
      );
    },
  );
}
