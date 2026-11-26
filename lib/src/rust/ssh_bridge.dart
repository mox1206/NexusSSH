import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:nexus_ssh/src/models/ssh_models.dart';
import 'package:nexus_ssh/src/rust/nexus_ffi.dart';

abstract class SshBackend {
  Stream<SessionOutputChunk> get outputStream;
  Stream<SessionStatusEvent> get statusStream;

  Future<List<HostProfile>> init(String dataDir);
  Future<List<HostProfile>> listHosts();
  Future<HostProfile> upsertHost(HostProfile profile);
  Future<bool> deleteHost(String hostId);

  // Snippets
  Future<List<SnippetItem>> listSnippets();
  Future<SnippetItem> upsertSnippet(SnippetItem snippet);
  Future<bool> deleteSnippet(String snippetId);

  // Known Hosts (TOFU)
  Future<bool> respondHostKey({
    required String requestId,
    required bool accept,
    bool persist = true,
  });
  Future<List<KnownHostEntry>> listKnownHosts();
  Future<bool> deleteKnownHost(String hostKey);

  // App Lock
  Future<AppLockConfig> getAppLockConfig();
  Future<AppLockConfig> setAppLockPasscode({
    required String passcode,
    required bool biometricsEnabled,
    required bool lockOnStartup,
    required int autoLockMinutes,
  });
  Future<bool> verifyAppLockPasscode(String passcode);
  Future<AppLockConfig> updateAppLockSettings({
    required bool biometricsEnabled,
    required bool lockOnStartup,
    required int autoLockMinutes,
  });
  Future<AppLockConfig> disableAppLock({
    String currentPasscode = '',
    bool bypassVerified = false,
  });

  // SFTP & Server Telemetry
  Future<SftpDirListing> sftpListDir(String sessionId, {String path = ''});
  Future<void> sftpMkdir(String sessionId, String path);
  Future<void> sftpRename(String sessionId, String oldPath, String newPath);
  Future<void> sftpDelete(
    String sessionId,
    String path, {
    required bool isDir,
  });
  Future<void> sftpChmod(String sessionId, String path, int modeOctal);
  Future<int> sftpDownload({
    required String sessionId,
    required String transferId,
    required String remotePath,
    required String localPath,
  });
  Future<int> sftpUpload({
    required String sessionId,
    required String transferId,
    required String localPath,
    required String remotePath,
  });
  Future<ServerMetrics> fetchServerMetrics(String sessionId);
  Future<List<String>> fetchRemoteHistory(
    String sessionId, {
    int maxEntries = 250,
  });

  // Helpers & WebDAV
  Future<QuickConnectTarget> parseQuickConnect(String expr);
  Future<KeyInspectionResult> inspectPrivateKey({
    String pemContent = '',
    String filePath = '',
    String passphrase = '',
  });
  Future<List<DiscoveredSshKey>> discoverLocalKeys();
  Future<WebDavConfig> getWebDavConfig();
  Future<WebDavConfig> saveWebDavConfig(WebDavConfig config);
  Future<ConnectionTestResult> testWebDav(WebDavConfig config);
  Future<WebDavSyncResult> syncWebDav({
    WebDavConfig? config,
    SyncMode mode = SyncMode.merge,
  });
  Future<ConnectionTestResult> testConnection(
    HostProfile profile, {
    int timeoutSecs = 10,
  });
  Future<void> connectSession({
    required String sessionId,
    required HostProfile profile,
    required int cols,
    required int rows,
  });
  Future<List<LocalShellOption>> listLocalShells();
  Future<String> connectLocalSession({
    required String sessionId,
    String shellProgram = '',
    String cwd = '',
    required int cols,
    required int rows,
  });
  void writeSession(String sessionId, Uint8List data);
  bool fillSudoPassword(String sessionId);
  void resizeSession(
    String sessionId, {
    required int cols,
    required int rows,
    int pixelWidth = 0,
    int pixelHeight = 0,
  });
  void disconnectSession(String sessionId);
  void prepareShutdown();
  void dispose();
}

class RustSshBackend implements SshBackend {
  RustSshBackend() {
    _ensureCallbacksRegistered();
  }

  static final StreamController<SessionOutputChunk> _outputController =
      StreamController<SessionOutputChunk>.broadcast();
  static final StreamController<SessionStatusEvent> _statusController =
      StreamController<SessionStatusEvent>.broadcast();

  static NativeCallable<DartOutputCallbackNative>? _outputCallable;
  static NativeCallable<DartStatusCallbackNative>? _statusCallable;

  static void _ensureCallbacksRegistered() {
    if (_outputCallable != null && _statusCallable != null) {
      return;
    }

    _outputCallable = NativeCallable<DartOutputCallbackNative>.listener((
      Pointer<Utf8> sessionIdPtr,
      Pointer<Uint8> dataPtr,
      int dataLen,
    ) {
      try {
        final sessionId = sessionIdPtr.toDartString();
        final copy = Uint8List.fromList(dataPtr.asTypedList(dataLen));
        _outputController.add(
          SessionOutputChunk(sessionId: sessionId, bytes: copy),
        );
      } finally {
        nexus_free_string(sessionIdPtr);
        nexus_free_bytes(dataPtr, dataLen);
      }
    });
    _outputCallable!.keepIsolateAlive = false;

    _statusCallable = NativeCallable<DartStatusCallbackNative>.listener((
      Pointer<Utf8> eventJsonPtr,
    ) {
      try {
        final rawJson = eventJsonPtr.toDartString();
        final decoded = jsonDecode(rawJson) as Map<String, dynamic>;
        _statusController.add(SessionStatusEvent.fromJson(decoded));
      } finally {
        nexus_free_string(eventJsonPtr);
      }
    });
    _statusCallable!.keepIsolateAlive = false;

    nexus_register_callbacks(
      _outputCallable!.nativeFunction,
      _statusCallable!.nativeFunction,
    );
  }

  @override
  Stream<SessionOutputChunk> get outputStream => _outputController.stream;

  @override
  Stream<SessionStatusEvent> get statusStream => _statusController.stream;

  static Map<String, dynamic> _consumeJsonResponse(Pointer<Utf8> ptr) {
    try {
      final jsonStr = ptr.toDartString();
      final map = jsonDecode(jsonStr) as Map<String, dynamic>;
      if (map['ok'] != true) {
        throw SshBridgeException(map['error'] as String? ?? '未知错误');
      }
      return map;
    } finally {
      nexus_free_string(ptr);
    }
  }

  @override
  Future<List<HostProfile>> init(String dataDir) async {
    return using((arena) {
      final cDir = dataDir.toNativeUtf8(allocator: arena);
      final map = _consumeJsonResponse(nexus_init_core(cDir));
      final list = map['data'] as List<dynamic>? ?? const [];
      return list
          .map((item) => HostProfile.fromJson(item as Map<String, dynamic>))
          .toList();
    });
  }

  @override
  Future<List<HostProfile>> listHosts() async {
    final map = _consumeJsonResponse(nexus_list_hosts());
    final list = map['data'] as List<dynamic>? ?? const [];
    return list
        .map((item) => HostProfile.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<HostProfile> upsertHost(HostProfile profile) async {
    return using((arena) {
      final raw = jsonEncode(profile.toJson());
      final cJson = raw.toNativeUtf8(allocator: arena);
      final map = _consumeJsonResponse(nexus_upsert_host(cJson));
      return HostProfile.fromJson(map['data'] as Map<String, dynamic>);
    });
  }

  @override
  Future<bool> deleteHost(String hostId) async {
    return using((arena) {
      final cId = hostId.toNativeUtf8(allocator: arena);
      final map = _consumeJsonResponse(nexus_delete_host(cId));
      return map['data'] as bool? ?? false;
    });
  }

  // --- Snippets ---

  @override
  Future<List<SnippetItem>> listSnippets() async {
    final map = _consumeJsonResponse(nexus_list_snippets());
    final list = map['data'] as List<dynamic>? ?? const [];
    return list
        .map((e) => SnippetItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<SnippetItem> upsertSnippet(SnippetItem snippet) async {
    return using((arena) {
      final cJson = jsonEncode(snippet.toJson()).toNativeUtf8(allocator: arena);
      final map = _consumeJsonResponse(nexus_upsert_snippet(cJson));
      return SnippetItem.fromJson(map['data'] as Map<String, dynamic>);
    });
  }

  @override
  Future<bool> deleteSnippet(String snippetId) async {
    return using((arena) {
      final cId = snippetId.toNativeUtf8(allocator: arena);
      final map = _consumeJsonResponse(nexus_delete_snippet(cId));
      return map['data'] as bool? ?? false;
    });
  }

  // --- Known Hosts (TOFU) ---

  @override
  Future<bool> respondHostKey({
    required String requestId,
    required bool accept,
    bool persist = true,
  }) async {
    return using((arena) {
      final cId = requestId.toNativeUtf8(allocator: arena);
      final map = _consumeJsonResponse(
        nexus_respond_host_key(cId, accept ? 1 : 0, persist ? 1 : 0),
      );
      return map['data'] as bool? ?? false;
    });
  }

  @override
  Future<List<KnownHostEntry>> listKnownHosts() async {
    final map = _consumeJsonResponse(nexus_list_known_hosts());
    final list = map['data'] as List<dynamic>? ?? const [];
    return list
        .map((e) => KnownHostEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<bool> deleteKnownHost(String hostKey) async {
    return using((arena) {
      final cKey = hostKey.toNativeUtf8(allocator: arena);
      final map = _consumeJsonResponse(nexus_delete_known_host(cKey));
      return map['data'] as bool? ?? false;
    });
  }

  // --- App Lock ---

  @override
  Future<AppLockConfig> getAppLockConfig() async {
    final map = _consumeJsonResponse(nexus_get_app_lock_config());
    return AppLockConfig.fromJson(map['data'] as Map<String, dynamic>);
  }

  @override
  Future<AppLockConfig> setAppLockPasscode({
    required String passcode,
    required bool biometricsEnabled,
    required bool lockOnStartup,
    required int autoLockMinutes,
  }) async {
    return Isolate.run(() {
      return using((arena) {
        final cPin = passcode.toNativeUtf8(allocator: arena);
        final map = _consumeJsonResponse(
          nexus_set_app_lock_passcode(
            cPin,
            biometricsEnabled ? 1 : 0,
            lockOnStartup ? 1 : 0,
            autoLockMinutes,
          ),
        );
        return AppLockConfig.fromJson(map['data'] as Map<String, dynamic>);
      });
    });
  }

  @override
  Future<bool> verifyAppLockPasscode(String passcode) async {
    return Isolate.run(() {
      return using((arena) {
        final cPin = passcode.toNativeUtf8(allocator: arena);
        final map = _consumeJsonResponse(nexus_verify_app_lock_passcode(cPin));
        return map['data'] as bool? ?? false;
      });
    });
  }

  @override
  Future<AppLockConfig> updateAppLockSettings({
    required bool biometricsEnabled,
    required bool lockOnStartup,
    required int autoLockMinutes,
  }) async {
    final map = _consumeJsonResponse(
      nexus_update_app_lock_settings(
        biometricsEnabled ? 1 : 0,
        lockOnStartup ? 1 : 0,
        autoLockMinutes,
      ),
    );
    return AppLockConfig.fromJson(map['data'] as Map<String, dynamic>);
  }

  @override
  Future<AppLockConfig> disableAppLock({
    String currentPasscode = '',
    bool bypassVerified = false,
  }) async {
    return Isolate.run(() {
      return using((arena) {
        final cPin = currentPasscode.toNativeUtf8(allocator: arena);
        final map = _consumeJsonResponse(
          nexus_disable_app_lock(cPin, bypassVerified ? 1 : 0),
        );
        return AppLockConfig.fromJson(map['data'] as Map<String, dynamic>);
      });
    });
  }

  // --- SFTP & Server Telemetry (Run on background worker isolate) ---

  @override
  Future<SftpDirListing> sftpListDir(
    String sessionId, {
    String path = '',
  }) async {
    return Isolate.run(() {
      return using((arena) {
        final cSid = sessionId.toNativeUtf8(allocator: arena);
        final cPath = path.toNativeUtf8(allocator: arena);
        final map = _consumeJsonResponse(nexus_sftp_list_dir(cSid, cPath));
        return SftpDirListing.fromJson(map['data'] as Map<String, dynamic>);
      });
    });
  }

  @override
  Future<void> sftpMkdir(String sessionId, String path) async {
    await Isolate.run(() {
      using((arena) {
        final cSid = sessionId.toNativeUtf8(allocator: arena);
        final cPath = path.toNativeUtf8(allocator: arena);
        _consumeJsonResponse(nexus_sftp_mkdir(cSid, cPath));
      });
    });
  }

  @override
  Future<void> sftpRename(
    String sessionId,
    String oldPath,
    String newPath,
  ) async {
    await Isolate.run(() {
      using((arena) {
        final cSid = sessionId.toNativeUtf8(allocator: arena);
        final cOld = oldPath.toNativeUtf8(allocator: arena);
        final cNew = newPath.toNativeUtf8(allocator: arena);
        _consumeJsonResponse(nexus_sftp_rename(cSid, cOld, cNew));
      });
    });
  }

  @override
  Future<void> sftpDelete(
    String sessionId,
    String path, {
    required bool isDir,
  }) async {
    await Isolate.run(() {
      using((arena) {
        final cSid = sessionId.toNativeUtf8(allocator: arena);
        final cPath = path.toNativeUtf8(allocator: arena);
        _consumeJsonResponse(nexus_sftp_delete(cSid, cPath, isDir ? 1 : 0));
      });
    });
  }

  @override
  Future<void> sftpChmod(String sessionId, String path, int modeOctal) async {
    await Isolate.run(() {
      using((arena) {
        final cSid = sessionId.toNativeUtf8(allocator: arena);
        final cPath = path.toNativeUtf8(allocator: arena);
        _consumeJsonResponse(nexus_sftp_chmod(cSid, cPath, modeOctal));
      });
    });
  }

  @override
  Future<int> sftpDownload({
    required String sessionId,
    required String transferId,
    required String remotePath,
    required String localPath,
  }) async {
    return Isolate.run(() {
      return using((arena) {
        final cSid = sessionId.toNativeUtf8(allocator: arena);
        final cTid = transferId.toNativeUtf8(allocator: arena);
        final cRem = remotePath.toNativeUtf8(allocator: arena);
        final cLoc = localPath.toNativeUtf8(allocator: arena);
        final map = _consumeJsonResponse(
          nexus_sftp_download(cSid, cTid, cRem, cLoc),
        );
        return (map['data'] as num?)?.toInt() ?? 0;
      });
    });
  }

  @override
  Future<int> sftpUpload({
    required String sessionId,
    required String transferId,
    required String localPath,
    required String remotePath,
  }) async {
    return Isolate.run(() {
      return using((arena) {
        final cSid = sessionId.toNativeUtf8(allocator: arena);
        final cTid = transferId.toNativeUtf8(allocator: arena);
        final cLoc = localPath.toNativeUtf8(allocator: arena);
        final cRem = remotePath.toNativeUtf8(allocator: arena);
        final map = _consumeJsonResponse(
          nexus_sftp_upload(cSid, cTid, cLoc, cRem),
        );
        return (map['data'] as num?)?.toInt() ?? 0;
      });
    });
  }

  @override
  Future<ServerMetrics> fetchServerMetrics(String sessionId) async {
    return Isolate.run(() {
      return using((arena) {
        final cSid = sessionId.toNativeUtf8(allocator: arena);
        final map = _consumeJsonResponse(nexus_fetch_server_metrics(cSid));
        return ServerMetrics.fromJson(map['data'] as Map<String, dynamic>);
      });
    });
  }

  @override
  Future<List<String>> fetchRemoteHistory(
    String sessionId, {
    int maxEntries = 250,
  }) async {
    return Isolate.run(() {
      return using((arena) {
        final cSid = sessionId.toNativeUtf8(allocator: arena);
        final map = _consumeJsonResponse(
          nexus_fetch_remote_history(cSid, maxEntries),
        );
        final raw = map['data'] as List<dynamic>? ?? const [];
        return raw.map((e) => e.toString()).toList();
      });
    });
  }

  // --- Helpers & WebDAV ---

  @override
  Future<QuickConnectTarget> parseQuickConnect(String expr) async {
    return using((arena) {
      final cExpr = expr.toNativeUtf8(allocator: arena);
      final map = _consumeJsonResponse(nexus_parse_quick_connect(cExpr));
      return QuickConnectTarget.fromJson(map['data'] as Map<String, dynamic>);
    });
  }

  @override
  Future<KeyInspectionResult> inspectPrivateKey({
    String pemContent = '',
    String filePath = '',
    String passphrase = '',
  }) async {
    return using((arena) {
      final cPem = pemContent.toNativeUtf8(allocator: arena);
      final cPath = filePath.toNativeUtf8(allocator: arena);
      final cPass = passphrase.toNativeUtf8(allocator: arena);
      final map = _consumeJsonResponse(
        nexus_inspect_private_key(cPem, cPath, cPass),
      );
      return KeyInspectionResult.fromJson(map['data'] as Map<String, dynamic>);
    });
  }

  @override
  Future<List<DiscoveredSshKey>> discoverLocalKeys() async {
    final map = _consumeJsonResponse(nexus_discover_local_keys());
    final list = map['data'] as List<dynamic>? ?? const [];
    return list
        .map((e) => DiscoveredSshKey.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<WebDavConfig> getWebDavConfig() async {
    final map = _consumeJsonResponse(nexus_get_webdav_config());
    return WebDavConfig.fromJson(map['data'] as Map<String, dynamic>);
  }

  @override
  Future<WebDavConfig> saveWebDavConfig(WebDavConfig config) async {
    return using((arena) {
      final cJson = jsonEncode(config.toJson()).toNativeUtf8(allocator: arena);
      final map = _consumeJsonResponse(nexus_save_webdav_config(cJson));
      return WebDavConfig.fromJson(map['data'] as Map<String, dynamic>);
    });
  }

  @override
  Future<ConnectionTestResult> testWebDav(WebDavConfig config) async {
    final payload = jsonEncode(config.toJson());
    return Isolate.run(() {
      return using((arena) {
        final cJson = payload.toNativeUtf8(allocator: arena);
        final map = _consumeJsonResponse(nexus_test_webdav(cJson));
        return ConnectionTestResult.fromJson(
          map['data'] as Map<String, dynamic>,
        );
      });
    });
  }

  @override
  Future<WebDavSyncResult> syncWebDav({
    WebDavConfig? config,
    SyncMode mode = SyncMode.merge,
  }) async {
    final cfgStr = config == null ? '' : jsonEncode(config.toJson());
    final modeWire = mode.wireValue;
    return Isolate.run(() {
      return using((arena) {
        final cCfg = cfgStr.toNativeUtf8(allocator: arena);
        final cMode = modeWire.toNativeUtf8(allocator: arena);
        final map = _consumeJsonResponse(nexus_sync_webdav(cCfg, cMode));
        return WebDavSyncResult.fromJson(map['data'] as Map<String, dynamic>);
      });
    });
  }

  @override
  Future<ConnectionTestResult> testConnection(
    HostProfile profile, {
    int timeoutSecs = 10,
  }) async {
    final payload = jsonEncode(profile.toJson());
    return Isolate.run(() {
      return using((arena) {
        final cJson = payload.toNativeUtf8(allocator: arena);
        final map = _consumeJsonResponse(
          nexus_test_connection(cJson, timeoutSecs),
        );
        return ConnectionTestResult.fromJson(
          map['data'] as Map<String, dynamic>,
        );
      });
    });
  }

  @override
  Future<void> connectSession({
    required String sessionId,
    required HostProfile profile,
    required int cols,
    required int rows,
  }) async {
    using((arena) {
      final cSid = sessionId.toNativeUtf8(allocator: arena);
      final cJson = jsonEncode(profile.toJson()).toNativeUtf8(allocator: arena);
      _consumeJsonResponse(nexus_session_connect(cSid, cJson, cols, rows));
    });
  }

  @override
  Future<List<LocalShellOption>> listLocalShells() async {
    final map = _consumeJsonResponse(nexus_list_local_shells());
    final list = map['data'] as List<dynamic>? ?? const [];
    return list
        .map((e) => LocalShellOption.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<String> connectLocalSession({
    required String sessionId,
    String shellProgram = '',
    String cwd = '',
    required int cols,
    required int rows,
  }) async {
    return using((arena) {
      final cSid = sessionId.toNativeUtf8(allocator: arena);
      final cProg = shellProgram.toNativeUtf8(allocator: arena);
      final cCwd = cwd.toNativeUtf8(allocator: arena);
      final map = _consumeJsonResponse(
        nexus_session_connect_local(cSid, cProg, cCwd, cols, rows),
      );
      return map['data'] as String? ?? '本地终端';
    });
  }

  @override
  void writeSession(String sessionId, Uint8List data) {
    if (data.isEmpty) return;
    using((arena) {
      final cSid = sessionId.toNativeUtf8(allocator: arena);
      final buf = arena<Uint8>(data.length);
      buf.asTypedList(data.length).setAll(0, data);
      nexus_session_write(cSid, buf, data.length);
    });
  }

  @override
  bool fillSudoPassword(String sessionId) {
    return using((arena) {
      final cSid = sessionId.toNativeUtf8(allocator: arena);
      return nexus_session_fill_sudo_password(cSid) == 0;
    });
  }

  @override
  void resizeSession(
    String sessionId, {
    required int cols,
    required int rows,
    int pixelWidth = 0,
    int pixelHeight = 0,
  }) {
    using((arena) {
      final cSid = sessionId.toNativeUtf8(allocator: arena);
      nexus_session_resize(cSid, cols, rows, pixelWidth, pixelHeight);
    });
  }

  @override
  void disconnectSession(String sessionId) {
    using((arena) {
      final cSid = sessionId.toNativeUtf8(allocator: arena);
      nexus_session_disconnect(cSid);
    });
  }

  @override
  void prepareShutdown() {
    nexus_prepare_shutdown();
  }

  @override
  void dispose() {}
}

class SshBridgeException implements Exception {
  const SshBridgeException(this.message);
  final String message;

  @override
  String toString() => message;
}
