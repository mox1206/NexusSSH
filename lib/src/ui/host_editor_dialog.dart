import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nexus_ssh/src/models/ssh_models.dart';
import 'package:nexus_ssh/src/state/app_controller.dart';
import 'package:nexus_ssh/src/ui/app_theme.dart';
import 'package:path/path.dart' as p;

class HostEditorResult {
  const HostEditorResult({required this.profile, required this.connectNow});

  final HostProfile profile;
  final bool connectNow;
}

class HostEditorDialog extends StatefulWidget {
  const HostEditorDialog({
    super.key,
    required this.controller,
    this.initialProfile,
    this.isQuickConnect = false,
    this.isBottomSheet = false,
  });

  final AppController controller;
  final HostProfile? initialProfile;
  final bool isQuickConnect;
  final bool isBottomSheet;

  static Future<HostEditorResult?> show(
    BuildContext context, {
    required AppController controller,
    HostProfile? initialProfile,
    bool isQuickConnect = false,
  }) {
    final isMobileSheet = MediaQuery.sizeOf(context).width < 640;
    if (isMobileSheet) {
      return showModalBottomSheet<HostEditorResult>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => HostEditorDialog(
          controller: controller,
          initialProfile: initialProfile,
          isQuickConnect: isQuickConnect,
          isBottomSheet: true,
        ),
      );
    }

    return showDialog<HostEditorResult>(
      context: context,
      builder: (_) => HostEditorDialog(
        controller: controller,
        initialProfile: initialProfile,
        isQuickConnect: isQuickConnect,
      ),
    );
  }

  @override
  State<HostEditorDialog> createState() => _HostEditorDialogState();
}

class _HostEditorDialogState extends State<HostEditorDialog> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _nameCtrl;
  late final TextEditingController _hostCtrl;
  late final TextEditingController _portCtrl;
  late final TextEditingController _userCtrl;
  late final TextEditingController _passwordCtrl;
  late final TextEditingController _privateKeyCtrl;
  late final TextEditingController _passphraseCtrl;
  late final TextEditingController _groupCtrl;

  late AuthMethod _authMethod;
  late String _accentHex;
  late String _privateKeyPath;
  late String _privateKeyLabel;
  String? _jumpHostId;

  bool _showManualKeyInput = false;
  bool _obscurePassword = true;
  bool _keepSavedPrivateKey = false;
  bool _keepSavedPassphrase = false;
  bool _clearPassphrase = false;
  bool _saveToVault = true;
  bool _testing = false;
  ConnectionTestResult? _testResult;

  List<DiscoveredSshKey> _localKeys = const [];
  KeyInspectionResult? _keyInspection;
  String? _keySelectError;

  bool get _isEditingExisting =>
      widget.initialProfile != null && widget.initialProfile!.id.isNotEmpty;

  bool get _hasSavedPassword =>
      _isEditingExisting && (widget.initialProfile?.hasStoredPassword ?? false);

  @override
  void initState() {
    super.initState();
    final prof = widget.initialProfile;
    _nameCtrl = TextEditingController(text: prof?.name ?? '');
    _hostCtrl = TextEditingController(text: prof?.host ?? '');
    _portCtrl = TextEditingController(text: (prof?.port ?? 22).toString());
    _userCtrl = TextEditingController(text: prof?.username ?? 'root');
    // Write-only security: never pre-populate saved secrets into UI text fields.
    _passwordCtrl = TextEditingController(
      text: _isEditingExisting ? '' : (prof?.password ?? ''),
    );
    _privateKeyCtrl = TextEditingController(
      text: _isEditingExisting ? '' : (prof?.privateKey ?? ''),
    );
    _passphraseCtrl = TextEditingController(
      text: _isEditingExisting ? '' : (prof?.passphrase ?? ''),
    );
    _groupCtrl = TextEditingController(
      text: (prof?.group == null || prof!.group == 'Default') ? '' : prof.group,
    );
    _authMethod = prof?.authMethod ?? AuthMethod.password;
    _accentHex = prof?.accentHex ?? NexusColors.hostAccents.first;
    _privateKeyPath = prof?.privateKeyPath ?? '';
    _privateKeyLabel = prof?.privateKeyLabel ?? '';
    _jumpHostId = (prof?.jumpHostId?.trim().isEmpty ?? true)
        ? null
        : prof!.jumpHostId!.trim();
    _keepSavedPrivateKey =
        _isEditingExisting && (prof?.hasStoredPrivateKey ?? false);
    _keepSavedPassphrase =
        _isEditingExisting && (prof?.hasStoredPassphrase ?? false);

    _loadLocalSshKeys();
    if (!_keepSavedPrivateKey && _hasAnyKeySource) {
      _refreshKeyInspection();
    }
  }

  bool get _hasAnyKeySource =>
      _keepSavedPrivateKey ||
      _privateKeyPath.trim().isNotEmpty ||
      _privateKeyCtrl.text.trim().isNotEmpty;

  Future<void> _loadLocalSshKeys() async {
    if (kIsWeb || Platform.isAndroid || Platform.isIOS) return;
    try {
      final keys = await widget.controller.discoverLocalKeys();
      if (!mounted) return;
      setState(() => _localKeys = keys);
    } catch (_) {}
  }

  Future<void> _refreshKeyInspection() async {
    if (_keepSavedPrivateKey && _privateKeyCtrl.text.trim().isEmpty) {
      if (mounted) {
        setState(() => _keyInspection = null);
      }
      return;
    }
    if (!_hasAnyKeySource) {
      if (mounted) {
        setState(() => _keyInspection = null);
      }
      return;
    }
    try {
      final info = await widget.controller.inspectPrivateKey(
        pemContent: _privateKeyCtrl.text,
        filePath: _privateKeyPath,
        passphrase: _passphraseCtrl.text,
      );
      if (!mounted) return;
      setState(() {
        _keyInspection = info;
        _keySelectError = null;
      });
    } catch (_) {}
  }

  String? _defaultSshDir() {
    if (kIsWeb || Platform.isAndroid || Platform.isIOS) return null;
    final home =
        Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
    if (home == null || home.isEmpty) return null;
    final sshDir = Directory(p.join(home, '.ssh'));
    return sshDir.existsSync() ? sshDir.path : null;
  }

  Future<void> _pickKeyFile() async {
    try {
      final picked = await FilePicker.pickFile(
        dialogTitle: '选择 SSH 私钥文件 (OpenSSH / PEM)',
        initialDirectory: _defaultSshDir(),
      );
      if (picked == null) return;

      final bytes = await picked.readAsBytes();
      final content = utf8.decode(bytes, allowMalformed: true);
      final isDesktop =
          !kIsWeb &&
          (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

      setState(() {
        // On desktop keep file path reference + cached fallback; on mobile store content + filename label
        _privateKeyPath = (isDesktop && picked.path != null)
            ? picked.path!
            : '';
        _privateKeyLabel = picked.name;
        _privateKeyCtrl.text = content;
        _keepSavedPrivateKey = false;
        _showManualKeyInput = false;
        _keySelectError = null;
      });
      await _refreshKeyInspection();
    } catch (e) {
      if (!mounted) return;
      setState(() => _keySelectError = '读取文件失败: $e');
    }
  }

  Future<void> _selectDiscoveredKey(DiscoveredSshKey key) async {
    String fallbackText = '';
    try {
      fallbackText = await File(key.path).readAsString();
    } catch (_) {}

    setState(() {
      _privateKeyPath = key.path;
      _privateKeyLabel = key.name;
      _privateKeyCtrl.text = fallbackText;
      _keepSavedPrivateKey = false;
      _showManualKeyInput = false;
      _keySelectError = null;
    });
    await _refreshKeyInspection();
  }

  void _clearKeySelection() {
    setState(() {
      _privateKeyPath = '';
      _privateKeyLabel = '';
      _privateKeyCtrl.clear();
      _keepSavedPrivateKey = false;
      _keyInspection = null;
      _keySelectError = null;
    });
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _userCtrl.dispose();
    _passwordCtrl.dispose();
    _privateKeyCtrl.dispose();
    _passphraseCtrl.dispose();
    _groupCtrl.dispose();
    super.dispose();
  }

  HostProfile _buildDraftProfile() {
    final port = int.tryParse(_portCtrl.text.trim()) ?? 22;
    final host = _hostCtrl.text.trim();
    final user = _userCtrl.text.trim().isEmpty ? 'root' : _userCtrl.text.trim();
    final name = _nameCtrl.text.trim().isEmpty ? host : _nameCtrl.text.trim();

    return HostProfile(
      id: widget.initialProfile?.id ?? '',
      name: name,
      host: host,
      port: port,
      username: user,
      authMethod: _authMethod,
      password: _passwordCtrl.text,
      privateKey: _privateKeyCtrl.text,
      privateKeyPath: _privateKeyPath,
      privateKeyLabel: _privateKeyLabel,
      passphrase: _passphraseCtrl.text,
      hasPassword: _hasSavedPassword || _passwordCtrl.text.isNotEmpty,
      hasPrivateKey: _hasAnyKeySource,
      hasPassphrase:
          (_keepSavedPassphrase && !_clearPassphrase) ||
          _passphraseCtrl.text.isNotEmpty,
      clearPassphrase: _clearPassphrase && _passphraseCtrl.text.isEmpty,
      jumpHostId: _jumpHostId,
      group: _groupCtrl.text.trim().isEmpty
          ? 'Default'
          : _groupCtrl.text.trim(),
      accentHex: _accentHex,
      createdAtMs: widget.initialProfile?.createdAtMs ?? 0,
      lastConnectedMs: widget.initialProfile?.lastConnectedMs,
    );
  }

  bool _validateAll() {
    final formOk = _formKey.currentState?.validate() ?? false;
    if (!formOk) return false;

    if (_authMethod == AuthMethod.privateKey && !_hasAnyKeySource) {
      setState(() => _keySelectError = '请选择密钥文件，或点击「手动输入」粘贴私钥');
      return false;
    }
    if (_authMethod == AuthMethod.privateKey &&
        _keyInspection != null &&
        !_keyInspection!.valid) {
      setState(() => _keySelectError = _keyInspection!.message);
      return false;
    }
    return true;
  }

  Future<void> _runTestConnection() async {
    if (!_validateAll()) return;
    setState(() {
      _testing = true;
      _testResult = null;
    });

    try {
      final res = await widget.controller.testConnection(_buildDraftProfile());
      if (!mounted) return;
      setState(() => _testResult = res);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testResult = ConnectionTestResult(
          ok: false,
          latencyMs: 0,
          message: e.toString(),
        );
      });
    } finally {
      if (mounted) {
        setState(() => _testing = false);
      }
    }
  }

  Future<void> _submit({required bool connectNow}) async {
    if (!_validateAll()) return;
    var draft = _buildDraftProfile();

    if (!widget.isQuickConnect || _saveToVault) {
      try {
        draft = await widget.controller.saveHost(draft);
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('保存失败: $e')));
        return;
      }
    }

    if (!mounted) return;
    Navigator.of(
      context,
    ).pop(HostEditorResult(profile: draft, connectNow: connectNow));
  }

  @override
  Widget build(BuildContext context) {
    final isEditing =
        widget.initialProfile != null && widget.initialProfile!.id.isNotEmpty;
    final title = widget.isQuickConnect
        ? '快速连接'
        : (isEditing ? '编辑主机' : '新建主机');
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

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
                    child: const Text('取消'),
                  ),
                  Expanded(
                    child: Text(
                      title,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 16.5,
                        fontWeight: FontWeight.w600,
                        color: NexusColors.textPrimary,
                      ),
                    ),
                  ),
                  if (!widget.isQuickConnect)
                    TextButton(
                      onPressed: () => _submit(connectNow: false),
                      style: TextButton.styleFrom(
                        foregroundColor: NexusColors.emerald,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(44, 34),
                      ),
                      child: const Text(
                        '保存',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    )
                  else
                    const SizedBox(width: 44),
                ],
              ),
              const SizedBox(height: 16),

              // Section 1: Address & Label
              const _SectionLabel('主机信息'),
              _InsetFormGroup(
                children: [
                  _InlineFieldRow(
                    label: '地址',
                    child: TextFormField(
                      controller: _hostCtrl,
                      style: TextStyle(
                        fontFamily: NexusTheme.monospaceFontFamily,
                        fontSize: 13.8,
                      ),
                      decoration: _bareDecoration('IP 或域名，如 192.168.1.10'),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? '请输入主机地址' : null,
                    ),
                  ),
                  _InlineFieldRow(
                    label: '端口',
                    child: TextFormField(
                      controller: _portCtrl,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      style: TextStyle(
                        fontFamily: NexusTheme.monospaceFontFamily,
                        fontSize: 13.8,
                      ),
                      decoration: _bareDecoration('默认 22'),
                      validator: (v) {
                        final n = int.tryParse(v ?? '');
                        if (n == null || n < 1 || n > 65535) {
                          return '端口范围 1-65535';
                        }
                        return null;
                      },
                    ),
                  ),
                  _InlineFieldRow(
                    label: '备注',
                    child: TextFormField(
                      controller: _nameCtrl,
                      decoration: _bareDecoration('可选，如 家里服务器'),
                    ),
                  ),
                  _InlineFieldRow(
                    label: '分组',
                    showDivider: false,
                    child: TextFormField(
                      controller: _groupCtrl,
                      decoration: _bareDecoration('可选，如 Production / Homelab'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),

              // Section 2: SSH Authentication
              Row(
                children: [
                  const _SectionLabel('SSH 认证', bottomPadding: 0),
                  const Spacer(),
                  _CompactAuthSwitch(
                    value: _authMethod,
                    onChanged: (m) => setState(() {
                      _authMethod = m;
                      _keySelectError = null;
                    }),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _InsetFormGroup(
                children: [
                  _InlineFieldRow(
                    label: '用户',
                    child: TextFormField(
                      controller: _userCtrl,
                      style: TextStyle(
                        fontFamily: NexusTheme.monospaceFontFamily,
                        fontSize: 13.8,
                      ),
                      decoration: _bareDecoration('root / ubuntu'),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? '请输入用户名' : null,
                    ),
                  ),
                  if (_authMethod == AuthMethod.none)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(14, 10, 14, 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.hub_outlined,
                            size: 16,
                            color: NexusColors.emerald,
                          ),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '免密认证（适用于 Tailscale SSH / 零信任网关，无需填写密码或私钥；若需浏览器二次验证将自动提示一键打开）',
                              style: TextStyle(
                                fontSize: 12,
                                height: 1.45,
                                color: NexusColors.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  else if (_authMethod == AuthMethod.password)
                    _InlineFieldRow(
                      label: '密码',
                      showDivider: false,
                      child: TextFormField(
                        controller: _passwordCtrl,
                        obscureText: _obscurePassword,
                        autofocus: widget.isQuickConnect,
                        onChanged: (_) => setState(() {}),
                        onFieldSubmitted: (_) => _submit(connectNow: true),
                        decoration:
                            _bareDecoration(
                              _hasSavedPassword
                                  ? '已保存密码（留空保持不变，输入则覆盖）'
                                  : '输入登录密码',
                            ).copyWith(
                              suffixIcon: _passwordCtrl.text.isNotEmpty
                                  ? IconButton(
                                      tooltip: _obscurePassword
                                          ? '显示刚输入的密码'
                                          : '隐藏密码',
                                      visualDensity: VisualDensity.compact,
                                      icon: Icon(
                                        _obscurePassword
                                            ? Icons.visibility_outlined
                                            : Icons.visibility_off_outlined,
                                        size: 17,
                                        color: NexusColors.textMuted,
                                      ),
                                      onPressed: () {
                                        setState(
                                          () => _obscurePassword =
                                              !_obscurePassword,
                                        );
                                      },
                                    )
                                  : (_hasSavedPassword
                                        ? const Tooltip(
                                            message: '登录密码已安全加密保存，不回显明文',
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
                    )
                  else ...[
                    _buildPrivateKeySelectorSection(),
                    const Divider(
                      height: 1,
                      indent: 66,
                      color: NexusColors.borderSubtle,
                    ),
                    _InlineFieldRow(
                      label: '口令',
                      showDivider: false,
                      child: TextFormField(
                        controller: _passphraseCtrl,
                        obscureText: true,
                        onChanged: (_) {
                          if (_clearPassphrase &&
                              _passphraseCtrl.text.isNotEmpty) {
                            _clearPassphrase = false;
                          }
                          setState(() {});
                          _refreshKeyInspection();
                        },
                        decoration:
                            _bareDecoration(
                              _clearPassphrase
                                  ? '保存后将清除已存私钥口令'
                                  : (_keepSavedPassphrase
                                        ? '已保存私钥口令（留空保持不变，输入则覆盖）'
                                        : (_keyInspection?.encrypted == true
                                              ? '请输入该加密私钥的口令'
                                              : '私钥密码（未加密则留空）')),
                            ).copyWith(
                              suffixIcon:
                                  _keepSavedPassphrase &&
                                      _passphraseCtrl.text.isEmpty
                                  ? TextButton(
                                      onPressed: () => setState(
                                        () => _clearPassphrase =
                                            !_clearPassphrase,
                                      ),
                                      style: TextButton.styleFrom(
                                        foregroundColor: _clearPassphrase
                                            ? NexusColors.emerald
                                            : NexusColors.textMuted,
                                        minimumSize: const Size(0, 28),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                        ),
                                      ),
                                      child: Text(
                                        _clearPassphrase ? '撤销' : '清除',
                                        style: const TextStyle(fontSize: 11.5),
                                      ),
                                    )
                                  : null,
                            ),
                      ),
                    ),
                  ],
                ],
              ),

              if (_keySelectError != null) ...[
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Text(
                    _keySelectError!,
                    style: const TextStyle(
                      fontSize: 12,
                      color: NexusColors.rose,
                    ),
                  ),
                ),
              ],

              const SizedBox(height: 18),

              // Section 3: ProxyJump (SSH Bastion / Jump Host)
              const _SectionLabel('ProxyJump'),
              _buildProxyJumpSection(),

              const SizedBox(height: 16),

              // Section 3: Accent Color & Save Toggle
              Row(
                children: [
                  for (final hex in NexusColors.hostAccents)
                    Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: GestureDetector(
                        onTap: () => setState(() => _accentHex = hex),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: HostProfile(
                              name: '',
                              host: '',
                              username: '',
                              accentHex: hex,
                            ).accentColor,
                            border: Border.all(
                              color: _accentHex == hex
                                  ? Colors.white
                                  : Colors.transparent,
                              width: 2.2,
                            ),
                          ),
                        ),
                      ),
                    ),
                  const Spacer(),
                  if (widget.isQuickConnect)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 22,
                          height: 22,
                          child: Checkbox(
                            value: _saveToVault,
                            onChanged: (v) =>
                                setState(() => _saveToVault = v ?? true),
                          ),
                        ),
                        const SizedBox(width: 6),
                        const Text(
                          '记住主机',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: NexusColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                ],
              ),

              if (_testResult != null) ...[
                const SizedBox(height: 14),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: (_testResult!.ok
                            ? NexusColors.emerald
                            : NexusColors.rose)
                        .withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _testResult!.ok
                            ? Icons.check_circle_rounded
                            : Icons.error_outline_rounded,
                        size: 17,
                        color: _testResult!.ok
                            ? NexusColors.emerald
                            : NexusColors.rose,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _testResult!.message,
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
                    onPressed: _testing ? null : _runTestConnection,
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
                    label: Text(_testing ? '探测中' : '测试'),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => _submit(connectNow: true),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 13),
                      ),
                      icon: const Icon(Icons.terminal_rounded, size: 17),
                      label: Text(isEditing ? '保存并连接' : '立即连接'),
                    ),
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

  Widget _buildPrivateKeySelectorSection() {
    final inspection = _keyInspection;
    final hasKey = _hasAnyKeySource;

    final String displayLabel;
    if (_privateKeyLabel.trim().isNotEmpty) {
      displayLabel = _privateKeyLabel.trim();
    } else if (_privateKeyPath.trim().isNotEmpty) {
      displayLabel = p.basename(_privateKeyPath.trim());
    } else {
      displayLabel = '手动输入的密钥';
    }

    final Color badgeColor;
    final IconData badgeIcon;
    if (_keepSavedPrivateKey && inspection == null) {
      badgeColor = NexusColors.emerald;
      badgeIcon = Icons.verified_user_rounded;
    } else if (inspection == null) {
      badgeColor = NexusColors.cyan;
      badgeIcon = Icons.vpn_key_rounded;
    } else if (inspection.valid) {
      badgeColor = NexusColors.emerald;
      badgeIcon = Icons.verified_rounded;
    } else if (inspection.encrypted) {
      badgeColor = NexusColors.amber;
      badgeIcon = Icons.lock_outline_rounded;
    } else {
      badgeColor = NexusColors.rose;
      badgeIcon = Icons.error_outline_rounded;
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(
                width: 52,
                child: Text(
                  '密钥',
                  style: TextStyle(
                    fontSize: 13.5,
                    color: NexusColors.textSecondary,
                  ),
                ),
              ),
              if (!hasKey) ...[
                FilledButton.tonalIcon(
                  onPressed: _pickKeyFile,
                  style: FilledButton.styleFrom(
                    backgroundColor: NexusColors.bgElevated,
                    foregroundColor: NexusColors.emerald,
                    minimumSize: const Size(0, 34),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(9),
                    ),
                  ),
                  icon: const Icon(Icons.folder_open_rounded, size: 16),
                  label: const Text('选择密钥文件', style: TextStyle(fontSize: 12.5)),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () {
                    setState(() => _showManualKeyInput = !_showManualKeyInput);
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: NexusColors.textSecondary,
                    minimumSize: const Size(0, 32),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  child: Text(
                    _showManualKeyInput ? '收起粘贴框' : '手动输入',
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
              ] else ...[
                // Loaded Key Summary Pill
                Expanded(
                  child: Tooltip(
                    message: _privateKeyPath.isNotEmpty
                        ? _privateKeyPath
                        : displayLabel,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: NexusColors.bgElevated,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          Icon(badgeIcon, size: 16, color: badgeColor),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  displayLabel,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: NexusColors.textPrimary,
                                  ),
                                ),
                                if (inspection != null)
                                  Text(
                                    inspection.message,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontFamily:
                                          NexusTheme.monospaceFontFamily,
                                      fontSize: 10.8,
                                      color: inspection.valid
                                          ? NexusColors.textSecondary
                                          : badgeColor,
                                    ),
                                  )
                                else if (_keepSavedPrivateKey)
                                  const Text(
                                    '已安全保存 · 不回显明文（重选或粘贴可替换）',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 10.8,
                                      color: NexusColors.textSecondary,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: '重新选择文件替换',
                  visualDensity: VisualDensity.compact,
                  onPressed: _pickKeyFile,
                  icon: const Icon(
                    Icons.folder_open_rounded,
                    size: 17,
                    color: NexusColors.textSecondary,
                  ),
                ),
                IconButton(
                  tooltip: _showManualKeyInput
                      ? '收起粘贴框'
                      : (_keepSavedPrivateKey ? '粘贴新私钥替换' : '粘贴/编辑密钥文本'),
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    setState(() => _showManualKeyInput = !_showManualKeyInput);
                  },
                  icon: Icon(
                    Icons.notes_rounded,
                    size: 17,
                    color: _showManualKeyInput
                        ? NexusColors.emerald
                        : NexusColors.textSecondary,
                  ),
                ),
                IconButton(
                  tooltip: '清除密钥',
                  visualDensity: VisualDensity.compact,
                  onPressed: _clearKeySelection,
                  icon: const Icon(
                    Icons.close_rounded,
                    size: 17,
                    color: NexusColors.textMuted,
                  ),
                ),
              ],
            ],
          ),

          // Quick-pick chips for detected `~/.ssh` keys on Desktop
          if (_localKeys.isNotEmpty) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(left: 52),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text(
                    '~/.ssh:',
                    style: TextStyle(
                      fontSize: 11,
                      color: NexusColors.textMuted,
                    ),
                  ),
                  for (final k in _localKeys)
                    InkWell(
                      borderRadius: BorderRadius.circular(7),
                      onTap: () => _selectDiscoveredKey(k),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3.5,
                        ),
                        decoration: BoxDecoration(
                          color: _privateKeyPath == k.path
                              ? NexusColors.emerald.withValues(alpha: 0.18)
                              : NexusColors.bgCanvas,
                          borderRadius: BorderRadius.circular(7),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              k.encrypted
                                  ? Icons.lock_outline_rounded
                                  : Icons.key_rounded,
                              size: 12,
                              color: _privateKeyPath == k.path
                                  ? NexusColors.emerald
                                  : NexusColors.textSecondary,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              k.name,
                              style: TextStyle(
                                fontFamily: NexusTheme.monospaceFontFamily,
                                fontSize: 11.2,
                                color: _privateKeyPath == k.path
                                    ? NexusColors.emerald
                                    : NexusColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],

          // Optional Collapsible Manual PEM Paste Area
          if (_showManualKeyInput) ...[
            const SizedBox(height: 10),
            Container(
              margin: const EdgeInsets.only(left: 52),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: NexusColors.bgCanvas,
                borderRadius: BorderRadius.circular(10),
              ),
              child: TextFormField(
                controller: _privateKeyCtrl,
                maxLines: 4,
                onChanged: (_) {
                  if (_privateKeyCtrl.text.trim().isNotEmpty) {
                    _keepSavedPrivateKey = false;
                    if (_privateKeyPath.isNotEmpty) {
                      _privateKeyPath = '';
                      _privateKeyLabel = '手动替换的密钥';
                    }
                  }
                  _refreshKeyInspection();
                },
                style: TextStyle(
                  fontFamily: NexusTheme.monospaceFontFamily,
                  fontSize: 11.8,
                ),
                decoration: _bareDecoration(
                  _keepSavedPrivateKey
                      ? '如需替换已保存私钥，请粘贴新的 PEM 内容...'
                      : '-----BEGIN OPENSSH PRIVATE KEY-----\n...',
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildProxyJumpSection() {
    final selfId = widget.initialProfile?.id ?? '';
    final eligible = widget.controller.eligibleProxyJumpHostsFor(selfId);
    final hasSelected = _jumpHostId != null && _jumpHostId!.isNotEmpty;
    final selectedExists =
        hasSelected && eligible.any((h) => h.id == _jumpHostId);
    final selectedMissing = hasSelected && !selectedExists;

    final previewChain = selectedExists
        ? widget.controller.resolveProxyJumpChain(
            HostProfile(
              id: selfId,
              name: _nameCtrl.text.trim(),
              host: _hostCtrl.text.trim(),
              username: _userCtrl.text.trim(),
              jumpHostId: _jumpHostId,
            ),
          )
        : const <HostProfile>[];

    return _InsetFormGroup(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
          child: Row(
            children: [
              Icon(
                Icons.alt_route_rounded,
                size: 16,
                color: selectedMissing
                    ? NexusColors.amber
                    : (selectedExists
                          ? NexusColors.emerald
                          : NexusColors.textMuted),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String?>(
                    key: const ValueKey('proxy_jump_dropdown'),
                    value: _jumpHostId,
                    isExpanded: true,
                    dropdownColor: NexusColors.bgElevated,
                    borderRadius: BorderRadius.circular(12),
                    style: const TextStyle(
                      fontSize: 13.4,
                      color: NexusColors.textPrimary,
                    ),
                    icon: const Icon(
                      Icons.unfold_more_rounded,
                      size: 18,
                      color: NexusColors.textMuted,
                    ),
                    onChanged: (val) => setState(() {
                      _jumpHostId = val;
                      _testResult = null;
                    }),
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text(
                          'Direct（直连）',
                          style: TextStyle(color: NexusColors.textSecondary),
                        ),
                      ),
                      if (selectedMissing)
                        DropdownMenuItem<String?>(
                          value: _jumpHostId,
                          child: const Text(
                            '原 ProxyJump 主机已删除（请重新选择）',
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: NexusColors.amber),
                          ),
                        ),
                      for (final h in eligible)
                        DropdownMenuItem<String?>(
                          value: h.id,
                          child: Text(
                            '${h.name}  ·  ${h.addressLabel}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        if (previewChain.isNotEmpty) ...[
          const Divider(height: 1, indent: 40, color: NexusColors.borderSubtle),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 9, 14, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.shield_outlined,
                  size: 14,
                  color: NexusColors.emerald,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'SSH direct-tcpip 隧道：Local → ${previewChain.map((h) => h.name).join(' → ')} → 当前主机',
                    style: const TextStyle(
                      fontSize: 11.6,
                      height: 1.4,
                      color: NexusColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ] else if (selectedMissing) ...[
          const Divider(height: 1, indent: 40, color: NexusColors.borderSubtle),
          const Padding(
            padding: EdgeInsets.fromLTRB(14, 9, 14, 10),
            child: Text(
              '原关联的 ProxyJump 跳板机已不存在，请重新选择有效主机或切回 Direct（直连）。',
              style: TextStyle(
                fontSize: 11.6,
                height: 1.4,
                color: NexusColors.amber,
              ),
            ),
          ),
        ],
      ],
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

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text, {this.bottomPadding = 8});

  final String text;
  final double bottomPadding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(left: 4, bottom: bottomPadding),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
          color: NexusColors.textMuted,
        ),
      ),
    );
  }
}

class _InsetFormGroup extends StatelessWidget {
  const _InsetFormGroup({required this.children});

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

class _InlineFieldRow extends StatelessWidget {
  const _InlineFieldRow({
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
                width: 52,
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
          const Divider(height: 1, indent: 66, color: NexusColors.borderSubtle),
      ],
    );
  }
}

class _CompactAuthSwitch extends StatelessWidget {
  const _CompactAuthSwitch({required this.value, required this.onChanged});

  final AuthMethod value;
  final ValueChanged<AuthMethod> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: NexusColors.bgSurface,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _pill(AuthMethod.password, '密码'),
          _pill(AuthMethod.privateKey, '密钥'),
          _pill(AuthMethod.none, '免密'),
        ],
      ),
    );
  }

  Widget _pill(AuthMethod method, String text) {
    final active = value == method;
    return GestureDetector(
      onTap: () => onChanged(method),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: active ? NexusColors.bgElevated : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            color: active ? NexusColors.emerald : NexusColors.textSecondary,
          ),
        ),
      ),
    );
  }
}
