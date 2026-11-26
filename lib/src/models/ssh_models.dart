import 'dart:typed_data';
import 'package:flutter/material.dart';

enum AuthMethod {
  password('password', '密码认证'),
  privateKey('private_key', '私钥认证'),
  none('none', '免密 / Tailscale');

  const AuthMethod(this.wireValue, this.label);
  final String wireValue;
  final String label;

  static AuthMethod fromWire(String? raw) {
    return switch (raw) {
      'private_key' => AuthMethod.privateKey,
      'none' => AuthMethod.none,
      _ => AuthMethod.password,
    };
  }
}

class HostProfile {
  const HostProfile({
    this.id = '',
    required this.name,
    required this.host,
    this.port = 22,
    required this.username,
    this.authMethod = AuthMethod.password,
    this.password = '',
    this.privateKey = '',
    this.privateKeyPath = '',
    this.privateKeyLabel = '',
    this.passphrase = '',
    this.hasPassword = false,
    this.hasPrivateKey = false,
    this.hasPassphrase = false,
    this.clearPassphrase = false,
    this.jumpHostId,
    this.group = 'Default',
    this.accentHex = '#2AD882',
    this.createdAtMs = 0,
    this.updatedAtMs = 0,
    this.lastConnectedMs,
  });

  final String id;
  final String name;
  final String host;
  final int port;
  final String username;
  final AuthMethod authMethod;
  final String password;
  final String privateKey;
  final String privateKeyPath;
  final String privateKeyLabel;
  final String passphrase;
  final bool hasPassword;
  final bool hasPrivateKey;
  final bool hasPassphrase;
  final bool clearPassphrase;
  final String? jumpHostId;
  final String group;
  final String accentHex;
  final int createdAtMs;
  final int updatedAtMs;
  final int? lastConnectedMs;

  bool get hasStoredPassword => hasPassword || password.isNotEmpty;
  bool get hasStoredPrivateKey =>
      hasPrivateKey ||
      privateKey.trim().isNotEmpty ||
      privateKeyPath.trim().isNotEmpty;
  bool get hasStoredPassphrase => hasPassphrase || passphrase.isNotEmpty;
  bool get usesProxyJump => jumpHostId != null && jumpHostId!.trim().isNotEmpty;

  String get addressLabel =>
      port == 22 ? '$username@$host' : '$username@$host:$port';

  Color get accentColor {
    final cleaned = accentHex.replaceFirst('#', '');
    final parsed = int.tryParse(
      cleaned.length == 6 ? 'FF$cleaned' : cleaned,
      radix: 16,
    );
    return parsed != null ? Color(parsed) : const Color(0xFF2AD882);
  }

  HostProfile copyWith({
    String? id,
    String? name,
    String? host,
    int? port,
    String? username,
    AuthMethod? authMethod,
    String? password,
    String? privateKey,
    String? privateKeyPath,
    String? privateKeyLabel,
    String? passphrase,
    bool? hasPassword,
    bool? hasPrivateKey,
    bool? hasPassphrase,
    bool? clearPassphrase,
    String? jumpHostId,
    bool clearJumpHost = false,
    String? group,
    String? accentHex,
    int? createdAtMs,
    int? updatedAtMs,
    int? lastConnectedMs,
  }) {
    return HostProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      authMethod: authMethod ?? this.authMethod,
      password: password ?? this.password,
      privateKey: privateKey ?? this.privateKey,
      privateKeyPath: privateKeyPath ?? this.privateKeyPath,
      privateKeyLabel: privateKeyLabel ?? this.privateKeyLabel,
      passphrase: passphrase ?? this.passphrase,
      hasPassword: hasPassword ?? this.hasPassword,
      hasPrivateKey: hasPrivateKey ?? this.hasPrivateKey,
      hasPassphrase: hasPassphrase ?? this.hasPassphrase,
      clearPassphrase: clearPassphrase ?? this.clearPassphrase,
      jumpHostId: clearJumpHost ? null : (jumpHostId ?? this.jumpHostId),
      group: group ?? this.group,
      accentHex: accentHex ?? this.accentHex,
      createdAtMs: createdAtMs ?? this.createdAtMs,
      updatedAtMs: updatedAtMs ?? this.updatedAtMs,
      lastConnectedMs: lastConnectedMs ?? this.lastConnectedMs,
    );
  }

  factory HostProfile.fromJson(Map<String, dynamic> json) {
    final password = json['password'] as String? ?? '';
    final privateKey = json['private_key'] as String? ?? '';
    final privateKeyPath = json['private_key_path'] as String? ?? '';
    final passphrase = json['passphrase'] as String? ?? '';
    return HostProfile(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      host: json['host'] as String? ?? '',
      port: (json['port'] as num?)?.toInt() ?? 22,
      username: json['username'] as String? ?? 'root',
      authMethod: AuthMethod.fromWire(json['auth_method'] as String?),
      password: password,
      privateKey: privateKey,
      privateKeyPath: privateKeyPath,
      privateKeyLabel: json['private_key_label'] as String? ?? '',
      passphrase: passphrase,
      hasPassword: (json['has_password'] as bool?) ?? password.isNotEmpty,
      hasPrivateKey:
          (json['has_private_key'] as bool?) ??
          (privateKey.trim().isNotEmpty || privateKeyPath.trim().isNotEmpty),
      hasPassphrase: (json['has_passphrase'] as bool?) ?? passphrase.isNotEmpty,
      clearPassphrase: json['clear_passphrase'] as bool? ?? false,
      jumpHostId: (json['jump_host_id'] as String?)?.trim().isEmpty == true
          ? null
          : (json['jump_host_id'] as String?)?.trim(),
      group: json['group'] as String? ?? 'Default',
      accentHex: json['accent_hex'] as String? ?? '#2AD882',
      createdAtMs: (json['created_at_ms'] as num?)?.toInt() ?? 0,
      updatedAtMs: (json['updated_at_ms'] as num?)?.toInt() ?? 0,
      lastConnectedMs: (json['last_connected_ms'] as num?)?.toInt(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'host': host,
      'port': port,
      'username': username,
      'auth_method': authMethod.wireValue,
      'password': password,
      'private_key': privateKey,
      'private_key_path': privateKeyPath,
      'private_key_label': privateKeyLabel,
      'passphrase': passphrase,
      'has_password': hasStoredPassword,
      'has_private_key': hasStoredPrivateKey,
      'has_passphrase': hasStoredPassphrase,
      'clear_passphrase': clearPassphrase,
      'jump_host_id': jumpHostId,
      'group': group,
      'accent_hex': accentHex,
      'created_at_ms': createdAtMs,
      'updated_at_ms': updatedAtMs,
      'last_connected_ms': lastConnectedMs,
    };
  }
}

class SnippetItem {
  const SnippetItem({
    this.id = '',
    required this.title,
    required this.command,
    this.category = '常用',
    this.autoEnter = true,
    this.createdAtMs = 0,
    this.updatedAtMs = 0,
  });

  final String id;
  final String title;
  final String command;
  final String category;
  final bool autoEnter;
  final int createdAtMs;
  final int updatedAtMs;

  SnippetItem copyWith({
    String? id,
    String? title,
    String? command,
    String? category,
    bool? autoEnter,
    int? createdAtMs,
    int? updatedAtMs,
  }) {
    return SnippetItem(
      id: id ?? this.id,
      title: title ?? this.title,
      command: command ?? this.command,
      category: category ?? this.category,
      autoEnter: autoEnter ?? this.autoEnter,
      createdAtMs: createdAtMs ?? this.createdAtMs,
      updatedAtMs: updatedAtMs ?? this.updatedAtMs,
    );
  }

  factory SnippetItem.fromJson(Map<String, dynamic> json) {
    return SnippetItem(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      command: json['command'] as String? ?? '',
      category: json['category'] as String? ?? '常用',
      autoEnter: json['auto_enter'] as bool? ?? true,
      createdAtMs: (json['created_at_ms'] as num?)?.toInt() ?? 0,
      updatedAtMs: (json['updated_at_ms'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'command': command,
      'category': category,
      'auto_enter': autoEnter,
      'created_at_ms': createdAtMs,
      'updated_at_ms': updatedAtMs,
    };
  }
}

class AppLockConfig {
  const AppLockConfig({
    this.enabled = false,
    this.biometricsEnabled = true,
    this.lockOnStartup = true,
    this.autoLockMinutes = 5,
    this.hasPasscode = false,
  });

  final bool enabled;
  final bool biometricsEnabled;
  final bool lockOnStartup;

  /// 0 = lock immediately on background/tray, >0 = minutes, -1 = manual only
  final int autoLockMinutes;
  final bool hasPasscode;

  String get autoLockLabel => switch (autoLockMinutes) {
    0 => '切到后台立即锁定',
    1 => '离开 1 分钟后锁定',
    5 => '离开 5 分钟后锁定',
    15 => '离开 15 分钟后锁定',
    < 0 => '仅手动锁定',
    _ => '离开 $autoLockMinutes 分钟后锁定',
  };

  AppLockConfig copyWith({
    bool? enabled,
    bool? biometricsEnabled,
    bool? lockOnStartup,
    int? autoLockMinutes,
    bool? hasPasscode,
  }) {
    return AppLockConfig(
      enabled: enabled ?? this.enabled,
      biometricsEnabled: biometricsEnabled ?? this.biometricsEnabled,
      lockOnStartup: lockOnStartup ?? this.lockOnStartup,
      autoLockMinutes: autoLockMinutes ?? this.autoLockMinutes,
      hasPasscode: hasPasscode ?? this.hasPasscode,
    );
  }

  factory AppLockConfig.fromJson(Map<String, dynamic> json) {
    return AppLockConfig(
      enabled: json['enabled'] as bool? ?? false,
      biometricsEnabled: json['biometrics_enabled'] as bool? ?? true,
      lockOnStartup: json['lock_on_startup'] as bool? ?? true,
      autoLockMinutes: (json['auto_lock_minutes'] as num?)?.toInt() ?? 5,
      hasPasscode: json['has_passcode'] as bool? ?? false,
    );
  }
}

class KnownHostEntry {
  const KnownHostEntry({
    required this.hostKey,
    required this.host,
    required this.port,
    required this.algorithm,
    required this.fingerprint,
    required this.publicKeyBase64,
    required this.trustedAtMs,
  });

  final String hostKey;
  final String host;
  final int port;
  final String algorithm;
  final String fingerprint;
  final String publicKeyBase64;
  final int trustedAtMs;

  factory KnownHostEntry.fromJson(Map<String, dynamic> json) {
    return KnownHostEntry(
      hostKey: json['host_key'] as String? ?? '',
      host: json['host'] as String? ?? '',
      port: (json['port'] as num?)?.toInt() ?? 22,
      algorithm: json['algorithm'] as String? ?? '',
      fingerprint: json['fingerprint'] as String? ?? '',
      publicKeyBase64: json['public_key_base64'] as String? ?? '',
      trustedAtMs: (json['trusted_at_ms'] as num?)?.toInt() ?? 0,
    );
  }
}

class HostKeyPromptEvent {
  const HostKeyPromptEvent({
    required this.requestId,
    required this.sessionId,
    required this.host,
    required this.port,
    required this.algorithm,
    required this.fingerprint,
    required this.isMismatch,
    this.previousFingerprint,
  });

  final String requestId;
  final String sessionId;
  final String host;
  final int port;
  final String algorithm;
  final String fingerprint;
  final bool isMismatch;
  final String? previousFingerprint;

  String get hostLabel => port == 22 ? host : '$host:$port';
}

class SftpEntry {
  const SftpEntry({
    required this.name,
    required this.path,
    required this.kind,
    required this.size,
    required this.permissionsOctal,
    required this.permissionsRwx,
    this.modifiedSec,
  });

  final String name;
  final String path;
  final String kind; // 'dir' | 'file' | 'symlink' | 'other'
  final int size;
  final int permissionsOctal;
  final String permissionsRwx;
  final int? modifiedSec;

  bool get isDir => kind == 'dir';
  bool get isSymlink => kind == 'symlink';

  String get octalLabel =>
      (permissionsOctal & 0xFFF).toRadixString(8).padLeft(3, '0');

  factory SftpEntry.fromJson(Map<String, dynamic> json) {
    return SftpEntry(
      name: json['name'] as String? ?? '',
      path: json['path'] as String? ?? '',
      kind: json['kind'] as String? ?? 'file',
      size: (json['size'] as num?)?.toInt() ?? 0,
      permissionsOctal: (json['permissions_octal'] as num?)?.toInt() ?? 0,
      permissionsRwx: json['permissions_rwx'] as String? ?? '---------',
      modifiedSec: (json['modified_sec'] as num?)?.toInt(),
    );
  }
}

class SftpDirListing {
  const SftpDirListing({required this.currentPath, required this.entries});

  final String currentPath;
  final List<SftpEntry> entries;

  factory SftpDirListing.fromJson(Map<String, dynamic> json) {
    final raw = json['entries'] as List<dynamic>? ?? const [];
    return SftpDirListing(
      currentPath: json['current_path'] as String? ?? '/',
      entries: raw
          .map((e) => SftpEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

class SftpTransferProgress {
  const SftpTransferProgress({
    required this.transferId,
    required this.sessionId,
    required this.direction,
    required this.fileName,
    required this.transferredBytes,
    required this.totalBytes,
    required this.done,
    this.error,
  });

  final String transferId;
  final String sessionId;
  final String direction; // 'upload' | 'download'
  final String fileName;
  final int transferredBytes;
  final int totalBytes;
  final bool done;
  final String? error;

  double get fraction => totalBytes > 0
      ? (transferredBytes / totalBytes).clamp(0.0, 1.0)
      : (done ? 1.0 : 0.0);
}

class DiskUsageItem {
  const DiskUsageItem({
    required this.mountPoint,
    required this.filesystem,
    required this.totalBytes,
    required this.usedBytes,
  });

  final String mountPoint;
  final String filesystem;
  final int totalBytes;
  final int usedBytes;

  double get ratio =>
      totalBytes > 0 ? (usedBytes / totalBytes).clamp(0.0, 1.0) : 0.0;

  factory DiskUsageItem.fromJson(Map<String, dynamic> json) {
    return DiskUsageItem(
      mountPoint: json['mount_point'] as String? ?? '/',
      filesystem: json['filesystem'] as String? ?? '',
      totalBytes: (json['total_bytes'] as num?)?.toInt() ?? 0,
      usedBytes: (json['used_bytes'] as num?)?.toInt() ?? 0,
    );
  }
}

class NetInterfaceRate {
  const NetInterfaceRate({
    required this.interfaceName,
    required this.rxBytesPerSec,
    required this.txBytesPerSec,
    required this.totalRxBytes,
    required this.totalTxBytes,
  });

  final String interfaceName;
  final int rxBytesPerSec;
  final int txBytesPerSec;
  final int totalRxBytes;
  final int totalTxBytes;

  factory NetInterfaceRate.fromJson(Map<String, dynamic> json) {
    return NetInterfaceRate(
      interfaceName: json['interface'] as String? ?? '',
      rxBytesPerSec: (json['rx_bytes_per_sec'] as num?)?.toInt() ?? 0,
      txBytesPerSec: (json['tx_bytes_per_sec'] as num?)?.toInt() ?? 0,
      totalRxBytes: (json['total_rx_bytes'] as num?)?.toInt() ?? 0,
      totalTxBytes: (json['total_tx_bytes'] as num?)?.toInt() ?? 0,
    );
  }
}

class ServerMetrics {
  const ServerMetrics({
    required this.hostname,
    required this.osName,
    required this.kernel,
    required this.uptimeSecs,
    required this.cpuCores,
    required this.cpuPercent,
    required this.load1,
    required this.load5,
    required this.load15,
    required this.memTotalBytes,
    required this.memUsedBytes,
    required this.swapTotalBytes,
    required this.swapUsedBytes,
    required this.disks,
    required this.networks,
    required this.collectedAtMs,
  });

  final String hostname;
  final String osName;
  final String kernel;
  final int uptimeSecs;
  final int cpuCores;
  final double cpuPercent;
  final double load1;
  final double load5;
  final double load15;
  final int memTotalBytes;
  final int memUsedBytes;
  final int swapTotalBytes;
  final int swapUsedBytes;
  final List<DiskUsageItem> disks;
  final List<NetInterfaceRate> networks;
  final int collectedAtMs;

  double get memRatio =>
      memTotalBytes > 0 ? (memUsedBytes / memTotalBytes).clamp(0.0, 1.0) : 0.0;

  double get swapRatio => swapTotalBytes > 0
      ? (swapUsedBytes / swapTotalBytes).clamp(0.0, 1.0)
      : 0.0;

  factory ServerMetrics.fromJson(Map<String, dynamic> json) {
    final rawDisks = json['disks'] as List<dynamic>? ?? const [];
    final rawNets = json['networks'] as List<dynamic>? ?? const [];
    return ServerMetrics(
      hostname: json['hostname'] as String? ?? '',
      osName: json['os_name'] as String? ?? '',
      kernel: json['kernel'] as String? ?? '',
      uptimeSecs: (json['uptime_secs'] as num?)?.toInt() ?? 0,
      cpuCores: (json['cpu_cores'] as num?)?.toInt() ?? 1,
      cpuPercent: (json['cpu_percent'] as num?)?.toDouble() ?? 0.0,
      load1: (json['load_1'] as num?)?.toDouble() ?? 0.0,
      load5: (json['load_5'] as num?)?.toDouble() ?? 0.0,
      load15: (json['load_15'] as num?)?.toDouble() ?? 0.0,
      memTotalBytes: (json['mem_total_bytes'] as num?)?.toInt() ?? 0,
      memUsedBytes: (json['mem_used_bytes'] as num?)?.toInt() ?? 0,
      swapTotalBytes: (json['swap_total_bytes'] as num?)?.toInt() ?? 0,
      swapUsedBytes: (json['swap_used_bytes'] as num?)?.toInt() ?? 0,
      disks: rawDisks
          .map((e) => DiskUsageItem.fromJson(e as Map<String, dynamic>))
          .toList(),
      networks: rawNets
          .map((e) => NetInterfaceRate.fromJson(e as Map<String, dynamic>))
          .toList(),
      collectedAtMs: (json['collected_at_ms'] as num?)?.toInt() ?? 0,
    );
  }
}

class QuickConnectTarget {
  const QuickConnectTarget({
    required this.username,
    required this.host,
    required this.port,
    required this.displayName,
  });

  final String username;
  final String host;
  final int port;
  final String displayName;

  factory QuickConnectTarget.fromJson(Map<String, dynamic> json) {
    return QuickConnectTarget(
      username: json['username'] as String? ?? 'root',
      host: json['host'] as String? ?? '',
      port: (json['port'] as num?)?.toInt() ?? 22,
      displayName: json['display_name'] as String? ?? '',
    );
  }
}

class ConnectionTestResult {
  const ConnectionTestResult({
    required this.ok,
    required this.latencyMs,
    this.serverFingerprint,
    required this.message,
  });

  final bool ok;
  final int latencyMs;
  final String? serverFingerprint;
  final String message;

  factory ConnectionTestResult.fromJson(Map<String, dynamic> json) {
    return ConnectionTestResult(
      ok: json['ok'] as bool? ?? false,
      latencyMs: (json['latency_ms'] as num?)?.toInt() ?? 0,
      serverFingerprint: json['server_fingerprint'] as String?,
      message: json['message'] as String? ?? '',
    );
  }
}

enum SessionPhase {
  connecting,
  connected,
  disconnected,
  error,
  verifyHostKey,
  sftpProgress,
}

class SessionStatusEvent {
  const SessionStatusEvent({
    required this.sessionId,
    required this.phase,
    required this.message,
    this.serverFingerprint,
    this.authUsed,
    this.latencyMs,
    this.exitCode,
    this.hostKeyPrompt,
    this.sftpProgress,
  });

  final String sessionId;
  final SessionPhase phase;
  final String message;
  final String? serverFingerprint;
  final String? authUsed;
  final int? latencyMs;
  final int? exitCode;
  final HostKeyPromptEvent? hostKeyPrompt;
  final SftpTransferProgress? sftpProgress;

  factory SessionStatusEvent.fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String? ?? '';
    final sid = json['session_id'] as String? ?? '';
    return switch (type) {
      'connecting' => SessionStatusEvent(
        sessionId: sid,
        phase: SessionPhase.connecting,
        message: json['message'] as String? ?? '正在连接...',
      ),
      'connected' => SessionStatusEvent(
        sessionId: sid,
        phase: SessionPhase.connected,
        serverFingerprint: json['server_fingerprint'] as String?,
        authUsed: json['auth_used'] as String?,
        latencyMs: (json['latency_ms'] as num?)?.toInt(),
        message: '已连接',
      ),
      'disconnected' => SessionStatusEvent(
        sessionId: sid,
        phase: SessionPhase.disconnected,
        exitCode: (json['exit_code'] as num?)?.toInt(),
        message: json['reason'] as String? ?? '连接已断开',
      ),
      'verify_host_key' => SessionStatusEvent(
        sessionId: sid,
        phase: SessionPhase.verifyHostKey,
        message: '请确认远程主机公钥指纹',
        hostKeyPrompt: HostKeyPromptEvent(
          requestId: json['request_id'] as String? ?? '',
          sessionId: sid,
          host: json['host'] as String? ?? '',
          port: (json['port'] as num?)?.toInt() ?? 22,
          algorithm: json['algorithm'] as String? ?? '',
          fingerprint: json['fingerprint'] as String? ?? '',
          isMismatch: (json['status'] as String?) == 'mismatch',
          previousFingerprint: json['previous_fingerprint'] as String?,
        ),
      ),
      'sftp_progress' => SessionStatusEvent(
        sessionId: sid,
        phase: SessionPhase.sftpProgress,
        message: '',
        sftpProgress: SftpTransferProgress(
          transferId: json['transfer_id'] as String? ?? '',
          sessionId: sid,
          direction: json['direction'] as String? ?? 'download',
          fileName: json['file_name'] as String? ?? '',
          transferredBytes: (json['transferred_bytes'] as num?)?.toInt() ?? 0,
          totalBytes: (json['total_bytes'] as num?)?.toInt() ?? 0,
          done: json['done'] as bool? ?? false,
          error: json['error'] as String?,
        ),
      ),
      _ => SessionStatusEvent(
        sessionId: sid,
        phase: SessionPhase.error,
        message: json['message'] as String? ?? '连接发生错误',
      ),
    };
  }
}

class SessionOutputChunk {
  const SessionOutputChunk({required this.sessionId, required this.bytes});

  final String sessionId;
  final Uint8List bytes;
}

class LocalShellOption {
  const LocalShellOption({
    required this.id,
    required this.name,
    required this.program,
    this.args = const [],
    this.isDefault = false,
  });

  final String id;
  final String name;
  final String program;
  final List<String> args;
  final bool isDefault;

  factory LocalShellOption.fromJson(Map<String, dynamic> json) {
    final rawArgs = json['args'] as List<dynamic>? ?? const [];
    return LocalShellOption(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      program: json['program'] as String? ?? '',
      args: rawArgs.map((e) => e.toString()).toList(),
      isDefault: json['is_default'] as bool? ?? false,
    );
  }
}

class KeyInspectionResult {
  const KeyInspectionResult({
    required this.valid,
    required this.encrypted,
    this.algorithm,
    this.fingerprint,
    required this.message,
  });

  final bool valid;
  final bool encrypted;
  final String? algorithm;
  final String? fingerprint;
  final String message;

  factory KeyInspectionResult.fromJson(Map<String, dynamic> json) {
    return KeyInspectionResult(
      valid: json['valid'] as bool? ?? false,
      encrypted: json['encrypted'] as bool? ?? false,
      algorithm: json['algorithm'] as String?,
      fingerprint: json['fingerprint'] as String?,
      message: json['message'] as String? ?? '',
    );
  }
}

class DiscoveredSshKey {
  const DiscoveredSshKey({
    required this.name,
    required this.path,
    required this.encrypted,
  });

  final String name;
  final String path;
  final bool encrypted;

  factory DiscoveredSshKey.fromJson(Map<String, dynamic> json) {
    return DiscoveredSshKey(
      name: json['name'] as String? ?? '',
      path: json['path'] as String? ?? '',
      encrypted: json['encrypted'] as bool? ?? false,
    );
  }
}

enum SyncMode {
  merge('merge', '双向合并', '按修改时间智能合并本地与云端，并写回最新结果'),
  pullOverwrite(
    'pull_overwrite',
    '仅拉取覆盖',
    '以云端为准覆盖本机，绝不把本机修改或删除上传到云端',
  ),
  pushOverwrite(
    'push_overwrite',
    '仅上传覆盖',
    '以本机配置直接覆盖云端备份',
  );

  const SyncMode(this.wireValue, this.label, this.description);
  final String wireValue;
  final String label;
  final String description;

  static SyncMode fromWire(String? raw) {
    return switch (raw) {
      'push_overwrite' => SyncMode.pushOverwrite,
      'pull_overwrite' => SyncMode.pullOverwrite,
      _ => SyncMode.merge,
    };
  }
}

class WebDavConfig {
  const WebDavConfig({
    this.url = '',
    this.username = '',
    this.password = '',
    this.remotePath = 'NexusSSH/hosts_sync.json',
    this.encryptionPassword = '',
    this.hasPassword = false,
    this.hasEncryptionPassword = false,
    this.clearEncryptionPassword = false,
    this.autoSync = false,
    this.defaultSyncMode = SyncMode.merge,
    this.lastSyncMs,
    this.lastSyncMessage,
  });

  final String url;
  final String username;
  final String password;
  final String remotePath;
  final String encryptionPassword;
  final bool hasPassword;
  final bool hasEncryptionPassword;
  final bool clearEncryptionPassword;
  final bool autoSync;
  final SyncMode defaultSyncMode;
  final int? lastSyncMs;
  final String? lastSyncMessage;

  bool get isConfigured => url.trim().isNotEmpty;
  bool get hasStoredPassword => hasPassword || password.isNotEmpty;
  bool get hasStoredEncryptionPassword =>
      hasEncryptionPassword || encryptionPassword.isNotEmpty;

  factory WebDavConfig.fromJson(Map<String, dynamic> json) {
    final password = json['password'] as String? ?? '';
    final encryptionPassword = json['encryption_password'] as String? ?? '';
    return WebDavConfig(
      url: json['url'] as String? ?? '',
      username: json['username'] as String? ?? '',
      password: password,
      remotePath: json['remote_path'] as String? ?? 'NexusSSH/hosts_sync.json',
      encryptionPassword: encryptionPassword,
      hasPassword: (json['has_password'] as bool?) ?? password.isNotEmpty,
      hasEncryptionPassword:
          (json['has_encryption_password'] as bool?) ??
          encryptionPassword.isNotEmpty,
      clearEncryptionPassword:
          json['clear_encryption_password'] as bool? ?? false,
      autoSync: json['auto_sync'] as bool? ?? false,
      defaultSyncMode: SyncMode.fromWire(json['default_sync_mode'] as String?),
      lastSyncMs: (json['last_sync_ms'] as num?)?.toInt(),
      lastSyncMessage: json['last_sync_message'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'url': url,
      'username': username,
      'password': password,
      'remote_path': remotePath,
      'encryption_password': encryptionPassword,
      'has_password': hasStoredPassword,
      'has_encryption_password': hasStoredEncryptionPassword,
      'clear_encryption_password': clearEncryptionPassword,
      'auto_sync': autoSync,
      'default_sync_mode': defaultSyncMode.wireValue,
      'last_sync_ms': lastSyncMs,
      'last_sync_message': lastSyncMessage,
    };
  }
}

class WebDavSyncResult {
  const WebDavSyncResult({
    required this.ok,
    required this.totalHosts,
    this.totalSnippets = 0,
    required this.syncedAtMs,
    required this.message,
    required this.hosts,
    this.snippets = const [],
  });

  final bool ok;
  final int totalHosts;
  final int totalSnippets;
  final int syncedAtMs;
  final String message;
  final List<HostProfile> hosts;
  final List<SnippetItem> snippets;

  factory WebDavSyncResult.fromJson(Map<String, dynamic> json) {
    final rawHosts = json['hosts'] as List<dynamic>? ?? const [];
    final rawSnippets = json['snippets'] as List<dynamic>? ?? const [];
    return WebDavSyncResult(
      ok: json['ok'] as bool? ?? false,
      totalHosts: (json['total_hosts'] as num?)?.toInt() ?? 0,
      totalSnippets: (json['total_snippets'] as num?)?.toInt() ?? 0,
      syncedAtMs: (json['synced_at_ms'] as num?)?.toInt() ?? 0,
      message: json['message'] as String? ?? '',
      hosts: rawHosts
          .map((e) => HostProfile.fromJson(e as Map<String, dynamic>))
          .toList(),
      snippets: rawSnippets
          .map((e) => SnippetItem.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}
