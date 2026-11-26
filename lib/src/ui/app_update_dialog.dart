import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:nexus_ssh/src/state/app_controller.dart';
import 'package:nexus_ssh/src/ui/app_theme.dart';
import 'package:nexus_ssh/src/update/app_update_models.dart';

/// Standalone dialog wrapper around [AppUpdatePanel].
class AppUpdateDialog extends StatelessWidget {
  const AppUpdateDialog({super.key, required this.controller});

  final AppController controller;

  static Future<void> show(
    BuildContext context, {
    required AppController controller,
  }) {
    if (controller.updateState.phase == UpdatePhase.idle) {
      controller.checkForUpdates();
    }
    return showDialog<void>(
      context: context,
      builder: (_) => AppUpdateDialog(controller: controller),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final state = controller.updateState;
        return AlertDialog(
          backgroundColor: NexusColors.bgCanvas,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: const BorderSide(color: NexusColors.borderActive),
          ),
          titlePadding: const EdgeInsets.fromLTRB(22, 20, 14, 0),
          contentPadding: const EdgeInsets.fromLTRB(22, 14, 22, 18),
          title: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: state.hasAvailableUpdate
                      ? NexusColors.emerald.withValues(alpha: 0.16)
                      : NexusColors.bgSurface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: state.hasAvailableUpdate
                        ? NexusColors.emerald.withValues(alpha: 0.45)
                        : NexusColors.borderSubtle,
                  ),
                ),
                child: Icon(
                  state.hasAvailableUpdate
                      ? Icons.system_update_alt_rounded
                      : Icons.verified_outlined,
                  size: 19,
                  color: state.hasAvailableUpdate
                      ? NexusColors.emerald
                      : NexusColors.textSecondary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '软件更新',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: NexusColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '当前版本 ${state.currentVersion.displayLabel} (Build ${state.currentVersion.buildNumber})',
                      style: TextStyle(
                        fontFamily: NexusTheme.monospaceFontFamily,
                        fontSize: 11.5,
                        color: NexusColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '关闭',
                visualDensity: VisualDensity.compact,
                onPressed: state.phase == UpdatePhase.installing
                    ? null
                    : () => Navigator.of(context).pop(),
                icon: const Icon(
                  Icons.close_rounded,
                  size: 18,
                  color: NexusColors.textMuted,
                ),
              ),
            ],
          ),
          content: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 340, maxWidth: 460),
            child: SingleChildScrollView(
              child: AppUpdatePanel(
                controller: controller,
                onIgnored: () => Navigator.of(context).pop(),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Reusable update status, release notes, mirror config, and action bar panel.
/// Embedded inside Settings ("关于与更新") and [AppUpdateDialog].
class AppUpdatePanel extends StatefulWidget {
  const AppUpdatePanel({
    super.key,
    required this.controller,
    this.onIgnored,
  });

  final AppController controller;
  final VoidCallback? onIgnored;

  @override
  State<AppUpdatePanel> createState() => _AppUpdatePanelState();
}

class _AppUpdatePanelState extends State<AppUpdatePanel> {
  late final TextEditingController _mirrorCtrl;
  bool _showMirrorEditor = false;

  @override
  void initState() {
    super.initState();
    _mirrorCtrl = TextEditingController(
      text: widget.controller.updateState.mirrorPrefix,
    );
    _showMirrorEditor = _mirrorCtrl.text.isNotEmpty;
  }

  @override
  void dispose() {
    _mirrorCtrl.dispose();
    super.dispose();
  }

  Future<void> _handleInstall() async {
    final msg = await widget.controller.installDownloadedUpdate();
    if (!mounted || msg == null || msg.isEmpty) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _handleOpenReleasePage() async {
    final opened = await widget.controller.openUpdateReleasePage();
    if (!mounted) return;
    if (!opened) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已复制 GitHub Release 链接到剪贴板')),
      );
    }
  }

  void _saveMirrorAndRecheck() {
    widget.controller.setUpdateMirrorPrefix(_mirrorCtrl.text);
    widget.controller.checkForUpdates();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final state = widget.controller.updateState;
        final manifest = state.manifest;
        final asset = state.matchedAsset;
        final canInAppInstall =
            widget.controller.supportsInAppUpdateInstall && asset != null;

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildStatusBanner(state),
            if (state.hasAvailableUpdate && manifest != null) ...[
              const SizedBox(height: 12),
              _buildReleaseInfoCard(manifest, asset),
            ],
            if (state.phase == UpdatePhase.downloading ||
                state.phase == UpdatePhase.verifying) ...[
              const SizedBox(height: 12),
              _buildDownloadProgress(state),
            ],
            if (state.errorMessage != null &&
                state.errorMessage!.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: NexusColors.rose.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: NexusColors.rose.withValues(alpha: 0.35),
                  ),
                ),
                child: Text(
                  state.errorMessage!,
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: NexusColors.rose,
                    height: 1.45,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            _buildMirrorSection(state),
            const SizedBox(height: 16),
            _buildActionRow(state, canInAppInstall),
          ],
        );
      },
    );
  }

  Widget _buildStatusBanner(UpdateState state) {
    final (Color accent, IconData icon, String text) = switch (state.phase) {
      UpdatePhase.checking => (
        NexusColors.cyan,
        Icons.sync_rounded,
        '正在从 GitHub Release 检查最新版本...',
      ),
      UpdatePhase.upToDate => (
        NexusColors.emerald,
        Icons.check_circle_outline_rounded,
        state.statusMessage ??
            '当前已是最新版本 (${state.currentVersion.displayLabel})',
      ),
      UpdatePhase.available => (
        NexusColors.emerald,
        Icons.new_releases_outlined,
        '发现新版本 v${state.manifest?.version ?? ''}，建议升级体验最新特性与修复。',
      ),
      UpdatePhase.downloading => (
        NexusColors.cyan,
        Icons.downloading_rounded,
        state.statusMessage ?? '正在下载更新包...',
      ),
      UpdatePhase.verifying => (
        NexusColors.amber,
        Icons.verified_user_outlined,
        '正在校验安装包 SHA-256 哈希...',
      ),
      UpdatePhase.readyToInstall => (
        NexusColors.emerald,
        Icons.task_alt_rounded,
        state.statusMessage ?? '更新包已通过 SHA-256 完整性校验，随时可以安装。',
      ),
      UpdatePhase.installing => (
        NexusColors.emerald,
        Icons.rocket_launch_outlined,
        state.statusMessage ?? '正在启动更新安装...',
      ),
      UpdatePhase.error => (
        NexusColors.rose,
        Icons.error_outline_rounded,
        '检查或下载更新时遇到问题',
      ),
      UpdatePhase.idle => (
        NexusColors.textSecondary,
        Icons.cloud_outlined,
        '更新源：GitHub Releases (${AppUpdateConfig.githubRepo})',
      ),
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: accent.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          if (state.phase == UpdatePhase.checking)
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: accent),
            )
          else
            Icon(icon, size: 17, color: accent),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: accent == NexusColors.textSecondary
                    ? NexusColors.textSecondary
                    : NexusColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReleaseInfoCard(UpdateManifest manifest, UpdateAsset? asset) {
    final notesText = manifest.notes.isNotEmpty
        ? manifest.notes
        : '暂无详细更新日志，可前往 GitHub Release 页面查看完整改动。';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: NexusColors.bgSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: NexusColors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: NexusColors.emerald.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text(
                  manifest.tag,
                  style: TextStyle(
                    fontFamily: NexusTheme.monospaceFontFamily,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: NexusColors.emerald,
                  ),
                ),
              ),
              if (asset != null) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${asset.fileName} · ${asset.formattedSize}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: NexusTheme.monospaceFontFamily,
                      fontSize: 11,
                      color: NexusColors.textMuted,
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (asset != null && asset.sha256.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              'SHA-256: ${asset.sha256.length > 24 ? '${asset.sha256.substring(0, 24)}...' : asset.sha256}',
              style: TextStyle(
                fontFamily: NexusTheme.monospaceFontFamily,
                fontSize: 10.5,
                color: NexusColors.textMuted,
              ),
            ),
          ],
          const SizedBox(height: 10),
          const Text(
            '更新内容',
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: NexusColors.textSecondary,
            ),
          ),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 160),
            child: SingleChildScrollView(
              child: SelectableText(
                notesText,
                style: const TextStyle(
                  fontSize: 12.5,
                  height: 1.5,
                  color: NexusColors.textPrimary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDownloadProgress(UpdateState state) {
    final progress = state.downloadProgress;
    final percentText = progress != null
        ? '${(progress * 100).toStringAsFixed(0)}%'
        : '计算中...';
    final downloadedMb = (state.downloadedBytes / (1024 * 1024))
        .toStringAsFixed(1);
    final totalMb = state.totalBytes > 0
        ? (state.totalBytes / (1024 * 1024)).toStringAsFixed(1)
        : '?';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              state.phase == UpdatePhase.verifying
                  ? '正在校验 SHA-256...'
                  : '已下载 $downloadedMb MB / $totalMb MB',
              style: const TextStyle(
                fontSize: 12,
                color: NexusColors.textSecondary,
              ),
            ),
            const Spacer(),
            Text(
              state.phase == UpdatePhase.verifying ? '校验中' : percentText,
              style: TextStyle(
                fontFamily: NexusTheme.monospaceFontFamily,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: NexusColors.emerald,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(99),
          child: LinearProgressIndicator(
            value: state.phase == UpdatePhase.verifying ? null : progress,
            minHeight: 6,
            backgroundColor: NexusColors.bgSurface,
            color: NexusColors.emerald,
          ),
        ),
      ],
    );
  }

  Widget _buildMirrorSection(UpdateState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => _showMirrorEditor = !_showMirrorEditor),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(
                  _showMirrorEditor
                      ? Icons.expand_more_rounded
                      : Icons.chevron_right_rounded,
                  size: 16,
                  color: NexusColors.textMuted,
                ),
                const SizedBox(width: 4),
                Text(
                  state.mirrorPrefix.isNotEmpty
                      ? 'GitHub 加速镜像（已启用）'
                      : 'GitHub 加速镜像（可选，直连缓慢时配置）',
                  style: const TextStyle(
                    fontSize: 12,
                    color: NexusColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_showMirrorEditor) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _mirrorCtrl,
                  enabled: !state.isBusy,
                  style: const TextStyle(fontSize: 12.5),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '留空直连 GitHub，例如 https://gh-proxy.com/',
                    hintStyle: const TextStyle(
                      fontSize: 11.5,
                      color: NexusColors.textMuted,
                    ),
                    filled: true,
                    fillColor: NexusColors.bgSurface,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 10,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(9),
                      borderSide: const BorderSide(
                        color: NexusColors.borderSubtle,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: state.isBusy ? null : _saveMirrorAndRecheck,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  side: const BorderSide(color: NexusColors.borderActive),
                ),
                child: const Text('保存并重试', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildActionRow(UpdateState state, bool canInAppInstall) {
    final actions = <Widget>[];

    if (state.hasAvailableUpdate &&
        state.phase != UpdatePhase.downloading &&
        state.phase != UpdatePhase.verifying &&
        state.phase != UpdatePhase.installing) {
      actions.add(
        TextButton(
          onPressed: () {
            widget.controller.ignoreAvailableUpdate();
            widget.onIgnored?.call();
          },
          child: const Text(
            '忽略此版本',
            style: TextStyle(color: NexusColors.textMuted),
          ),
        ),
      );
      actions.add(
        TextButton(
          onPressed: _handleOpenReleasePage,
          child: const Text('浏览器打开'),
        ),
      );
    }

    if (state.phase == UpdatePhase.readyToInstall) {
      final installLabel = !kIsWeb && Platform.isWindows
          ? '立即重启并更新'
          : (!kIsWeb && Platform.isAndroid ? '立即安装 APK' : '打开下载页');
      actions.add(
        FilledButton.icon(
          onPressed: _handleInstall,
          icon: const Icon(Icons.install_desktop_rounded, size: 17),
          label: Text(installLabel),
        ),
      );
    } else if (state.hasAvailableUpdate &&
        state.phase != UpdatePhase.downloading &&
        state.phase != UpdatePhase.verifying &&
        state.phase != UpdatePhase.installing) {
      if (canInAppInstall) {
        actions.add(
          FilledButton.icon(
            onPressed: widget.controller.downloadAvailableUpdate,
            icon: const Icon(Icons.download_rounded, size: 17),
            label: const Text('下载更新'),
          ),
        );
      } else {
        actions.add(
          FilledButton.icon(
            onPressed: _handleOpenReleasePage,
            icon: const Icon(Icons.open_in_new_rounded, size: 16),
            label: const Text('前往下载'),
          ),
        );
      }
    } else if (!state.isBusy) {
      actions.add(
        FilledButton.icon(
          onPressed: () => widget.controller.checkForUpdates(),
          icon: const Icon(Icons.refresh_rounded, size: 17),
          label: const Text('检查更新'),
        ),
      );
    }

    return Wrap(
      alignment: WrapAlignment.end,
      spacing: 8,
      runSpacing: 8,
      children: actions,
    );
  }
}
