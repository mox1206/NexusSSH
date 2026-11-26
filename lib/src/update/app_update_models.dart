import 'package:flutter/foundation.dart';

class AppUpdateConfig {
  AppUpdateConfig._();

  static const String githubRepo = 'mox1206/NexusSSH';
  static const String defaultManifestUrl =
      'https://github.com/$githubRepo/releases/latest/download/latest.json';
  static const String defaultReleasesPageUrl =
      'https://github.com/$githubRepo/releases';

  /// Embedded at build time via `--dart-define=APP_VERSION=...` in CI,
  /// defaulting to the version declared in `pubspec.yaml`.
  static const String fallbackVersion = String.fromEnvironment(
    'APP_VERSION',
    defaultValue: '1.0.1',
  );
  static const int fallbackBuildNumber = int.fromEnvironment(
    'APP_BUILD_NUMBER',
    defaultValue: 2,
  );
}

@immutable
class AppVersionInfo {
  const AppVersionInfo({required this.version, required this.buildNumber});

  final String version;
  final int buildNumber;

  String get displayLabel => 'v$version';

  bool isNewerThan(AppVersionInfo other) {
    final cmp = compareSemVer(version, other.version);
    if (cmp != 0) return cmp > 0;
    return buildNumber > other.buildNumber;
  }

  /// Compares two semantic version strings (e.g. `1.2.3`, `1.2.3-beta.1`, `v1.2.3`).
  /// Returns `> 0` if [a] is newer than [b], `< 0` if older, `0` if equal.
  static int compareSemVer(String a, String b) {
    final pa = _ParsedSemVer.parse(a);
    final pb = _ParsedSemVer.parse(b);

    if (pa.major != pb.major) return pa.major.compareTo(pb.major);
    if (pa.minor != pb.minor) return pa.minor.compareTo(pb.minor);
    if (pa.patch != pb.patch) return pa.patch.compareTo(pb.patch);

    // Release without pre-release tag is newer than a pre-release of the same version
    if (pa.preRelease.isEmpty && pb.preRelease.isEmpty) return 0;
    if (pa.preRelease.isEmpty) return 1;
    if (pb.preRelease.isEmpty) return -1;

    final maxLen = pa.preRelease.length > pb.preRelease.length
        ? pa.preRelease.length
        : pb.preRelease.length;
    for (var i = 0; i < maxLen; i++) {
      if (i >= pa.preRelease.length) return -1;
      if (i >= pb.preRelease.length) return 1;
      final segA = pa.preRelease[i];
      final segB = pb.preRelease[i];
      final numA = int.tryParse(segA);
      final numB = int.tryParse(segB);
      if (numA != null && numB != null) {
        if (numA != numB) return numA.compareTo(numB);
      } else if (numA != null) {
        return -1;
      } else if (numB != null) {
        return 1;
      } else {
        final strCmp = segA.compareTo(segB);
        if (strCmp != 0) return strCmp;
      }
    }
    return 0;
  }

  @override
  bool operator ==(Object other) =>
      other is AppVersionInfo &&
      other.version == version &&
      other.buildNumber == buildNumber;

  @override
  int get hashCode => Object.hash(version, buildNumber);
}

class _ParsedSemVer {
  const _ParsedSemVer(this.major, this.minor, this.patch, this.preRelease);

  final int major;
  final int minor;
  final int patch;
  final List<String> preRelease;

  static _ParsedSemVer parse(String raw) {
    var cleaned = raw.trim();
    if (cleaned.startsWith('v') || cleaned.startsWith('V')) {
      cleaned = cleaned.substring(1);
    }
    final plusIdx = cleaned.indexOf('+');
    if (plusIdx >= 0) {
      cleaned = cleaned.substring(0, plusIdx);
    }
    String core = cleaned;
    List<String> pre = const [];
    final dashIdx = cleaned.indexOf('-');
    if (dashIdx >= 0) {
      core = cleaned.substring(0, dashIdx);
      final preStr = cleaned.substring(dashIdx + 1);
      if (preStr.isNotEmpty) {
        pre = preStr.split('.');
      }
    }
    final parts = core.split('.');
    int partAt(int index) =>
        index < parts.length ? (int.tryParse(parts[index]) ?? 0) : 0;
    return _ParsedSemVer(partAt(0), partAt(1), partAt(2), pre);
  }
}

@immutable
class UpdateAsset {
  const UpdateAsset({
    required this.platformKey,
    required this.fileName,
    required this.url,
    required this.sha256,
    required this.size,
    required this.kind,
  });

  final String platformKey;
  final String fileName;
  final String url;
  final String sha256;
  final int size;
  final String kind;

  factory UpdateAsset.fromJson(String platformKey, Map<String, dynamic> json) {
    return UpdateAsset(
      platformKey: platformKey,
      fileName: (json['fileName'] as String? ?? '').trim(),
      url: (json['url'] as String? ?? '').trim(),
      sha256: (json['sha256'] as String? ?? '').trim().toLowerCase(),
      size: (json['size'] as num? ?? 0).toInt(),
      kind: (json['kind'] as String? ?? '').trim().toLowerCase(),
    );
  }

  String get formattedSize {
    if (size <= 0) return '未知大小';
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) {
      return '${(size / 1024).toStringAsFixed(1)} KB';
    }
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

@immutable
class UpdateManifest {
  const UpdateManifest({
    required this.schemaVersion,
    required this.version,
    required this.buildNumber,
    required this.tag,
    required this.publishedAt,
    required this.releaseUrl,
    required this.notes,
    required this.platforms,
  });

  final int schemaVersion;
  final String version;
  final int buildNumber;
  final String tag;
  final String publishedAt;
  final String releaseUrl;
  final String notes;
  final Map<String, UpdateAsset> platforms;

  AppVersionInfo get versionInfo =>
      AppVersionInfo(version: version, buildNumber: buildNumber);

  factory UpdateManifest.fromJson(Map<String, dynamic> json) {
    final version = (json['version'] as String? ?? '').trim();
    if (version.isEmpty) {
      throw const FormatException('更新清单缺少 version 字段');
    }
    final rawPlatforms = json['platforms'];
    final parsedPlatforms = <String, UpdateAsset>{};
    if (rawPlatforms is Map) {
      for (final entry in rawPlatforms.entries) {
        final key = entry.key.toString().trim();
        final value = entry.value;
        if (key.isNotEmpty && value is Map) {
          final asset = UpdateAsset.fromJson(
            key,
            Map<String, dynamic>.from(value),
          );
          if (asset.url.isNotEmpty && asset.fileName.isNotEmpty) {
            parsedPlatforms[key] = asset;
          }
        }
      }
    }
    return UpdateManifest(
      schemaVersion: (json['schemaVersion'] as num? ?? 1).toInt(),
      version: version,
      buildNumber: (json['buildNumber'] as num? ?? 0).toInt(),
      tag: (json['tag'] as String? ?? 'v$version').trim(),
      publishedAt: (json['publishedAt'] as String? ?? '').trim(),
      releaseUrl: (json['releaseUrl'] as String? ??
              AppUpdateConfig.defaultReleasesPageUrl)
          .trim(),
      notes: (json['notes'] as String? ?? '').trim(),
      platforms: Map<String, UpdateAsset>.unmodifiable(parsedPlatforms),
    );
  }
}

enum UpdatePhase {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  verifying,
  readyToInstall,
  installing,
  error,
}

@immutable
class UpdateState {
  const UpdateState({
    this.phase = UpdatePhase.idle,
    this.currentVersion = const AppVersionInfo(
      version: AppUpdateConfig.fallbackVersion,
      buildNumber: AppUpdateConfig.fallbackBuildNumber,
    ),
    this.manifest,
    this.matchedAsset,
    this.downloadedFilePath,
    this.downloadedBytes = 0,
    this.totalBytes = 0,
    this.errorMessage,
    this.statusMessage,
    this.ignoredVersion = '',
    this.mirrorPrefix = '',
    this.lastCheckedAt,
  });

  final UpdatePhase phase;
  final AppVersionInfo currentVersion;
  final UpdateManifest? manifest;
  final UpdateAsset? matchedAsset;
  final String? downloadedFilePath;
  final int downloadedBytes;
  final int totalBytes;
  final String? errorMessage;
  final String? statusMessage;
  final String ignoredVersion;
  final String mirrorPrefix;
  final DateTime? lastCheckedAt;

  bool get hasAvailableUpdate {
    final m = manifest;
    if (m == null) return false;
    return m.versionInfo.isNewerThan(currentVersion);
  }

  bool get hasUnignoredUpdate =>
      hasAvailableUpdate &&
      manifest!.version.isNotEmpty &&
      manifest!.version != ignoredVersion;

  bool get isBusy =>
      phase == UpdatePhase.checking ||
      phase == UpdatePhase.downloading ||
      phase == UpdatePhase.verifying ||
      phase == UpdatePhase.installing;

  double? get downloadProgress {
    if (totalBytes <= 0) return null;
    return (downloadedBytes / totalBytes).clamp(0.0, 1.0);
  }

  UpdateState copyWith({
    UpdatePhase? phase,
    AppVersionInfo? currentVersion,
    UpdateManifest? manifest,
    bool clearManifest = false,
    UpdateAsset? matchedAsset,
    bool clearMatchedAsset = false,
    String? downloadedFilePath,
    bool clearDownloadedFilePath = false,
    int? downloadedBytes,
    int? totalBytes,
    String? errorMessage,
    bool clearErrorMessage = false,
    String? statusMessage,
    bool clearStatusMessage = false,
    String? ignoredVersion,
    String? mirrorPrefix,
    DateTime? lastCheckedAt,
  }) {
    return UpdateState(
      phase: phase ?? this.phase,
      currentVersion: currentVersion ?? this.currentVersion,
      manifest: clearManifest ? null : (manifest ?? this.manifest),
      matchedAsset: clearMatchedAsset
          ? null
          : (matchedAsset ?? this.matchedAsset),
      downloadedFilePath: clearDownloadedFilePath
          ? null
          : (downloadedFilePath ?? this.downloadedFilePath),
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      errorMessage: clearErrorMessage
          ? null
          : (errorMessage ?? this.errorMessage),
      statusMessage: clearStatusMessage
          ? null
          : (statusMessage ?? this.statusMessage),
      ignoredVersion: ignoredVersion ?? this.ignoredVersion,
      mirrorPrefix: mirrorPrefix ?? this.mirrorPrefix,
      lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
    );
  }
}
