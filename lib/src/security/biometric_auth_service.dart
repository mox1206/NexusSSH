import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

class BiometricCapability {
  const BiometricCapability({
    required this.supported,
    required this.label,
    this.hasFace = false,
    this.hasFingerprint = false,
  });

  static const unsupported = BiometricCapability(
    supported: false,
    label: '生物识别',
  );

  final bool supported;
  final String label;
  final bool hasFace;
  final bool hasFingerprint;
}

class BiometricAuthOutcome {
  const BiometricAuthOutcome({required this.succeeded, this.errorMessage});

  final bool succeeded;
  final String? errorMessage;
}

abstract class BiometricAuthService {
  Future<BiometricCapability> checkCapability();
  Future<BiometricAuthOutcome> authenticate({required String reason});
}

class NoopBiometricAuthService implements BiometricAuthService {
  const NoopBiometricAuthService();

  @override
  Future<BiometricCapability> checkCapability() async =>
      BiometricCapability.unsupported;

  @override
  Future<BiometricAuthOutcome> authenticate({required String reason}) async {
    return const BiometricAuthOutcome(
      succeeded: false,
      errorMessage: '当前设备不支持生物识别',
    );
  }
}

class LocalBiometricAuthService implements BiometricAuthService {
  LocalBiometricAuthService([LocalAuthentication? auth])
    : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  static bool get _platformHasLocalAuth =>
      !kIsWeb &&
      (Platform.isAndroid ||
          Platform.isIOS ||
          Platform.isMacOS ||
          Platform.isWindows);

  @override
  Future<BiometricCapability> checkCapability() async {
    if (!_platformHasLocalAuth) {
      return BiometricCapability.unsupported;
    }
    try {
      final deviceSupported = await _auth.isDeviceSupported();
      final canCheck = await _auth.canCheckBiometrics;
      if (!deviceSupported && !canCheck) {
        return BiometricCapability.unsupported;
      }

      List<BiometricType> types = const [];
      try {
        types = await _auth.getAvailableBiometrics();
      } catch (_) {}

      final hasFace = types.contains(BiometricType.face);
      final hasFingerprint =
          types.contains(BiometricType.fingerprint) ||
          types.contains(BiometricType.strong);

      final String label;
      if (Platform.isWindows) {
        label = 'Windows Hello';
      } else if (Platform.isMacOS) {
        label = '触控 ID / 系统认证';
      } else if (Platform.isIOS) {
        if (hasFace) {
          label = '面容 ID';
        } else if (hasFingerprint) {
          label = '触控 ID';
        } else {
          label = '面容 / 触控 ID';
        }
      } else {
        // Android
        if (hasFace && hasFingerprint) {
          label = '指纹 / 面部识别';
        } else if (hasFace) {
          label = '面部识别';
        } else if (hasFingerprint) {
          label = '指纹识别';
        } else {
          label = '生物识别 / 设备锁';
        }
      }

      return BiometricCapability(
        supported: true,
        label: label,
        hasFace: hasFace,
        hasFingerprint: hasFingerprint,
      );
    } catch (_) {
      return BiometricCapability.unsupported;
    }
  }

  @override
  Future<BiometricAuthOutcome> authenticate({required String reason}) async {
    if (!_platformHasLocalAuth) {
      return const BiometricAuthOutcome(
        succeeded: false,
        errorMessage: '当前平台不支持系统生物识别，请使用应用密码解锁',
      );
    }
    try {
      final ok = await _auth.authenticate(
        localizedReason: reason,
        biometricOnly: false,
        persistAcrossBackgrounding: true,
      );
      return BiometricAuthOutcome(
        succeeded: ok,
        errorMessage: ok ? null : '未完成身份验证',
      );
    } on LocalAuthException catch (e) {
      return BiometricAuthOutcome(
        succeeded: false,
        errorMessage: _friendlyError(e),
      );
    } on MissingPluginException {
      return const BiometricAuthOutcome(
        succeeded: false,
        errorMessage: '当前环境未启用系统生物识别组件',
      );
    } catch (e) {
      return BiometricAuthOutcome(succeeded: false, errorMessage: '验证失败: $e');
    }
  }

  String _friendlyError(LocalAuthException e) {
    return switch (e.code) {
      LocalAuthExceptionCode.userCanceled ||
      LocalAuthExceptionCode.systemCanceled => '已取消生物识别验证',
      LocalAuthExceptionCode.noBiometricsEnrolled ||
      LocalAuthExceptionCode.noCredentialsSet => '系统尚未设置生物识别或设备锁，请使用应用密码',
      LocalAuthExceptionCode.temporaryLockout ||
      LocalAuthExceptionCode.biometricLockout => '尝试次数过多，请改用应用密码解锁',
      LocalAuthExceptionCode.noBiometricHardware ||
      LocalAuthExceptionCode.biometricHardwareTemporarilyUnavailable =>
        '当前设备生物识别不可用，请使用应用密码',
      _ => e.description ?? '生物识别验证失败',
    };
  }
}
