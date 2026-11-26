import 'package:flutter/material.dart';
import 'package:nexus_ssh/src/desktop/desktop_tray_service.dart';
import 'package:nexus_ssh/src/models/ssh_models.dart';
import 'package:nexus_ssh/src/state/app_controller.dart';
import 'package:nexus_ssh/src/ui/app_lock_settings_dialog.dart';
import 'package:nexus_ssh/src/ui/app_theme.dart';
import 'package:nexus_ssh/src/ui/host_editor_dialog.dart';
import 'package:nexus_ssh/src/ui/settings_dialog.dart';
import 'package:nexus_ssh/src/ui/snippets_panel.dart';

class HostsVaultView extends StatefulWidget {
  const HostsVaultView({super.key, required this.controller});

  final AppController controller;

  @override
  State<HostsVaultView> createState() => _HostsVaultViewState();
}

class _HostsVaultViewState extends State<HostsVaultView> {
  final _omniCtrl = TextEditingController();

  @override
  void dispose() {
    _omniCtrl.dispose();
    super.dispose();
  }

  /// Heuristic: input looks like an SSH target if it contains `@`, `:`, `.`,
  /// or starts with `ssh `.
  bool get _canQuickConnect {
    final text = _omniCtrl.text.trim();
    if (text.isEmpty) return false;
    return text.contains('@') ||
        text.contains('.') ||
        text.contains(':') ||
        text.toLowerCase().startsWith('ssh ');
  }

  Future<void> _handleOmniSubmit() async {
    final raw = _omniCtrl.text.trim();
    if (raw.isEmpty) return;

    // If exact single filtered host matches and user didn't type user@host syntax, connect it
    final filtered = widget.controller.filteredHosts;
    if (filtered.length == 1 && !raw.contains('@') && !raw.startsWith('ssh ')) {
      _clearOmni();
      await widget.controller.openSession(filtered.first);
      return;
    }

    try {
      final target = await widget.controller.parseQuickConnect(raw);
      if (!mounted) return;

      final existing = widget.controller.allHosts.where((h) {
        return h.host.toLowerCase() == target.host.toLowerCase() &&
            h.port == target.port &&
            h.username == target.username;
      }).firstOrNull;

      if (existing != null) {
        _clearOmni();
        await widget.controller.openSession(existing);
        return;
      }

      final result = await HostEditorDialog.show(
        context,
        controller: widget.controller,
        initialProfile: HostProfile(
          name: target.host,
          host: target.host,
          port: target.port,
          username: target.username,
        ),
        isQuickConnect: true,
      );

      if (result != null && result.connectNow) {
        _clearOmni();
        await widget.controller.openSession(result.profile);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  void _clearOmni() {
    _omniCtrl.clear();
    widget.controller.setSearchQuery('');
    setState(() {});
  }

  Future<void> _openCreateOrEdit([HostProfile? initial]) async {
    final res = await HostEditorDialog.show(
      context,
      controller: widget.controller,
      initialProfile: initial,
    );
    if (res != null && res.connectNow) {
      await widget.controller.openSession(res.profile);
    }
  }

  Future<void> _confirmDelete(HostProfile host) async {
    final hasCloud = widget.controller.webDavConfig.isConfigured;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移除主机'),
        content: Text(
          hasCloud
              ? '确定要移除「${host.name}」(${host.addressLabel}) 吗？\n\n仅从本机移除，不会自动同步删除云端备份（可手动同步或从云端拉取恢复）。'
              : '确定要移除「${host.name}」(${host.addressLabel}) 吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: NexusColors.rose),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('移除', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (ok == true) {
      await widget.controller.removeHost(host.id);
    }
  }

  void _showMobileHostSheet(HostProfile host) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: NexusColors.borderActive,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              ListTile(
                leading: Icon(Icons.terminal_rounded, color: host.accentColor),
                title: Text(
                  host.name,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  host.addressLabel,
                  style: TextStyle(fontFamily: NexusTheme.monospaceFontFamily),
                ),
              ),
              const Divider(height: 12),
              ListTile(
                leading: const Icon(Icons.login_rounded, size: 20),
                title: const Text('新建终端会话'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  widget.controller.openSession(host);
                },
              ),
              ListTile(
                leading: const Icon(Icons.edit_outlined, size: 20),
                title: const Text('编辑主机'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _openCreateOrEdit(host);
                },
              ),
              ListTile(
                leading: const Icon(Icons.copy_all_outlined, size: 20),
                title: const Text('克隆副本'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _openCreateOrEdit(
                    host.copyWith(
                      id: '',
                      name: '${host.name} 副本',
                      password: '',
                      privateKey: '',
                      passphrase: '',
                      hasPassword: false,
                      hasPrivateKey: false,
                      hasPassphrase: false,
                    ),
                  );
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.delete_outline_rounded,
                  size: 20,
                  color: NexusColors.rose,
                ),
                title: const Text(
                  '删除主机',
                  style: TextStyle(color: NexusColors.rose),
                ),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _confirmDelete(host);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool _isHostConnected(HostProfile host) {
    return widget.controller.sessions.any(
      (s) =>
          s.phase == SessionPhase.connected &&
          ((host.id.isNotEmpty && s.profile.id == host.id) ||
              (s.profile.host == host.host &&
                  s.profile.port == host.port &&
                  s.profile.username == host.username)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hosts = widget.controller.filteredHosts;
    final groups = widget.controller.groups;
    final width = MediaQuery.sizeOf(context).width;
    final isMobile = width < 780;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        isMobile ? 16 : 28,
        isMobile ? 10 : 22,
        isMobile ? 16 : 28,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Clean Termius-style Header on Mobile (Desktop already has sidebar)
          if (isMobile) ...[
            Row(
              children: [
                const Text(
                  'Hosts',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.4,
                    color: NexusColors.textPrimary,
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: '命令片段',
                  onPressed: () => SnippetsPanel.showModal(
                    context,
                    controller: widget.controller,
                  ),
                  style: IconButton.styleFrom(
                    fixedSize: const Size(38, 38),
                    minimumSize: const Size(38, 38),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: EdgeInsets.zero,
                    backgroundColor: NexusColors.bgSurface,
                    foregroundColor: NexusColors.textSecondary,
                  ),
                  icon: const Icon(Icons.code_rounded, size: 19),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: '应用锁与安全',
                  onPressed: () => AppLockSettingsDialog.show(
                    context,
                    controller: widget.controller,
                  ),
                  onLongPress: widget.controller.appLockConfig.enabled
                      ? widget.controller.lockNow
                      : null,
                  style: IconButton.styleFrom(
                    fixedSize: const Size(38, 38),
                    minimumSize: const Size(38, 38),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: EdgeInsets.zero,
                    backgroundColor: NexusColors.bgSurface,
                    foregroundColor: widget.controller.appLockConfig.enabled
                        ? NexusColors.emerald
                        : NexusColors.textSecondary,
                  ),
                  icon: Icon(
                    widget.controller.appLockConfig.enabled
                        ? Icons.verified_user_rounded
                        : Icons.shield_outlined,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: widget.controller.hasUnignoredUpdate
                      ? '设置（发现新版本 v${widget.controller.updateState.manifest?.version ?? ''}）'
                      : '设置',
                  onPressed: () => SettingsDialog.show(
                    context,
                    controller: widget.controller,
                  ),
                  style: IconButton.styleFrom(
                    fixedSize: const Size(38, 38),
                    minimumSize: const Size(38, 38),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: EdgeInsets.zero,
                    backgroundColor: NexusColors.bgSurface,
                    foregroundColor: widget.controller.hasUnignoredUpdate
                        ? NexusColors.emerald
                        : NexusColors.textSecondary,
                  ),
                  icon: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      const Icon(Icons.settings_outlined, size: 19),
                      if (widget.controller.hasUnignoredUpdate)
                        Positioned(
                          right: -2,
                          top: -2,
                          child: Container(
                            width: 7,
                            height: 7,
                            decoration: const BoxDecoration(
                              color: NexusColors.emerald,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  tooltip: '新建主机',
                  onPressed: () => _openCreateOrEdit(),
                  style: IconButton.styleFrom(
                    fixedSize: const Size(38, 38),
                    minimumSize: const Size(38, 38),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: EdgeInsets.zero,
                    backgroundColor: NexusColors.emerald.withValues(
                      alpha: 0.16,
                    ),
                    foregroundColor: NexusColors.emerald,
                  ),
                  icon: const Icon(Icons.add_rounded, size: 21),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],

          // Unified Smart Omni-Bar: Search + Quick Connect in one clean pill!
          Container(
            height: 46,
            padding: const EdgeInsets.only(left: 14, right: 8),
            decoration: BoxDecoration(
              color: NexusColors.bgSurface,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Icon(
                  _canQuickConnect
                      ? Icons.terminal_rounded
                      : Icons.search_rounded,
                  size: 19,
                  color: _canQuickConnect
                      ? NexusColors.emerald
                      : NexusColors.textMuted,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _omniCtrl,
                    onChanged: (v) {
                      widget.controller.setSearchQuery(v);
                      setState(() {});
                    },
                    onSubmitted: (_) => _handleOmniSubmit(),
                    style: const TextStyle(
                      fontSize: 13.8,
                      color: NexusColors.textPrimary,
                    ),
                    decoration: const InputDecoration(
                      hintText: '搜索主机，或输入 user@host 直连...',
                      filled: false,
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                    ),
                  ),
                ),
                if (_omniCtrl.text.isNotEmpty)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(
                      Icons.close_rounded,
                      size: 17,
                      color: NexusColors.textMuted,
                    ),
                    onPressed: _clearOmni,
                  ),
                if (_canQuickConnect)
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: FilledButton(
                      onPressed: _handleOmniSubmit,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 32),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(9),
                        ),
                      ),
                      child: const Text(
                        '直连',
                        style: TextStyle(fontSize: 12.5),
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // Subtle Group Filter Pills (only shown when 2+ groups exist)
          if (groups.length > 2) ...[
            const SizedBox(height: 14),
            SizedBox(
              height: 32,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: groups.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, idx) {
                  final g = groups[idx];
                  final selected = widget.controller.selectedGroup == g;
                  return GestureDetector(
                    onTap: () => widget.controller.setSelectedGroup(g),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 140),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: selected
                            ? NexusColors.emerald.withValues(alpha: 0.18)
                            : NexusColors.bgSurface,
                        borderRadius: BorderRadius.circular(99),
                      ),
                      child: Text(
                        g == 'All' ? '全部' : g,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w400,
                          color: selected
                              ? NexusColors.emerald
                              : NexusColors.textSecondary,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],

          const SizedBox(height: 16),

          // Section Caption
          if (hosts.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 10),
              child: Text(
                'HOSTS (${hosts.length})',
                style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.6,
                  color: NexusColors.textMuted,
                ),
              ),
            ),

          // Hosts List (Mobile) / Clean Grid (Desktop)
          Expanded(
            child: hosts.isEmpty
                ? _EmptyHostsState(
                    hasAnyHost: widget.controller.allHosts.isNotEmpty,
                    onQuickConnect: _canQuickConnect ? _handleOmniSubmit : null,
                    quickText: _omniCtrl.text.trim(),
                    onCreateHost: () => _openCreateOrEdit(),
                  )
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final cols = constraints.maxWidth >= 980
                          ? 3
                          : (constraints.maxWidth >= 580 ? 2 : 1);
                      return GridView.builder(
                        padding: const EdgeInsets.only(bottom: 88),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: cols,
                          mainAxisExtent: 74,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 10,
                        ),
                        itemCount: hosts.length,
                        itemBuilder: (context, index) {
                          final host = hosts[index];
                          final jumpChain = widget.controller
                              .resolveProxyJumpChain(host);
                          final jumpRouteLabel = host.usesProxyJump
                              ? (jumpChain.isNotEmpty
                                    ? jumpChain.map((h) => h.name).join(' → ')
                                    : null)
                              : null;
                          return _TermiusHostTile(
                            host: host,
                            jumpRouteLabel: jumpRouteLabel,
                            jumpHostMissing:
                                host.usesProxyJump && jumpChain.isEmpty,
                            isOnline: _isHostConnected(host),
                            isMobile: isMobile,
                            onConnect: () =>
                                widget.controller.openSession(host),
                            onLongPress: (isMobile && !isDesktopHostPlatform)
                                ? () => _showMobileHostSheet(host)
                                : null,
                            onMoreMobile: () => _showMobileHostSheet(host),
                            onEdit: () => _openCreateOrEdit(host),
                            onDuplicate: () => _openCreateOrEdit(
                              host.copyWith(
                                id: '',
                                name: '${host.name} 副本',
                                password: '',
                                privateKey: '',
                                passphrase: '',
                                hasPassword: false,
                                hasPrivateKey: false,
                                hasPassphrase: false,
                              ),
                            ),
                            onDelete: () => _confirmDelete(host),
                          );
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Termius-inspired sleek compact Host Tile:
/// Squircle icon with live indicator + clean two-line typography + subtle menu.
class _TermiusHostTile extends StatelessWidget {
  const _TermiusHostTile({
    required this.host,
    this.jumpRouteLabel,
    this.jumpHostMissing = false,
    required this.isOnline,
    required this.isMobile,
    required this.onConnect,
    this.onLongPress,
    required this.onMoreMobile,
    required this.onEdit,
    required this.onDuplicate,
    required this.onDelete,
  });

  final HostProfile host;
  final String? jumpRouteLabel;
  final bool jumpHostMissing;
  final bool isOnline;
  final bool isMobile;
  final VoidCallback onConnect;
  final VoidCallback? onLongPress;
  final VoidCallback onMoreMobile;
  final VoidCallback onEdit;
  final VoidCallback onDuplicate;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final accent = host.accentColor;

    return Material(
      color: NexusColors.bgSurface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onConnect,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              // Termius-style Squircle Badge + Live Online Dot
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(13),
                    ),
                    child: Icon(
                      switch (host.authMethod) {
                        AuthMethod.privateKey => Icons.vpn_key_rounded,
                        AuthMethod.none => Icons.hub_rounded,
                        AuthMethod.password => Icons.dns_rounded,
                      },
                      color: accent,
                      size: 21,
                    ),
                  ),
                  if (isOnline)
                    Positioned(
                      right: -2,
                      bottom: -2,
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: NexusColors.emerald,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: NexusColors.bgSurface,
                            width: 2.2,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 13),

              // Crisp Two-Line Host Info
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            host.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: NexusColors.textPrimary,
                            ),
                          ),
                        ),
                        if (host.usesProxyJump) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5.5,
                              vertical: 1.5,
                            ),
                            decoration: BoxDecoration(
                              color: jumpHostMissing
                                  ? NexusColors.amber.withValues(alpha: 0.14)
                                  : NexusColors.emerald.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  jumpHostMissing
                                      ? Icons.warning_amber_rounded
                                      : Icons.alt_route_rounded,
                                  size: 10.5,
                                  color: jumpHostMissing
                                      ? NexusColors.amber
                                      : NexusColors.emerald,
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  jumpHostMissing ? 'ProxyJump?' : 'ProxyJump',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: jumpHostMissing
                                        ? NexusColors.amber
                                        : NexusColors.emerald,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                        if (host.group != 'Default') ...[
                          const SizedBox(width: 7),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1.5,
                            ),
                            decoration: BoxDecoration(
                              color: NexusColors.bgElevated,
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: Text(
                              host.group,
                              style: const TextStyle(
                                fontSize: 10.5,
                                color: NexusColors.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      jumpRouteLabel != null
                          ? '$jumpRouteLabel → ${host.addressLabel}'
                          : 'SSH · ${host.addressLabel}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: NexusTheme.monospaceFontFamily,
                        fontSize: 12,
                        color: NexusColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),

              // Action Menu (Bottom Sheet on Mobile, Sleek Popup on Desktop)
              if (isMobile)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  onPressed: onMoreMobile,
                  icon: const Icon(
                    Icons.more_horiz_rounded,
                    size: 20,
                    color: NexusColors.textMuted,
                  ),
                )
              else
                PopupMenuButton<String>(
                  tooltip: '更多',
                  icon: const Icon(
                    Icons.more_horiz_rounded,
                    size: 19,
                    color: NexusColors.textMuted,
                  ),
                  onSelected: (action) {
                    switch (action) {
                      case 'edit':
                        onEdit();
                      case 'dup':
                        onDuplicate();
                      case 'del':
                        onDelete();
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'edit', child: Text('编辑主机')),
                    PopupMenuItem(value: 'dup', child: Text('克隆副本')),
                    PopupMenuDivider(),
                    PopupMenuItem(
                      value: 'del',
                      child: Text(
                        '删除主机',
                        style: TextStyle(color: NexusColors.rose),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyHostsState extends StatelessWidget {
  const _EmptyHostsState({
    required this.hasAnyHost,
    required this.onCreateHost,
    this.onQuickConnect,
    this.quickText = '',
  });

  final bool hasAnyHost;
  final VoidCallback onCreateHost;
  final VoidCallback? onQuickConnect;
  final String quickText;

  @override
  Widget build(BuildContext context) {
    if (onQuickConnect != null) {
      return Center(
        child: FilledButton.tonalIcon(
          onPressed: onQuickConnect,
          style: FilledButton.styleFrom(
            backgroundColor: NexusColors.bgSurface,
            foregroundColor: NexusColors.emerald,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          icon: const Icon(Icons.flash_on_rounded, size: 18),
          label: Text('快速连接 "$quickText"'),
        ),
      );
    }

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                color: NexusColors.emerald.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(18),
              ),
              child: const Icon(
                Icons.dns_rounded,
                size: 28,
                color: NexusColors.emerald,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              hasAnyHost ? '未找到匹配的主机' : '还没有添加主机',
              style: const TextStyle(
                fontSize: 16.5,
                fontWeight: FontWeight.w600,
                color: NexusColors.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              hasAnyHost
                  ? '尝试更换关键词，或直接在上方输入 user@host 连接'
                  : '点击下方按钮保存常用服务器，随时一键直连终端',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13,
                height: 1.45,
                color: NexusColors.textSecondary,
              ),
            ),
            if (!hasAnyHost) ...[
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: onCreateHost,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('新建主机'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
