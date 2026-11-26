import 'package:flutter/material.dart';
import 'package:nexus_ssh/src/desktop/desktop_tray_service.dart';
import 'package:nexus_ssh/src/models/ssh_models.dart';
import 'package:nexus_ssh/src/state/app_controller.dart';
import 'package:nexus_ssh/src/ui/app_theme.dart';
import 'package:nexus_ssh/src/ui/app_update_dialog.dart';
import 'package:nexus_ssh/src/ui/webdav_sync_dialog.dart';
import 'package:nexus_ssh/src/update/app_update_models.dart';

enum SettingsSection {
  general('常规', Icons.tune_rounded),
  shortcuts('快捷键', Icons.keyboard_rounded),
  sync('云同步', Icons.cloud_outlined),
  updates('关于与更新', Icons.system_update_alt_rounded);

  const SettingsSection(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// Unified Termius-style Settings Center consolidating window close behavior,
/// keyboard shortcuts (ready for Windows custom bindings), WebDAV cloud sync,
/// and GitHub Releases software updates.
class SettingsDialog extends StatefulWidget {
  const SettingsDialog({
    super.key,
    required this.controller,
    this.initialSection,
    this.isBottomSheet = false,
  });

  final AppController controller;
  final SettingsSection? initialSection;
  final bool isBottomSheet;

  static Future<void> show(
    BuildContext context, {
    required AppController controller,
    SettingsSection? initialSection,
  }) {
    final isMobile = MediaQuery.sizeOf(context).width < 680;
    if (isMobile) {
      return showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Colors.transparent,
        builder: (_) => SettingsDialog(
          controller: controller,
          initialSection: initialSection,
          isBottomSheet: true,
        ),
      );
    }
    return showDialog<void>(
      context: context,
      builder: (_) => SettingsDialog(
        controller: controller,
        initialSection: initialSection,
      ),
    );
  }

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late SettingsSection _section;

  List<SettingsSection> get _availableSections {
    final isDesktop = widget.controller.isDesktopTraySupported;
    return [
      if (isDesktop) SettingsSection.general,
      if (isDesktop) SettingsSection.shortcuts,
      SettingsSection.sync,
      SettingsSection.updates,
    ];
  }

  @override
  void initState() {
    super.initState();
    final sections = _availableSections;
    if (widget.initialSection != null &&
        sections.contains(widget.initialSection)) {
      _section = widget.initialSection!;
    } else {
      _section = sections.first;
    }
    if (_section == SettingsSection.updates &&
        widget.controller.updateState.phase == UpdatePhase.idle) {
      widget.controller.checkForUpdates();
    }
  }

  void _selectSection(SettingsSection next) {
    if (_section == next) return;
    setState(() => _section = next);
    if (next == SettingsSection.updates &&
        widget.controller.updateState.phase == UpdatePhase.idle) {
      widget.controller.checkForUpdates();
    }
  }

  Future<void> _quickSyncWebDav() async {
    final res = await widget.controller.syncWebDav();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(res.message),
        backgroundColor: res.ok ? NexusColors.bgElevated : NexusColors.rose,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        if (widget.isBottomSheet) {
          return _buildMobileSheet(context);
        }
        return _buildDesktopDialog(context);
      },
    );
  }

  Widget _buildDesktopDialog(BuildContext context) {
    final sections = _availableSections;
    final hasUpdate = widget.controller.hasUnignoredUpdate;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 740, maxHeight: 540),
        child: Material(
          color: NexusColors.bgCanvas,
          borderRadius: BorderRadius.circular(20),
          clipBehavior: Clip.antiAlias,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: NexusColors.borderActive),
            ),
            child: Row(
              children: [
                // Left navigation rail
                Container(
                  width: 196,
                  decoration: const BoxDecoration(
                    color: NexusColors.bgSidebar,
                    border: Border(
                      right: BorderSide(
                        color: NexusColors.borderSubtle,
                        width: 0.9,
                      ),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(18, 18, 14, 14),
                        child: Row(
                          children: [
                            Container(
                              width: 28,
                              height: 28,
                              decoration: BoxDecoration(
                                color: NexusColors.emerald.withValues(
                                  alpha: 0.14,
                                ),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: NexusColors.emerald.withValues(
                                    alpha: 0.35,
                                  ),
                                ),
                              ),
                              child: const Icon(
                                Icons.settings_rounded,
                                size: 15.5,
                                color: NexusColors.emerald,
                              ),
                            ),
                            const SizedBox(width: 9),
                            const Text(
                              '设置',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: NexusColors.textPrimary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Divider(
                        height: 1,
                        thickness: 0.8,
                        color: NexusColors.borderSubtle,
                      ),
                      const SizedBox(height: 10),
                      for (final item in sections)
                        _buildNavTile(
                          item,
                          selected: _section == item,
                          showDot: item == SettingsSection.updates && hasUpdate,
                          subtitleBadge:
                              item == SettingsSection.sync &&
                                  widget.controller.webDavConfig.isConfigured
                              ? '已连接'
                              : null,
                        ),
                      const Spacer(),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
                        child: Text(
                          'Nexus SSH ${widget.controller.updateState.currentVersion.displayLabel}',
                          style: TextStyle(
                            fontFamily: NexusTheme.monospaceFontFamily,
                            fontSize: 11,
                            color: NexusColors.textMuted,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // Right content area
                Expanded(
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(22, 16, 14, 12),
                        child: Row(
                          children: [
                            Icon(
                              _section.icon,
                              size: 18,
                              color: NexusColors.emerald,
                            ),
                            const SizedBox(width: 9),
                            Text(
                              _section.label,
                              style: const TextStyle(
                                fontSize: 15.5,
                                fontWeight: FontWeight.w700,
                                color: NexusColors.textPrimary,
                              ),
                            ),
                            const Spacer(),
                            IconButton(
                              tooltip: '关闭',
                              visualDensity: VisualDensity.compact,
                              onPressed: () => Navigator.of(context).pop(),
                              icon: const Icon(
                                Icons.close_rounded,
                                size: 18,
                                color: NexusColors.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Divider(
                        height: 1,
                        thickness: 0.8,
                        color: NexusColors.borderSubtle,
                      ),
                      Expanded(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(22, 18, 22, 22),
                          child: _buildSectionContent(context),
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
    );
  }

  Widget _buildMobileSheet(BuildContext context) {
    final sections = _availableSections;
    final hasUpdate = widget.controller.hasUnignoredUpdate;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.86,
      ),
      decoration: const BoxDecoration(
        color: NexusColors.bgCanvas,
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        border: Border(top: BorderSide(color: NexusColors.borderActive)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.only(top: 10, bottom: 8),
            decoration: BoxDecoration(
              color: NexusColors.borderActive,
              borderRadius: BorderRadius.circular(99),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 2, 12, 10),
            child: Row(
              children: [
                const Text(
                  '设置',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: NexusColors.textPrimary,
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: '关闭',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(
                    Icons.close_rounded,
                    size: 19,
                    color: NexusColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(
              children: [
                for (var i = 0; i < sections.length; i++) ...[
                  if (i > 0) const SizedBox(width: 8),
                  Expanded(
                    child: _buildMobileTabChip(
                      sections[i],
                      selected: _section == sections[i],
                      showDot:
                          sections[i] == SettingsSection.updates && hasUpdate,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const Divider(
            height: 1,
            thickness: 0.8,
            color: NexusColors.borderSubtle,
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 24),
              child: _buildSectionContent(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNavTile(
    SettingsSection item, {
    required bool selected,
    bool showDot = false,
    String? subtitleBadge,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Material(
        color: selected
            ? NexusColors.emerald.withValues(alpha: 0.12)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => _selectSection(item),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
            child: Row(
              children: [
                Icon(
                  item.icon,
                  size: 16.5,
                  color: selected
                      ? NexusColors.emerald
                      : NexusColors.textSecondary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    item.label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: selected
                          ? NexusColors.emerald
                          : NexusColors.textPrimary,
                    ),
                  ),
                ),
                if (showDot)
                  Container(
                    width: 7,
                    height: 7,
                    decoration: const BoxDecoration(
                      color: NexusColors.emerald,
                      shape: BoxShape.circle,
                    ),
                  )
                else if (subtitleBadge != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 1.5,
                    ),
                    decoration: BoxDecoration(
                      color: NexusColors.emerald.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: Text(
                      subtitleBadge,
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: NexusColors.emerald,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMobileTabChip(
    SettingsSection item, {
    required bool selected,
    bool showDot = false,
  }) {
    return Material(
      color: selected
          ? NexusColors.emerald.withValues(alpha: 0.14)
          : NexusColors.bgSurface,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _selectSection(item),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected
                  ? NexusColors.emerald.withValues(alpha: 0.45)
                  : NexusColors.borderSubtle,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                item.icon,
                size: 15,
                color: selected
                    ? NexusColors.emerald
                    : NexusColors.textSecondary,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: selected
                        ? NexusColors.emerald
                        : NexusColors.textPrimary,
                  ),
                ),
              ),
              if (showDot) ...[
                const SizedBox(width: 5),
                Container(
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(
                    color: NexusColors.emerald,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionContent(BuildContext context) {
    return switch (_section) {
      SettingsSection.general => _buildGeneralSection(),
      SettingsSection.shortcuts => _buildShortcutsSection(),
      SettingsSection.sync => _buildWebDavSection(context),
      SettingsSection.updates => _buildUpdatesSection(),
    };
  }

  Widget _buildGeneralSection() {
    final current = widget.controller.closeBehavior;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeading(
          '关闭窗口行为',
          '设置点击桌面端主窗口关闭按钮时的默认动作',
        ),
        const SizedBox(height: 12),
        _closeOptionTile(
          selected: current == DesktopCloseBehavior.ask,
          icon: Icons.help_outline_rounded,
          title: '每次询问',
          subtitle: '点击关闭按钮时弹窗选择退出或退到系统托盘',
          onTap: () =>
              widget.controller.setCloseBehavior(DesktopCloseBehavior.ask),
        ),
        const SizedBox(height: 8),
        _closeOptionTile(
          selected: current == DesktopCloseBehavior.minimizeToTray,
          icon: Icons.south_east_rounded,
          title: '退到系统托盘',
          subtitle: '隐藏主窗口并保持 SSH 与本地终端会话后台在线',
          onTap: () => widget.controller.setCloseBehavior(
            DesktopCloseBehavior.minimizeToTray,
          ),
        ),
        const SizedBox(height: 8),
        _closeOptionTile(
          selected: current == DesktopCloseBehavior.exit,
          icon: Icons.power_settings_new_rounded,
          title: '直接退出',
          subtitle: '断开所有会话并彻底关闭应用程序',
          onTap: () =>
              widget.controller.setCloseBehavior(DesktopCloseBehavior.exit),
        ),
      ],
    );
  }

  Widget _buildShortcutsSection() {
    const builtInBindings = <(String, String, String)>[
      ('终端原生补全', '透传给远端或本地 Shell 执行原生补全', 'Tab'),
      ('一键采纳行尾联想', '在命令提示浮窗显示时快速补全当前建议', '→'),
      ('切换并确认命令提示', '在联想候选中上下移动并回车确认', '↑ / ↓ + Enter'),
      ('终端复制 / 粘贴', '在活动终端会话内复制选区或粘贴文本', 'Ctrl + Shift + C / V'),
      ('展开 / 收起侧边栏', '在工作区左侧切换完整导航与极简图标栏', '侧栏顶部按钮'),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeading(
          '桌面快捷键',
          '查看当前内置终端与工作区快捷键，自定义按键映射将在后续版本接入',
        ),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: NexusColors.cyan.withValues(alpha: 0.09),
            borderRadius: BorderRadius.circular(11),
            border: Border.all(
              color: NexusColors.cyan.withValues(alpha: 0.28),
            ),
          ),
          child: const Row(
            children: [
              Icon(
                Icons.auto_awesome_outlined,
                size: 16.5,
                color: NexusColors.cyan,
              ),
              SizedBox(width: 9),
              Expanded(
                child: Text(
                  'Windows 自定义快捷键配置（新建标签、切标签、唤起主窗口等）已预留扩展位，即将支持。',
                  style: TextStyle(
                    fontSize: 12.2,
                    height: 1.45,
                    color: NexusColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Container(
          decoration: BoxDecoration(
            color: NexusColors.bgSurface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: NexusColors.borderSubtle),
          ),
          child: Column(
            children: [
              for (var i = 0; i < builtInBindings.length; i++) ...[
                if (i > 0)
                  const Divider(
                    height: 1,
                    thickness: 0.7,
                    color: NexusColors.borderSubtle,
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 13,
                    vertical: 11,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              builtInBindings[i].$1,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: NexusColors.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              builtInBindings[i].$2,
                              style: const TextStyle(
                                fontSize: 11.5,
                                color: NexusColors.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: NexusColors.bgCanvas,
                          borderRadius: BorderRadius.circular(7),
                          border: Border.all(color: NexusColors.borderActive),
                        ),
                        child: Text(
                          builtInBindings[i].$3,
                          style: TextStyle(
                            fontFamily: NexusTheme.monospaceFontFamily,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: NexusColors.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildWebDavSection(BuildContext context) {
    final cfg = widget.controller.webDavConfig;
    final configured = cfg.isConfigured;
    final syncing = widget.controller.syncingWebDav;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeading(
          'WebDAV 云同步',
          '跨设备加密同步主机资产与命令片段，兼容坚果云、Nextcloud、Alist / OpenList 等服务',
        ),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: NexusColors.bgSurface,
            borderRadius: BorderRadius.circular(13),
            border: Border.all(
              color: configured
                  ? NexusColors.emerald.withValues(alpha: 0.38)
                  : NexusColors.borderSubtle,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: (configured
                              ? NexusColors.emerald
                              : NexusColors.textMuted)
                          .withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      configured
                          ? Icons.cloud_done_rounded
                          : Icons.cloud_off_outlined,
                      size: 19,
                      color: configured
                          ? NexusColors.emerald
                          : NexusColors.textSecondary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          configured ? 'WebDAV 已连接' : '尚未配置 WebDAV',
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: NexusColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          configured
                              ? cfg.url
                              : '配置后可在多设备间安全合并主机配置与命令片段',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: configured
                                ? NexusTheme.monospaceFontFamily
                                : null,
                            fontSize: 11.5,
                            color: NexusColors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (configured) ...[
                const SizedBox(height: 12),
                const Divider(
                  height: 1,
                  thickness: 0.7,
                  color: NexusColors.borderSubtle,
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _statusChip(
                      icon: Icons.sync_rounded,
                      label: '策略：${cfg.defaultSyncMode.label}',
                      accent: NexusColors.cyan,
                    ),
                    _statusChip(
                      icon: cfg.hasStoredEncryptionPassword
                          ? Icons.enhanced_encryption_outlined
                          : Icons.warning_amber_rounded,
                      label: cfg.hasStoredEncryptionPassword
                          ? 'AES-256-GCM 端到端加密'
                          : '未开启端到端加密',
                      accent: cfg.hasStoredEncryptionPassword
                          ? NexusColors.emerald
                          : NexusColors.amber,
                    ),
                    _statusChip(
                      icon: cfg.autoSync
                          ? Icons.bolt_rounded
                          : Icons.pan_tool_alt_outlined,
                      label: cfg.autoSync ? '自动同步已开启' : '仅手动同步',
                      accent: NexusColors.textSecondary,
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 14),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: () => WebDavSyncDialog.show(
                      context,
                      controller: widget.controller,
                    ),
                    icon: const Icon(Icons.tune_rounded, size: 16.5),
                    label: Text(configured ? '修改 WebDAV 配置' : '配置 WebDAV 云同步'),
                  ),
                  if (configured)
                    OutlinedButton.icon(
                      onPressed: syncing ? null : _quickSyncWebDav,
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: NexusColors.borderActive),
                      ),
                      icon: syncing
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(
                              switch (cfg.defaultSyncMode) {
                                SyncMode.merge => Icons.sync_rounded,
                                SyncMode.pullOverwrite =>
                                  Icons.cloud_download_outlined,
                                SyncMode.pushOverwrite =>
                                  Icons.cloud_upload_outlined,
                              },
                              size: 16.5,
                              color: NexusColors.emerald,
                            ),
                      label: Text(
                        syncing ? '正在同步...' : '立即同步（${cfg.defaultSyncMode.label}）',
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildUpdatesSection() {
    final state = widget.controller.updateState;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Brand & version header card
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: NexusColors.bgSurface,
            borderRadius: BorderRadius.circular(13),
            border: Border.all(color: NexusColors.borderSubtle),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.asset(
                  'assets/icons/app_icon.png',
                  width: 40,
                  height: 40,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Nexus SSH',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: NexusColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '当前版本 ${state.currentVersion.displayLabel} (Build ${state.currentVersion.buildNumber}) · MIT Open Source',
                      style: TextStyle(
                        fontFamily: NexusTheme.monospaceFontFamily,
                        fontSize: 11.2,
                        color: NexusColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              OutlinedButton.icon(
                onPressed: widget.controller.openUpdateReleasePage,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  side: const BorderSide(color: NexusColors.borderActive),
                ),
                icon: const Icon(Icons.open_in_new_rounded, size: 14.5),
                label: const Text('GitHub', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        AppUpdatePanel(controller: widget.controller),
      ],
    );
  }

  Widget _sectionHeading(String title, String subtitle) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: NexusColors.textPrimary,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          subtitle,
          style: const TextStyle(
            fontSize: 12,
            height: 1.4,
            color: NexusColors.textMuted,
          ),
        ),
      ],
    );
  }

  Widget _statusChip({
    required IconData icon,
    required String label,
    required Color accent,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: accent.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13.5, color: accent),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w500,
              color: accent == NexusColors.textSecondary
                  ? NexusColors.textSecondary
                  : accent,
            ),
          ),
        ],
      ),
    );
  }

  Widget _closeOptionTile({
    required bool selected,
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Material(
      color: selected
          ? NexusColors.emerald.withValues(alpha: 0.13)
          : NexusColors.bgSurface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected
                  ? NexusColors.emerald.withValues(alpha: 0.5)
                  : NexusColors.borderSubtle,
            ),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 18,
                color: selected
                    ? NexusColors.emerald
                    : NexusColors.textSecondary,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: selected
                            ? NexusColors.emerald
                            : NexusColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: NexusColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              if (selected)
                const Icon(
                  Icons.check_circle_rounded,
                  size: 18,
                  color: NexusColors.emerald,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
