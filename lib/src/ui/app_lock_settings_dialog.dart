import 'package:flutter/material.dart';
import 'package:nexus_ssh/src/state/app_controller.dart';
import 'package:nexus_ssh/src/ui/app_theme.dart';
import 'package:nexus_ssh/src/ui/known_hosts_dialog.dart';

class AppLockSettingsDialog extends StatefulWidget {
  const AppLockSettingsDialog({
    super.key,
    required this.controller,
    this.isBottomSheet = false,
  });

  final AppController controller;
  final bool isBottomSheet;

  static Future<void> show(
    BuildContext context, {
    required AppController controller,
  }) {
    final isMobile = MediaQuery.sizeOf(context).width < 640;
    if (isMobile) {
      return showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) =>
            AppLockSettingsDialog(controller: controller, isBottomSheet: true),
      );
    }
    return showDialog<void>(
      context: context,
      builder: (_) => AppLockSettingsDialog(controller: controller),
    );
  }

  @override
  State<AppLockSettingsDialog> createState() => _AppLockSettingsDialogState();
}

class _AppLockSettingsDialogState extends State<AppLockSettingsDialog> {
  final _passCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  final _currentCtrl = TextEditingController();

  late bool _biometricsEnabled;
  late bool _lockOnStartup;
  late int _autoLockMinutes;
  bool _changingPasscode = false;
  bool _saving = false;
  String? _error;

  static const _timeoutOptions = <(int, String)>[
    (0, '切到后台立即锁定'),
    (1, '离开 1 分钟后'),
    (5, '离开 5 分钟后'),
    (15, '离开 15 分钟后'),
    (-1, '仅手动锁定'),
  ];

  @override
  void initState() {
    super.initState();
    final cfg = widget.controller.appLockConfig;
    _biometricsEnabled =
        cfg.biometricsEnabled && widget.controller.biometricCapability.supported;
    _lockOnStartup = cfg.lockOnStartup;
    _autoLockMinutes = cfg.autoLockMinutes;
  }

  @override
  void dispose() {
    _passCtrl.dispose();
    _confirmCtrl.dispose();
    _currentCtrl.dispose();
    super.dispose();
  }

  Future<void> _enableOrUpdatePasscode() async {
    final cfg = widget.controller.appLockConfig;
    final p1 = _passCtrl.text;
    final p2 = _confirmCtrl.text;

    if (p1.length < 4) {
      setState(() => _error = '应用密码至少需要 4 位字符');
      return;
    }
    if (p1 != p2) {
      setState(() => _error = '两次输入的密码不一致');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (cfg.enabled) {
        final verified = await widget.controller.backend.verifyAppLockPasscode(
          _currentCtrl.text,
        );
        if (!verified) {
          if (!mounted) return;
          setState(() => _error = '当前应用密码不正确');
          return;
        }
      }

      await widget.controller.enableOrChangeAppLock(
        passcode: p1,
        biometricsEnabled: _biometricsEnabled,
        lockOnStartup: _lockOnStartup,
        autoLockMinutes: _autoLockMinutes,
      );
      if (!mounted) return;
      _passCtrl.clear();
      _confirmCtrl.clear();
      _currentCtrl.clear();
      setState(() => _changingPasscode = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(cfg.enabled ? '应用锁密码已更新' : '应用锁已开启'),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveSettingsOnly() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.controller.updateAppLockSettings(
        biometricsEnabled: _biometricsEnabled,
        lockOnStartup: _lockOnStartup,
        autoLockMinutes: _autoLockMinutes,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _confirmDisable() async {
    final canBio = widget.controller.canUseBiometricsForUnlock;
    if (canBio) {
      final bio = await widget.controller.verifyBiometricsForSensitiveAction(
        '验证身份以关闭 Nexus SSH 应用锁',
      );
      if (bio.succeeded) {
        await widget.controller.disableAppLock(bypassVerified: true);
        if (!mounted) return;
        Navigator.of(context).pop();
        return;
      }
    }

    if (!mounted) return;
    final ctrl = TextEditingController();
    String? dialogError;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('关闭应用锁'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '请输入当前应用锁密码以确认关闭保护：',
                style: TextStyle(fontSize: 13, color: NexusColors.textSecondary),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                obscureText: true,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: '当前应用密码',
                  errorText: dialogError,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: NexusColors.rose),
              onPressed: () async {
                try {
                  await widget.controller.disableAppLock(
                    currentPasscode: ctrl.text,
                  );
                  if (ctx.mounted) Navigator.of(ctx).pop(true);
                } catch (e) {
                  setDialogState(() => dialogError = e.toString());
                }
              },
              child: const Text('确认关闭', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
    ctrl.dispose();
    if (confirmed == true && mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final cfg = widget.controller.appLockConfig;
    final bioCap = widget.controller.biometricCapability;
    final showPasscodeForm = !cfg.enabled || _changingPasscode;

    final content = Padding(
      padding: EdgeInsets.fromLTRB(20, 14, 20, 20 + bottomInset),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.isBottomSheet)
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(
                    color: NexusColors.borderActive,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              ),
            Row(
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: TextButton.styleFrom(
                    foregroundColor: NexusColors.textSecondary,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(44, 34),
                  ),
                  child: const Text('关闭'),
                ),
                const Expanded(
                  child: Text(
                    '安全中心',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 16.5,
                      fontWeight: FontWeight.w600,
                      color: NexusColors.textPrimary,
                    ),
                  ),
                ),
                const SizedBox(width: 44),
              ],
            ),
            const SizedBox(height: 14),

            // Status Banner
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: (cfg.enabled
                        ? NexusColors.emerald
                        : NexusColors.textMuted)
                    .withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  Icon(
                    cfg.enabled
                        ? Icons.verified_user_rounded
                        : Icons.lock_open_rounded,
                    size: 20,
                    color: cfg.enabled
                        ? NexusColors.emerald
                        : NexusColors.textSecondary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          cfg.enabled ? '应用锁已开启' : '应用锁未开启',
                          style: TextStyle(
                            fontSize: 13.8,
                            fontWeight: FontWeight.w600,
                            color: cfg.enabled
                                ? NexusColors.emerald
                                : NexusColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          cfg.enabled
                              ? '启动及离开应用后自动隐藏终端与主机凭据'
                              : '设置本地应用密码后，可使用密码或${bioCap.supported ? bioCap.label : "主密码"}保护凭据库',
                          style: const TextStyle(
                            fontSize: 11.8,
                            color: NexusColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (cfg.enabled)
                    TextButton.icon(
                      onPressed: () {
                        Navigator.of(context).pop();
                        widget.controller.lockNow();
                      },
                      style: TextButton.styleFrom(
                        foregroundColor: NexusColors.emerald,
                        backgroundColor: NexusColors.bgSurface,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        minimumSize: const Size(0, 32),
                      ),
                      icon: const Icon(Icons.lock_outline_rounded, size: 15),
                      label: const Text('立即锁屏', style: TextStyle(fontSize: 12)),
                    ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // Policy Settings Card
            Material(
              color: NexusColors.bgSurface,
              borderRadius: BorderRadius.circular(14),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  if (bioCap.supported) ...[
                    SwitchListTile.adaptive(
                      value: _biometricsEnabled,
                      activeTrackColor: NexusColors.emerald,
                      title: Text(
                        '使用 ${bioCap.label} 解锁',
                        style: const TextStyle(fontSize: 13.8),
                      ),
                      subtitle: const Text(
                        '优先调用系统生物识别，失败时可回退应用密码',
                        style: TextStyle(
                          fontSize: 11.6,
                          color: NexusColors.textMuted,
                        ),
                      ),
                      onChanged: (v) {
                        setState(() => _biometricsEnabled = v);
                        if (cfg.enabled) _saveSettingsOnly();
                      },
                    ),
                    const Divider(
                      height: 1,
                      indent: 16,
                      color: NexusColors.borderSubtle,
                    ),
                  ],
                  SwitchListTile.adaptive(
                    value: _lockOnStartup,
                    activeTrackColor: NexusColors.emerald,
                    title: const Text(
                      '启动时要求解锁',
                      style: TextStyle(fontSize: 13.8),
                    ),
                    subtitle: const Text(
                      '每次打开 Nexus SSH 时先通过身份验证',
                      style: TextStyle(
                        fontSize: 11.6,
                        color: NexusColors.textMuted,
                      ),
                    ),
                    onChanged: (v) {
                      setState(() => _lockOnStartup = v);
                      if (cfg.enabled) _saveSettingsOnly();
                    },
                  ),
                  const Divider(
                    height: 1,
                    indent: 16,
                    color: NexusColors.borderSubtle,
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '切到后台 / 托盘后自动锁定',
                          style: TextStyle(
                            fontSize: 13.2,
                            color: NexusColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final (mins, label) in _timeoutOptions)
                              ChoiceChip(
                                label: Text(
                                  label,
                                  style: TextStyle(
                                    fontSize: 11.8,
                                    color: _autoLockMinutes == mins
                                        ? NexusColors.emerald
                                        : NexusColors.textSecondary,
                                  ),
                                ),
                                selected: _autoLockMinutes == mins,
                                selectedColor: NexusColors.emerald.withValues(
                                  alpha: 0.16,
                                ),
                                backgroundColor: NexusColors.bgCanvas,
                                side: BorderSide(
                                  color: _autoLockMinutes == mins
                                      ? NexusColors.emerald.withValues(
                                          alpha: 0.65,
                                        )
                                      : NexusColors.borderSubtle,
                                ),
                                showCheckmark: false,
                                onSelected: (_) {
                                  setState(() => _autoLockMinutes = mins);
                                  if (cfg.enabled) _saveSettingsOnly();
                                },
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // Passcode setup / change section
            if (showPasscodeForm) ...[
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: NexusColors.bgSurface,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      cfg.enabled ? '修改应用锁密码' : '设置本地应用密码（至少 4 位）',
                      style: const TextStyle(
                        fontSize: 13.2,
                        fontWeight: FontWeight.w600,
                        color: NexusColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (cfg.enabled) ...[
                      TextField(
                        controller: _currentCtrl,
                        obscureText: true,
                        decoration: const InputDecoration(
                          hintText: '输入当前应用密码',
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    TextField(
                      controller: _passCtrl,
                      obscureText: true,
                      decoration: const InputDecoration(
                        hintText: '输入新应用密码（数字或字符均可）',
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _confirmCtrl,
                      obscureText: true,
                      onSubmitted: (_) => _enableOrUpdatePasscode(),
                      decoration: const InputDecoration(
                        hintText: '再次输入新密码确认',
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _error!,
                        style: const TextStyle(
                          fontSize: 12,
                          color: NexusColors.rose,
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        if (cfg.enabled) ...[
                          TextButton(
                            onPressed: _saving
                                ? null
                                : () => setState(() {
                                    _changingPasscode = false;
                                    _error = null;
                                  }),
                            child: const Text('取消'),
                          ),
                          const SizedBox(width: 8),
                        ],
                        Expanded(
                          child: FilledButton(
                            onPressed: _saving ? null : _enableOrUpdatePasscode,
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                            child: Text(cfg.enabled ? '保存新密码' : '开启应用锁'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ] else ...[
              Row(
                children: [
                  Expanded(
                    child: TextButton.icon(
                      onPressed: () => setState(() {
                        _changingPasscode = true;
                        _error = null;
                      }),
                      style: TextButton.styleFrom(
                        backgroundColor: NexusColors.bgSurface,
                        foregroundColor: NexusColors.textPrimary,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      icon: const Icon(Icons.password_rounded, size: 17),
                      label: const Text('修改密码'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextButton.icon(
                      onPressed: _confirmDisable,
                      style: TextButton.styleFrom(
                        backgroundColor: NexusColors.rose.withValues(
                          alpha: 0.14,
                        ),
                        foregroundColor: NexusColors.rose,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      icon: const Icon(Icons.lock_open_rounded, size: 17),
                      label: const Text('关闭应用锁'),
                    ),
                  ),
                ],
              ),
            ],

            const SizedBox(height: 16),

            // Additional Security Tools: known_hosts + Clipboard Auto-Clear
            ListenableBuilder(
              listenable: widget.controller,
              builder: (context, _) => Material(
                color: NexusColors.bgSurface,
                borderRadius: BorderRadius.circular(14),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(
                        Icons.fingerprint_rounded,
                        size: 20,
                        color: NexusColors.cyan,
                      ),
                      title: const Text(
                        '受信任主机指纹 (known_hosts)',
                        style: TextStyle(fontSize: 13.6),
                      ),
                      subtitle: const Text(
                        '查看或清理已记录的 SSH 服务器公钥指纹',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: NexusColors.textMuted,
                        ),
                      ),
                      trailing: const Icon(
                        Icons.chevron_right_rounded,
                        size: 18,
                        color: NexusColors.textMuted,
                      ),
                      onTap: () => KnownHostsDialog.show(
                        context,
                        controller: widget.controller,
                      ),
                    ),
                    const Divider(
                      height: 1,
                      indent: 16,
                      color: NexusColors.borderSubtle,
                    ),
                    SwitchListTile.adaptive(
                      value: widget.controller.clipboardAutoClearEnabled,
                      activeTrackColor: NexusColors.emerald,
                      title: const Text(
                        '剪贴板 30 秒自动清空',
                        style: TextStyle(fontSize: 13.6),
                      ),
                      subtitle: const Text(
                        '从终端或命令片段复制内容后自动清理残留剪贴板',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: NexusColors.textMuted,
                        ),
                      ),
                      onChanged: widget.controller.setClipboardAutoClearEnabled,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );

    if (widget.isBottomSheet) return content;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: content,
      ),
    );
  }
}
