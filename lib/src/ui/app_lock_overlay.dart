import 'package:flutter/material.dart';
import 'package:nexus_ssh/src/state/app_controller.dart';
import 'package:nexus_ssh/src/ui/app_theme.dart';

/// Full-screen Termius-style lock screen shown above all hosts, terminals,
/// and modal overlays whenever App Lock is engaged.
class AppLockOverlay extends StatefulWidget {
  const AppLockOverlay({super.key, required this.controller});

  final AppController controller;

  @override
  State<AppLockOverlay> createState() => _AppLockOverlayState();
}

class _AppLockOverlayState extends State<AppLockOverlay> {
  final _passcodeCtrl = TextEditingController();
  final _focusNode = FocusNode();

  bool _verifying = false;
  bool _obscure = true;
  bool _autoBiometricAttempted = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeAutoPromptBiometrics();
    });
  }

  void _onControllerChanged() {
    if (!mounted) return;
    _maybeAutoPromptBiometrics();
  }

  void _maybeAutoPromptBiometrics() {
    if (!mounted || widget.controller.privacyShieldActive) {
      // Wait until the app is actually foreground/resumed before popping
      // system Face ID / Touch ID / Windows Hello prompts.
      return;
    }
    if (widget.controller.canUseBiometricsForUnlock &&
        !_autoBiometricAttempted) {
      _autoBiometricAttempted = true;
      _triggerBiometrics();
    } else if (!_focusNode.hasFocus) {
      _focusNode.requestFocus();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _passcodeCtrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _submitPasscode() async {
    final pin = _passcodeCtrl.text;
    if (pin.isEmpty || _verifying) return;
    setState(() {
      _verifying = true;
      _errorText = null;
    });
    try {
      final ok = await widget.controller.unlockWithPasscode(pin);
      if (!mounted) return;
      if (!ok) {
        _passcodeCtrl.clear();
        setState(() => _errorText = '应用密码错误，请重试');
        _focusNode.requestFocus();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorText = e.toString());
    } finally {
      if (mounted) {
        setState(() => _verifying = false);
      }
    }
  }

  Future<void> _triggerBiometrics() async {
    if (_verifying) return;
    setState(() {
      _verifying = true;
      _errorText = null;
    });
    try {
      final outcome = await widget.controller.unlockWithBiometrics();
      if (!mounted) return;
      if (!outcome.succeeded && outcome.errorMessage != null) {
        setState(() => _errorText = outcome.errorMessage);
        _focusNode.requestFocus();
      }
    } finally {
      if (mounted) {
        setState(() => _verifying = false);
      }
    }
  }

  IconData _biometricIcon() {
    final cap = widget.controller.biometricCapability;
    if (cap.hasFace && !cap.hasFingerprint) {
      return Icons.face_rounded;
    }
    return Icons.fingerprint_rounded;
  }

  @override
  Widget build(BuildContext context) {
    final canBio = widget.controller.canUseBiometricsForUnlock;
    final bioLabel = widget.controller.biometricCapability.label;

    return PopScope(
      canPop: false,
      child: Material(
        color: NexusColors.bgCanvas,
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Container(
                          width: 68,
                          height: 68,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              color: NexusColors.borderActive,
                              width: 1.2,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: NexusColors.emerald.withValues(
                                  alpha: 0.14,
                                ),
                                blurRadius: 24,
                                spreadRadius: 2,
                              ),
                            ],
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: Image.asset(
                            'assets/icons/app_icon.png',
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => const ColoredBox(
                              color: NexusColors.bgSurface,
                              child: Icon(
                                Icons.terminal_rounded,
                                color: NexusColors.emerald,
                                size: 32,
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          right: -4,
                          bottom: -4,
                          child: Container(
                            width: 26,
                            height: 26,
                            decoration: BoxDecoration(
                              color: NexusColors.emerald,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: NexusColors.bgCanvas,
                                width: 2.5,
                              ),
                            ),
                            child: const Icon(
                              Icons.lock_rounded,
                              size: 13,
                              color: Color(0xFF062819),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      'Nexus SSH 已锁定',
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                        color: NexusColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      '请输入应用锁密码以访问服务器凭据与活动终端',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12.8,
                        color: NexusColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 24),
                    TextField(
                      controller: _passcodeCtrl,
                      focusNode: _focusNode,
                      obscureText: _obscure,
                      enabled: !_verifying,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _submitPasscode(),
                      style: const TextStyle(
                        fontSize: 15,
                        letterSpacing: 1.4,
                        color: NexusColors.textPrimary,
                      ),
                      decoration: InputDecoration(
                        hintText: '输入应用锁密码',
                        prefixIcon: const Icon(
                          Icons.key_rounded,
                          size: 18,
                          color: NexusColors.textMuted,
                        ),
                        suffixIcon: IconButton(
                          visualDensity: VisualDensity.compact,
                          onPressed: () => setState(() => _obscure = !_obscure),
                          icon: Icon(
                            _obscure
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                            size: 18,
                            color: NexusColors.textMuted,
                          ),
                        ),
                      ),
                    ),
                    if (_errorText != null) ...[
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          const Icon(
                            Icons.error_outline_rounded,
                            size: 15,
                            color: NexusColors.rose,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              _errorText!,
                              style: const TextStyle(
                                fontSize: 12.2,
                                color: NexusColors.rose,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _verifying ? null : _submitPasscode,
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 13),
                        ),
                        child: _verifying
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Color(0xFF062819),
                                ),
                              )
                            : const Text('解锁'),
                      ),
                    ),
                    if (canBio) ...[
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: TextButton.icon(
                          onPressed: _verifying ? null : _triggerBiometrics,
                          style: TextButton.styleFrom(
                            backgroundColor: NexusColors.bgSurface,
                            foregroundColor: NexusColors.emerald,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          icon: Icon(_biometricIcon(), size: 19),
                          label: Text('使用 $bioLabel 解锁'),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Instant opaque privacy shield rendered when the app transitions to
/// background / task-switcher while App Lock is enabled so OS snapshots
/// never leak terminal output or host addresses.
class PrivacyShieldOverlay extends StatelessWidget {
  const PrivacyShieldOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return const Material(
      color: NexusColors.bgCanvas,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.shield_rounded,
              size: 46,
              color: NexusColors.emerald,
            ),
            SizedBox(height: 12),
            Text(
              'Nexus SSH 隐私保护中',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: NexusColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
