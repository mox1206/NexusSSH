import 'package:flutter/material.dart';
import 'package:nexus_ssh/src/state/app_controller.dart';
import 'package:nexus_ssh/src/ui/app_theme.dart';
import 'package:nexus_ssh/src/ui/server_monitor_panel.dart';
import 'package:nexus_ssh/src/ui/sftp_panel.dart';
import 'package:nexus_ssh/src/ui/snippets_panel.dart';

class SessionSideDrawer extends StatefulWidget {
  const SessionSideDrawer({
    super.key,
    required this.controller,
    required this.session,
    required this.initialTab,
    required this.onClose,
    this.onRefocusTerminal,
    this.isMobileSheet = false,
  });

  final AppController controller;
  final TerminalSessionItem session;
  final SessionDrawerTab initialTab;
  final VoidCallback onClose;
  final VoidCallback? onRefocusTerminal;
  final bool isMobileSheet;

  static Future<void> showMobileSheet(
    BuildContext context, {
    required AppController controller,
    required TerminalSessionItem session,
    required SessionDrawerTab initialTab,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => FractionallySizedBox(
        heightFactor: 0.82,
        child: SessionSideDrawer(
          controller: controller,
          session: session,
          initialTab: initialTab,
          isMobileSheet: true,
          onClose: () => Navigator.of(ctx).pop(),
        ),
      ),
    );
  }

  @override
  State<SessionSideDrawer> createState() => _SessionSideDrawerState();
}

class _SessionSideDrawerState extends State<SessionSideDrawer> {
  late SessionDrawerTab _tab;

  @override
  void initState() {
    super.initState();
    _tab = widget.session.isLocal
        ? SessionDrawerTab.snippets
        : widget.initialTab;
  }

  @override
  void didUpdateWidget(covariant SessionSideDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialTab != widget.initialTab ||
        oldWidget.session.isLocal != widget.session.isLocal) {
      _tab = widget.session.isLocal
          ? SessionDrawerTab.snippets
          : widget.initialTab;
    }
  }

  void _switchTab(SessionDrawerTab next) {
    setState(() => _tab = next);
    if (!widget.isMobileSheet) {
      widget.session.desktopDrawerTab = next;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: widget.isMobileSheet ? double.infinity : 370,
      decoration: BoxDecoration(
        color: NexusColors.bgSidebar,
        borderRadius: widget.isMobileSheet
            ? const BorderRadius.vertical(top: Radius.circular(22))
            : null,
        border: widget.isMobileSheet
            ? null
            : const Border(
                left: BorderSide(color: NexusColors.borderSubtle, width: 0.8),
              ),
      ),
      child: Column(
        children: [
          if (widget.isMobileSheet)
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(top: 10, bottom: 4),
                decoration: BoxDecoration(
                  color: NexusColors.borderActive,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
            ),

          // Clean Segmented Header: [SFTP 文件 | 状态监控 | 命令片段] + [×]
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: NexusColors.bgSurface,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        if (!widget.session.isLocal) ...[
                          _tabButton(
                            SessionDrawerTab.sftp,
                            Icons.folder_open_rounded,
                            'SFTP',
                          ),
                          _tabButton(
                            SessionDrawerTab.monitor,
                            Icons.speed_rounded,
                            '监控',
                          ),
                        ],
                        _tabButton(
                          SessionDrawerTab.snippets,
                          Icons.code_rounded,
                          widget.session.isLocal ? '命令片段' : '片段',
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  tooltip: '收起面板',
                  visualDensity: VisualDensity.compact,
                  onPressed: widget.onClose,
                  icon: const Icon(
                    Icons.close_rounded,
                    size: 18,
                    color: NexusColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: NexusColors.borderSubtle),

          Expanded(
            child: switch (_tab) {
              SessionDrawerTab.sftp => SftpPanel(
                controller: widget.controller,
                session: widget.session,
              ),
              SessionDrawerTab.monitor => ServerMonitorPanel(
                controller: widget.controller,
                sessionId: widget.session.id,
              ),
              SessionDrawerTab.snippets => SnippetsPanel(
                controller: widget.controller,
                activeSessionId: widget.session.id,
                onAfterExecute: widget.isMobileSheet
                    ? widget.onClose
                    : widget.onRefocusTerminal,
              ),
            },
          ),
        ],
      ),
    );
  }

  Widget _tabButton(SessionDrawerTab tab, IconData icon, String label) {
    final active = _tab == tab;
    return Expanded(
      child: GestureDetector(
        onTap: () => _switchTab(tab),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: active ? NexusColors.bgElevated : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 14,
                color: active ? NexusColors.emerald : NexusColors.textSecondary,
              ),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                  color: active
                      ? NexusColors.textPrimary
                      : NexusColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
