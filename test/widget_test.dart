import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_ssh/main.dart';
import 'package:nexus_ssh/src/desktop/desktop_tray_service.dart';
import 'package:nexus_ssh/src/models/snippet_template.dart';
import 'package:nexus_ssh/src/models/ssh_models.dart';
import 'package:nexus_ssh/src/rust/ssh_bridge.dart';
import 'package:nexus_ssh/src/security/biometric_auth_service.dart';
import 'package:nexus_ssh/src/state/app_controller.dart';
import 'package:nexus_ssh/src/terminal/command_autocomplete.dart';
import 'package:nexus_ssh/src/terminal/sudo_prompt_detector.dart';
import 'package:nexus_ssh/src/ui/host_editor_dialog.dart';
import 'package:nexus_ssh/src/ui/known_hosts_dialog.dart';
import 'package:nexus_ssh/src/ui/webdav_sync_dialog.dart';
import 'package:xterm3/xterm.dart';

class _LoopbackMockBackend implements SshBackend {
  final _outCtrl = StreamController<SessionOutputChunk>.broadcast();
  final _statusCtrl = StreamController<SessionStatusEvent>.broadcast();
  final List<String> sentCommands = [];
  bool requireTofuOnConnect = false;
  bool? lastTofuAccepted;
  Completer<bool>? _tofuCompleter;

  final List<HostProfile> _hosts = [
    const HostProfile(
      id: 'default-1',
      name: '10.0.0.10',
      host: '10.0.0.10',
      port: 22,
      username: 'demo',
      password: 'mock-sudo-password',
    ),
  ];

  final List<SnippetItem> _snippets = [
    const SnippetItem(
      id: 'snip-1',
      title: '系统负载概览',
      command: 'uptime',
      category: '运维巡检',
      autoEnter: true,
    ),
    const SnippetItem(
      id: 'snip-var-1',
      title: '查看容器日志',
      command: 'docker logs -f --tail {{行数:100}} {{容器名}}',
      category: '容器',
      autoEnter: true,
    ),
  ];

  @override
  Stream<SessionOutputChunk> get outputStream => _outCtrl.stream;

  @override
  Stream<SessionStatusEvent> get statusStream => _statusCtrl.stream;

  @override
  Future<List<HostProfile>> init(String dataDir) async => List.of(_hosts);

  @override
  Future<List<HostProfile>> listHosts() async => List.of(_hosts);

  @override
  Future<HostProfile> upsertHost(HostProfile profile) async {
    final saved = profile.copyWith(
      id: profile.id.isEmpty ? 'id-${_hosts.length + 1}' : profile.id,
    );
    _hosts.add(saved);
    return saved;
  }

  @override
  Future<bool> deleteHost(String hostId) async {
    _hosts.removeWhere((h) => h.id == hostId);
    return true;
  }

  @override
  Future<List<SnippetItem>> listSnippets() async => List.of(_snippets);

  @override
  Future<SnippetItem> upsertSnippet(SnippetItem snippet) async {
    final saved = SnippetItem(
      id: snippet.id.isEmpty ? 'snip-${_snippets.length + 1}' : snippet.id,
      title: snippet.title,
      command: snippet.command,
      category: snippet.category,
      autoEnter: snippet.autoEnter,
    );
    _snippets.removeWhere((s) => s.id == saved.id);
    _snippets.add(saved);
    return saved;
  }

  @override
  Future<bool> deleteSnippet(String snippetId) async {
    _snippets.removeWhere((s) => s.id == snippetId);
    return true;
  }

  @override
  Future<bool> respondHostKey({
    required String requestId,
    required bool accept,
    bool persist = true,
  }) async {
    lastTofuAccepted = accept;
    _tofuCompleter?.complete(accept);
    return true;
  }

  final List<KnownHostEntry> _knownHosts = [
    const KnownHostEntry(
      hostKey: '198.51.100.10:22',
      host: '198.51.100.10',
      port: 22,
      algorithm: 'ssh-ed25519',
      fingerprint: 'SHA256:DemoTrustedHostFingerprint1234',
      publicKeyBase64: 'AAAAC3NzaC1lZDI1NTE5',
      trustedAtMs: 1700000000000,
    ),
  ];

  @override
  Future<List<KnownHostEntry>> listKnownHosts() async => List.of(_knownHosts);

  @override
  Future<bool> deleteKnownHost(String hostKey) async {
    final before = _knownHosts.length;
    _knownHosts.removeWhere((e) => e.hostKey == hostKey);
    return _knownHosts.length < before;
  }

  AppLockConfig _appLock = const AppLockConfig();
  String _appLockPin = '';

  @override
  Future<AppLockConfig> getAppLockConfig() async => _appLock;

  @override
  Future<AppLockConfig> setAppLockPasscode({
    required String passcode,
    required bool biometricsEnabled,
    required bool lockOnStartup,
    required int autoLockMinutes,
  }) async {
    _appLockPin = passcode;
    _appLock = AppLockConfig(
      enabled: true,
      biometricsEnabled: biometricsEnabled,
      lockOnStartup: lockOnStartup,
      autoLockMinutes: autoLockMinutes,
      hasPasscode: true,
    );
    return _appLock;
  }

  @override
  Future<bool> verifyAppLockPasscode(String passcode) async =>
      _appLock.enabled && passcode == _appLockPin;

  @override
  Future<AppLockConfig> updateAppLockSettings({
    required bool biometricsEnabled,
    required bool lockOnStartup,
    required int autoLockMinutes,
  }) async {
    _appLock = _appLock.copyWith(
      biometricsEnabled: biometricsEnabled,
      lockOnStartup: lockOnStartup,
      autoLockMinutes: autoLockMinutes,
    );
    return _appLock;
  }

  @override
  Future<AppLockConfig> disableAppLock({
    String currentPasscode = '',
    bool bypassVerified = false,
  }) async {
    if (!bypassVerified && currentPasscode != _appLockPin) {
      throw const SshBridgeException('当前应用密码不正确');
    }
    _appLockPin = '';
    _appLock = const AppLockConfig();
    return _appLock;
  }

  @override
  Future<SftpDirListing> sftpListDir(String sessionId, {String path = ''}) async {
    return const SftpDirListing(
      currentPath: '/home/demo',
      entries: [
        SftpEntry(
          name: 'logs',
          path: '/home/demo/logs',
          kind: 'dir',
          size: 4096,
          permissionsOctal: 0x1ED, // 0755
          permissionsRwx: 'drwxr-xr-x',
        ),
        SftpEntry(
          name: 'nginx.conf',
          path: '/home/demo/nginx.conf',
          kind: 'file',
          size: 2048,
          permissionsOctal: 0x1A4, // 0644
          permissionsRwx: '-rw-r--r--',
        ),
      ],
    );
  }

  @override
  Future<void> sftpMkdir(String sessionId, String path) async {}

  @override
  Future<void> sftpRename(
    String sessionId,
    String oldPath,
    String newPath,
  ) async {}

  @override
  Future<void> sftpDelete(
    String sessionId,
    String path, {
    required bool isDir,
  }) async {}

  @override
  Future<void> sftpChmod(String sessionId, String path, int modeOctal) async {}

  @override
  Future<int> sftpDownload({
    required String sessionId,
    required String transferId,
    required String remotePath,
    required String localPath,
  }) async => 2048;

  @override
  Future<int> sftpUpload({
    required String sessionId,
    required String transferId,
    required String localPath,
    required String remotePath,
  }) async => 2048;

  @override
  Future<ServerMetrics> fetchServerMetrics(String sessionId) async {
    return const ServerMetrics(
      hostname: 'ubuntu-prod',
      osName: 'Ubuntu 24.04 LTS',
      kernel: 'Linux 6.8.0',
      uptimeSecs: 172800,
      cpuPercent: 18.5,
      cpuCores: 8,
      load1: 0.32,
      load5: 0.28,
      load15: 0.21,
      memTotalBytes: 16 * 1024 * 1024 * 1024,
      memUsedBytes: 5 * 1024 * 1024 * 1024,
      swapTotalBytes: 2 * 1024 * 1024 * 1024,
      swapUsedBytes: 0,
      disks: [
        DiskUsageItem(
          filesystem: '/dev/nvme0n1p1',
          mountPoint: '/',
          totalBytes: 100 * 1024 * 1024 * 1024,
          usedBytes: 38 * 1024 * 1024 * 1024,
        ),
      ],
      networks: [
        NetInterfaceRate(
          interfaceName: 'eth0',
          rxBytesPerSec: 125000,
          txBytesPerSec: 42000,
          totalRxBytes: 980000000,
          totalTxBytes: 310000000,
        ),
      ],
      collectedAtMs: 1700000000000,
    );
  }

  @override
  Future<List<String>> fetchRemoteHistory(
    String sessionId, {
    int maxEntries = 250,
  }) async {
    return const [
      'systemctl restart nginx-proxy',
      'docker compose logs -f --tail 50 api',
    ];
  }

  @override
  Future<QuickConnectTarget> parseQuickConnect(String expr) async {
    return const QuickConnectTarget(
      username: 'demo',
      host: '10.0.0.10',
      port: 22,
      displayName: 'demo@10.0.0.10',
    );
  }

  @override
  Future<KeyInspectionResult> inspectPrivateKey({
    String pemContent = '',
    String filePath = '',
    String passphrase = '',
  }) async {
    return const KeyInspectionResult(
      valid: true,
      encrypted: false,
      algorithm: 'ssh-ed25519',
      fingerprint: 'SHA256:mockfp',
      message: 'ssh-ed25519 · SHA256:mockfp',
    );
  }

  @override
  Future<List<DiscoveredSshKey>> discoverLocalKeys() async {
    return const [
      DiscoveredSshKey(
        name: 'id_ed25519',
        path: '/mock/.ssh/id_ed25519',
        encrypted: false,
      ),
    ];
  }

  WebDavConfig _davCfg = const WebDavConfig();
  final List<SyncMode> syncCalls = [];

  @override
  Future<WebDavConfig> getWebDavConfig() async => _davCfg;

  @override
  Future<WebDavConfig> saveWebDavConfig(WebDavConfig config) async {
    _davCfg = config;
    return _davCfg;
  }

  @override
  Future<ConnectionTestResult> testWebDav(WebDavConfig config) async {
    return const ConnectionTestResult(
      ok: true,
      latencyMs: 25,
      message: 'WebDAV 连接成功 (207)',
    );
  }

  @override
  Future<WebDavSyncResult> syncWebDav({
    WebDavConfig? config,
    SyncMode mode = SyncMode.merge,
  }) async {
    if (config != null) _davCfg = config;
    syncCalls.add(mode);
    return WebDavSyncResult(
      ok: true,
      totalHosts: _hosts.length,
      totalSnippets: _snippets.length,
      syncedAtMs: DateTime.now().millisecondsSinceEpoch,
      message: 'WebDAV 同步完成',
      hosts: List.of(_hosts),
      snippets: List.of(_snippets),
    );
  }

  @override
  Future<ConnectionTestResult> testConnection(
    HostProfile profile, {
    int timeoutSecs = 10,
  }) async {
    return const ConnectionTestResult(
      ok: true,
      latencyMs: 12,
      serverFingerprint: 'SHA256:test',
      message: 'OK',
    );
  }

  void emitOutput(String sessionId, String text) {
    _outCtrl.add(
      SessionOutputChunk(
        sessionId: sessionId,
        bytes: Uint8List.fromList(utf8.encode(text)),
      ),
    );
  }

  void emitHostKeyPrompt(String sessionId) {
    _statusCtrl.add(
      SessionStatusEvent(
        sessionId: sessionId,
        phase: SessionPhase.verifyHostKey,
        message: '请确认远程主机公钥指纹',
        hostKeyPrompt: HostKeyPromptEvent(
          requestId: 'req-tofu-1',
          sessionId: sessionId,
          host: '10.0.0.10',
          port: 22,
          algorithm: 'ssh-ed25519',
          fingerprint: 'SHA256:AbCdEf1234567890MockFingerprint',
          isMismatch: false,
        ),
      ),
    );
  }

  @override
  Future<void> connectSession({
    required String sessionId,
    required HostProfile profile,
    required int cols,
    required int rows,
  }) async {
    if (requireTofuOnConnect) {
      _tofuCompleter = Completer<bool>();
      emitHostKeyPrompt(sessionId);
      final accepted = await _tofuCompleter!.future;
      if (!accepted) return;
    }
    _statusCtrl.add(
      SessionStatusEvent(
        sessionId: sessionId,
        phase: SessionPhase.connected,
        serverFingerprint: 'SHA256:testfp',
        authUsed: 'password',
        latencyMs: 15,
        message: '已连接',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    // Simulate split multi-byte UTF-8 CJK + server MOTD arriving in separate chunks
    final fullBytes = utf8.encode(
      'Welcome to Ubuntu 24.04 LTS — 服务器已就绪\r\ndemo@server:~\$ ',
    );
    final splitAt = fullBytes.indexOf(0xE6) + 1; // split inside '服' (E6 9C 8D)
    _outCtrl.add(
      SessionOutputChunk(
        sessionId: sessionId,
        bytes: Uint8List.sublistView(Uint8List.fromList(fullBytes), 0, splitAt),
      ),
    );
    _outCtrl.add(
      SessionOutputChunk(
        sessionId: sessionId,
        bytes: Uint8List.sublistView(Uint8List.fromList(fullBytes), splitAt),
      ),
    );
  }

  @override
  Future<List<LocalShellOption>> listLocalShells() async => const [
    LocalShellOption(
      id: 'pwsh',
      name: 'PowerShell 7',
      program: 'pwsh.exe',
      args: ['-NoLogo'],
      isDefault: true,
    ),
    LocalShellOption(
      id: 'cmd',
      name: '命令提示符 (CMD)',
      program: 'cmd.exe',
    ),
  ];

  @override
  Future<String> connectLocalSession({
    required String sessionId,
    String shellProgram = '',
    String cwd = '',
    required int cols,
    required int rows,
  }) async {
    final name = shellProgram.toLowerCase().contains('cmd')
        ? '命令提示符 (CMD)'
        : 'PowerShell 7';
    _statusCtrl.add(
      SessionStatusEvent(
        sessionId: sessionId,
        phase: SessionPhase.connected,
        serverFingerprint: name,
        authUsed: 'local-pty',
        latencyMs: 0,
        message: '已连接',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    _outCtrl.add(
      SessionOutputChunk(
        sessionId: sessionId,
        bytes: Uint8List.fromList(utf8.encode('PS C:\\Users\\demo> ')),
      ),
    );
    return name;
  }

  @override
  void writeSession(String sessionId, Uint8List data) {
    final text = utf8.decode(data, allowMalformed: true);
    sentCommands.add(text);
    _outCtrl.add(SessionOutputChunk(sessionId: sessionId, bytes: data));
  }

  @override
  bool fillSudoPassword(String sessionId) {
    final pwd = _hosts.first.password;
    if (pwd.isEmpty) return false;
    writeSession(sessionId, Uint8List.fromList(utf8.encode('$pwd\r')));
    return true;
  }

  @override
  void resizeSession(
    String sessionId, {
    required int cols,
    required int rows,
    int pixelWidth = 0,
    int pixelHeight = 0,
  }) {}

  @override
  void disconnectSession(String sessionId) {}

  @override
  void prepareShutdown() {}

  @override
  void dispose() {
    _outCtrl.close();
    _statusCtrl.close();
  }
}

void main() {
  testWidgets(
    'TerminalView streams split UTF-8 MOTD, captures keystrokes, and opens SFTP/Monitor/Snippets drawers & TOFU overlay cleanly',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 820);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final backend = _LoopbackMockBackend()..requireTofuOnConnect = true;
      final controller = AppController(backend: backend);
      await controller.initialize('');
      addTearDown(controller.dispose);

      await tester.pumpWidget(NexusSshApp(controller: controller));
      await tester.pumpAndSettle();

      expect(find.text('SSH · demo@10.0.0.10'), findsOneWidget);
      expect(find.text('Snippets'), findsOneWidget);
      expect(find.byTooltip('WebDAV 云同步'), findsOneWidget);

      // Click the Termius-style host tile to connect
      await tester.tap(find.text('SSH · demo@10.0.0.10'));
      await tester.pump(const Duration(milliseconds: 300));

      // Verify TOFU fingerprint overlay renders and accepts cleanly
      expect(find.text('确认远程主机指纹'), findsOneWidget);
      await tester.tap(find.text('信任并连接'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(backend.lastTofuAccepted, isTrue);
      expect(find.text('确认远程主机指纹'), findsNothing);

      final session = controller.activeSession!;
      final bufferText = [
        for (var i = 0; i < session.terminal.buffer.lines.length; i++)
          session.terminal.buffer.lines[i].getText(),
      ].join('\n');

      expect(bufferText, contains('Welcome to Ubuntu 24.04 LTS — 服务器已就绪'));
      expect(bufferText, contains('demo@server:~\$'));

      // Verify hardware keyboard typing flows straight to writeSession without extra click
      await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(backend.sentCommands.join(), equals('pwd\r'));

      // Toggle SFTP drawer on Desktop
      await tester.tap(find.byTooltip('SFTP 文件管理'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('nginx.conf'), findsOneWidget);

      // Switch to Server Monitor tab inside drawer
      await tester.tap(find.text('监控'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.textContaining('ubuntu-prod'), findsOneWidget);

      // Switch to Snippets tab and execute plain snippet into terminal
      await tester.tap(find.text('片段'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('系统负载概览'), findsOneWidget);
      await tester.tap(find.text('系统负载概览'));
      await tester.pump();
      expect(backend.sentCommands.last, equals('uptime\r'));

      // Tap parameterized snippet, fill variables in dialog, and verify rendered command
      expect(find.text('2 变量'), findsOneWidget);
      await tester.tap(find.text('查看容器日志'));
      await tester.pumpAndSettle();
      expect(find.text('命令预览'), findsOneWidget);

      // First empty field ('容器名') is auto-focused; enter value and submit
      final varFields = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      await tester.enterText(varFields.at(0), '200');
      await tester.enterText(varFields.at(1), 'api-gateway');
      await tester.pump();
      expect(
        find.text('docker logs -f --tail 200 api-gateway'),
        findsOneWidget,
      );
      await tester.tap(find.text('发送到终端'));
      await tester.pumpAndSettle();
      expect(
        backend.sentCommands.last,
        equals('docker logs -f --tail 200 api-gateway\r'),
      );

      // Close Desktop side drawer
      await tester.tap(find.byTooltip('收起面板'));
      await tester.pump(const Duration(milliseconds: 150));

      // Verify Termius-style one-tap sudo floating pill with ZERO TerminalView height shift
      final termHeightBefore = tester.getSize(find.byType(TerminalView)).height;
      expect(termHeightBefore, greaterThan(400));
      backend.emitOutput(session.id, '\r\n[sudo] password for demo: ');
      await tester.pump();
      expect(find.text('填入主机密码'), findsOneWidget);
      expect(
        tester.getSize(find.byType(TerminalView)).height,
        equals(termHeightBefore),
      );
      await tester.tap(find.text('填入主机密码'));
      await tester.pump();
      expect(backend.sentCommands.last, equals('mock-sudo-password\r'));
      expect(find.text('填入主机密码'), findsNothing);

      // Verify Termius-style cursor-following autocomplete popup with ZERO TerminalView height shift
      // and keyboard navigation (ArrowDown selects next without leaking ESC[B; Enter accepts navigated item)
      backend.emitOutput(session.id, '\r\ndemo@server:~\$ sys');
      await tester.pump();
      expect(
        tester.getSize(find.byType(TerminalView)).height,
        equals(termHeightBefore),
      );
      final suggestionFinder = find.textContaining(
        'systemctl restart nginx-proxy',
      );
      expect(suggestionFinder, findsOneWidget);

      final countBeforeArrow = backend.sentCommands.length;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(session.autocompleteNavigated, isTrue);
      expect(session.autocompleteSelectedIndex, equals(0));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(session.autocompleteSelectedIndex, equals(1));
      expect(backend.sentCommands.length, equals(countBeforeArrow));

      // ArrowUp returns to index 0, then Enter accepts navigated item (Tab stays native to shell)
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(session.autocompleteSelectedIndex, equals(0));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(backend.sentCommands.last, equals('temctl restart nginx-proxy'));

      // Verify when popup is hidden, ArrowUp falls back to native terminal history sequence (ESC[A)
      backend.emitOutput(session.id, '\r\ndemo@server:~\$ ');
      await tester.pump();
      expect(session.autocompleteSuggestions, isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(backend.sentCommands.last, equals('\x1b[A'));

      // Verify on-screen tactile extra-keys bar arrows control popup when open & send ESC[A/D when closed
      await tester.tap(find.byTooltip('扩展快捷按键栏'));
      await tester.pump();
      backend.emitOutput(session.id, '\r\ndemo@server:~\$ sys');
      await tester.pump();
      expect(session.autocompleteSuggestions, isNotEmpty);
      await tester.tap(find.text('↓'));
      await tester.pump();
      expect(session.autocompleteSelectedIndex, equals(0));
      await tester.tap(find.text('↓'));
      await tester.pump();
      expect(session.autocompleteSelectedIndex, equals(1));
      await tester.tap(find.text('↑'));
      await tester.pump();
      expect(session.autocompleteSelectedIndex, equals(0));
      await tester.tap(find.text('ESC'));
      await tester.pump();
      expect(session.autocompleteSuggestions, isEmpty);
      await tester.tap(find.text('←'));
      await tester.pump();
      expect(backend.sentCommands.last, equals('\x1b[D'));

      // Verify Termius Mobile responsive layout + "< Hosts" + Floating Active Session Pill
      tester.view.physicalSize = const Size(390, 844);
      await tester.pump(const Duration(milliseconds: 200));

      await tester.tap(find.text('Hosts'));
      await tester.pumpAndSettle();
      expect(find.text('返回终端'), findsOneWidget);
    },
  );

  test('SnippetTemplate parses variables, preserves Go/Docker templates & shell vars', () {
    // Docker Go template fields starting with `.` must NOT be treated as prompt vars
    const dockerPs = "docker ps --format 'table {{.Names}}\\t{{.Status}}\\t{{.Ports}}'";
    expect(SnippetTemplate.extractVariables(dockerPs), isEmpty);

    // Shell env vars must NOT be treated as prompt vars
    expect(SnippetTemplate.extractVariables(r'echo "$HOME" "${PATH}"'), isEmpty);

    // Deduplicates repeated vars, supports defaults containing `:` (e.g. URLs)
    const tpl = 'curl -s {{url:http://127.0.0.1:8080/health}} && cp {{file}} {{file}}.bak';
    final vars = SnippetTemplate.extractVariables(tpl);
    expect(vars.map((v) => v.name).toList(), equals(['url', 'file']));
    expect(vars[0].defaultValue, equals('http://127.0.0.1:8080/health'));
    expect(vars[1].defaultValue, isEmpty);

    final rendered = SnippetTemplate.render(tpl, {
      'url': 'http://10.0.0.2:9000/ok',
      'file': 'app.conf',
    });
    expect(
      rendered,
      equals('curl -s http://10.0.0.2:9000/ok && cp app.conf app.conf.bak'),
    );
  });

  test('SudoPromptDetector matches real sudo/password prompts and ignores logs', () {
    expect(
      SudoPromptDetector.matchLine('[sudo] password for demo: '),
      isNotNull,
    );
    expect(
      SudoPromptDetector.matchLine('[sudo] demo 的密码：'),
      isNotNull,
    );
    expect(SudoPromptDetector.matchLine('Password: '), isNotNull);
    expect(SudoPromptDetector.matchLine('密码：'), isNotNull);
    expect(
      SudoPromptDetector.matchLine('doas (ops@server) password:'),
      isNotNull,
    );
    expect(
      SudoPromptDetector.matchLine("root@10.0.0.1's password: "),
      isNotNull,
    );

    // Negative cases: regular logs / shell prompts must never trigger
    expect(SudoPromptDetector.matchLine('demo@server:~\$ '), isNull);
    expect(
      SudoPromptDetector.matchLine('INFO: Password verification succeeded'),
      isNull,
    );
    expect(SudoPromptDetector.matchLine('sudo systemctl restart nginx'), isNull);
  });

  test('CommandAutocompleteEngine ranks history/snippets/builtin and supports sudo prefix', () {
    final prefix = CommandAutocompleteEngine.extractCommandPrefix(
      lineBeforeCursor: 'demo@server:~\$ sudo sys',
      fullLineTrimmed: 'demo@server:~\$ sudo sys',
    );
    expect(prefix, equals('sudo sys'));

    final suggestions = CommandAutocompleteEngine.suggest(
      rawPrefix: prefix!,
      localHistory: const ['systemctl status redis'],
      remoteHistory: const ['systemctl restart nginx'],
      snippets: const [],
    );

    expect(suggestions, isNotEmpty);
    expect(suggestions.first.fullText, equals('sudo systemctl status redis'));
    expect(suggestions.first.insertSuffix, equals('temctl status redis'));
    expect(suggestions.first.source, equals(SuggestionSource.localHistory));
    expect(suggestions[1].fullText, equals('sudo systemctl restart nginx'));
    expect(suggestions[1].source, equals(SuggestionSource.remoteHistory));
  });

  test('CommandAutocompleteEngine adapts prompts and dictionaries for PowerShell, CMD, and Unix shells', () {
    const linuxSnippets = [
      SnippetItem(
        id: 's1',
        title: '查看端口',
        command: 'ss -tulpn',
      ),
      SnippetItem(
        id: 's2',
        title: '系统状态',
        command: 'systemctl status nginx',
      ),
    ];

    // 1. PowerShell: suggests PowerShell cmdlets and excludes Linux commands/snippets
    final psPrefix = CommandAutocompleteEngine.extractCommandPrefix(
      lineBeforeCursor: r'PS C:\Users\dev> get-p',
      fullLineTrimmed: r'PS C:\Users\dev> get-p',
      shellKind: AutocompleteShellKind.powershell,
    );
    expect(psPrefix, equals('get-p'));
    final psSuggestions = CommandAutocompleteEngine.suggest(
      rawPrefix: psPrefix!,
      localHistory: const [],
      remoteHistory: const [],
      snippets: linuxSnippets,
      shellKind: AutocompleteShellKind.powershell,
    );
    expect(psSuggestions.any((s) => s.fullText == 'Get-Process'), isTrue);

    final psSysSuggestions = CommandAutocompleteEngine.suggest(
      rawPrefix: 'sys',
      localHistory: const [],
      remoteHistory: const [],
      snippets: linuxSnippets,
      shellKind: AutocompleteShellKind.powershell,
    );
    expect(psSysSuggestions.any((s) => s.fullText.startsWith('systemctl')), isFalse);

    // 2. CMD: parses prompt without trailing space and suggests CMD commands only
    final cmdPrefix = CommandAutocompleteEngine.extractCommandPrefix(
      lineBeforeCursor: r'C:\Users\dev>ipco',
      fullLineTrimmed: r'C:\Users\dev>ipco',
      shellKind: AutocompleteShellKind.cmd,
    );
    expect(cmdPrefix, equals('ipco'));
    final cmdSuggestions = CommandAutocompleteEngine.suggest(
      rawPrefix: cmdPrefix!,
      localHistory: const [],
      remoteHistory: const [],
      snippets: linuxSnippets,
      shellKind: AutocompleteShellKind.cmd,
    );
    expect(cmdSuggestions.any((s) => s.fullText == 'ipconfig /all'), isTrue);
    expect(cmdSuggestions.any((s) => s.fullText.startsWith('Get-')), isFalse);
  });

  testWidgets(
    'Desktop close prompt supports minimize-to-tray, remember choice, settings switch, and exit',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 820);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final backend = _LoopbackMockBackend();
      final desktop = _MockDesktopWindowAdapter();
      final controller = AppController(
        backend: backend,
        desktopAdapter: desktop,
      );
      await controller.initialize('');
      controller.initDesktopTray();
      addTearDown(controller.dispose);

      await tester.pumpWidget(NexusSshApp(controller: controller));
      await tester.pumpAndSettle();

      // 1. Default behavior is ask -> trigger close -> overlay appears
      desktop.triggerCloseRequest();
      await tester.pumpAndSettle();
      expect(find.text('关闭 Nexus SSH'), findsOneWidget);
      expect(find.text('退到系统托盘'), findsOneWidget);
      expect(find.text('直接退出'), findsOneWidget);

      // Check "remember choice" and choose "退到系统托盘"
      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      await tester.tap(find.text('退到系统托盘'));
      await tester.pumpAndSettle();
      expect(desktop.hideCount, equals(1));
      expect(controller.closeBehavior, equals(DesktopCloseBehavior.minimizeToTray));

      // 2. Subsequent close hides straight to tray without showing overlay
      desktop.triggerCloseRequest();
      await tester.pump();
      expect(find.text('关闭 Nexus SSH'), findsNothing);
      expect(desktop.hideCount, equals(2));

      // 3. Clicking tray icon restores window
      desktop.triggerTrayShow();
      expect(desktop.showCount, equals(1));

      // 4. User can change remembered preference via bottom-left settings button
      await tester.tap(find.byIcon(Icons.tune_rounded));
      await tester.pumpAndSettle();
      expect(find.text('关闭窗口行为'), findsOneWidget);
      await tester.tap(find.text('直接退出'));
      await tester.pumpAndSettle();
      expect(controller.closeBehavior, equals(DesktopCloseBehavior.exit));

      // 5. Closing now exits directly
      desktop.triggerCloseRequest();
      expect(desktop.exitCount, equals(1));
    },
  );

  test(
    'WebDAV respects persistent defaultSyncMode and never auto-syncs deletions',
    () async {
      final backend = _LoopbackMockBackend();
      await backend.saveWebDavConfig(
        const WebDavConfig(
          url: 'https://dav.example.com/dav/',
          autoSync: true,
          defaultSyncMode: SyncMode.pullOverwrite,
        ),
      );
      final controller = AppController(backend: backend);
      addTearDown(controller.dispose);

      // 1. Startup auto-sync uses saved pullOverwrite mode
      await controller.initialize('');
      await Future<void>.delayed(Duration.zero);
      expect(backend.syncCalls, equals([SyncMode.pullOverwrite]));

      // 2. Saving a host in pullOverwrite mode does NOT overwrite local edit
      backend.syncCalls.clear();
      await controller.saveHost(
        const HostProfile(
          id: 'h-new',
          name: 'Local Temp',
          host: '10.0.0.99',
          username: 'root',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(backend.syncCalls, isEmpty);

      // 3. Even in merge + autoSync mode, deleting a host NEVER auto-syncs to cloud
      await controller.saveWebDavConfig(
        const WebDavConfig(
          url: 'https://dav.example.com/dav/',
          autoSync: true,
          defaultSyncMode: SyncMode.merge,
        ),
      );
      await controller.removeHost('h-new');
      await Future<void>.delayed(Duration.zero);
      expect(backend.syncCalls, isEmpty);

      // 4. Default manual syncWebDav() uses persisted defaultSyncMode (pullOverwrite)
      await controller.saveWebDavConfig(
        const WebDavConfig(
          url: 'https://dav.example.com/dav/',
          autoSync: false,
          defaultSyncMode: SyncMode.pullOverwrite,
        ),
      );
      await controller.syncWebDav();
      expect(backend.syncCalls, equals([SyncMode.pullOverwrite]));
    },
  );

  testWidgets(
    'HostEditorDialog keeps saved password write-only and hides reveal icon until new text typed',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 860);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final backend = _LoopbackMockBackend();
      final controller = AppController(backend: backend);
      await controller.initialize('');

      // Replace mock host with a redacted profile (password empty, hasPassword true)
      final redacted = const HostProfile(
        id: 'saved-1',
        name: 'Prod Box',
        host: '198.51.100.20',
        port: 22,
        username: 'ops',
        password: '',
        hasPassword: true,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => Center(
                child: FilledButton(
                  onPressed: () {
                    showDialog<void>(
                      context: ctx,
                      builder: (_) => HostEditorDialog(
                        controller: controller,
                        initialProfile: redacted,
                      ),
                    );
                  },
                  child: const Text('Open Editor'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Editor'));
      await tester.pumpAndSettle();

      // Saved password hint is shown, NO visibility eye button is shown!
      expect(find.text('已保存密码（留空保持不变，输入则覆盖）'), findsOneWidget);
      expect(find.byIcon(Icons.visibility_outlined), findsNothing);
      expect(find.byIcon(Icons.verified_user_outlined), findsOneWidget);

      // Typing a replacement password reveals the visibility eye button for the new input only
      final pwdField = find.widgetWithText(
        TextFormField,
        '已保存密码（留空保持不变，输入则覆盖）',
      );
      await tester.enterText(pwdField, 'NewReplacementPass!');
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.visibility_outlined), findsOneWidget);

      controller.dispose();
    },
  );

  testWidgets(
    'App Lock supports passcode lock/unlock, biometric unlock, and lifecycle privacy shield',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 820);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final backend = _LoopbackMockBackend();
      final bio = _MockBiometricAuthService();
      final controller = AppController(
        backend: backend,
        biometricService: bio,
      );
      await controller.initialize('');
      addTearDown(controller.dispose);

      await tester.pumpWidget(NexusSshApp(controller: controller));
      await tester.pumpAndSettle();

      // Enable app lock with immediate background lock & biometrics enabled
      await controller.enableOrChangeAppLock(
        passcode: '6789',
        biometricsEnabled: true,
        lockOnStartup: true,
        autoLockMinutes: 0,
      );
      await tester.pumpAndSettle();

      // 1. Manual lock engages AppLockOverlay; auto-biometric fails first so we test passcode
      bio.nextResult = false;
      controller.lockNow();
      await tester.pumpAndSettle();
      expect(find.text('Nexus SSH 已锁定'), findsOneWidget);
      expect(find.text('使用 指纹识别 解锁'), findsOneWidget);

      // 2. Wrong passcode shows error and stays locked
      final lockField = find.widgetWithText(TextField, '输入应用锁密码');
      await tester.enterText(lockField, '0000');
      await tester.tap(find.text('解锁'));
      await tester.pumpAndSettle();
      expect(find.text('应用密码错误，请重试'), findsOneWidget);
      expect(controller.isAppLocked, isTrue);

      // 3. Correct passcode unlocks immediately
      await tester.enterText(lockField, '6789');
      await tester.tap(find.text('解锁'));
      await tester.pumpAndSettle();
      expect(controller.isAppLocked, isFalse);
      expect(find.text('Nexus SSH 已锁定'), findsNothing);

      // 4. Lifecycle paused triggers immediate lock when autoLockMinutes == 0,
      //    and biometric button unlocks cleanly
      bio.nextResult = true;
      controller.onAppLifecycleChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(controller.isAppLocked, isTrue);
      controller.onAppLifecycleChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      // Auto biometric succeeded on lock overlay mount!
      expect(controller.isAppLocked, isFalse);
      expect(bio.authenticateCalls, greaterThanOrEqualTo(2));
    },
  );

  test('SnippetTemplate.detectDangerReason flags destructive commands and allows safe ones', () {
    expect(SnippetTemplate.detectDangerReason('rm -rf /var/tmp/build'), isNotNull);
    expect(SnippetTemplate.detectDangerReason('sudo reboot'), isNotNull);
    expect(SnippetTemplate.detectDangerReason('mkfs.ext4 /dev/sdb1'), isNotNull);
    expect(SnippetTemplate.detectDangerReason('dd if=/dev/zero of=/dev/sda bs=1M'), isNotNull);
    expect(SnippetTemplate.detectDangerReason('DROP TABLE users;'), isNotNull);

    expect(SnippetTemplate.detectDangerReason('docker ps -a'), isNull);
    expect(SnippetTemplate.detectDangerReason('rm temp.log'), isNull);
    expect(SnippetTemplate.detectDangerReason('systemctl status nginx'), isNull);
  });

  testWidgets(
    'KnownHostsDialog lists and deletes trusted fingerprints & WebDavSyncDialog warns when unencrypted',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 820);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final backend = _LoopbackMockBackend();
      final controller = AppController(backend: backend);
      await controller.initialize('');
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => Row(
                children: [
                  FilledButton(
                    onPressed: () =>
                        KnownHostsDialog.show(ctx, controller: controller),
                    child: const Text('Open KnownHosts'),
                  ),
                  FilledButton(
                    onPressed: () =>
                        WebDavSyncDialog.show(ctx, controller: controller),
                    child: const Text('Open WebDAV'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      // 1. KnownHostsDialog displays trusted entry and deletes after confirmation
      await tester.tap(find.text('Open KnownHosts'));
      await tester.pumpAndSettle();
      expect(find.text('198.51.100.10:22'), findsOneWidget);
      expect(find.text('SHA256:DemoTrustedHostFingerprint1234'), findsOneWidget);

      await tester.tap(find.byTooltip('移除信任'));
      await tester.pumpAndSettle();
      expect(find.text('移除信任指纹'), findsOneWidget);
      await tester.tap(find.text('移除'));
      await tester.pumpAndSettle();
      expect(find.text('暂无已信任主机记录'), findsOneWidget);

      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();

      // 2. WebDavSyncDialog displays prominent amber unencrypted warning
      await tester.tap(find.text('Open WebDAV'));
      await tester.pumpAndSettle();
      expect(find.textContaining('未设置加密口令时'), findsOneWidget);
    },
  );

  testWidgets(
    'Desktop sidebar launches Local Terminal tab, hides remote SFTP/Monitor buttons, and supports shell picker',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 820);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final tempDir = Directory.systemTemp.createTempSync('nexus_local_shell_');
      addTearDown(() {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });

      final backend = _LoopbackMockBackend();
      final controller = AppController(backend: backend);
      await controller.initialize(tempDir.path);
      addTearDown(controller.dispose);

      await tester.pumpWidget(NexusSshApp(controller: controller));
      await tester.pumpAndSettle();

      // Sidebar shows Local Terminal quick action button with default shell tooltip
      expect(find.byTooltip('本地终端 · PowerShell 7'), findsOneWidget);
      await tester.tap(find.byTooltip('本地终端 · PowerShell 7'));
      await tester.pumpAndSettle();

      expect(controller.sessions.length, equals(1));
      expect(controller.activeSession!.isLocal, isTrue);
      expect(find.text('本地终端 · PowerShell 7'), findsOneWidget);
      // Remote-only tools (SFTP / Server Monitor / Disconnect) are hidden in local terminal
      expect(find.byTooltip('SFTP 文件管理'), findsNothing);
      expect(find.byTooltip('服务器状态监控'), findsNothing);
      expect(find.byTooltip('断开连接'), findsNothing);
      expect(find.byTooltip('关闭本地终端'), findsNothing);
      // Snippets drawer still works in local terminal
      expect(find.byTooltip('命令片段'), findsOneWidget);

      // Shell picker launches a second local terminal (CMD) and remembers it as the preferred shell
      await tester.tap(find.byTooltip('选择本地 Shell'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('命令提示符 (CMD)'));
      await tester.pumpAndSettle();

      expect(controller.sessions.length, equals(2));
      expect(find.text('本地终端 · 命令提示符 (CMD)'), findsOneWidget);
      expect(controller.preferredLocalShell?.id, equals('cmd'));
      expect(find.byTooltip('本地终端 · 命令提示符 (CMD)'), findsOneWidget);

      // Clicking the Local Terminal icon directly now opens CMD (the last selected shell)
      await tester.tap(find.byTooltip('本地终端 · 命令提示符 (CMD)'));
      await tester.pumpAndSettle();
      expect(controller.sessions.length, equals(3));
      expect(controller.activeSession!.localShellProgram, equals('cmd.exe'));

      // Persisted across restart
      final controller2 = AppController(backend: backend);
      await controller2.initialize(tempDir.path);
      addTearDown(controller2.dispose);
      expect(controller2.preferredLocalShell?.id, equals('cmd'));
    },
  );

  testWidgets(
    'Tailscale SSH check-mode URL in terminal output displays one-tap browser verification banner',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 820);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final backend = _LoopbackMockBackend();
      final controller = AppController(backend: backend);
      await controller.initialize('');
      addTearDown(controller.dispose);

      await tester.pumpWidget(NexusSshApp(controller: controller));
      await tester.pumpAndSettle();

      final openFuture = controller.openSession(
        const HostProfile(
          id: 'ts-1',
          name: 'Oracle Tailscale',
          host: 'oracle-arm.example.ts.net',
          username: 'ubuntu',
          authMethod: AuthMethod.none,
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      await openFuture;
      await tester.pumpAndSettle();

      final sid = controller.activeSessionId!;
      backend.emitOutput(
        sid,
        '# Tailscale SSH requires an additional check.\r\n'
        '# To authenticate, visit: https://login.tailscale.com/a/demo123456\r\n',
      );
      await tester.pumpAndSettle();

      expect(find.text('需要浏览器身份验证 (Tailscale SSH)'), findsOneWidget);
      expect(find.text('https://login.tailscale.com/a/demo123456'), findsOneWidget);
      expect(find.text('打开浏览器'), findsOneWidget);

      // Dismiss hides banner cleanly
      await tester.tap(find.byTooltip('隐藏'));
      await tester.pumpAndSettle();
      expect(find.text('打开浏览器'), findsNothing);

      // A new check URL re-shows banner, and completing auth (shell prompt arrives) auto-clears it
      backend.emitOutput(
        sid,
        '# To authenticate, visit: https://login.tailscale.com/a/demo654321\r\n',
      );
      await tester.pumpAndSettle();
      expect(find.text('https://login.tailscale.com/a/demo654321'), findsOneWidget);

      backend.emitOutput(sid, 'ubuntu@oracle-arm:~\$ ');
      await tester.pumpAndSettle();
      expect(find.text('打开浏览器'), findsNothing);
    },
  );

  testWidgets(
    'HostEditorDialog configures ProxyJump host and HostsView renders ProxyJump badge & route',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 820);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final backend = _LoopbackMockBackend();
      final controller = AppController(backend: backend);
      await controller.initialize('');
      addTearDown(controller.dispose);

      await tester.pumpWidget(NexusSshApp(controller: controller));
      await tester.pumpAndSettle();

      // Existing bastion host is present in vault (`id: default-1`, `name: 10.0.0.10`)
      expect(find.text('10.0.0.10'), findsOneWidget);

      // Open "新建主机" from desktop sidebar
      await tester.tap(find.text('新建主机'));
      await tester.pumpAndSettle();

      // Fill target internal server fields
      await tester.enterText(
        find.widgetWithText(TextFormField, 'IP 或域名，如 192.168.1.10'),
        '10.20.0.8',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, '可选，如 家里服务器'),
        'Internal DB',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, '输入登录密码'),
        'internal-pw',
      );

      // Select 10.0.0.10 as ProxyJump bastion
      final dropdown = find.byKey(const ValueKey('proxy_jump_dropdown'));
      await tester.ensureVisible(dropdown);
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('10.0.0.10  ·  demo@10.0.0.10').last);
      await tester.pumpAndSettle();

      // Tunnel route preview appears inside dialog
      expect(
        find.textContaining('Local → 10.0.0.10 → 当前主机'),
        findsOneWidget,
      );

      // Save host
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      // HostsView card displays ProxyJump badge and hop route subtitle
      expect(find.text('Internal DB'), findsOneWidget);
      expect(find.text('ProxyJump'), findsOneWidget);
      expect(find.text('10.0.0.10 → root@10.20.0.8'), findsOneWidget);
    },
  );

  testWidgets(
    'Desktop HostsView ignores long-press bottom sheet and absorbs phantom clicks right after window maximize',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 820);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final backend = _LoopbackMockBackend();
      final controller = AppController(
        backend: backend,
        desktopAdapter: _MockDesktopWindowAdapter(),
      );
      await controller.initialize('');
      addTearDown(controller.dispose);

      await tester.pumpWidget(NexusSshApp(controller: controller));
      await tester.pumpAndSettle();

      // Simulate titlebar double-click maximize (window physicalSize changes):
      // both leaked long-press and leaked tap during the transition are absorbed.
      tester.view.physicalSize = const Size(1920, 1040);
      await tester.pump();

      await tester.tap(
        find.text('SSH · demo@10.0.0.10'),
        warnIfMissed: false,
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(controller.sessions, isEmpty);
      expect(find.text('连接终端'), findsNothing);

      // After the brief 240ms guard expires, long-pressing on desktop still never
      // opens the mobile bottom sheet (and releasing connects cleanly via onTap).
      await tester.pump(const Duration(milliseconds: 250));
      await tester.longPress(find.text('SSH · demo@10.0.0.10'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('连接终端'), findsNothing);
      expect(controller.sessions.length, equals(1));
    },
  );

  testWidgets(
    'Autocomplete returns Tab to shell, supports ArrowRight quick-accept, ArrowDown+Enter select, and mobile double-tap Tab',
    (WidgetTester tester) async {
      // 1. Desktop: verify Plan B autocomplete keybindings
      tester.view.physicalSize = const Size(1280, 820);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final backend = _LoopbackMockBackend();
      final controller = AppController(backend: backend);
      await controller.initialize('');
      addTearDown(controller.dispose);

      await tester.pumpWidget(NexusSshApp(controller: controller));
      await tester.pumpAndSettle();

      await tester.tap(find.text('SSH · demo@10.0.0.10'));
      await tester.pump(const Duration(milliseconds: 100));
      final sid = controller.activeSessionId!;

      // Type "doc" to trigger autocomplete suggestions (e.g. docker ...)
      backend.emitOutput(sid, 'doc');
      await tester.pump();
      expect(controller.activeSession!.autocompleteSuggestions, isNotEmpty);
      expect(controller.activeSession!.autocompleteNavigated, isFalse);
      final firstSuffix =
          controller.activeSession!.autocompleteSuggestions.first.insertSuffix;

      // Pressing Tab must pass native '\t' to shell and dismiss popup (NOT accept suggestion)
      backend.sentCommands.clear();
      controller.sendVirtualKey(sid, TerminalKey.tab);
      await tester.pump();
      expect(backend.sentCommands, equals(['\t']));
      expect(controller.activeSession!.autocompleteSuggestions, isEmpty);

      // Re-trigger suggestions on a fresh prompt line with "doc"
      backend.emitOutput(sid, '\r\ndemo@server:~\$ doc');
      await tester.pump();
      expect(controller.activeSession!.autocompleteSuggestions, isNotEmpty);

      // Pressing ArrowRight at end of line immediately accepts 1st suggestion
      backend.sentCommands.clear();
      controller.sendVirtualKey(sid, TerminalKey.arrowRight);
      await tester.pump();
      expect(backend.sentCommands, equals([firstSuffix]));

      // Re-trigger and verify ArrowDown selects index 0, then Enter accepts it
      backend.emitOutput(sid, '\r\ndemo@server:~\$ doc');
      await tester.pump();
      expect(controller.activeSession!.autocompleteNavigated, isFalse);
      controller.sendVirtualKey(sid, TerminalKey.arrowDown);
      await tester.pump();
      expect(controller.activeSession!.autocompleteNavigated, isTrue);
      expect(controller.activeSession!.autocompleteSelectedIndex, equals(0));
      backend.sentCommands.clear();
      controller.sendVirtualKey(sid, TerminalKey.enter);
      await tester.pump();
      expect(backend.sentCommands, equals([firstSuffix]));

      // Desktop double-click on TerminalView must NOT send Tab (keeps word selection)
      backend.sentCommands.clear();
      final termCenter = tester.getCenter(find.byType(TerminalView));
      await tester.tapAt(termCenter);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tapAt(termCenter);
      await tester.pump(const Duration(milliseconds: 40));
      expect(backend.sentCommands.contains('\t'), isFalse);

      // 2. Mobile viewport: double-tapping TerminalView sends Tab
      tester.view.physicalSize = const Size(412, 892);
      await tester.pumpAndSettle();

      backend.sentCommands.clear();
      final mobileCenter = tester.getCenter(find.byType(TerminalView));
      await tester.tapAt(mobileCenter);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tapAt(mobileCenter);
      await tester.pump(const Duration(milliseconds: 40));
      expect(backend.sentCommands, contains('\t'));
    },
  );

  testWidgets(
    'Desktop sidebar supports collapse/expand, section folding, equal-width icon dock, and persists state',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 820);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final tempDir = Directory.systemTemp.createTempSync('nexus_sidebar_test_');
      addTearDown(() {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });

      final backend = _LoopbackMockBackend();
      await backend.upsertHost(
        const HostProfile(
          id: 'h-prod',
          name: 'Prod API',
          host: '10.0.1.10',
          username: 'ops',
          group: '生产环境',
        ),
      );
      await backend.upsertHost(
        const HostProfile(
          id: 'h-stage',
          name: 'Stage Web',
          host: '10.0.2.10',
          username: 'ops',
          group: '测试集群',
        ),
      );

      final controller = AppController(
        backend: backend,
        desktopAdapter: _MockDesktopWindowAdapter(),
      );
      await controller.initialize(tempDir.path);
      addTearDown(controller.dispose);

      await tester.pumpWidget(NexusSshApp(controller: controller));
      await tester.pumpAndSettle();

      // Expanded sidebar shows brand title, action row, core nav, collapsible groups, and icon dock
      expect(find.text('Nexus SSH'), findsOneWidget);
      expect(find.text('新建主机'), findsOneWidget);
      expect(find.byTooltip('本地终端 · PowerShell 7'), findsOneWidget);
      expect(find.text('GROUPS'), findsOneWidget);
      expect(find.byTooltip('WebDAV 云同步'), findsOneWidget);
      expect(find.byTooltip('安全中心（未加锁）'), findsOneWidget);
      expect(find.byIcon(Icons.tune_rounded), findsOneWidget);

      // Fold GROUPS section and verify state flips
      await tester.tap(find.text('GROUPS'));
      await tester.pumpAndSettle();
      expect(controller.sidebarGroupsCollapsed, isTrue);

      // Collapse sidebar into 58px icon rail
      await tester.tap(find.byKey(const ValueKey('sidebar_collapse_btn')));
      await tester.pumpAndSettle();
      expect(controller.sidebarCollapsed, isTrue);
      expect(find.text('Nexus SSH'), findsNothing);
      expect(find.byKey(const ValueKey('sidebar_expand_btn')), findsOneWidget);
      expect(find.byTooltip('新建主机'), findsOneWidget);
      expect(find.byTooltip('WebDAV 云同步'), findsOneWidget);

      // Re-initialize a brand-new controller pointing at the same dataDir -> persisted states restore
      final controller2 = AppController(
        backend: backend,
        desktopAdapter: _MockDesktopWindowAdapter(),
      );
      await controller2.initialize(tempDir.path);
      addTearDown(controller2.dispose);
      expect(controller2.sidebarCollapsed, isTrue);
      expect(controller2.sidebarGroupsCollapsed, isTrue);

      // Expand sidebar back via rail toggle
      await tester.tap(find.byKey(const ValueKey('sidebar_expand_btn')));
      await tester.pumpAndSettle();
      expect(controller.sidebarCollapsed, isFalse);
      expect(find.text('Nexus SSH'), findsOneWidget);

      // Opening Security Center dialog renders ListTile/SwitchListTile inside Material without framework assertions
      await tester.tap(find.byTooltip('安全中心（未加锁）'));
      await tester.pumpAndSettle();
      expect(find.text('受信任主机指纹 (known_hosts)'), findsOneWidget);
      expect(find.text('剪贴板 30 秒自动清空'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
    },
  );
}

class _MockBiometricAuthService implements BiometricAuthService {
  bool nextResult = true;
  int authenticateCalls = 0;

  @override
  Future<BiometricCapability> checkCapability() async {
    return const BiometricCapability(
      supported: true,
      label: '指纹识别',
      hasFingerprint: true,
    );
  }

  @override
  Future<BiometricAuthOutcome> authenticate({required String reason}) async {
    authenticateCalls++;
    return BiometricAuthOutcome(
      succeeded: nextResult,
      errorMessage: nextResult ? null : '未完成身份验证',
    );
  }
}

class _MockDesktopWindowAdapter implements DesktopWindowAdapter {
  VoidCallback? _onCloseRequested;
  VoidCallback? _onTrayShow;

  int showCount = 0;
  int hideCount = 0;
  int exitCount = 0;

  @override
  bool get isSupported => true;

  @override
  void initialize({
    required VoidCallback onCloseRequested,
    required VoidCallback onTrayShow,
    required VoidCallback onTrayExit,
  }) {
    _onCloseRequested = onCloseRequested;
    _onTrayShow = onTrayShow;
  }

  void triggerCloseRequest() => _onCloseRequested?.call();
  void triggerTrayShow() => _onTrayShow?.call();

  @override
  void showAndFocusWindow() => showCount++;

  @override
  void hideToTray() => hideCount++;

  @override
  void exitApp() => exitCount++;

  @override
  void dispose() {}
}
