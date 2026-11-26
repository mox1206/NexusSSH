import 'package:flutter/material.dart';
import 'package:nexus_ssh/src/desktop/desktop_tray_service.dart';
import 'package:nexus_ssh/src/models/ssh_models.dart';
import 'package:nexus_ssh/src/state/app_controller.dart';
import 'package:nexus_ssh/src/ui/app_theme.dart';

/// Non-imperative centered overlay shown when the desktop user clicks the
/// window close button and `closeBehavior == DesktopCloseBehavior.ask`.
class DesktopCloseActionOverlay extends StatefulWidget {
  const DesktopCloseActionOverlay({super.key, required this.controller});

  final AppController controller;

  @override
  State<DesktopCloseActionOverlay> createState() =>
      _DesktopCloseActionOverlayState();
}

class _DesktopCloseActionOverlayState extends State<DesktopCloseActionOverlay> {
  bool _rememberChoice = false;

  @override
  Widget build(BuildContext context) {
    final activeCount = widget.controller.sessions
        .where(
          (s) =>
              s.phase == SessionPhase.connected ||
              s.phase == SessionPhase.connecting,
        )
        .length;

    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.62),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Material(
              color: NexusColors.bgCanvas,
              borderRadius: BorderRadius.circular(20),
              child: Container(
                padding: const EdgeInsets.all(22),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: NexusColors.borderActive),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: NexusColors.emerald.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(11),
                          ),
                          child: const Icon(
                            Icons.power_settings_new_rounded,
                            color: NexusColors.emerald,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text(
                            '关闭 Nexus SSH',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: NexusColors.textPrimary,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '取消',
                          visualDensity: VisualDensity.compact,
                          onPressed: widget.controller.cancelClosePrompt,
                          icon: const Icon(
                            Icons.close_rounded,
                            size: 18,
                            color: NexusColors.textMuted,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text(
                      activeCount > 0
                          ? '当前有 $activeCount 个活动 SSH 会话运行中。最小化到系统托盘可保持连接不断开，随时从托盘恢复窗口。'
                          : '点击关闭按钮时，你希望最小化到系统托盘还是直接退出程序？',
                      style: const TextStyle(
                        fontSize: 13,
                        height: 1.5,
                        color: NexusColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 14),
                    GestureDetector(
                      onTap: () =>
                          setState(() => _rememberChoice = !_rememberChoice),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 22,
                            height: 22,
                            child: Checkbox(
                              value: _rememberChoice,
                              onChanged: (v) => setState(
                                () => _rememberChoice = v ?? false,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text(
                              '记住我的选择（可在左下角设置随时修改）',
                              style: TextStyle(
                                fontSize: 12.5,
                                color: NexusColors.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        Expanded(
                          child: TextButton(
                            onPressed: () =>
                                widget.controller.resolveClosePrompt(
                                  action: DesktopCloseBehavior.exit,
                                  remember: _rememberChoice,
                                ),
                            style: TextButton.styleFrom(
                              backgroundColor: NexusColors.rose.withValues(
                                alpha: 0.14,
                              ),
                              foregroundColor: NexusColors.rose,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(11),
                              ),
                            ),
                            child: const Text(
                              '直接退出',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: FilledButton(
                            onPressed: () =>
                                widget.controller.resolveClosePrompt(
                                  action: DesktopCloseBehavior.minimizeToTray,
                                  remember: _rememberChoice,
                                ),
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                            child: const Text('退到系统托盘'),
                          ),
                        ),
                      ],
                    ),
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

class DesktopCloseSettingsDialog {
  DesktopCloseSettingsDialog._();

  static Future<void> show(
    BuildContext context, {
    required AppController controller,
  }) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final current = controller.closeBehavior;
          return AlertDialog(
            title: const Text('关闭窗口行为'),
            content: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 320, maxWidth: 400),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _optionTile(
                    selected: current == DesktopCloseBehavior.ask,
                    icon: Icons.help_outline_rounded,
                    title: '每次询问',
                    subtitle: '点击关闭按钮时弹窗选择退出或退到托盘',
                    onTap: () {
                      controller.setCloseBehavior(DesktopCloseBehavior.ask);
                      Navigator.of(ctx).pop();
                    },
                  ),
                  const SizedBox(height: 8),
                  _optionTile(
                    selected: current == DesktopCloseBehavior.minimizeToTray,
                    icon: Icons.south_east_rounded,
                    title: '退到系统托盘',
                    subtitle: '隐藏主窗口并保持 SSH 会话后台在线',
                    onTap: () {
                      controller.setCloseBehavior(
                        DesktopCloseBehavior.minimizeToTray,
                      );
                      Navigator.of(ctx).pop();
                    },
                  ),
                  const SizedBox(height: 8),
                  _optionTile(
                    selected: current == DesktopCloseBehavior.exit,
                    icon: Icons.power_settings_new_rounded,
                    title: '直接退出',
                    subtitle: '断开所有会话并彻底关闭应用程序',
                    onTap: () {
                      controller.setCloseBehavior(DesktopCloseBehavior.exit);
                      Navigator.of(ctx).pop();
                    },
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('关闭'),
              ),
            ],
          );
        },
      ),
    );
  }

  static Widget _optionTile({
    required bool selected,
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Material(
      color: selected
          ? NexusColors.emerald.withValues(alpha: 0.14)
          : NexusColors.bgSurface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
