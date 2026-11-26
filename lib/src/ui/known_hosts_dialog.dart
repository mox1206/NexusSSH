import 'package:flutter/material.dart';
import 'package:nexus_ssh/src/models/ssh_models.dart';
import 'package:nexus_ssh/src/state/app_controller.dart';
import 'package:nexus_ssh/src/ui/app_theme.dart';

class KnownHostsDialog extends StatefulWidget {
  const KnownHostsDialog({
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
        builder: (_) => FractionallySizedBox(
          heightFactor: 0.82,
          child: KnownHostsDialog(controller: controller, isBottomSheet: true),
        ),
      );
    }
    return showDialog<void>(
      context: context,
      builder: (_) => KnownHostsDialog(controller: controller),
    );
  }

  @override
  State<KnownHostsDialog> createState() => _KnownHostsDialogState();
}

class _KnownHostsDialogState extends State<KnownHostsDialog> {
  List<KnownHostEntry> _entries = const [];
  bool _loading = true;
  String? _error;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await widget.controller.listKnownHosts();
      if (!mounted) return;
      setState(() {
        _entries = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _confirmRemove(KnownHostEntry entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移除信任指纹'),
        content: Text(
          '确定移除「${entry.hostKey}」的已信任主机公钥吗？\n\n下次连接该服务器时将重新弹出指纹确认（适用于服务器重装系统后刷新指纹）。',
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
    if (ok != true) return;
    await widget.controller.deleteKnownHost(entry.hostKey);
    await _reload();
  }

  String _formatDate(int ms) {
    if (ms <= 0) return '-';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final filtered = _entries.where((e) {
      if (q.isEmpty) return true;
      return e.hostKey.toLowerCase().contains(q) ||
          e.algorithm.toLowerCase().contains(q) ||
          e.fingerprint.toLowerCase().contains(q);
    }).toList();

    final body = Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.isBottomSheet)
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 14),
              decoration: BoxDecoration(
                color: NexusColors.borderActive,
                borderRadius: BorderRadius.circular(99),
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
              Expanded(
                child: Text(
                  '受信任主机指纹 (${_entries.length})',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: NexusColors.textPrimary,
                  ),
                ),
              ),
              IconButton(
                tooltip: '刷新',
                visualDensity: VisualDensity.compact,
                onPressed: _reload,
                icon: const Icon(
                  Icons.refresh_rounded,
                  size: 18,
                  color: NexusColors.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 38,
            child: TextField(
              onChanged: (v) => setState(() => _query = v),
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(
                hintText: '搜索主机地址、算法或 SHA256 指纹...',
                prefixIcon: Icon(Icons.search_rounded, size: 17),
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? Center(
                    child: Text(
                      _error!,
                      style: const TextStyle(color: NexusColors.rose),
                    ),
                  )
                : filtered.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.fingerprint_rounded,
                          size: 36,
                          color: NexusColors.textMuted,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _entries.isEmpty
                              ? '暂无已信任主机记录'
                              : '未找到匹配的主机指纹',
                          style: const TextStyle(
                            fontSize: 13,
                            color: NexusColors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.separated(
                    itemCount: filtered.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, idx) {
                      final e = filtered[idx];
                      return Container(
                        padding: const EdgeInsets.fromLTRB(13, 10, 8, 10),
                        decoration: BoxDecoration(
                          color: NexusColors.bgSurface,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Flexible(
                                        child: Text(
                                          e.hostKey,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontFamily:
                                                NexusTheme.monospaceFontFamily,
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                            color: NexusColors.textPrimary,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 1.5,
                                        ),
                                        decoration: BoxDecoration(
                                          color: NexusColors.emerald
                                              .withValues(alpha: 0.14),
                                          borderRadius: BorderRadius.circular(
                                            5,
                                          ),
                                        ),
                                        child: Text(
                                          e.algorithm,
                                          style: TextStyle(
                                            fontFamily:
                                                NexusTheme.monospaceFontFamily,
                                            fontSize: 10.5,
                                            color: NexusColors.emerald,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  SelectableText(
                                    e.fingerprint,
                                    style: TextStyle(
                                      fontFamily:
                                          NexusTheme.monospaceFontFamily,
                                      fontSize: 11.3,
                                      color: NexusColors.textSecondary,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '信任时间: ${_formatDate(e.trustedAtMs)}',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: NexusColors.textMuted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: '移除信任',
                              visualDensity: VisualDensity.compact,
                              onPressed: () => _confirmRemove(e),
                              icon: const Icon(
                                Icons.delete_outline_rounded,
                                size: 18,
                                color: NexusColors.rose,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );

    if (widget.isBottomSheet) return body;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 540),
        child: body,
      ),
    );
  }
}
