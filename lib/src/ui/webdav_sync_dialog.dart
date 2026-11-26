import 'package:flutter/material.dart';
import 'package:nexus_ssh/src/models/ssh_models.dart';
import 'package:nexus_ssh/src/state/app_controller.dart';
import 'package:nexus_ssh/src/ui/app_theme.dart';

class WebDavSyncDialog extends StatefulWidget {
  const WebDavSyncDialog({
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
            WebDavSyncDialog(controller: controller, isBottomSheet: true),
      );
    }

    return showDialog<void>(
      context: context,
      builder: (_) => WebDavSyncDialog(controller: controller),
    );
  }

  @override
  State<WebDavSyncDialog> createState() => _WebDavSyncDialogState();
}

class _WebDavSyncDialogState extends State<WebDavSyncDialog> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _urlCtrl;
  late final TextEditingController _userCtrl;
  late final TextEditingController _passCtrl;
  late final TextEditingController _pathCtrl;
  late final TextEditingController _encPassCtrl;

  late bool _autoSync;
  late SyncMode _defaultSyncMode;
  late bool _hasSavedPass;
  late bool _hasSavedEncPass;
  bool _clearEncPass = false;
  bool _obscurePass = true;
  bool _obscureEncPass = true;
  bool _testing = false;
  bool _syncing = false;
  bool? _feedbackOk;
  String? _feedbackMessage;

  @override
  void initState() {
    super.initState();
    final cfg = widget.controller.webDavConfig;
    _urlCtrl = TextEditingController(text: cfg.url);
    _userCtrl = TextEditingController(text: cfg.username);
    // Write-only security: never pre-populate stored WebDAV/E2E passwords in UI.
    _passCtrl = TextEditingController();
    _pathCtrl = TextEditingController(
      text: cfg.remotePath.isEmpty ? 'NexusSSH/hosts_sync.json' : cfg.remotePath,
    );
    _encPassCtrl = TextEditingController();
    _hasSavedPass = cfg.hasStoredPassword;
    _hasSavedEncPass = cfg.hasStoredEncryptionPassword;
    _autoSync = cfg.autoSync;
    _defaultSyncMode = cfg.defaultSyncMode;
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    _pathCtrl.dispose();
    _encPassCtrl.dispose();
    super.dispose();
  }

  WebDavConfig _buildDraft() {
    final prev = widget.controller.webDavConfig;
    return WebDavConfig(
      url: _urlCtrl.text.trim(),
      username: _userCtrl.text.trim(),
      password: _passCtrl.text,
      remotePath: _pathCtrl.text.trim().isEmpty
          ? 'NexusSSH/hosts_sync.json'
          : _pathCtrl.text.trim(),
      encryptionPassword: _encPassCtrl.text,
      hasPassword: _hasSavedPass || _passCtrl.text.isNotEmpty,
      hasEncryptionPassword:
          (_hasSavedEncPass && !_clearEncPass) || _encPassCtrl.text.isNotEmpty,
      clearEncryptionPassword: _clearEncPass && _encPassCtrl.text.isEmpty,
      autoSync: _autoSync,
      defaultSyncMode: _defaultSyncMode,
      lastSyncMs: prev.lastSyncMs,
      lastSyncMessage: prev.lastSyncMessage,
    );
  }

  Future<void> _saveOnly() async {
    final draft = _buildDraft();
    if (draft.url.isNotEmpty && !(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    try {
      await widget.controller.saveWebDavConfig(draft);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _feedbackOk = false;
        _feedbackMessage = e.toString();
      });
    }
  }

  Future<void> _runTest() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _testing = true;
      _feedbackMessage = null;
    });

    try {
      final res = await widget.controller.testWebDav(_buildDraft());
      if (!mounted) return;
      setState(() {
        _feedbackOk = res.ok;
        _feedbackMessage = res.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _feedbackOk = false;
        _feedbackMessage = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() => _testing = false);
      }
    }
  }

  bool get _willBeEncrypted =>
      (_hasSavedEncPass && !_clearEncPass) ||
      _encPassCtrl.text.trim().isNotEmpty;

  Future<void> _runSync(SyncMode mode) async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    if (!_willBeEncrypted && mode != SyncMode.pullOverwrite) {
      final proceedUnencrypted = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Row(
            children: [
              Icon(
                Icons.warning_amber_rounded,
                color: NexusColors.amber,
                size: 22,
              ),
              SizedBox(width: 8),
              Expanded(child: Text('未开启端到端加密')),
            ],
          ),
          content: const Text(
            '当前尚未设置 AES-256 端到端加密口令。\n\n继续同步将以明文 JSON 格式将服务器地址、账号、密码和私钥上传到 WebDAV 网盘，强烈建议先设置加密口令！',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('返回设置加密'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: NexusColors.amber,
                foregroundColor: const Color(0xFF1F1600),
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('了解风险，仍要同步'),
            ),
          ],
        ),
      );
      if (proceedUnencrypted != true) return;
      if (!mounted) return;
    }

    if (mode == SyncMode.pullOverwrite || mode == SyncMode.pushOverwrite) {
      final isPull = mode == SyncMode.pullOverwrite;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(isPull ? '从云端覆盖本地' : '上传并覆盖云端'),
          content: Text(
            isPull
                ? '此操作将使用云端配置完全替换当前本机的主机与片段列表（可用于恢复本机误删），确定继续吗？'
                : '此操作将使用当前本机配置完全替换云端备份（若本机已删除主机，云端也会同步移除），确定继续吗？',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(isPull ? '确定拉取覆盖' : '确定上传覆盖'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    setState(() {
      _syncing = true;
      _feedbackMessage = null;
    });

    try {
      final res = await widget.controller.syncWebDav(
        config: _buildDraft(),
        mode: mode,
      );
      if (!mounted) return;
      setState(() {
        _feedbackOk = res.ok;
        _feedbackMessage = res.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _feedbackOk = false;
        _feedbackMessage = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() => _syncing = false);
      }
    }
  }

  String _autoSyncHint() {
    if (!_autoSync) {
      return '当前为手动同步，仅在点击同步按钮时执行';
    }
    return switch (_defaultSyncMode) {
      SyncMode.merge => '启动与保存变更后自动合并 · 删除主机不会自动上传',
      SyncMode.pullOverwrite => '仅启动应用时自动从云端拉取 · 绝不上传本机改动',
      SyncMode.pushOverwrite => '保存变更后自动上传 · 启动与删除不会自动覆盖云端',
    };
  }

  static IconData _modeIcon(SyncMode mode) {
    return switch (mode) {
      SyncMode.merge => Icons.sync_rounded,
      SyncMode.pullOverwrite => Icons.cloud_download_outlined,
      SyncMode.pushOverwrite => Icons.cloud_upload_outlined,
    };
  }

  String? _formatLastSync(int? ms) {
    if (ms == null || ms <= 0) return null;
    final dt = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.month}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final savedCfg = widget.controller.webDavConfig;
    final lastSyncStr = _formatLastSync(savedCfg.lastSyncMs);

    final body = Padding(
      padding: EdgeInsets.fromLTRB(20, 14, 20, 20 + bottomInset),
      child: Form(
        key: _formKey,
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

              // Top Header
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
                      'WebDAV 云同步',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 16.5,
                        fontWeight: FontWeight.w600,
                        color: NexusColors.textPrimary,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _saveOnly,
                    style: TextButton.styleFrom(
                      foregroundColor: NexusColors.emerald,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(44, 34),
                    ),
                    child: const Text(
                      '保存',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Section 1: WebDAV Server
              const _Label('服务器连接（支持坚果云 / Nextcloud / Alist 等）'),
              _GroupCard(
                children: [
                  _RowField(
                    label: '地址',
                    child: TextFormField(
                      controller: _urlCtrl,
                      style: TextStyle(
                        fontFamily: NexusTheme.monospaceFontFamily,
                        fontSize: 13,
                      ),
                      decoration: _bareDecoration(
                        'https://dav.jianguoyun.com/dav/',
                      ),
                      validator: (v) {
                        final s = v?.trim() ?? '';
                        if (s.isEmpty) return '请输入 WebDAV 地址';
                        if (!s.startsWith('http://') &&
                            !s.startsWith('https://')) {
                          return '需以 https:// 或 http:// 开头';
                        }
                        return null;
                      },
                    ),
                  ),
                  _RowField(
                    label: '账号',
                    child: TextFormField(
                      controller: _userCtrl,
                      decoration: _bareDecoration('用户名或邮箱'),
                    ),
                  ),
                  _RowField(
                    label: '密码',
                    child: TextFormField(
                      controller: _passCtrl,
                      obscureText: _obscurePass,
                      onChanged: (_) => setState(() {}),
                      decoration:
                          _bareDecoration(
                            _hasSavedPass
                                ? '已保存密码（留空保持不变，输入则覆盖）'
                                : '密码或第三方应用授权码',
                          ).copyWith(
                            suffixIcon: _passCtrl.text.isNotEmpty
                                ? IconButton(
                                    visualDensity: VisualDensity.compact,
                                    icon: Icon(
                                      _obscurePass
                                          ? Icons.visibility_outlined
                                          : Icons.visibility_off_outlined,
                                      size: 17,
                                      color: NexusColors.textMuted,
                                    ),
                                    onPressed: () => setState(
                                      () => _obscurePass = !_obscurePass,
                                    ),
                                  )
                                : (_hasSavedPass
                                      ? const Tooltip(
                                          message: 'WebDAV 密码已安全保存，不回显明文',
                                          child: Padding(
                                            padding: EdgeInsets.all(10),
                                            child: Icon(
                                              Icons.verified_user_outlined,
                                              size: 16,
                                              color: NexusColors.emerald,
                                            ),
                                          ),
                                        )
                                      : null),
                          ),
                    ),
                  ),
                  _RowField(
                    label: '路径',
                    showDivider: false,
                    child: TextFormField(
                      controller: _pathCtrl,
                      style: TextStyle(
                        fontFamily: NexusTheme.monospaceFontFamily,
                        fontSize: 12.8,
                      ),
                      decoration: _bareDecoration('NexusSSH/hosts_sync.json'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Section 2: Security & Sync Strategy
              const _Label('安全与同步策略'),
              _GroupCard(
                children: [
                  _RowField(
                    label: '加密',
                    child: TextFormField(
                      controller: _encPassCtrl,
                      obscureText: _obscureEncPass,
                      onChanged: (_) {
                        if (_clearEncPass && _encPassCtrl.text.isNotEmpty) {
                          _clearEncPass = false;
                        }
                        setState(() {});
                      },
                      decoration:
                          _bareDecoration(
                            _clearEncPass
                                ? '保存后将关闭端到端加密'
                                : (_hasSavedEncPass
                                      ? '已启用 AES-256 加密（留空保持不变，输入则覆盖）'
                                      : '可选：设置端到端加密口令 (AES-256)'),
                          ).copyWith(
                            suffixIcon: _encPassCtrl.text.isNotEmpty
                                ? IconButton(
                                    visualDensity: VisualDensity.compact,
                                    icon: Icon(
                                      _obscureEncPass
                                          ? Icons.visibility_outlined
                                          : Icons.visibility_off_outlined,
                                      size: 17,
                                      color: NexusColors.textMuted,
                                    ),
                                    onPressed: () => setState(
                                      () => _obscureEncPass = !_obscureEncPass,
                                    ),
                                  )
                                : (_hasSavedEncPass
                                      ? TextButton(
                                          onPressed: () => setState(
                                            () =>
                                                _clearEncPass = !_clearEncPass,
                                          ),
                                          style: TextButton.styleFrom(
                                            foregroundColor: _clearEncPass
                                                ? NexusColors.emerald
                                                : NexusColors.textMuted,
                                            minimumSize: const Size(0, 28),
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                            ),
                                          ),
                                          child: Text(
                                            _clearEncPass ? '撤销' : '移除',
                                            style: const TextStyle(
                                              fontSize: 11.5,
                                            ),
                                          ),
                                        )
                                      : null),
                          ),
                    ),
                  ),
                  if (!_willBeEncrypted)
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.fromLTRB(12, 6, 12, 10),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 11,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: NexusColors.amber.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: NexusColors.amber.withValues(alpha: 0.35),
                        ),
                      ),
                      child: const Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.warning_amber_rounded,
                            size: 16,
                            color: NexusColors.amber,
                          ),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '安全提示：未设置加密口令时，网盘备份将以明文存储服务器凭据，强烈建议开启 AES-256 端到端加密。',
                              style: TextStyle(
                                fontSize: 11.4,
                                height: 1.4,
                                color: NexusColors.amber,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '默认同步方式（点击保存或同步后持久生效）',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: NexusColors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            for (final mode in SyncMode.values) ...[
                              if (mode != SyncMode.values.first)
                                const SizedBox(width: 6),
                              Expanded(
                                child: _SyncModeChip(
                                  label: mode.label,
                                  selected: _defaultSyncMode == mode,
                                  onTap: () => setState(
                                    () => _defaultSyncMode = mode,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 7),
                        Text(
                          _defaultSyncMode.description,
                          style: const TextStyle(
                            fontSize: 11.6,
                            color: NexusColors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(
                    height: 1,
                    indent: 14,
                    color: NexusColors.borderSubtle,
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '自动同步',
                                style: TextStyle(
                                  fontSize: 13.5,
                                  color: NexusColors.textPrimary,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _autoSyncHint(),
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  color: NexusColors.textMuted,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Switch.adaptive(
                          value: _autoSync,
                          activeTrackColor: NexusColors.emerald,
                          onChanged: (v) => setState(() => _autoSync = v),
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              if (lastSyncStr != null && _feedbackMessage == null) ...[
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Text(
                    '上次同步: $lastSyncStr · ${savedCfg.lastSyncMessage ?? ''}',
                    style: const TextStyle(
                      fontSize: 11.8,
                      color: NexusColors.textMuted,
                    ),
                  ),
                ),
              ],

              if (_feedbackMessage != null) ...[
                const SizedBox(height: 14),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: (_feedbackOk == true
                            ? NexusColors.emerald
                            : NexusColors.rose)
                        .withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _feedbackOk == true
                            ? Icons.check_circle_rounded
                            : Icons.error_outline_rounded,
                        size: 17,
                        color: _feedbackOk == true
                            ? NexusColors.emerald
                            : NexusColors.rose,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _feedbackMessage!,
                          style: const TextStyle(fontSize: 12.5),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 20),

              // Bottom Action Row
              Row(
                children: [
                  TextButton.icon(
                    onPressed: (_testing || _syncing) ? null : _runTest,
                    style: TextButton.styleFrom(
                      foregroundColor: NexusColors.textSecondary,
                      backgroundColor: NexusColors.bgSurface,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: _testing
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.bolt_rounded, size: 17),
                    label: Text(_testing ? '检测中' : '测试'),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: (_testing || _syncing)
                          ? null
                          : () => _runSync(_defaultSyncMode),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 13),
                      ),
                      icon: _syncing
                          ? const SizedBox(
                              width: 15,
                              height: 15,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Color(0xFF062819),
                              ),
                            )
                          : Icon(_modeIcon(_defaultSyncMode), size: 18),
                      label: Text(
                        _syncing
                            ? '正在同步...'
                            : '立即执行 (${_defaultSyncMode.label})',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  PopupMenuButton<SyncMode>(
                    tooltip: '临时单次执行其他模式',
                    enabled: !_testing && !_syncing,
                    onSelected: _runSync,
                    style: IconButton.styleFrom(
                      backgroundColor: NexusColors.bgSurface,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: const Icon(
                      Icons.more_horiz_rounded,
                      color: NexusColors.textSecondary,
                    ),
                    itemBuilder: (_) => [
                      for (final mode in SyncMode.values)
                        if (mode != _defaultSyncMode)
                          PopupMenuItem(
                            value: mode,
                            child: Text('仅本次：${mode.label}'),
                          ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    if (widget.isBottomSheet) {
      return body;
    }

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 490),
        child: body,
      ),
    );
  }

  InputDecoration _bareDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      filled: false,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(vertical: 12),
      border: InputBorder.none,
      enabledBorder: InputBorder.none,
      focusedBorder: InputBorder.none,
      errorBorder: InputBorder.none,
      focusedErrorBorder: InputBorder.none,
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: NexusColors.textMuted,
        ),
      ),
    );
  }
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: NexusColors.bgSurface,
        borderRadius: BorderRadius.circular(14),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

class _RowField extends StatelessWidget {
  const _RowField({
    required this.label,
    required this.child,
    this.showDivider = true,
  });

  final String label;
  final Widget child;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              SizedBox(
                width: 48,
                child: Text(
                  label,
                  style: const TextStyle(
                    fontSize: 13.5,
                    color: NexusColors.textSecondary,
                  ),
                ),
              ),
              Expanded(child: child),
            ],
          ),
        ),
        if (showDivider)
          const Divider(height: 1, indent: 62, color: NexusColors.borderSubtle),
      ],
    );
  }
}

class _SyncModeChip extends StatelessWidget {
  const _SyncModeChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected
          ? NexusColors.emerald.withValues(alpha: 0.16)
          : NexusColors.bgCanvas,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected
                  ? NexusColors.emerald.withValues(alpha: 0.7)
                  : NexusColors.borderSubtle,
              width: 1,
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              color: selected
                  ? NexusColors.emerald
                  : NexusColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
