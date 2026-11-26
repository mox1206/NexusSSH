import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:nexus_ssh/src/models/ssh_models.dart';
import 'package:nexus_ssh/src/state/app_controller.dart';
import 'package:nexus_ssh/src/ui/app_lock_overlay.dart';
import 'package:nexus_ssh/src/ui/app_lock_settings_dialog.dart';
import 'package:nexus_ssh/src/ui/app_theme.dart';
import 'package:nexus_ssh/src/ui/desktop_close_dialog.dart';
import 'package:nexus_ssh/src/ui/host_editor_dialog.dart';
import 'package:nexus_ssh/src/ui/host_key_dialog.dart';
import 'package:nexus_ssh/src/ui/hosts_view.dart';
import 'package:nexus_ssh/src/ui/snippets_panel.dart';
import 'package:nexus_ssh/src/ui/terminal_session_view.dart';
import 'package:nexus_ssh/src/ui/webdav_sync_dialog.dart';

class WorkspaceScreen extends StatefulWidget {
  const WorkspaceScreen({super.key, required this.controller});

  final AppController controller;

  static Color _phaseDotColor(SessionPhase phase) {
    return switch (phase) {
      SessionPhase.connecting || SessionPhase.verifyHostKey => NexusColors.amber,
      SessionPhase.connected || SessionPhase.sftpProgress => NexusColors.emerald,
      SessionPhase.disconnected => NexusColors.textMuted,
      SessionPhase.error => NexusColors.rose,
    };
  }

  @override
  State<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends State<WorkspaceScreen>
    with WidgetsBindingObserver {
  AppController get controller => widget.controller;

  final Set<int> _activePointers = <int>{};
  Size? _lastMetricsSize;
  bool _suppressResizePointers = false;
  Timer? _resizePointerTimer;

  Size? _currentPhysicalWindowSize() {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return null;
    return views.first.physicalSize;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lastMetricsSize = _currentPhysicalWindowSize();
  }

  @override
  void dispose() {
    _resizePointerTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    controller.onAppLifecycleChanged(state);
  }

  @override
  void didChangeMetrics() {
    final nextSize = _currentPhysicalWindowSize();
    final prevSize = _lastMetricsSize;
    _lastMetricsSize = nextSize;

    // On Windows/desktop, double-clicking the native titlebar (WM_NCLBUTTONDBLCLK)
    // maximizes/restores the window while the mouse button may still be held down,
    // leaking a phantom PointerDown/Up onto whichever host card moves under the cursor.
    // Cancel any active pointers and absorb spurious pointer events briefly across the resize.
    if (!controller.isDesktopTraySupported ||
        prevSize == null ||
        nextSize == null ||
        prevSize == nextSize) {
      return;
    }

    for (final pointer in _activePointers.toList()) {
      GestureBinding.instance.cancelPointer(pointer);
    }
    _activePointers.clear();

    _resizePointerTimer?.cancel();
    if (!_suppressResizePointers && mounted) {
      setState(() => _suppressResizePointers = true);
    }
    _resizePointerTimer = Timer(const Duration(milliseconds: 240), () {
      if (mounted && _suppressResizePointers) {
        setState(() => _suppressResizePointers = false);
      }
    });
  }

  Future<void> _createNewHost(BuildContext context) async {
    final res = await HostEditorDialog.show(context, controller: controller);
    if (res != null && res.connectNow) {
      await controller.openSession(res.profile);
    }
  }

  void _showMobileSessionsSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final sessions = controller.sessions;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
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
                      const Padding(
                        padding: EdgeInsets.only(left: 8),
                        child: Text(
                          '活动终端',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: NexusColors.textPrimary,
                          ),
                        ),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          controller.showHostsVault();
                        },
                        icon: const Icon(Icons.dns_outlined, size: 16),
                        label: const Text('返回主机列表'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  for (final s in sessions)
                    ListTile(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      selected: controller.activeSessionId == s.id,
                      selectedTileColor: NexusColors.bgSurface,
                      leading: Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: WorkspaceScreen._phaseDotColor(s.phase),
                        ),
                      ),
                      title: Text(
                        s.tabTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        s.profile.addressLabel,
                        style: TextStyle(
                          fontFamily: NexusTheme.monospaceFontFamily,
                          fontSize: 12,
                        ),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.close_rounded, size: 18),
                        onPressed: () {
                          controller.closeSessionTab(s.id);
                          if (controller.sessions.isEmpty) {
                            Navigator.of(ctx).pop();
                          }
                        },
                      ),
                      onTap: () {
                        Navigator.of(ctx).pop();
                        controller.selectSession(s.id);
                      },
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (!controller.initialized) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final width = MediaQuery.sizeOf(context).width;
        final isDesktop = width >= 780;
        final activeSession = controller.activeSession;
        final pendingPrompt = controller.nextHostKeyPrompt;

        final Widget mainLayout;
        if (!isDesktop) {
          // Mobile Layout: Clean Termius-style full-screen Hosts + Floating Active Terminal Pill,
          // or full-screen Immersive Terminal
          mainLayout = activeSession != null
              ? TerminalSessionView(
                  key: ValueKey('session_${activeSession.id}'),
                  controller: controller,
                  session: activeSession,
                  isMobile: true,
                  onShowSessionSwitcher: () =>
                      _showMobileSessionsSheet(context),
                )
              : Stack(
                  children: [
                    HostsVaultView(controller: controller),
                    if (controller.sessions.isNotEmpty)
                      Positioned(
                        left: 16,
                        right: 16,
                        bottom: 16,
                        child: _MobileActiveSessionsFloatingBar(
                          controller: controller,
                          onOpenSheet: () => _showMobileSessionsSheet(context),
                        ),
                      ),
                  ],
                );
        } else {
          // Desktop Layout: Minimal Termius Sidebar + Conditional Clean Tab Bar
          mainLayout = Row(
            children: [
              _DesktopSidebar(
                controller: controller,
                onNewHost: () => _createNewHost(context),
              ),
              Expanded(
                child: Column(
                  children: [
                    if (controller.sessions.isNotEmpty)
                      _DesktopSessionTabBar(controller: controller),
                    if (controller.initError != null)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        color: NexusColors.rose.withValues(alpha: 0.15),
                        child: Text(
                          '存储初始化提示: ${controller.initError}',
                          style: const TextStyle(
                            color: NexusColors.rose,
                            fontSize: 12.5,
                          ),
                        ),
                      ),
                    Expanded(
                      child: activeSession == null
                          ? HostsVaultView(controller: controller)
                          : TerminalSessionView(
                              key: ValueKey('session_${activeSession.id}'),
                              controller: controller,
                              session: activeSession,
                            ),
                    ),
                  ],
                ),
              ),
            ],
          );
        }

        return Scaffold(
          body: Stack(
            children: [
              Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (e) => _activePointers.add(e.pointer),
                onPointerUp: (e) => _activePointers.remove(e.pointer),
                onPointerCancel: (e) => _activePointers.remove(e.pointer),
                child: AbsorbPointer(
                  absorbing: _suppressResizePointers,
                  child: SafeArea(child: mainLayout),
                ),
              ),
              if (pendingPrompt != null)
                Positioned.fill(
                  child: HostKeyVerificationOverlay(
                    key: ValueKey('tofu_${pendingPrompt.requestId}'),
                    controller: controller,
                    prompt: pendingPrompt,
                  ),
                ),
              if (controller.closePromptPending)
                Positioned.fill(
                  child: DesktopCloseActionOverlay(controller: controller),
                ),
              if (controller.privacyShieldActive && !controller.isAppLocked)
                const Positioned.fill(child: PrivacyShieldOverlay()),
              if (controller.isAppLocked)
                Positioned.fill(
                  child: AppLockOverlay(controller: controller),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Termius Mobile-inspired floating pill shown at the bottom of Hosts screen
/// when one or more SSH terminals are running in the background.
class _MobileActiveSessionsFloatingBar extends StatelessWidget {
  const _MobileActiveSessionsFloatingBar({
    required this.controller,
    required this.onOpenSheet,
  });

  final AppController controller;
  final VoidCallback onOpenSheet;

  @override
  Widget build(BuildContext context) {
    final latest = controller.sessions.last;
    final count = controller.sessions.length;

    return Material(
      color: NexusColors.bgElevated,
      elevation: 8,
      shadowColor: Colors.black54,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          if (count == 1) {
            controller.selectSession(latest.id);
          } else {
            onOpenSheet();
          }
        },
        child: Container(
          height: 54,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: NexusColors.emerald.withValues(alpha: 0.35),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: WorkspaceScreen._phaseDotColor(latest.phase),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      count == 1 ? latest.tabTitle : '$count 个活动终端运行中',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: NexusColors.textPrimary,
                      ),
                    ),
                    Text(
                      latest.profile.addressLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: NexusTheme.monospaceFontFamily,
                        fontSize: 11.2,
                        color: NexusColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const Text(
                '返回终端',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: NexusColors.emerald,
                ),
              ),
              const SizedBox(width: 4),
              const Icon(
                Icons.arrow_forward_ios_rounded,
                size: 13,
                color: NexusColors.emerald,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DesktopSidebar extends StatelessWidget {
  const _DesktopSidebar({
    required this.controller,
    required this.onNewHost,
  });

  static const double _expandedWidth = 216;
  static const double _collapsedWidth = 58;

  final AppController controller;
  final VoidCallback onNewHost;

  Future<void> _triggerQuickWebDavSync(BuildContext context) async {
    try {
      final res = await controller.syncWebDav();
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(res.message)));
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('同步失败: $e')));
    }
  }

  void _openSnippets(BuildContext context) {
    SnippetsPanel.showModal(
      context,
      controller: controller,
      activeSessionId: controller.activeSession?.phase == SessionPhase.connected
          ? controller.activeSessionId
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final collapsed = controller.sidebarCollapsed;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      width: collapsed ? _collapsedWidth : _expandedWidth,
      decoration: const BoxDecoration(
        color: NexusColors.bgSidebar,
        border: Border(
          right: BorderSide(color: NexusColors.borderSubtle, width: 0.8),
        ),
      ),
      child: ClipRect(
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 130) {
              return _CollapsedSidebarContent(
                controller: controller,
                onNewHost: onNewHost,
                onOpenSnippets: () => _openSnippets(context),
                onQuickWebDavSync: () => _triggerQuickWebDavSync(context),
              );
            }
            return OverflowBox(
              minWidth: _expandedWidth - 0.8,
              maxWidth: _expandedWidth - 0.8,
              alignment: Alignment.topLeft,
              child: _ExpandedSidebarContent(
                controller: controller,
                onNewHost: onNewHost,
                onOpenSnippets: () => _openSnippets(context),
                onQuickWebDavSync: () => _triggerQuickWebDavSync(context),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ExpandedSidebarContent extends StatelessWidget {
  const _ExpandedSidebarContent({
    required this.controller,
    required this.onNewHost,
    required this.onOpenSnippets,
    required this.onQuickWebDavSync,
  });

  final AppController controller;
  final VoidCallback onNewHost;
  final VoidCallback onOpenSnippets;
  final VoidCallback onQuickWebDavSync;

  @override
  Widget build(BuildContext context) {
    final inVault = controller.activeSessionId == null;
    final customGroups = controller.groups.where((g) => g != 'All').toList();
    final hasGroups = controller.groups.length > 2;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 1. Minimal Brand Header + Collapse Toggle
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 10, 12),
          child: Row(
            children: [
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: NexusColors.borderActive.withValues(alpha: 0.7),
                    width: 0.8,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: Image.asset(
                  'assets/icons/app_icon.png',
                  width: 26,
                  height: 26,
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.medium,
                ),
              ),
              const SizedBox(width: 9),
              const Expanded(
                child: Text(
                  'Nexus SSH',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                    color: NexusColors.textPrimary,
                  ),
                ),
              ),
              Tooltip(
                message: '收起侧边栏',
                child: Material(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  child: InkWell(
                    key: const ValueKey('sidebar_collapse_btn'),
                    borderRadius: BorderRadius.circular(8),
                    onTap: controller.toggleSidebarCollapsed,
                    child: const SizedBox(
                      width: 28,
                      height: 28,
                      child: Icon(
                        Icons.keyboard_double_arrow_left_rounded,
                        size: 17,
                        color: NexusColors.textMuted,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),

        // 2. Compact Action Row: New Host + Local Terminal
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 36,
                  child: FilledButton.icon(
                    onPressed: onNewHost,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      textStyle: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    icon: const Icon(Icons.add_rounded, size: 17),
                    label: const Text(
                      '新建主机',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
              if (controller.isLocalTerminalSupported) ...[
                const SizedBox(width: 6),
                _LocalTerminalSplitButton(controller: controller),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),

        // 3. Core Navigation
        _SidebarItem(
          icon: Icons.dns_rounded,
          label: 'Hosts',
          badgeText: '${controller.allHosts.length}',
          selected: inVault && controller.selectedGroup == 'All',
          onTap: () {
            controller.setSelectedGroup('All');
            controller.showHostsVault();
          },
        ),
        _SidebarItem(
          icon: Icons.code_rounded,
          label: 'Snippets',
          badgeText: '${controller.snippets.length}',
          selected: false,
          onTap: onOpenSnippets,
        ),

        // 4. Unified Scrollable Middle Region: Collapsible GROUPS & TERMINALS
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(top: 6, bottom: 8),
            children: [
              if (hasGroups) ...[
                _SidebarSectionHeader(
                  title: 'GROUPS',
                  count: customGroups.length,
                  collapsed: controller.sidebarGroupsCollapsed,
                  onToggle: controller.toggleSidebarGroupsCollapsed,
                ),
                if (!controller.sidebarGroupsCollapsed)
                  for (final group in customGroups)
                    _SidebarItem(
                      icon: Icons.folder_outlined,
                      iconSize: 15.5,
                      label: group,
                      badgeText:
                          '${controller.allHosts.where((h) => h.group == group).length}',
                      selected: inVault && controller.selectedGroup == group,
                      onTap: () {
                        controller.setSelectedGroup(group);
                        controller.showHostsVault();
                      },
                    ),
              ],
              if (controller.sessions.isNotEmpty) ...[
                _SidebarSectionHeader(
                  title: 'TERMINALS',
                  count: controller.sessions.length,
                  accentCount: true,
                  collapsed: controller.sidebarTerminalsCollapsed,
                  onToggle: controller.toggleSidebarTerminalsCollapsed,
                ),
                if (!controller.sidebarTerminalsCollapsed)
                  for (final s in controller.sessions)
                    _SidebarItem(
                      icon: s.isLocal ? Icons.terminal_rounded : Icons.circle,
                      iconSize: s.isLocal ? 14 : 8,
                      iconColor: s.isLocal
                          ? NexusColors.cyan
                          : WorkspaceScreen._phaseDotColor(s.phase),
                      label: s.tabTitle,
                      selected: controller.activeSessionId == s.id,
                      showTrailingOnHover: true,
                      onTap: () => controller.selectSession(s.id),
                      trailing: Tooltip(
                        message: '关闭会话',
                        child: InkWell(
                          borderRadius: BorderRadius.circular(5),
                          onTap: () => controller.closeSessionTab(s.id),
                          child: const Padding(
                            padding: EdgeInsets.all(2),
                            child: Icon(
                              Icons.close_rounded,
                              size: 14,
                              color: NexusColors.textMuted,
                            ),
                          ),
                        ),
                      ),
                    ),
              ],
            ],
          ),
        ),

        // 5. Equal-width Icon Utility Dock Footer
        const Divider(height: 1, thickness: 0.8, color: NexusColors.borderSubtle),
        _SidebarFooterDock(
          controller: controller,
          onQuickWebDavSync: onQuickWebDavSync,
        ),
      ],
    );
  }
}

class _CollapsedSidebarContent extends StatelessWidget {
  const _CollapsedSidebarContent({
    required this.controller,
    required this.onNewHost,
    required this.onOpenSnippets,
    required this.onQuickWebDavSync,
  });

  final AppController controller;
  final VoidCallback onNewHost;
  final VoidCallback onOpenSnippets;
  final VoidCallback onQuickWebDavSync;

  @override
  Widget build(BuildContext context) {
    final inVault = controller.activeSessionId == null;
    final davConfigured = controller.webDavConfig.isConfigured;
    final appLockEnabled = controller.appLockConfig.enabled;

    return Column(
      children: [
        const SizedBox(height: 14),
        Tooltip(
          message: 'Nexus SSH · 展开侧边栏',
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: controller.toggleSidebarCollapsed,
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: NexusColors.borderActive.withValues(alpha: 0.7),
                  width: 0.8,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: Image.asset(
                'assets/icons/app_icon.png',
                width: 28,
                height: 28,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.medium,
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        _RailIconButton(
          key: const ValueKey('sidebar_expand_btn'),
          tooltip: '展开侧边栏',
          icon: Icons.keyboard_double_arrow_right_rounded,
          iconColor: NexusColors.textMuted,
          height: 30,
          onTap: controller.toggleSidebarCollapsed,
        ),
        const SizedBox(height: 8),

        // Primary quick actions
        Tooltip(
          message: '新建主机',
          child: Material(
            color: NexusColors.emerald,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: onNewHost,
              child: const SizedBox(
                width: 36,
                height: 36,
                child: Icon(
                  Icons.add_rounded,
                  size: 19,
                  color: Color(0xFF062819),
                ),
              ),
            ),
          ),
        ),
        if (controller.isLocalTerminalSupported) ...[
          const SizedBox(height: 6),
          Tooltip(
            message: controller.preferredLocalShell != null
                ? '本地终端 · ${controller.preferredLocalShell!.name}'
                : '本地终端',
            child: Material(
              color: NexusColors.bgSurface,
              borderRadius: BorderRadius.circular(10),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => controller.openLocalSession(),
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: NexusColors.borderSubtle,
                      width: 0.8,
                    ),
                  ),
                  child: const Icon(
                    Icons.terminal_rounded,
                    size: 16.5,
                    color: NexusColors.cyan,
                  ),
                ),
              ),
            ),
          ),
        ],

        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Container(
            width: 24,
            height: 0.8,
            color: NexusColors.borderSubtle,
          ),
        ),

        // Core nav icons
        _RailIconButton(
          tooltip: 'Hosts (${controller.allHosts.length})',
          icon: Icons.dns_rounded,
          selected: inVault,
          onTap: () {
            controller.setSelectedGroup('All');
            controller.showHostsVault();
          },
        ),
        const SizedBox(height: 4),
        _RailIconButton(
          tooltip: 'Snippets (${controller.snippets.length})',
          icon: Icons.code_rounded,
          onTap: onOpenSnippets,
        ),

        // Active sessions indicator dots
        if (controller.sessions.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Container(
              width: 24,
              height: 0.8,
              color: NexusColors.borderSubtle,
            ),
          ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.only(bottom: 8),
              itemCount: controller.sessions.length,
              separatorBuilder: (_, _) => const SizedBox(height: 4),
              itemBuilder: (context, index) {
                final s = controller.sessions[index];
                final active = controller.activeSessionId == s.id;
                final dotColor = WorkspaceScreen._phaseDotColor(s.phase);
                return Center(
                  child: Tooltip(
                    message:
                        '${s.tabTitle} · ${s.isLocal ? '本地终端' : s.profile.addressLabel}',
                    child: Material(
                      color: active
                          ? NexusColors.bgSurface
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(10),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () => controller.selectSession(s.id),
                        child: SizedBox(
                          width: 38,
                          height: 34,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              if (active)
                                Positioned(
                                  left: 2,
                                  child: Container(
                                    width: 2.5,
                                    height: 14,
                                    decoration: BoxDecoration(
                                      color: NexusColors.emerald,
                                      borderRadius: BorderRadius.circular(99),
                                    ),
                                  ),
                                ),
                              if (s.isLocal)
                                Icon(
                                  Icons.terminal_rounded,
                                  size: 15,
                                  color: active
                                      ? NexusColors.cyan
                                      : NexusColors.textSecondary,
                                )
                              else
                                Container(
                                  width: 9,
                                  height: 9,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: dotColor,
                                    boxShadow: active
                                        ? [
                                            BoxShadow(
                                              color: dotColor.withValues(
                                                alpha: 0.45,
                                              ),
                                              blurRadius: 6,
                                            ),
                                          ]
                                        : null,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ] else
          const Spacer(),

        // Compact vertical utility dock
        Container(
          width: 28,
          height: 0.8,
          color: NexusColors.borderSubtle,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            children: [
              _RailIconButton(
                tooltip: controller.syncingWebDav
                    ? '正在同步 WebDAV...'
                    : (davConfigured ? 'WebDAV 已连接（点击配置）' : 'WebDAV 云同步'),
                height: 32,
                customChild: controller.syncingWebDav
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 1.8),
                      )
                    : Icon(
                        davConfigured
                            ? Icons.cloud_done_rounded
                            : Icons.cloud_outlined,
                        size: 16.5,
                        color: davConfigured
                            ? NexusColors.emerald
                            : NexusColors.textSecondary,
                      ),
                onTap: () =>
                    WebDavSyncDialog.show(context, controller: controller),
              ),
              if (davConfigured && !controller.syncingWebDav) ...[
                const SizedBox(height: 2),
                _RailIconButton(
                  tooltip:
                      '立即执行（${controller.webDavConfig.defaultSyncMode.label}）',
                  height: 32,
                  icon: _syncModeIcon(controller.webDavConfig.defaultSyncMode),
                  iconSize: 16,
                  iconColor: NexusColors.emerald,
                  onTap: onQuickWebDavSync,
                ),
              ],
              const SizedBox(height: 2),
              _RailIconButton(
                tooltip: appLockEnabled ? '安全中心（应用锁已开启）' : '安全中心（未加锁）',
                height: 32,
                icon: appLockEnabled
                    ? Icons.verified_user_rounded
                    : Icons.shield_outlined,
                iconSize: 16.5,
                iconColor: appLockEnabled
                    ? NexusColors.emerald
                    : NexusColors.textSecondary,
                onTap: () =>
                    AppLockSettingsDialog.show(context, controller: controller),
              ),
              if (appLockEnabled) ...[
                const SizedBox(height: 2),
                _RailIconButton(
                  tooltip: '立即锁屏',
                  height: 32,
                  icon: Icons.lock_outline_rounded,
                  iconSize: 16,
                  iconColor: NexusColors.emerald,
                  onTap: controller.lockNow,
                ),
              ],
              if (controller.isDesktopTraySupported) ...[
                const SizedBox(height: 2),
                _RailIconButton(
                  tooltip: '关闭行为：${controller.closeBehavior.label}',
                  height: 32,
                  icon: Icons.tune_rounded,
                  iconSize: 16,
                  iconColor: NexusColors.textSecondary,
                  onTap: () => DesktopCloseSettingsDialog.show(
                    context,
                    controller: controller,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

IconData _syncModeIcon(SyncMode mode) {
  return switch (mode) {
    SyncMode.merge => Icons.sync_rounded,
    SyncMode.pullOverwrite => Icons.cloud_download_outlined,
    SyncMode.pushOverwrite => Icons.cloud_upload_outlined,
  };
}

class _LocalTerminalSplitButton extends StatelessWidget {
  const _LocalTerminalSplitButton({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final multiShell = controller.localShells.length > 1;
    final preferred = controller.preferredLocalShell;

    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: NexusColors.bgSurface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: NexusColors.borderSubtle, width: 0.8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: preferred != null ? '本地终端 · ${preferred.name}' : '本地终端',
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => controller.openLocalSession(),
                child: SizedBox(
                  width: multiShell ? 35 : 38,
                  height: 36,
                  child: const Icon(
                    Icons.terminal_rounded,
                    size: 16.5,
                    color: NexusColors.cyan,
                  ),
                ),
              ),
            ),
          ),
          if (multiShell) ...[
            Container(
              width: 0.8,
              height: 16,
              color: NexusColors.borderActive.withValues(alpha: 0.7),
            ),
            PopupMenuButton<LocalShellOption>(
              tooltip: '选择本地 Shell',
              padding: EdgeInsets.zero,
              onSelected: (shell) => controller.openLocalSession(shell: shell),
              itemBuilder: (_) => [
                for (final sh in controller.localShells)
                  () {
                    final isCurrent =
                        preferred != null &&
                        (preferred.id.isNotEmpty
                            ? sh.id == preferred.id
                            : sh.program == preferred.program);
                    return PopupMenuItem(
                      value: sh,
                      child: Row(
                        children: [
                          Icon(
                            Icons.terminal_rounded,
                            size: 15,
                            color: isCurrent
                                ? NexusColors.emerald
                                : NexusColors.textSecondary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              sh.name,
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                          if (isCurrent)
                            const Text(
                              '当前',
                              style: TextStyle(
                                fontSize: 11,
                                color: NexusColors.emerald,
                              ),
                            ),
                        ],
                      ),
                    );
                  }(),
              ],
              child: const SizedBox(
                width: 22,
                height: 36,
                child: Icon(
                  Icons.expand_more_rounded,
                  size: 15,
                  color: NexusColors.textMuted,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SidebarSectionHeader extends StatefulWidget {
  const _SidebarSectionHeader({
    required this.title,
    required this.count,
    required this.collapsed,
    required this.onToggle,
    this.accentCount = false,
  });

  final String title;
  final int count;
  final bool collapsed;
  final VoidCallback onToggle;
  final bool accentCount;

  @override
  State<_SidebarSectionHeader> createState() => _SidebarSectionHeaderState();
}

class _SidebarSectionHeaderState extends State<_SidebarSectionHeader> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final textColor = _hovered
        ? NexusColors.textSecondary
        : NexusColors.textMuted;

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Material(
          color: _hovered
              ? NexusColors.bgSurface.withValues(alpha: 0.45)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
          child: InkWell(
            borderRadius: BorderRadius.circular(7),
            onTap: widget.onToggle,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  Icon(
                    widget.collapsed
                        ? Icons.chevron_right_rounded
                        : Icons.expand_more_rounded,
                    size: 14,
                    color: textColor,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      widget.title,
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.65,
                        color: textColor,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5.5,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: widget.accentCount
                          ? NexusColors.emerald.withValues(alpha: 0.14)
                          : NexusColors.bgSurface.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: Text(
                      '${widget.count}',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: widget.accentCount
                            ? NexusColors.emerald
                            : NexusColors.textMuted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SidebarFooterDock extends StatelessWidget {
  const _SidebarFooterDock({
    required this.controller,
    required this.onQuickWebDavSync,
  });

  final AppController controller;
  final VoidCallback onQuickWebDavSync;

  @override
  Widget build(BuildContext context) {
    final davConfigured = controller.webDavConfig.isConfigured;
    final appLockEnabled = controller.appLockConfig.enabled;

    final buttons = <Widget>[
      _DockIconButton(
        tooltip: controller.syncingWebDav
            ? '正在同步 WebDAV...'
            : (davConfigured ? 'WebDAV 已连接（点击配置）' : 'WebDAV 云同步'),
        activeAccent: davConfigured,
        onTap: () => WebDavSyncDialog.show(context, controller: controller),
        child: controller.syncingWebDav
            ? const SizedBox(
                width: 15,
                height: 15,
                child: CircularProgressIndicator(strokeWidth: 1.8),
              )
            : Icon(
                davConfigured ? Icons.cloud_done_rounded : Icons.cloud_outlined,
                size: 17,
                color: davConfigured
                    ? NexusColors.emerald
                    : NexusColors.textSecondary,
              ),
      ),
      if (davConfigured && !controller.syncingWebDav)
        _DockIconButton(
          tooltip: '立即执行（${controller.webDavConfig.defaultSyncMode.label}）',
          activeAccent: true,
          onTap: onQuickWebDavSync,
          child: Icon(
            _syncModeIcon(controller.webDavConfig.defaultSyncMode),
            size: 16.5,
            color: NexusColors.emerald,
          ),
        ),
      _DockIconButton(
        tooltip: appLockEnabled ? '安全中心（应用锁已开启）' : '安全中心（未加锁）',
        activeAccent: appLockEnabled,
        onTap: () =>
            AppLockSettingsDialog.show(context, controller: controller),
        child: Icon(
          appLockEnabled ? Icons.verified_user_rounded : Icons.shield_outlined,
          size: 17,
          color: appLockEnabled
              ? NexusColors.emerald
              : NexusColors.textSecondary,
        ),
      ),
      if (appLockEnabled)
        _DockIconButton(
          tooltip: '立即锁屏',
          activeAccent: true,
          onTap: controller.lockNow,
          child: const Icon(
            Icons.lock_outline_rounded,
            size: 16.5,
            color: NexusColors.emerald,
          ),
        ),
      if (controller.isDesktopTraySupported)
        _DockIconButton(
          tooltip: '关闭行为：${controller.closeBehavior.label}',
          onTap: () =>
              DesktopCloseSettingsDialog.show(context, controller: controller),
          child: const Icon(
            Icons.tune_rounded,
            size: 16.5,
            color: NexusColors.textSecondary,
          ),
        ),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      child: Row(
        children: [
          for (var i = 0; i < buttons.length; i++) ...[
            if (i > 0) const SizedBox(width: 5),
            Expanded(child: buttons[i]),
          ],
        ],
      ),
    );
  }
}

class _DockIconButton extends StatelessWidget {
  const _DockIconButton({
    required this.tooltip,
    required this.onTap,
    required this.child,
    this.activeAccent = false,
  });

  final String tooltip;
  final VoidCallback onTap;
  final Widget child;
  final bool activeAccent;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: activeAccent
            ? NexusColors.emerald.withValues(alpha: 0.09)
            : NexusColors.bgSurface.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          borderRadius: BorderRadius.circular(9),
          onTap: onTap,
          child: SizedBox(height: 34, child: Center(child: child)),
        ),
      ),
    );
  }
}

class _RailIconButton extends StatelessWidget {
  const _RailIconButton({
    super.key,
    required this.tooltip,
    required this.onTap,
    this.icon,
    this.customChild,
    this.iconSize = 17.5,
    this.iconColor,
    this.selected = false,
    this.height = 36,
  });

  final String tooltip;
  final VoidCallback onTap;
  final IconData? icon;
  final Widget? customChild;
  final double iconSize;
  final Color? iconColor;
  final bool selected;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: selected ? NexusColors.bgSurface : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: SizedBox(
            width: 38,
            height: height,
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (selected)
                  Positioned(
                    left: 2,
                    child: Container(
                      width: 2.5,
                      height: 14,
                      decoration: BoxDecoration(
                        color: NexusColors.emerald,
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                  ),
                customChild ??
                    Icon(
                      icon,
                      size: iconSize,
                      color:
                          iconColor ??
                          (selected
                              ? NexusColors.emerald
                              : NexusColors.textSecondary),
                    ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SidebarItem extends StatefulWidget {
  const _SidebarItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.iconSize = 16.5,
    this.iconColor,
    this.badgeText,
    this.trailing,
    this.showTrailingOnHover = false,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final double iconSize;
  final Color? iconColor;
  final String? badgeText;
  final Widget? trailing;
  final bool showTrailingOnHover;

  @override
  State<_SidebarItem> createState() => _SidebarItemState();
}

class _SidebarItemState extends State<_SidebarItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final showTrailing =
        widget.trailing != null && (!widget.showTrailingOnHover || _hovered);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1.5),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Material(
          color: widget.selected
              ? NexusColors.bgSurface
              : (_hovered
                    ? NexusColors.bgSurface.withValues(alpha: 0.42)
                    : Colors.transparent),
          borderRadius: BorderRadius.circular(9),
          child: InkWell(
            borderRadius: BorderRadius.circular(9),
            onTap: widget.onTap,
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                if (widget.selected)
                  Positioned(
                    left: 2.5,
                    child: Container(
                      width: 2.5,
                      height: 14,
                      decoration: BoxDecoration(
                        color: NexusColors.emerald,
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 7.5,
                  ),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 18,
                        child: Center(
                          child: Icon(
                            widget.icon,
                            size: widget.iconSize,
                            color:
                                widget.iconColor ??
                                (widget.selected
                                    ? NexusColors.emerald
                                    : NexusColors.textSecondary),
                          ),
                        ),
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          widget.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: widget.selected
                                ? FontWeight.w600
                                : FontWeight.w400,
                            color: widget.selected
                                ? NexusColors.textPrimary
                                : NexusColors.textSecondary,
                          ),
                        ),
                      ),
                      if (widget.badgeText != null)
                        Text(
                          widget.badgeText!,
                          style: const TextStyle(
                            fontSize: 11.2,
                            color: NexusColors.textMuted,
                          ),
                        ),
                      if (showTrailing) widget.trailing!,
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
}

class _DesktopSessionTabBar extends StatelessWidget {
  const _DesktopSessionTabBar({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final inVault = controller.activeSessionId == null;

    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: const BoxDecoration(
        color: NexusColors.bgSidebar,
        border: Border(
          bottom: BorderSide(color: NexusColors.borderSubtle, width: 0.8),
        ),
      ),
      child: Row(
        children: [
          _TabPill(
            icon: Icons.dns_rounded,
            label: 'Hosts',
            active: inVault,
            onTap: controller.showHostsVault,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: controller.sessions.length,
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemBuilder: (context, index) {
                final session = controller.sessions[index];
                return Center(
                  child: _TabPill(
                    icon: session.isLocal ? Icons.terminal_rounded : null,
                    statusColor: session.isLocal
                        ? null
                        : WorkspaceScreen._phaseDotColor(session.phase),
                    label: session.tabTitle,
                    active: controller.activeSessionId == session.id,
                    onTap: () => controller.selectSession(session.id),
                    onClose: () => controller.closeSessionTab(session.id),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _TabPill extends StatelessWidget {
  const _TabPill({
    this.icon,
    this.statusColor,
    required this.label,
    required this.active,
    required this.onTap,
    this.onClose,
  });

  final IconData? icon;
  final Color? statusColor;
  final String label;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: active ? NexusColors.bgSurface : Colors.transparent,
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: onTap,
        child: Container(
          height: 30,
          constraints: const BoxConstraints(maxWidth: 190),
          padding: const EdgeInsets.symmetric(horizontal: 11),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: 14,
                  color: active
                      ? NexusColors.emerald
                      : NexusColors.textSecondary,
                ),
                const SizedBox(width: 6),
              ] else if (statusColor != null) ...[
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: statusColor,
                  ),
                ),
                const SizedBox(width: 7),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.2,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                    color: active
                        ? NexusColors.textPrimary
                        : NexusColors.textSecondary,
                  ),
                ),
              ),
              if (onClose != null) ...[
                const SizedBox(width: 6),
                InkWell(
                  borderRadius: BorderRadius.circular(4),
                  onTap: onClose,
                  child: const Padding(
                    padding: EdgeInsets.all(2),
                    child: Icon(
                      Icons.close_rounded,
                      size: 13,
                      color: NexusColors.textMuted,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
