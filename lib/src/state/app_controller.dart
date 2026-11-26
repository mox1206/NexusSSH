import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:nexus_ssh/src/desktop/desktop_shortcuts.dart';
import 'package:nexus_ssh/src/desktop/desktop_tray_service.dart';
import 'package:nexus_ssh/src/models/ssh_models.dart';
import 'package:nexus_ssh/src/rust/ssh_bridge.dart';
import 'package:nexus_ssh/src/security/biometric_auth_service.dart';
import 'package:nexus_ssh/src/terminal/command_autocomplete.dart';
import 'package:nexus_ssh/src/terminal/sudo_prompt_detector.dart';
import 'package:nexus_ssh/src/ui/terminal_palettes.dart';
import 'package:nexus_ssh/src/update/app_update_models.dart';
import 'package:nexus_ssh/src/update/app_update_service.dart';
import 'package:xterm3/xterm.dart';

enum SessionDrawerTab { sftp, monitor, snippets }

class TerminalSessionItem {
  TerminalSessionItem({
    required this.id,
    required this.profile,
    required this.terminal,
    required this.controller,
    required ByteConversionSink utf8ByteSink,
    this.isLocal = false,
    this.localShellProgram = '',
    this.localShellName = '',
    this.localCwd = '',
  }) {
    _utf8ByteSink = utf8ByteSink;
  }

  final String id;
  final HostProfile profile;
  final Terminal terminal;
  final TerminalController controller;
  final bool isLocal;
  final String localShellProgram;
  String localShellName;
  final String localCwd;
  bool pendingLocalConnect = false;
  Timer? _localConnectFallbackTimer;
  late ByteConversionSink _utf8ByteSink;

  SessionPhase phase = SessionPhase.connecting;
  String statusMessage = '正在建立 SSH 连接...';
  String? serverFingerprint;
  String? authUsed;
  int? latencyMs;
  int lastCols = 100;
  int lastRows = 30;
  String? remoteTitle;

  // Collapsible right-hand inspector drawer state (Desktop)
  SessionDrawerTab? desktopDrawerTab;

  // Cached SFTP current directory path per session so reopening SFTP stays where you were
  String currentSftpPath = '';

  // Termius-style sudo password autofill prompt state (never auto-sends without tap)
  String? sudoPromptLabel;
  int? sudoPromptIgnoredLineY;

  // Tailscale SSH / ZeroTrust interactive browser authentication URL banner
  String? browserAuthUrl;
  String? dismissedBrowserAuthUrl;

  // Smart command autocomplete state (local history + remote history + snippets + builtin)
  final List<String> localHistory = [];
  List<String> remoteHistory = const [];
  List<AutocompleteSuggestion> autocompleteSuggestions = const [];
  int autocompleteSelectedIndex = 0;
  bool autocompleteNavigated = false;
  bool remoteHistoryLoaded = false;

  AutocompleteShellKind get shellKind =>
      CommandAutocompleteEngine.detectShellKind(
        isLocal: isLocal,
        shellProgram: localShellProgram,
        shellName: localShellName,
      );

  String get tabTitle {
    if (remoteTitle != null && remoteTitle!.trim().isNotEmpty) {
      return remoteTitle!.trim();
    }
    if (isLocal) {
      return localShellName.isNotEmpty ? localShellName : '本地终端';
    }
    return profile.name;
  }

  void appendRawBytes(Uint8List bytes) {
    _utf8ByteSink.add(bytes);
  }

  void resetDecoder(ByteConversionSink newSink) {
    _utf8ByteSink.close();
    _utf8ByteSink = newSink;
  }

  void dispose() {
    _localConnectFallbackTimer?.cancel();
    _localConnectFallbackTimer = null;
    _utf8ByteSink.close();
    controller.dispose();
  }
}

class AppController extends ChangeNotifier {
  AppController({
    required this.backend,
    DesktopWindowAdapter? desktopAdapter,
    BiometricAuthService? biometricService,
    AppUpdateService? updateService,
    this.autoAcceptHostKeys = false,
  }) : _desktopAdapter = desktopAdapter ?? const NoopDesktopWindowAdapter(),
       _biometricService = biometricService ?? const NoopBiometricAuthService(),
       _updateService = updateService ?? AppUpdateService() {
    _outputSub = backend.outputStream.listen(_handleOutputChunk);
    _statusSub = backend.statusStream.listen(_handleStatusEvent);
    _showVirtualKeys = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
  }

  final SshBackend backend;
  final DesktopWindowAdapter _desktopAdapter;
  final BiometricAuthService _biometricService;
  final AppUpdateService _updateService;
  final bool autoAcceptHostKeys;

  UpdateState _updateState = const UpdateState();
  Timer? _startupUpdateTimer;
  DesktopShortcutConfig _shortcutConfig = DesktopShortcutConfig.defaults();
  int _searchFocusRevision = 0;
  bool _shortcutRecordingActive = false;

  late final StreamSubscription<SessionOutputChunk> _outputSub;
  late final StreamSubscription<SessionStatusEvent> _statusSub;

  String _dataDir = '';
  bool _initialized = false;
  String? _initError;
  DesktopCloseBehavior _closeBehavior = DesktopCloseBehavior.ask;
  bool _closePromptPending = false;
  bool _sidebarCollapsed = false;
  bool _sidebarGroupsCollapsed = false;
  bool _sidebarTerminalsCollapsed = false;
  String? _preferredLocalShellId;
  List<HostProfile> _hosts = const [];
  List<SnippetItem> _snippets = const [];
  List<LocalShellOption> _localShells = const [];
  String _searchQuery = '';
  String _selectedGroup = 'All';

  final List<TerminalSessionItem> _sessions = [];
  String? _activeSessionId;

  final List<HostKeyPromptEvent> _pendingHostKeyPrompts = [];
  final Map<String, SftpTransferProgress> _sftpTransfers = {};
  final Map<String, Map<String, String>> _lastSnippetVariables = {};

  String _paletteId = NexusTerminalPalettes.all.first.id;
  double _fontSize = 14.0;
  bool _showVirtualKeys = false;
  bool _autocompleteEnabled = true;
  bool _ctrlArmed = false;
  bool _altArmed = false;
  int _sessionSeq = 0;
  int _transferSeq = 0;

  WebDavConfig _webDavConfig = const WebDavConfig();
  bool _syncingWebDav = false;

  AppLockConfig _appLockConfig = const AppLockConfig();
  BiometricCapability _biometricCapability = BiometricCapability.unsupported;
  bool _isAppLocked = false;
  bool _privacyShieldActive = false;
  DateTime? _backgroundedAt;
  bool _authenticatingBiometrics = false;
  bool _clipboardAutoClearEnabled = true;
  Timer? _clipboardClearTimer;
  String? _lastCopiedSensitiveText;

  bool get initialized => _initialized;
  String? get initError => _initError;
  bool get isDesktopTraySupported => _desktopAdapter.isSupported;
  DesktopCloseBehavior get closeBehavior => _closeBehavior;
  bool get closePromptPending => _closePromptPending;
  bool get sidebarCollapsed => _sidebarCollapsed;
  bool get sidebarGroupsCollapsed => _sidebarGroupsCollapsed;
  bool get sidebarTerminalsCollapsed => _sidebarTerminalsCollapsed;
  AppLockConfig get appLockConfig => _appLockConfig;
  BiometricCapability get biometricCapability => _biometricCapability;
  bool get isAppLocked => _isAppLocked;
  bool get privacyShieldActive => _privacyShieldActive;
  bool get clipboardAutoClearEnabled => _clipboardAutoClearEnabled;
  bool get canUseBiometricsForUnlock =>
      _appLockConfig.enabled &&
      _appLockConfig.biometricsEnabled &&
      _biometricCapability.supported;
  List<HostProfile> get allHosts => _hosts;
  List<SnippetItem> get snippets => _snippets;
  List<LocalShellOption> get localShells => _localShells;
  bool get isLocalTerminalSupported => _localShells.isNotEmpty;
  LocalShellOption? get preferredLocalShell {
    final pref = _preferredLocalShellId?.trim();
    if (pref != null && pref.isNotEmpty) {
      for (final sh in _localShells) {
        if (sh.id == pref || sh.program.toLowerCase() == pref.toLowerCase()) {
          return sh;
        }
      }
    }
    for (final sh in _localShells) {
      if (sh.isDefault) return sh;
    }
    return _localShells.firstOrNull;
  }
  String get searchQuery => _searchQuery;
  String get selectedGroup => _selectedGroup;
  List<TerminalSessionItem> get sessions => List.unmodifiable(_sessions);
  String? get activeSessionId => _activeSessionId;
  TerminalPalettePreset get palette => NexusTerminalPalettes.byId(_paletteId);
  double get fontSize => _fontSize;
  bool get showVirtualKeys => _showVirtualKeys;
  bool get autocompleteEnabled => _autocompleteEnabled;
  bool get ctrlArmed => _ctrlArmed;
  bool get altArmed => _altArmed;
  WebDavConfig get webDavConfig => _webDavConfig;
  bool get syncingWebDav => _syncingWebDav;

  HostKeyPromptEvent? get nextHostKeyPrompt =>
      _pendingHostKeyPrompts.firstOrNull;

  List<SftpTransferProgress> transfersForSession(String sessionId) {
    return _sftpTransfers.values
        .where((t) => t.sessionId == sessionId)
        .toList();
  }

  TerminalSessionItem? get activeSession {
    final id = _activeSessionId;
    if (id == null) return null;
    for (final s in _sessions) {
      if (s.id == id) return s;
    }
    return null;
  }

  List<String> get groups {
    final set = <String>{};
    for (final h in _hosts) {
      final g = h.group.trim();
      if (g.isNotEmpty) set.add(g);
    }
    final sorted = set.toList()..sort();
    return ['All', ...sorted];
  }

  List<HostProfile> get filteredHosts {
    final q = _searchQuery.trim().toLowerCase();
    return _hosts.where((h) {
      if (_selectedGroup != 'All' && h.group != _selectedGroup) {
        return false;
      }
      if (q.isEmpty) return true;
      return h.name.toLowerCase().contains(q) ||
          h.host.toLowerCase().contains(q) ||
          h.username.toLowerCase().contains(q) ||
          h.group.toLowerCase().contains(q);
    }).toList();
  }

  Future<void> initialize(String dataDir) async {
    _dataDir = dataDir;
    _loadDesktopPrefs();
    try {
      _hosts = await backend.init(dataDir);
      _snippets = await backend.listSnippets();
      _webDavConfig = await backend.getWebDavConfig();
      _appLockConfig = await backend.getAppLockConfig();
      try {
        _localShells = await backend.listLocalShells();
      } catch (_) {
        _localShells = const [];
      }
      _biometricCapability = await _biometricService.checkCapability();
      if (_appLockConfig.enabled && _appLockConfig.lockOnStartup) {
        _isAppLocked = true;
      }
      _initError = null;
      if (_webDavConfig.isConfigured && _webDavConfig.autoSync) {
        unawaited(_triggerBackgroundAutoSync(isStartup: true));
      }
    } catch (e) {
      _initError = e.toString();
    } finally {
      _initialized = true;
      notifyListeners();
    }
  }

  void initDesktopTray() {
    if (!_desktopAdapter.isSupported) return;
    _desktopAdapter.initialize(
      onCloseRequested: handleDesktopCloseRequest,
      onTrayShow: () {
        _checkAutoLockOnResume();
        _desktopAdapter.showAndFocusWindow();
      },
      onTrayExit: exitApplication,
    );
  }

  // --- App Lock, Biometrics & Privacy Shield ---

  void onAppLifecycleChanged(AppLifecycleState state) {
    if (!_appLockConfig.enabled) {
      if (_privacyShieldActive) {
        _privacyShieldActive = false;
        notifyListeners();
      }
      return;
    }

    if (_authenticatingBiometrics) {
      // System Face ID / Touch ID / Windows Hello dialog briefly triggers `inactive`
      return;
    }

    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _backgroundedAt ??= DateTime.now();
        var changed = false;
        if (!_privacyShieldActive) {
          _privacyShieldActive = true;
          changed = true;
        }
        if (_appLockConfig.autoLockMinutes == 0 && !_isAppLocked) {
          _isAppLocked = true;
          changed = true;
        }
        if (changed) notifyListeners();
      case AppLifecycleState.resumed:
        var changed = false;
        if (_privacyShieldActive) {
          _privacyShieldActive = false;
          changed = true;
        }
        if (_checkAutoLockOnResume(notify: false)) {
          changed = true;
        }
        if (changed) notifyListeners();
      case AppLifecycleState.detached:
        break;
    }
  }

  bool _checkAutoLockOnResume({bool notify = true}) {
    final bgAt = _backgroundedAt;
    _backgroundedAt = null;
    if (!_appLockConfig.enabled || _isAppLocked || bgAt == null) {
      return false;
    }
    final mins = _appLockConfig.autoLockMinutes;
    if (mins < 0) return false;
    final elapsed = DateTime.now().difference(bgAt);
    if (mins == 0 || elapsed >= Duration(minutes: mins)) {
      _isAppLocked = true;
      if (notify) notifyListeners();
      return true;
    }
    return false;
  }

  void lockNow() {
    if (!_appLockConfig.enabled || _isAppLocked) return;
    _isAppLocked = true;
    _privacyShieldActive = false;
    _backgroundedAt = null;
    notifyListeners();
  }

  Future<bool> unlockWithPasscode(String passcode) async {
    final ok = await backend.verifyAppLockPasscode(passcode);
    if (ok) {
      _isAppLocked = false;
      _privacyShieldActive = false;
      _backgroundedAt = null;
      notifyListeners();
    }
    return ok;
  }

  Future<BiometricAuthOutcome> unlockWithBiometrics({
    String reason = '验证身份以解锁 Nexus SSH',
  }) async {
    if (!canUseBiometricsForUnlock) {
      return const BiometricAuthOutcome(
        succeeded: false,
        errorMessage: '未启用或不支持生物识别',
      );
    }
    _authenticatingBiometrics = true;
    try {
      final outcome = await _biometricService.authenticate(reason: reason);
      if (outcome.succeeded) {
        _isAppLocked = false;
        _privacyShieldActive = false;
        _backgroundedAt = null;
        notifyListeners();
      }
      return outcome;
    } finally {
      _authenticatingBiometrics = false;
    }
  }

  Future<BiometricAuthOutcome> verifyBiometricsForSensitiveAction(
    String reason,
  ) async {
    if (!_biometricCapability.supported) {
      return const BiometricAuthOutcome(
        succeeded: false,
        errorMessage: '当前设备不支持生物识别',
      );
    }
    _authenticatingBiometrics = true;
    try {
      return await _biometricService.authenticate(reason: reason);
    } finally {
      _authenticatingBiometrics = false;
    }
  }

  Future<AppLockConfig> enableOrChangeAppLock({
    required String passcode,
    required bool biometricsEnabled,
    required bool lockOnStartup,
    required int autoLockMinutes,
  }) async {
    final saved = await backend.setAppLockPasscode(
      passcode: passcode,
      biometricsEnabled: biometricsEnabled,
      lockOnStartup: lockOnStartup,
      autoLockMinutes: autoLockMinutes,
    );
    _appLockConfig = saved;
    notifyListeners();
    return saved;
  }

  Future<AppLockConfig> updateAppLockSettings({
    required bool biometricsEnabled,
    required bool lockOnStartup,
    required int autoLockMinutes,
  }) async {
    final saved = await backend.updateAppLockSettings(
      biometricsEnabled: biometricsEnabled,
      lockOnStartup: lockOnStartup,
      autoLockMinutes: autoLockMinutes,
    );
    _appLockConfig = saved;
    notifyListeners();
    return saved;
  }

  Future<AppLockConfig> disableAppLock({
    String currentPasscode = '',
    bool bypassVerified = false,
  }) async {
    final saved = await backend.disableAppLock(
      currentPasscode: currentPasscode,
      bypassVerified: bypassVerified,
    );
    _appLockConfig = saved;
    _isAppLocked = false;
    _privacyShieldActive = false;
    _backgroundedAt = null;
    notifyListeners();
    return saved;
  }

  void handleDesktopCloseRequest() {
    switch (_closeBehavior) {
      case DesktopCloseBehavior.minimizeToTray:
        minimizeToTray();
      case DesktopCloseBehavior.exit:
        exitApplication();
      case DesktopCloseBehavior.ask:
        if (!_closePromptPending) {
          _closePromptPending = true;
          notifyListeners();
        }
    }
  }

  void resolveClosePrompt({
    required DesktopCloseBehavior action,
    required bool remember,
  }) {
    _closePromptPending = false;
    if (remember) {
      setCloseBehavior(action);
    } else {
      notifyListeners();
    }
    if (action == DesktopCloseBehavior.minimizeToTray) {
      minimizeToTray();
    } else if (action == DesktopCloseBehavior.exit) {
      exitApplication();
    }
  }

  void cancelClosePrompt() {
    if (!_closePromptPending) return;
    _closePromptPending = false;
    notifyListeners();
  }

  void setCloseBehavior(DesktopCloseBehavior behavior) {
    _closeBehavior = behavior;
    _saveDesktopPrefs();
    notifyListeners();
  }

  void setSidebarCollapsed(bool collapsed) {
    if (_sidebarCollapsed == collapsed) return;
    _sidebarCollapsed = collapsed;
    _saveDesktopPrefs();
    notifyListeners();
  }

  void toggleSidebarCollapsed() => setSidebarCollapsed(!_sidebarCollapsed);

  void toggleSidebarGroupsCollapsed() {
    _sidebarGroupsCollapsed = !_sidebarGroupsCollapsed;
    _saveDesktopPrefs();
    notifyListeners();
  }

  void toggleSidebarTerminalsCollapsed() {
    _sidebarTerminalsCollapsed = !_sidebarTerminalsCollapsed;
    _saveDesktopPrefs();
    notifyListeners();
  }

  void setClipboardAutoClearEnabled(bool enabled) {
    if (_clipboardAutoClearEnabled == enabled) return;
    _clipboardAutoClearEnabled = enabled;
    if (!enabled) {
      _clipboardClearTimer?.cancel();
      _clipboardClearTimer = null;
      _lastCopiedSensitiveText = null;
    }
    _saveDesktopPrefs();
    notifyListeners();
  }

  /// Copies [text] to the system clipboard and, when [clipboardAutoClearEnabled]
  /// is enabled, automatically clears the clipboard after [clearAfter] only if
  /// the clipboard still holds the exact copied text.
  Future<void> copySensitiveText(
    String text, {
    Duration clearAfter = const Duration(seconds: 30),
  }) async {
    await Clipboard.setData(ClipboardData(text: text));
    _clipboardClearTimer?.cancel();
    _clipboardClearTimer = null;
    if (!_clipboardAutoClearEnabled || text.isEmpty) {
      _lastCopiedSensitiveText = null;
      return;
    }
    _lastCopiedSensitiveText = text;
    _clipboardClearTimer = Timer(clearAfter, () async {
      final expected = _lastCopiedSensitiveText;
      _lastCopiedSensitiveText = null;
      if (expected == null) return;
      try {
        final current = await Clipboard.getData(Clipboard.kTextPlain);
        if (current?.text == expected) {
          await Clipboard.setData(const ClipboardData(text: ''));
        }
      } catch (_) {}
    });
  }

  void minimizeToTray() {
    if (_appLockConfig.enabled) {
      _backgroundedAt ??= DateTime.now();
      if (_appLockConfig.autoLockMinutes == 0 && !_isAppLocked) {
        _isAppLocked = true;
        notifyListeners();
      }
    }
    _desktopAdapter.hideToTray();
  }

  void exitApplication() {
    _closePromptPending = false;
    backend.prepareShutdown();
    _desktopAdapter.exitApp();
  }

  File? get _desktopPrefsFile {
    if (_dataDir.trim().isEmpty) return null;
    return File('$_dataDir${Platform.pathSeparator}desktop_prefs_v1.json');
  }

  void _loadDesktopPrefs() {
    final file = _desktopPrefsFile;
    if (file == null || !file.existsSync()) return;
    try {
      final raw = jsonDecode(file.readAsStringSync());
      if (raw is Map<String, dynamic>) {
        _closeBehavior = DesktopCloseBehavior.fromStorage(
          raw['close_behavior'] as String?,
        );
        if (raw['clipboard_auto_clear'] is bool) {
          _clipboardAutoClearEnabled = raw['clipboard_auto_clear'] as bool;
        }
        if (raw['sidebar_collapsed'] is bool) {
          _sidebarCollapsed = raw['sidebar_collapsed'] as bool;
        }
        if (raw['sidebar_groups_collapsed'] is bool) {
          _sidebarGroupsCollapsed = raw['sidebar_groups_collapsed'] as bool;
        }
        if (raw['sidebar_terminals_collapsed'] is bool) {
          _sidebarTerminalsCollapsed =
              raw['sidebar_terminals_collapsed'] as bool;
        }
        if (raw['preferred_local_shell_id'] is String &&
            (raw['preferred_local_shell_id'] as String).trim().isNotEmpty) {
          _preferredLocalShellId =
              (raw['preferred_local_shell_id'] as String).trim();
        }
        final savedIgnoredVersion = raw['ignored_update_version'] is String
            ? (raw['ignored_update_version'] as String).trim()
            : '';
        final savedMirrorPrefix = raw['update_mirror_prefix'] is String
            ? (raw['update_mirror_prefix'] as String).trim()
            : '';
        if (savedIgnoredVersion.isNotEmpty || savedMirrorPrefix.isNotEmpty) {
          _updateState = _updateState.copyWith(
            ignoredVersion: savedIgnoredVersion,
            mirrorPrefix: savedMirrorPrefix,
          );
        }
        if (raw['shortcuts'] is Map) {
          _shortcutConfig = DesktopShortcutConfig.fromJson(raw['shortcuts']);
        }
      }
    } catch (_) {}
  }

  void _saveDesktopPrefs() {
    final file = _desktopPrefsFile;
    if (file == null) return;
    try {
      if (!file.parent.existsSync()) {
        file.parent.createSync(recursive: true);
      }
      file.writeAsStringSync(
        jsonEncode({
          'close_behavior': _closeBehavior.storageValue,
          'clipboard_auto_clear': _clipboardAutoClearEnabled,
          'sidebar_collapsed': _sidebarCollapsed,
          'sidebar_groups_collapsed': _sidebarGroupsCollapsed,
          'sidebar_terminals_collapsed': _sidebarTerminalsCollapsed,
          if (_preferredLocalShellId != null &&
              _preferredLocalShellId!.isNotEmpty)
            'preferred_local_shell_id': _preferredLocalShellId,
          if (_updateState.ignoredVersion.isNotEmpty)
            'ignored_update_version': _updateState.ignoredVersion,
          if (_updateState.mirrorPrefix.isNotEmpty)
            'update_mirror_prefix': _updateState.mirrorPrefix,
          'shortcuts': _shortcutConfig.toJson(),
        }),
      );
    } catch (_) {}
  }

  // --- Desktop Keyboard Shortcuts ---

  DesktopShortcutConfig get shortcutConfig => _shortcutConfig;
  int get searchFocusRevision => _searchFocusRevision;
  bool get shortcutRecordingActive => _shortcutRecordingActive;

  void setShortcutRecordingActive(bool active) {
    if (_shortcutRecordingActive == active) return;
    _shortcutRecordingActive = active;
  }

  void setShortcutPreset(ShortcutPreset preset) {
    final base = DesktopShortcutConfig.defaults(preset: preset);
    _shortcutConfig = base.copyWith(
      smartCtrlCCopy: _shortcutConfig.smartCtrlCCopy,
      rightClickQuickPaste: _shortcutConfig.rightClickQuickPaste,
    );
    _saveDesktopPrefs();
    notifyListeners();
  }

  void setShortcutBinding(
    ShortcutAction action,
    ShortcutBinding? binding, {
    bool clearConflicting = true,
  }) {
    final updated = Map<ShortcutAction, ShortcutBinding?>.from(
      _shortcutConfig.bindings,
    );
    if (binding != null && clearConflicting) {
      for (final entry in _shortcutConfig.bindings.entries) {
        if (entry.key != action && entry.value == binding) {
          updated[entry.key] = null;
        }
      }
    }
    updated[action] = binding;
    _shortcutConfig = _shortcutConfig.copyWith(
      bindings: Map.unmodifiable(updated),
    );
    _saveDesktopPrefs();
    notifyListeners();
  }

  void resetShortcuts() {
    _shortcutConfig = DesktopShortcutConfig.defaults(
      preset: _shortcutConfig.preset,
    );
    _saveDesktopPrefs();
    notifyListeners();
  }

  void setSmartCtrlCCopy(bool enabled) {
    if (_shortcutConfig.smartCtrlCCopy == enabled) return;
    _shortcutConfig = _shortcutConfig.copyWith(smartCtrlCCopy: enabled);
    _saveDesktopPrefs();
    notifyListeners();
  }

  void setRightClickQuickPaste(bool enabled) {
    if (_shortcutConfig.rightClickQuickPaste == enabled) return;
    _shortcutConfig = _shortcutConfig.copyWith(rightClickQuickPaste: enabled);
    _saveDesktopPrefs();
    notifyListeners();
  }

  void requestSearchFocus() {
    _activeSessionId = null;
    _searchFocusRevision++;
    notifyListeners();
  }

  void selectNextSession() {
    if (_sessions.isEmpty) return;
    final idx = _sessions.indexWhere((s) => s.id == _activeSessionId);
    final nextIdx = idx < 0 ? 0 : (idx + 1) % _sessions.length;
    selectSession(_sessions[nextIdx].id);
  }

  void selectPreviousSession() {
    if (_sessions.isEmpty) return;
    final idx = _sessions.indexWhere((s) => s.id == _activeSessionId);
    final prevIdx = idx < 0
        ? _sessions.length - 1
        : (idx - 1 + _sessions.length) % _sessions.length;
    selectSession(_sessions[prevIdx].id);
  }

  void selectSessionByIndex(int index) {
    if (index < 0 || index >= _sessions.length) return;
    selectSession(_sessions[index].id);
  }

  // --- App Auto-Update ---

  UpdateState get updateState => _updateState;
  bool get hasUnignoredUpdate => _updateState.hasUnignoredUpdate;
  bool get supportsInAppUpdateInstall => _updateService.supportsInAppInstall;

  void scheduleStartupUpdateCheck({
    Duration delay = const Duration(seconds: 3),
  }) {
    _startupUpdateTimer?.cancel();
    _startupUpdateTimer = Timer(delay, () {
      unawaited(checkForUpdates(silent: true));
    });
  }

  Future<void> checkForUpdates({bool silent = false}) async {
    if (_updateState.isBusy) return;
    final current = await _updateService.getCurrentVersion();
    if (!silent) {
      _updateState = _updateState.copyWith(
        phase: UpdatePhase.checking,
        currentVersion: current,
        clearErrorMessage: true,
        clearStatusMessage: true,
      );
      notifyListeners();
    } else {
      _updateState = _updateState.copyWith(currentVersion: current);
    }

    try {
      final manifest = await _updateService.fetchLatestManifest(
        mirrorPrefix: _updateState.mirrorPrefix,
      );
      final asset = await _updateService.selectAssetForCurrentPlatform(
        manifest,
      );
      final isNewer = manifest.versionInfo.isNewerThan(current);

      _updateState = _updateState.copyWith(
        phase: isNewer ? UpdatePhase.available : UpdatePhase.upToDate,
        currentVersion: current,
        manifest: manifest,
        matchedAsset: asset,
        clearMatchedAsset: asset == null,
        clearDownloadedFilePath: true,
        downloadedBytes: 0,
        totalBytes: asset?.size ?? 0,
        clearErrorMessage: true,
        statusMessage: isNewer
            ? '发现新版本 v${manifest.version}'
            : '当前已是最新版本 (${current.displayLabel})',
        lastCheckedAt: DateTime.now(),
      );
      notifyListeners();
    } catch (e) {
      if (silent) {
        return;
      }
      _updateState = _updateState.copyWith(
        phase: UpdatePhase.error,
        currentVersion: current,
        errorMessage: _formatUpdateError(e),
        clearStatusMessage: true,
        lastCheckedAt: DateTime.now(),
      );
      notifyListeners();
    }
  }

  Future<void> downloadAvailableUpdate() async {
    final asset = _updateState.matchedAsset;
    if (asset == null || _updateState.isBusy) return;

    _updateState = _updateState.copyWith(
      phase: UpdatePhase.downloading,
      downloadedBytes: 0,
      totalBytes: asset.size,
      clearErrorMessage: true,
      statusMessage: '正在下载 ${asset.fileName}...',
    );
    notifyListeners();

    try {
      final filePath = await _updateService.downloadAndVerifyAsset(
        asset,
        mirrorPrefix: _updateState.mirrorPrefix,
        onProgress: (received, total) {
          _updateState = _updateState.copyWith(
            phase: UpdatePhase.downloading,
            downloadedBytes: received,
            totalBytes: total > 0 ? total : asset.size,
          );
          notifyListeners();
        },
        onVerifying: () {
          _updateState = _updateState.copyWith(
            phase: UpdatePhase.verifying,
            statusMessage: '正在校验 SHA-256 完整性...',
          );
          notifyListeners();
        },
      );

      _updateState = _updateState.copyWith(
        phase: UpdatePhase.readyToInstall,
        downloadedFilePath: filePath,
        downloadedBytes: asset.size > 0
            ? asset.size
            : _updateState.downloadedBytes,
        totalBytes: asset.size > 0 ? asset.size : _updateState.totalBytes,
        clearErrorMessage: true,
        statusMessage: 'SHA-256 校验通过，已准备就绪',
      );
      notifyListeners();
    } catch (e) {
      _updateState = _updateState.copyWith(
        phase: UpdatePhase.error,
        errorMessage: _formatUpdateError(e),
        clearStatusMessage: true,
      );
      notifyListeners();
    }
  }

  /// Launches platform-specific installation for a downloaded & verified update.
  /// Returns an optional status message to display to the user.
  Future<String?> installDownloadedUpdate() async {
    final filePath = _updateState.downloadedFilePath;
    if (filePath == null || filePath.isEmpty) {
      return '请先下载更新包';
    }

    _updateState = _updateState.copyWith(
      phase: UpdatePhase.installing,
      clearErrorMessage: true,
      statusMessage: '正在启动更新安装...',
    );
    notifyListeners();

    try {
      if (!kIsWeb && Platform.isWindows) {
        await _updateService.launchWindowsSelfUpdate(
          zipFilePath: filePath,
          onRequestExit: exitApplication,
        );
        return '正在退出并自动应用更新...';
      }
      if (!kIsWeb && Platform.isAndroid) {
        final outcome = await _updateService.launchAndroidApkInstall(filePath);
        _updateState = _updateState.copyWith(
          phase: UpdatePhase.readyToInstall,
          statusMessage: outcome == 'permission_required'
              ? '请允许「安装未知应用」权限后再次点击安装'
              : '已拉起系统安装器',
        );
        notifyListeners();
        return _updateState.statusMessage;
      }
      await openUpdateReleasePage();
      _updateState = _updateState.copyWith(
        phase: UpdatePhase.readyToInstall,
        statusMessage: '已打开 GitHub Release 页面',
      );
      notifyListeners();
      return _updateState.statusMessage;
    } catch (e) {
      _updateState = _updateState.copyWith(
        phase: UpdatePhase.error,
        errorMessage: _formatUpdateError(e),
        clearStatusMessage: true,
      );
      notifyListeners();
      return _updateState.errorMessage;
    }
  }

  void ignoreAvailableUpdate() {
    final version = _updateState.manifest?.version ?? '';
    if (version.isEmpty) return;
    _updateState = _updateState.copyWith(ignoredVersion: version);
    _saveDesktopPrefs();
    notifyListeners();
  }

  void setUpdateMirrorPrefix(String prefix) {
    final cleaned = prefix.trim();
    _updateState = _updateState.copyWith(mirrorPrefix: cleaned);
    _saveDesktopPrefs();
    notifyListeners();
  }

  Future<bool> openUpdateReleasePage() {
    final url =
        _updateState.manifest?.releaseUrl ??
        AppUpdateConfig.defaultReleasesPageUrl;
    return openExternalUrl(url);
  }

  String _formatUpdateError(Object e) {
    final raw = e.toString();
    if (raw.startsWith('Bad state: ')) {
      return raw.substring('Bad state: '.length);
    }
    if (raw.startsWith('HttpException: ')) {
      return raw.substring('HttpException: '.length).split(',').first.trim();
    }
    if (raw.contains('SocketException') ||
        raw.contains('TimeoutException') ||
        raw.contains('HandshakeException')) {
      return '无法连接到 GitHub 更新源，可在下方配置加速镜像后重试';
    }
    return raw;
  }

  Future<void> refreshHosts() async {
    _hosts = await backend.listHosts();
    notifyListeners();
  }

  HostProfile? findHostById(String? hostId) {
    final trimmed = hostId?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    for (final h in _hosts) {
      if (h.id == trimmed) return h;
    }
    return null;
  }

  /// Resolves the ordered ProxyJump chain from outermost bastion to immediate
  /// jump host (excluding [profile] itself). Cycle-safe.
  List<HostProfile> resolveProxyJumpChain(HostProfile profile) {
    final first = profile.jumpHostId?.trim();
    if (first == null || first.isEmpty) return const [];
    final visited = <String>{if (profile.id.trim().isNotEmpty) profile.id.trim()};
    final reversed = <HostProfile>[];
    String? cursor = first;
    while (cursor != null && cursor.isNotEmpty && reversed.length < 5) {
      if (!visited.add(cursor)) break;
      final hop = findHostById(cursor);
      if (hop == null) break;
      reversed.add(hop);
      cursor = hop.jumpHostId?.trim();
    }
    return reversed.reversed.toList();
  }

  /// Returns saved hosts that can safely act as a ProxyJump host for [selfId]
  /// without creating self-references or routing loops.
  List<HostProfile> eligibleProxyJumpHostsFor(String selfId) {
    final trimmedSelf = selfId.trim();
    final eligible = <HostProfile>[];
    for (final candidate in _hosts) {
      if (candidate.id.isEmpty) continue;
      if (trimmedSelf.isNotEmpty && candidate.id == trimmedSelf) continue;
      if (trimmedSelf.isNotEmpty) {
        final chain = resolveProxyJumpChain(candidate);
        if (chain.any((h) => h.id == trimmedSelf)) continue;
        if (chain.length >= 4) continue;
      }
      eligible.add(candidate);
    }
    return eligible;
  }

  Future<void> refreshSnippets() async {
    _snippets = await backend.listSnippets();
    notifyListeners();
  }

  void setSearchQuery(String query) {
    if (_searchQuery == query) return;
    _searchQuery = query;
    notifyListeners();
  }

  void setSelectedGroup(String group) {
    if (_selectedGroup == group) return;
    _selectedGroup = group;
    notifyListeners();
  }

  void showHostsVault() {
    if (_activeSessionId == null) return;
    _activeSessionId = null;
    notifyListeners();
  }

  void selectSession(String sessionId) {
    if (_activeSessionId == sessionId) return;
    _activeSessionId = sessionId;
    notifyListeners();
  }

  void toggleSessionDrawer(String sessionId, SessionDrawerTab tab) {
    final item = _sessions.where((s) => s.id == sessionId).firstOrNull;
    if (item == null) return;
    if (item.desktopDrawerTab == tab) {
      item.desktopDrawerTab = null;
    } else {
      item.desktopDrawerTab = tab;
    }
    notifyListeners();
  }

  void closeSessionDrawer(String sessionId) {
    final item = _sessions.where((s) => s.id == sessionId).firstOrNull;
    if (item == null || item.desktopDrawerTab == null) return;
    item.desktopDrawerTab = null;
    notifyListeners();
  }

  void setPalette(String id) {
    _paletteId = id;
    notifyListeners();
  }

  void adjustFontSize(double delta) {
    _fontSize = (_fontSize + delta).clamp(10.0, 26.0);
    notifyListeners();
  }

  void resetFontSize() {
    if (_fontSize == 14.0) return;
    _fontSize = 14.0;
    notifyListeners();
  }

  void toggleVirtualKeys() {
    _showVirtualKeys = !_showVirtualKeys;
    notifyListeners();
  }

  void toggleAutocomplete() {
    _autocompleteEnabled = !_autocompleteEnabled;
    if (!_autocompleteEnabled) {
      for (final s in _sessions) {
        s.autocompleteSuggestions = const [];
      }
    } else {
      for (final s in _sessions) {
        _refreshAutocompleteSuggestions(s, notify: false);
      }
    }
    notifyListeners();
  }

  void toggleCtrlArmed() {
    _ctrlArmed = !_ctrlArmed;
    notifyListeners();
  }

  void toggleAltArmed() {
    _altArmed = !_altArmed;
    notifyListeners();
  }

  Future<HostProfile> saveHost(HostProfile profile) async {
    final saved = await backend.upsertHost(profile);
    await refreshHosts();
    if (_webDavConfig.isConfigured && _webDavConfig.autoSync) {
      unawaited(_triggerBackgroundAutoSync(isStartup: false));
    }
    return saved;
  }

  Future<void> removeHost(String hostId) async {
    await backend.deleteHost(hostId);
    await refreshHosts();
    if (_selectedGroup != 'All' && !groups.contains(_selectedGroup)) {
      _selectedGroup = 'All';
      notifyListeners();
    }
    // Intentionally do NOT auto-sync deletions to cloud so a local removal
    // never silently wipes cloud backups when the user intends to re-pull.
  }

  // --- Snippets Actions ---

  Future<SnippetItem> saveSnippet(SnippetItem snippet) async {
    final saved = await backend.upsertSnippet(snippet);
    await refreshSnippets();
    if (_webDavConfig.isConfigured && _webDavConfig.autoSync) {
      unawaited(_triggerBackgroundAutoSync(isStartup: false));
    }
    return saved;
  }

  Future<void> removeSnippet(String snippetId) async {
    await backend.deleteSnippet(snippetId);
    await refreshSnippets();
    // Intentionally do NOT auto-sync deletions to cloud.
  }

  void executeSnippetInSession(String sessionId, SnippetItem snippet) {
    executeCommandInSession(
      sessionId,
      snippet.command,
      autoEnter: snippet.autoEnter,
    );
  }

  void executeCommandInSession(
    String sessionId,
    String command, {
    bool autoEnter = true,
  }) {
    final payload = autoEnter ? '$command\r' : command;
    backend.writeSession(sessionId, Uint8List.fromList(utf8.encode(payload)));
  }

  Map<String, String> getLastSnippetVariables(String snippetId) {
    return Map<String, String>.from(_lastSnippetVariables[snippetId] ?? const {});
  }

  void rememberSnippetVariables(String snippetId, Map<String, String> values) {
    if (snippetId.isEmpty) return;
    _lastSnippetVariables[snippetId] = Map<String, String>.from(values);
  }

  // --- Known Hosts (TOFU) ---

  Future<void> respondHostKeyPrompt(
    String requestId, {
    required bool accept,
    bool persist = true,
  }) async {
    _pendingHostKeyPrompts.removeWhere((p) => p.requestId == requestId);
    notifyListeners();
    await backend.respondHostKey(
      requestId: requestId,
      accept: accept,
      persist: persist,
    );
  }

  Future<List<KnownHostEntry>> listKnownHosts() => backend.listKnownHosts();
  Future<bool> deleteKnownHost(String hostKey) =>
      backend.deleteKnownHost(hostKey);

  // --- SFTP & Server Telemetry ---

  Future<SftpDirListing> sftpListDir(String sessionId, {String path = ''}) async {
    final listing = await backend.sftpListDir(sessionId, path: path);
    final item = _sessions.where((s) => s.id == sessionId).firstOrNull;
    if (item != null) {
      item.currentSftpPath = listing.currentPath;
    }
    return listing;
  }

  Future<void> sftpMkdir(String sessionId, String path) =>
      backend.sftpMkdir(sessionId, path);

  Future<void> sftpRename(String sessionId, String oldPath, String newPath) =>
      backend.sftpRename(sessionId, oldPath, newPath);

  Future<void> sftpDelete(
    String sessionId,
    String path, {
    required bool isDir,
  }) => backend.sftpDelete(sessionId, path, isDir: isDir);

  Future<void> sftpChmod(String sessionId, String path, int modeOctal) =>
      backend.sftpChmod(sessionId, path, modeOctal);

  Future<int> sftpDownload({
    required String sessionId,
    required String remotePath,
    required String localPath,
  }) {
    _transferSeq += 1;
    final tid = 'dl_${DateTime.now().millisecondsSinceEpoch}_$_transferSeq';
    return backend.sftpDownload(
      sessionId: sessionId,
      transferId: tid,
      remotePath: remotePath,
      localPath: localPath,
    );
  }

  Future<int> sftpUpload({
    required String sessionId,
    required String localPath,
    required String remotePath,
  }) {
    _transferSeq += 1;
    final tid = 'ul_${DateTime.now().millisecondsSinceEpoch}_$_transferSeq';
    return backend.sftpUpload(
      sessionId: sessionId,
      transferId: tid,
      localPath: localPath,
      remotePath: remotePath,
    );
  }

  Future<ServerMetrics> fetchServerMetrics(String sessionId) =>
      backend.fetchServerMetrics(sessionId);

  // --- WebDAV & Helpers ---

  Future<WebDavConfig> saveWebDavConfig(WebDavConfig config) async {
    _webDavConfig = await backend.saveWebDavConfig(config);
    notifyListeners();
    return _webDavConfig;
  }

  Future<ConnectionTestResult> testWebDav(WebDavConfig config) {
    return backend.testWebDav(config);
  }

  Future<WebDavSyncResult> syncWebDav({
    WebDavConfig? config,
    SyncMode? mode,
  }) async {
    final effectiveMode =
        mode ?? config?.defaultSyncMode ?? _webDavConfig.defaultSyncMode;
    _syncingWebDav = true;
    notifyListeners();
    try {
      final res = await backend.syncWebDav(config: config, mode: effectiveMode);
      _hosts = res.hosts;
      _snippets = res.snippets.isNotEmpty
          ? res.snippets
          : await backend.listSnippets();
      _webDavConfig = await backend.getWebDavConfig();
      if (_selectedGroup != 'All' && !groups.contains(_selectedGroup)) {
        _selectedGroup = 'All';
      }
      return res;
    } finally {
      _syncingWebDav = false;
      notifyListeners();
    }
  }

  Future<void> _triggerBackgroundAutoSync({required bool isStartup}) async {
    if (_syncingWebDav || !_webDavConfig.isConfigured || !_webDavConfig.autoSync) {
      return;
    }
    final mode = _webDavConfig.defaultSyncMode;
    // Never overwrite cloud blindly on startup, and never clobber a freshly
    // edited local record when configured in pull-only mode.
    if (isStartup && mode == SyncMode.pushOverwrite) return;
    if (!isStartup && mode == SyncMode.pullOverwrite) return;
    try {
      await syncWebDav(mode: mode);
    } catch (_) {}
  }

  Future<QuickConnectTarget> parseQuickConnect(String expr) {
    return backend.parseQuickConnect(expr);
  }

  Future<KeyInspectionResult> inspectPrivateKey({
    String pemContent = '',
    String filePath = '',
    String passphrase = '',
  }) {
    return backend.inspectPrivateKey(
      pemContent: pemContent,
      filePath: filePath,
      passphrase: passphrase,
    );
  }

  Future<List<DiscoveredSshKey>> discoverLocalKeys() {
    return backend.discoverLocalKeys();
  }

  Future<ConnectionTestResult> testConnection(HostProfile profile) {
    return backend.testConnection(profile);
  }

  ByteConversionSink _buildUtf8SinkForTerminal(Terminal terminal) {
    return const Utf8Decoder(allowMalformed: true).startChunkedConversion(
      _ImmediateTerminalStringSink((decoded) {
        if (decoded.isNotEmpty) {
          terminal.write(decoded);
        }
      }),
    );
  }

  TerminalTargetPlatform _hostTerminalPlatform() {
    if (kIsWeb) return TerminalTargetPlatform.web;
    if (Platform.isWindows) return TerminalTargetPlatform.windows;
    if (Platform.isMacOS) return TerminalTargetPlatform.macos;
    if (Platform.isLinux) return TerminalTargetPlatform.linux;
    if (Platform.isAndroid) return TerminalTargetPlatform.android;
    if (Platform.isIOS) return TerminalTargetPlatform.ios;
    return TerminalTargetPlatform.unknown;
  }

  Future<String> openSession(HostProfile profile) async {
    _sessionSeq += 1;
    final sessionId =
        'sess_${DateTime.now().millisecondsSinceEpoch}_$_sessionSeq';

    late final TerminalSessionItem sessionItem;
    final terminal = Terminal(
      maxLines: 5000,
      platform: _hostTerminalPlatform(),
      onTitleChange: (title) {
        sessionItem.remoteTitle = title;
        notifyListeners();
      },
      onClipboardStore: (_, text) {
        copySensitiveText(text);
      },
      onOpenUrl: (url) {
        unawaited(openExternalUrl(url));
      },
      onOutput: (String data) {
        _sendTerminalInput(sessionId, data);
      },
      onResize: (int cols, int rows, int pixW, int pixH) {
        sessionItem.lastCols = cols;
        sessionItem.lastRows = rows;
        backend.resizeSession(
          sessionId,
          cols: cols,
          rows: rows,
          pixelWidth: pixW,
          pixelHeight: pixH,
        );
      },
    );
    terminal.onReply = (String data) {
      if (data.isEmpty) return;
      backend.writeSession(sessionId, Uint8List.fromList(utf8.encode(data)));
    };

    sessionItem = TerminalSessionItem(
      id: sessionId,
      profile: profile,
      terminal: terminal,
      controller: TerminalController(),
      utf8ByteSink: _buildUtf8SinkForTerminal(terminal),
    );

    _sessions.add(sessionItem);
    _activeSessionId = sessionId;
    notifyListeners();

    _writeBannerLine(
      terminal,
      '\x1b[38;5;244m╭─ Nexus SSH · Powered by Rust (russh)\x1b[0m',
    );
    if (profile.usesProxyJump) {
      final chain = resolveProxyJumpChain(profile);
      final hopNames = chain.isEmpty
          ? 'ProxyJump'
          : chain.map((h) => h.name).join(' → ');
      _writeBannerLine(
        terminal,
        '\x1b[38;5;244m├─ ProxyJump: \x1b[36m$hopNames\x1b[0;38;5;244m → \x1b[1;36m${profile.addressLabel}\x1b[0m',
      );
    } else {
      _writeBannerLine(
        terminal,
        '\x1b[38;5;244m╰─ 正在连接 \x1b[1;36m${profile.addressLabel}\x1b[0;38;5;244m ...\x1b[0m',
      );
    }

    try {
      await backend.connectSession(
        sessionId: sessionId,
        profile: profile,
        cols: sessionItem.lastCols,
        rows: sessionItem.lastRows,
      );
    } catch (e) {
      sessionItem.phase = SessionPhase.error;
      sessionItem.statusMessage = e.toString();
      _writeBannerLine(terminal, '\x1b[1;31m✖ 启动连接失败: $e\x1b[0m');
      notifyListeners();
    }

    return sessionId;
  }

  Future<String> openLocalSession({
    LocalShellOption? shell,
    String cwd = '',
  }) async {
    _sessionSeq += 1;
    final sessionId =
        'local_${DateTime.now().millisecondsSinceEpoch}_$_sessionSeq';

    final chosen = shell ?? preferredLocalShell;
    if (shell != null) {
      final prefKey = shell.id.trim().isNotEmpty
          ? shell.id.trim()
          : shell.program.trim();
      if (prefKey.isNotEmpty && _preferredLocalShellId != prefKey) {
        _preferredLocalShellId = prefKey;
        _saveDesktopPrefs();
      }
    }
    final shellName = chosen?.name ?? '本地终端';
    final shellProgram = chosen?.program ?? '';

    late final TerminalSessionItem sessionItem;
    final terminal = Terminal(
      maxLines: 5000,
      platform: _hostTerminalPlatform(),
      onTitleChange: (title) {
        sessionItem.remoteTitle = title;
        notifyListeners();
      },
      onClipboardStore: (_, text) {
        copySensitiveText(text);
      },
      onOpenUrl: (url) {
        unawaited(openExternalUrl(url));
      },
      onOutput: (String data) {
        _sendTerminalInput(sessionId, data);
      },
      onResize: (int cols, int rows, int pixW, int pixH) {
        sessionItem.lastCols = cols;
        sessionItem.lastRows = rows;
        if (sessionItem.pendingLocalConnect) {
          unawaited(_startPendingLocalSession(sessionItem, cols, rows));
          return;
        }
        backend.resizeSession(
          sessionId,
          cols: cols,
          rows: rows,
          pixelWidth: pixW,
          pixelHeight: pixH,
        );
      },
    );
    terminal.onReply = (String data) {
      if (data.isEmpty) return;
      backend.writeSession(sessionId, Uint8List.fromList(utf8.encode(data)));
    };

    sessionItem = TerminalSessionItem(
      id: sessionId,
      profile: HostProfile(
        id: 'local',
        name: shellName,
        host: 'localhost',
        username: 'local',
      ),
      terminal: terminal,
      controller: TerminalController(),
      utf8ByteSink: _buildUtf8SinkForTerminal(terminal),
      isLocal: true,
      localShellProgram: shellProgram,
      localShellName: shellName,
      localCwd: cwd,
    );
    sessionItem.pendingLocalConnect = true;
    sessionItem.lastCols = terminal.viewWidth;
    sessionItem.lastRows = terminal.viewHeight;

    _sessions.add(sessionItem);
    _activeSessionId = sessionId;
    notifyListeners();

    // Defer spawning the local ConPTY until TerminalView reports its real
    // laid-out (cols, rows) on the next frame so Windows PowerShell never
    // suffers a startup ResizePseudoConsole race. Fallback timer ensures
    // headless tests without a mounted TerminalView still connect promptly.
    sessionItem._localConnectFallbackTimer = Timer(
      const Duration(milliseconds: 120),
      () {
        if (sessionItem.pendingLocalConnect &&
            _sessions.any((s) => s.id == sessionId)) {
          unawaited(
            _startPendingLocalSession(
              sessionItem,
              sessionItem.terminal.viewWidth,
              sessionItem.terminal.viewHeight,
            ),
          );
        }
      },
    );

    return sessionId;
  }

  /// Called by [TerminalSessionView] immediately after its first layout frame
  /// so pending local PTY sessions spawn with the exact measured grid size
  /// (even when the measured size happens to equal Terminal's default 80x24).
  void notifyTerminalViewLaidOut(
    String sessionId, {
    required int cols,
    required int rows,
  }) {
    final item = _sessions.where((s) => s.id == sessionId).firstOrNull;
    if (item == null || !item.pendingLocalConnect) return;
    unawaited(_startPendingLocalSession(item, cols, rows));
  }

  Future<void> _startPendingLocalSession(
    TerminalSessionItem sessionItem,
    int cols,
    int rows,
  ) async {
    if (!sessionItem.pendingLocalConnect) return;
    sessionItem.pendingLocalConnect = false;
    sessionItem._localConnectFallbackTimer?.cancel();
    sessionItem._localConnectFallbackTimer = null;
    sessionItem.lastCols = cols;
    sessionItem.lastRows = rows;

    try {
      final resolvedName = await backend.connectLocalSession(
        sessionId: sessionItem.id,
        shellProgram: sessionItem.localShellProgram,
        cwd: sessionItem.localCwd,
        cols: cols,
        rows: rows,
      );
      if (resolvedName.trim().isNotEmpty &&
          sessionItem.localShellName != resolvedName.trim()) {
        sessionItem.localShellName = resolvedName.trim();
        notifyListeners();
      }
    } catch (e) {
      sessionItem.phase = SessionPhase.error;
      sessionItem.statusMessage = e.toString();
      _writeBannerLine(sessionItem.terminal, '\x1b[1;31m✖ 启动本地终端失败: $e\x1b[0m');
      notifyListeners();
    }
  }

  Future<void> reconnectSession(String sessionId) async {
    final item = _sessions.where((s) => s.id == sessionId).firstOrNull;
    if (item == null) return;

    backend.disconnectSession(sessionId);
    item.resetDecoder(_buildUtf8SinkForTerminal(item.terminal));
    item.phase = SessionPhase.connecting;
    item.statusMessage = item.isLocal ? '正在重新启动本地终端...' : '正在重新连接...';
    notifyListeners();

    if (item.isLocal) {
      _writeBannerLine(item.terminal, '');
      try {
        await backend.connectLocalSession(
          sessionId: sessionId,
          shellProgram: item.localShellProgram,
          cwd: item.localCwd,
          cols: item.lastCols,
          rows: item.lastRows,
        );
      } catch (e) {
        item.phase = SessionPhase.error;
        item.statusMessage = e.toString();
        _writeBannerLine(item.terminal, '\x1b[1;31m✖ 重启本地终端失败: $e\x1b[0m');
        notifyListeners();
      }
      return;
    }

    _writeBannerLine(item.terminal, '');
    _writeBannerLine(
      item.terminal,
      '\x1b[38;5;244m↻ 正在重新连接 \x1b[1;36m${item.profile.addressLabel}\x1b[0m',
    );

    try {
      await backend.connectSession(
        sessionId: sessionId,
        profile: item.profile,
        cols: item.lastCols,
        rows: item.lastRows,
      );
    } catch (e) {
      item.phase = SessionPhase.error;
      item.statusMessage = e.toString();
      _writeBannerLine(item.terminal, '\x1b[1;31m✖ 重连失败: $e\x1b[0m');
      notifyListeners();
    }
  }

  void disconnectSession(String sessionId) {
    backend.disconnectSession(sessionId);
  }

  void closeSessionTab(String sessionId) {
    final idx = _sessions.indexWhere((s) => s.id == sessionId);
    if (idx < 0) return;

    backend.disconnectSession(sessionId);
    _pendingHostKeyPrompts.removeWhere((p) => p.sessionId == sessionId);
    _sftpTransfers.removeWhere((_, t) => t.sessionId == sessionId);
    final removed = _sessions.removeAt(idx);
    removed.dispose();

    if (_activeSessionId == sessionId) {
      if (_sessions.isEmpty) {
        _activeSessionId = null;
      } else {
        final nextIdx = idx >= _sessions.length ? _sessions.length - 1 : idx;
        _activeSessionId = _sessions[nextIdx].id;
      }
    }
    notifyListeners();
  }

  void sendVirtualKey(String sessionId, TerminalKey key) {
    final item = _sessions.where((s) => s.id == sessionId).firstOrNull;
    if (item == null) return;
    final ctrl = _ctrlArmed;
    final alt = _altArmed;
    if (ctrl || alt) {
      _ctrlArmed = false;
      _altArmed = false;
      notifyListeners();
    }

    final popupVisible =
        !ctrl &&
        !alt &&
        item.phase == SessionPhase.connected &&
        _autocompleteEnabled &&
        item.sudoPromptLabel == null &&
        item.autocompleteSuggestions.isNotEmpty;

    if (popupVisible) {
      if (key == TerminalKey.arrowDown) {
        moveAutocompleteSelection(sessionId, 1);
        return;
      }
      if (key == TerminalKey.arrowUp) {
        moveAutocompleteSelection(sessionId, -1);
        return;
      }
      if (key == TerminalKey.arrowRight &&
          isAutocompleteCursorAtLineEnd(sessionId)) {
        acceptSelectedAutocomplete(sessionId);
        return;
      }
      if (key == TerminalKey.tab) {
        // Return Tab directly to the shell for native path/argument completion
        _clearAutocompleteForSession(item);
      } else if (key == TerminalKey.escape) {
        dismissAutocomplete(sessionId);
        return;
      } else if ((key == TerminalKey.enter || key == TerminalKey.numpadEnter) &&
          item.autocompleteNavigated) {
        acceptSelectedAutocomplete(sessionId);
        return;
      }
    }

    if (key == TerminalKey.enter ||
        key == TerminalKey.numpadEnter ||
        key == TerminalKey.escape ||
        (ctrl && (key == TerminalKey.keyC || key == TerminalKey.keyD))) {
      if (key == TerminalKey.enter || key == TerminalKey.numpadEnter) {
        _recordCurrentCommandIfAny(item);
      }
      if (key != TerminalKey.escape) {
        _clearSudoPromptForSession(item, ignoreCurrentLine: true);
      }
      _clearAutocompleteForSession(item);
    }
    item.terminal.keyInput(key, ctrl: ctrl, alt: alt);
  }

  void sendRawSequence(String sessionId, List<int> bytes) {
    if (_ctrlArmed || _altArmed) {
      _ctrlArmed = false;
      _altArmed = false;
      notifyListeners();
    }
    if (bytes.contains(0x03) ||
        bytes.contains(0x04) ||
        bytes.contains(0x0d) ||
        bytes.contains(0x0a)) {
      final item = _sessions.where((s) => s.id == sessionId).firstOrNull;
      if (item != null) {
        if (bytes.contains(0x0d) || bytes.contains(0x0a)) {
          _recordCurrentCommandIfAny(item);
        }
        _clearSudoPromptForSession(item, ignoreCurrentLine: true);
        _clearAutocompleteForSession(item);
      }
    }
    backend.writeSession(sessionId, Uint8List.fromList(bytes));
  }

  void acceptAutocompleteSuggestion(
    String sessionId,
    AutocompleteSuggestion suggestion,
  ) {
    if (suggestion.insertSuffix.isEmpty) return;
    final item = _sessions.where((s) => s.id == sessionId).firstOrNull;
    if (item != null) {
      item.autocompleteSelectedIndex = 0;
      item.autocompleteNavigated = false;
    }
    backend.writeSession(
      sessionId,
      Uint8List.fromList(utf8.encode(suggestion.insertSuffix)),
    );
  }

  bool isAutocompleteCursorAtLineEnd(String sessionId) {
    final item = _sessions.where((s) => s.id == sessionId).firstOrNull;
    if (item == null || item.terminal.buffer.isAltBuffer) return false;
    final buf = item.terminal.buffer;
    final y = buf.absoluteCursorY;
    if (y < 0 || y >= buf.lines.length) return false;
    final line = buf.lines[y];
    final fullTrimmed = line.getText().trimRight();
    final beforeCursor = line.getText(0, buf.cursorX).trimRight();
    return beforeCursor == fullTrimmed;
  }

  void moveAutocompleteSelection(String sessionId, int delta) {
    final item = _sessions.where((s) => s.id == sessionId).firstOrNull;
    if (item == null || item.autocompleteSuggestions.isEmpty) return;
    final len = item.autocompleteSuggestions.length;
    if (!item.autocompleteNavigated) {
      item.autocompleteSelectedIndex = delta >= 0 ? 0 : (len - 1);
      item.autocompleteNavigated = true;
    } else {
      item.autocompleteSelectedIndex =
          ((item.autocompleteSelectedIndex + delta) % len + len) % len;
    }
    notifyListeners();
  }

  void acceptSelectedAutocomplete(String sessionId) {
    final item = _sessions.where((s) => s.id == sessionId).firstOrNull;
    if (item == null || item.autocompleteSuggestions.isEmpty) return;
    final idx = item.autocompleteSelectedIndex.clamp(
      0,
      item.autocompleteSuggestions.length - 1,
    );
    acceptAutocompleteSuggestion(sessionId, item.autocompleteSuggestions[idx]);
  }

  void dismissAutocomplete(String sessionId) {
    final item = _sessions.where((s) => s.id == sessionId).firstOrNull;
    if (item == null) return;
    _clearAutocompleteForSession(item);
  }

  void _clearAutocompleteForSession(TerminalSessionItem item) {
    if (item.autocompleteSuggestions.isNotEmpty ||
        item.autocompleteSelectedIndex != 0 ||
        item.autocompleteNavigated) {
      item.autocompleteSuggestions = const [];
      item.autocompleteSelectedIndex = 0;
      item.autocompleteNavigated = false;
      notifyListeners();
    }
  }

  void _recordCurrentCommandIfAny(TerminalSessionItem item) {
    if (item.phase != SessionPhase.connected ||
        item.sudoPromptLabel != null ||
        item.terminal.buffer.isAltBuffer) {
      return;
    }
    final buf = item.terminal.buffer;
    final y = buf.absoluteCursorY;
    if (y < 0 || y >= buf.lines.length) return;
    final line = buf.lines[y];
    final prefix = CommandAutocompleteEngine.extractCommandPrefix(
      lineBeforeCursor: line.getText(0, buf.cursorX),
      fullLineTrimmed: line.getText().trimRight(),
      shellKind: item.shellKind,
    );
    if (prefix == null ||
        !CommandAutocompleteEngine.shouldRecordInHistory(prefix)) {
      return;
    }
    final clean = prefix.trim();
    item.localHistory.remove(clean);
    item.localHistory.insert(0, clean);
    if (item.localHistory.length > 120) {
      item.localHistory.removeRange(120, item.localHistory.length);
    }
  }

  void _refreshAutocompleteSuggestions(
    TerminalSessionItem item, {
    bool notify = true,
  }) {
    List<AutocompleteSuggestion> next = const [];
    if (_autocompleteEnabled &&
        item.phase == SessionPhase.connected &&
        item.sudoPromptLabel == null &&
        !item.terminal.buffer.isAltBuffer) {
      final buf = item.terminal.buffer;
      final y = buf.absoluteCursorY;
      if (y >= 0 && y < buf.lines.length) {
        final line = buf.lines[y];
        final prefix = CommandAutocompleteEngine.extractCommandPrefix(
          lineBeforeCursor: line.getText(0, buf.cursorX),
          fullLineTrimmed: line.getText().trimRight(),
          shellKind: item.shellKind,
        );
        if (prefix != null && prefix.trimLeft().length >= 2) {
          next = CommandAutocompleteEngine.suggest(
            rawPrefix: prefix,
            localHistory: item.localHistory,
            remoteHistory: item.remoteHistory,
            snippets: _snippets,
            shellKind: item.shellKind,
          );
        }
      }
    }

    final prev = item.autocompleteSuggestions;
    var changed = prev.length != next.length;
    if (!changed) {
      for (var i = 0; i < prev.length; i++) {
        if (prev[i].fullText != next[i].fullText ||
            prev[i].insertSuffix != next[i].insertSuffix) {
          changed = true;
          break;
        }
      }
    }
    if (changed) {
      item.autocompleteSuggestions = next;
      item.autocompleteSelectedIndex = 0;
      item.autocompleteNavigated = false;
      if (notify) {
        notifyListeners();
      }
    }
  }

  Future<void> _loadRemoteHistoryInBackground(TerminalSessionItem item) async {
    if (item.remoteHistoryLoaded) return;
    item.remoteHistoryLoaded = true;
    try {
      final history = await backend.fetchRemoteHistory(item.id);
      if (_sessions.any((s) => s.id == item.id)) {
        item.remoteHistory = history;
        _refreshAutocompleteSuggestions(item);
      }
    } catch (_) {
      // Silently ignore on servers without standard shell history files
    }
  }

  void fillSudoPassword(String sessionId) {
    final item = _sessions.where((s) => s.id == sessionId).firstOrNull;
    if (item == null || !item.profile.hasStoredPassword) return;
    _clearSudoPromptForSession(item, ignoreCurrentLine: true);
    if (!backend.fillSudoPassword(sessionId) &&
        item.profile.password.isNotEmpty) {
      // Fallback for non-persisted mock/in-memory profiles
      backend.writeSession(
        sessionId,
        Uint8List.fromList(utf8.encode('${item.profile.password}\r')),
      );
    }
  }

  void dismissSudoPrompt(String sessionId) {
    final item = _sessions.where((s) => s.id == sessionId).firstOrNull;
    if (item == null) return;
    _clearSudoPromptForSession(item, ignoreCurrentLine: true);
  }

  void _clearSudoPromptForSession(
    TerminalSessionItem item, {
    bool ignoreCurrentLine = false,
  }) {
    if (ignoreCurrentLine) {
      item.sudoPromptIgnoredLineY = item.terminal.buffer.absoluteCursorY;
    }
    if (item.sudoPromptLabel != null) {
      item.sudoPromptLabel = null;
      notifyListeners();
    }
  }

  void _inspectSudoPrompt(TerminalSessionItem item) {
    if (item.isLocal ||
        item.phase != SessionPhase.connected ||
        !item.profile.hasStoredPassword ||
        item.terminal.buffer.isAltBuffer) {
      if (item.sudoPromptLabel != null) {
        item.sudoPromptLabel = null;
        notifyListeners();
      }
      return;
    }

    final buf = item.terminal.buffer;
    final y = buf.absoluteCursorY;
    if (y < 0 || y >= buf.lines.length) return;

    if (item.sudoPromptIgnoredLineY != null &&
        item.sudoPromptIgnoredLineY != y) {
      item.sudoPromptIgnoredLineY = null;
    }

    final lineText = buf.lines[y].getText(0, buf.cursorX);
    final match = SudoPromptDetector.matchLine(lineText);
    final nextLabel = (match != null && item.sudoPromptIgnoredLineY != y)
        ? match.label
        : null;

    if (item.sudoPromptLabel != nextLabel) {
      item.sudoPromptLabel = nextLabel;
      notifyListeners();
    }
  }

  void _sendTerminalInput(String sessionId, String data) {
    if (data.isEmpty) return;

    if (data == '\x1b' ||
        data.contains('\r') ||
        data.contains('\n') ||
        data.contains('\x03') ||
        data.contains('\x04')) {
      final item = _sessions.where((s) => s.id == sessionId).firstOrNull;
      if (item != null) {
        if (data.contains('\r') || data.contains('\n')) {
          _recordCurrentCommandIfAny(item);
        }
        if (data != '\x1b') {
          _clearSudoPromptForSession(item, ignoreCurrentLine: true);
        }
        _clearAutocompleteForSession(item);
      }
    }

    if ((_ctrlArmed || _altArmed) && data.length == 1) {
      final code = data.codeUnitAt(0);
      final useCtrl = _ctrlArmed;
      final useAlt = _altArmed;
      _ctrlArmed = false;
      _altArmed = false;
      notifyListeners();

      final out = <int>[];
      if (useAlt) out.add(0x1b);
      if (useCtrl && code >= 0x40 && code <= 0x7f) {
        final ctrlByte = code & 0x1f;
        if (ctrlByte == 0x03 || ctrlByte == 0x04) {
          final item = _sessions.where((s) => s.id == sessionId).firstOrNull;
          if (item != null) {
            _clearSudoPromptForSession(item, ignoreCurrentLine: true);
          }
        }
        out.add(ctrlByte);
      } else {
        out.addAll(utf8.encode(data));
      }
      backend.writeSession(sessionId, Uint8List.fromList(out));
      return;
    }

    backend.writeSession(sessionId, Uint8List.fromList(utf8.encode(data)));
  }

  static final RegExp _tailscaleUrlRegex = RegExp(
    r'https://login\.tailscale\.com/[^\s\r\n"<>' "'" r'\)]+',
  );
  static final RegExp _genericAuthUrlRegex = RegExp(
    r'(?:To authenticate|authenticate|verify)[^\r\n]{0,80}?(https://[^\s\r\n"<>' "'" r'\)]+)',
    caseSensitive: false,
  );

  static String? extractBrowserAuthUrl(String text) {
    final ts = _tailscaleUrlRegex.firstMatch(text);
    if (ts != null) return ts.group(0);
    final gen = _genericAuthUrlRegex.firstMatch(text);
    return gen?.group(1);
  }

  void dismissBrowserAuthUrl(String sessionId) {
    final item = _sessions.where((s) => s.id == sessionId).firstOrNull;
    if (item == null || item.browserAuthUrl == null) return;
    item.dismissedBrowserAuthUrl = item.browserAuthUrl;
    item.browserAuthUrl = null;
    notifyListeners();
  }

  /// Opens an `http(s)` URL in the OS default browser on desktop, or copies it
  /// to the clipboard on mobile. Returns `true` if a browser process was started.
  Future<bool> openExternalUrl(String rawUrl) async {
    final trimmed = rawUrl.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) {
      return false;
    }
    try {
      if (!kIsWeb && Platform.isWindows) {
        await Process.start(
          'rundll32.exe',
          ['url.dll,FileProtocolHandler', trimmed],
          runInShell: false,
        );
        return true;
      }
      if (!kIsWeb && Platform.isMacOS) {
        await Process.start('open', [trimmed]);
        return true;
      }
      if (!kIsWeb && Platform.isLinux) {
        await Process.start('xdg-open', [trimmed]);
        return true;
      }
    } catch (_) {}
    await Clipboard.setData(ClipboardData(text: trimmed));
    return false;
  }

  void _inspectBrowserAuthPrompt(TerminalSessionItem item, String decoded) {
    final url = extractBrowserAuthUrl(decoded);
    if (url != null) {
      if (url != item.dismissedBrowserAuthUrl && item.browserAuthUrl != url) {
        item.browserAuthUrl = url;
        notifyListeners();
      }
      return;
    }
    // Auto-dismiss once the remote shell prompt appears after browser verification succeeds
    if (item.browserAuthUrl != null &&
        item.phase == SessionPhase.connected &&
        !decoded.contains('Tailscale') &&
        (decoded.contains(r'$ ') || decoded.contains('# '))) {
      item.browserAuthUrl = null;
      notifyListeners();
    }
  }

  void _handleOutputChunk(SessionOutputChunk chunk) {
    for (final s in _sessions) {
      if (s.id == chunk.sessionId) {
        s.appendRawBytes(chunk.bytes);
        if (!s.isLocal) {
          final text = utf8.decode(chunk.bytes, allowMalformed: true);
          _inspectBrowserAuthPrompt(s, text);
        }
        _inspectSudoPrompt(s);
        _refreshAutocompleteSuggestions(s);
        return;
      }
    }
  }

  void _handleStatusEvent(SessionStatusEvent event) {
    if (event.phase == SessionPhase.verifyHostKey &&
        event.hostKeyPrompt != null) {
      final prompt = event.hostKeyPrompt!;
      if (autoAcceptHostKeys) {
        unawaited(
          backend.respondHostKey(
            requestId: prompt.requestId,
            accept: true,
            persist: true,
          ),
        );
        return;
      }
      _pendingHostKeyPrompts.add(prompt);
      notifyListeners();
      return;
    }

    if (event.phase == SessionPhase.sftpProgress &&
        event.sftpProgress != null) {
      final prog = event.sftpProgress!;
      _sftpTransfers[prog.transferId] = prog;
      notifyListeners();
      if (prog.done) {
        Timer(const Duration(seconds: 3), () {
          if (_sftpTransfers.remove(prog.transferId) != null) {
            notifyListeners();
          }
        });
      }
      return;
    }

    final item = _sessions.where((s) => s.id == event.sessionId).firstOrNull;
    if (item == null) return;

    item.phase = event.phase;
    item.statusMessage = event.message;
    if (event.serverFingerprint != null) {
      item.serverFingerprint = event.serverFingerprint;
    }
    if (event.authUsed != null) {
      item.authUsed = event.authUsed;
    }
    if (event.latencyMs != null) {
      item.latencyMs = event.latencyMs;
    }

    switch (event.phase) {
      case SessionPhase.connecting:
      case SessionPhase.verifyHostKey:
      case SessionPhase.sftpProgress:
        break;
      case SessionPhase.connected:
        if (!item.isLocal) {
          _writeBannerLine(
            item.terminal,
            '\x1b[1;32m✔ 已连接\x1b[0;38;5;244m · ${event.authUsed ?? 'ssh'} · ${event.latencyMs ?? 0}ms · ${event.serverFingerprint ?? ''}\x1b[0m\r\n',
          );
          unawaited(refreshHosts());
          unawaited(_loadRemoteHistoryInBackground(item));
        }
      case SessionPhase.disconnected:
        item.sudoPromptLabel = null;
        item.browserAuthUrl = null;
        item.autocompleteSuggestions = const [];
        item.remoteHistoryLoaded = false;
        final codeSuffix = event.exitCode != null
            ? ' (exit ${event.exitCode})'
            : '';
        _writeBannerLine(
          item.terminal,
          '\r\n\x1b[38;5;244m[会话已断开: ${event.message}$codeSuffix]\x1b[0m',
        );
      case SessionPhase.error:
        item.sudoPromptLabel = null;
        item.browserAuthUrl = null;
        item.autocompleteSuggestions = const [];
        item.remoteHistoryLoaded = false;
        _writeBannerLine(
          item.terminal,
          '\r\n\x1b[1;31m✖ 连接错误: ${event.message}\x1b[0m',
        );
    }

    notifyListeners();
  }

  void _writeBannerLine(Terminal terminal, String text) {
    terminal.write('$text\r\n');
  }

  @override
  void dispose() {
    _startupUpdateTimer?.cancel();
    _clipboardClearTimer?.cancel();
    _desktopAdapter.dispose();
    _outputSub.cancel();
    _statusSub.cancel();
    for (final s in _sessions) {
      backend.disconnectSession(s.id);
      s.dispose();
    }
    backend.dispose();
    super.dispose();
  }
}

class _ImmediateTerminalStringSink extends StringConversionSinkBase {
  _ImmediateTerminalStringSink(this._onChunk);

  final void Function(String chunk) _onChunk;

  @override
  void add(String str) {
    if (str.isNotEmpty) {
      _onChunk(str);
    }
  }

  @override
  void addSlice(String str, int start, int end, bool isLast) {
    if (end > start) {
      _onChunk(str.substring(start, end));
    }
  }

  @override
  void close() {}
}
