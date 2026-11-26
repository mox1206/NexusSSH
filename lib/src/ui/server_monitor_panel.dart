import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nexus_ssh/src/models/ssh_models.dart';
import 'package:nexus_ssh/src/state/app_controller.dart';
import 'package:nexus_ssh/src/ui/app_theme.dart';

class ServerMonitorPanel extends StatefulWidget {
  const ServerMonitorPanel({
    super.key,
    required this.controller,
    required this.sessionId,
  });

  final AppController controller;
  final String sessionId;

  @override
  State<ServerMonitorPanel> createState() => _ServerMonitorPanelState();
}

class _ServerMonitorPanelState extends State<ServerMonitorPanel> {
  ServerMetrics? _metrics;
  String? _error;
  bool _loading = true;
  bool _fetching = false;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _fetchNow();
    _pollTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _fetchNow(),
    );
  }

  @override
  void didUpdateWidget(covariant ServerMonitorPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId) {
      setState(() {
        _metrics = null;
        _loading = true;
        _error = null;
      });
      _fetchNow();
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _fetchNow() async {
    if (_fetching || !mounted) return;
    _fetching = true;
    try {
      final data = await widget.controller.fetchServerMetrics(widget.sessionId);
      if (!mounted) return;
      setState(() {
        _metrics = data;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    } finally {
      _fetching = false;
    }
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    final gb = mb / 1024;
    if (gb < 1024) return '${gb.toStringAsFixed(2)} GB';
    return '${(gb / 1024).toStringAsFixed(2)} TB';
  }

  static String _formatRate(int bytesPerSec) {
    return '${_formatBytes(bytesPerSec)}/s';
  }

  static String _formatUptime(int secs) {
    final days = secs ~/ 86400;
    final hours = (secs % 86400) ~/ 3600;
    final mins = (secs % 3600) ~/ 60;
    if (days > 0) return '$days天 $hours小时';
    if (hours > 0) return '$hours小时 $mins分钟';
    return '$mins分钟';
  }

  Color _usageColor(double ratio) {
    if (ratio >= 0.88) return NexusColors.rose;
    if (ratio >= 0.72) return NexusColors.amber;
    return NexusColors.emerald;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _metrics == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null && _metrics == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline_rounded,
                color: NexusColors.rose,
                size: 28,
              ),
              const SizedBox(height: 10),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 12.5,
                  color: NexusColors.textSecondary,
                ),
              ),
              const SizedBox(height: 14),
              FilledButton.tonalIcon(
                onPressed: _fetchNow,
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    final m = _metrics!;
    final cpuRatio = (m.cpuPercent / 100.0).clamp(0.0, 1.0);

    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 20),
      children: [
        // Host & Uptime Summary Card
        _MetricCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.dns_rounded,
                    size: 16,
                    color: NexusColors.emerald,
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      m.hostname,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: NexusColors.textPrimary,
                      ),
                    ),
                  ),
                  Text(
                    '运行 ${_formatUptime(m.uptimeSecs)}',
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: NexusColors.textSecondary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '${m.osName} · ${m.kernel}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: NexusTheme.monospaceFontFamily,
                  fontSize: 11.2,
                  color: NexusColors.textMuted,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),

        // CPU & Load Average Card
        _MetricCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text(
                    'CPU 占用',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: NexusColors.textSecondary,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '(${m.cpuCores} 核)',
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: NexusColors.textMuted,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${m.cpuPercent.toStringAsFixed(1)}%',
                    style: TextStyle(
                      fontFamily: NexusTheme.monospaceFontFamily,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: _usageColor(cpuRatio),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _SmoothBar(value: cpuRatio, color: _usageColor(cpuRatio)),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(child: _LoadChip('1m', m.load1)),
                  const SizedBox(width: 6),
                  Expanded(child: _LoadChip('5m', m.load5)),
                  const SizedBox(width: 6),
                  Expanded(child: _LoadChip('15m', m.load15)),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),

        // Memory & Swap Card
        _MetricCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text(
                    '物理内存',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: NexusColors.textSecondary,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${_formatBytes(m.memUsedBytes)} / ${_formatBytes(m.memTotalBytes)}',
                    style: TextStyle(
                      fontFamily: NexusTheme.monospaceFontFamily,
                      fontSize: 11.8,
                      color: NexusColors.textPrimary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 7),
              _SmoothBar(value: m.memRatio, color: _usageColor(m.memRatio)),
              if (m.swapTotalBytes > 0) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Text(
                      'Swap 交换区',
                      style: TextStyle(
                        fontSize: 12,
                        color: NexusColors.textMuted,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${_formatBytes(m.swapUsedBytes)} / ${_formatBytes(m.swapTotalBytes)}',
                      style: TextStyle(
                        fontFamily: NexusTheme.monospaceFontFamily,
                        fontSize: 11.2,
                        color: NexusColors.textSecondary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                _SmoothBar(value: m.swapRatio, color: NexusColors.cyan),
              ],
            ],
          ),
        ),

        // Disks Card
        if (m.disks.isNotEmpty) ...[
          const SizedBox(height: 10),
          _MetricCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '磁盘存储',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: NexusColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 10),
                for (var i = 0; i < m.disks.length; i++) ...[
                  if (i > 0) const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          m.disks[i].mountPoint,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: NexusTheme.monospaceFontFamily,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: NexusColors.textPrimary,
                          ),
                        ),
                      ),
                      Text(
                        '${_formatBytes(m.disks[i].usedBytes)} / ${_formatBytes(m.disks[i].totalBytes)}',
                        style: TextStyle(
                          fontFamily: NexusTheme.monospaceFontFamily,
                          fontSize: 11.2,
                          color: NexusColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  _SmoothBar(
                    value: m.disks[i].ratio,
                    color: _usageColor(m.disks[i].ratio),
                  ),
                ],
              ],
            ),
          ),
        ],

        // Network Interfaces Card
        if (m.networks.isNotEmpty) ...[
          const SizedBox(height: 10),
          _MetricCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '实时网络吞吐',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: NexusColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 8),
                for (final nic in m.networks.take(4))
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(
                      children: [
                        Flexible(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: NexusColors.bgElevated,
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: Text(
                              nic.interfaceName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: NexusTheme.monospaceFontFamily,
                                fontSize: 11,
                                color: NexusColors.textPrimary,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    '↓ ${_formatRate(nic.rxBytesPerSec)}',
                                    style: TextStyle(
                                      fontFamily:
                                          NexusTheme.monospaceFontFamily,
                                      fontSize: 11.3,
                                      color: NexusColors.emerald,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    '↑ ${_formatRate(nic.txBytesPerSec)}',
                                    style: TextStyle(
                                      fontFamily:
                                          NexusTheme.monospaceFontFamily,
                                      fontSize: 11.3,
                                      color: NexusColors.cyan,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: NexusColors.bgSurface,
        borderRadius: BorderRadius.circular(13),
      ),
      child: child,
    );
  }
}

class _SmoothBar extends StatelessWidget {
  const _SmoothBar({required this.value, required this.color});
  final double value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(99),
      child: LinearProgressIndicator(
        value: value,
        minHeight: 6,
        backgroundColor: NexusColors.bgCanvas,
        valueColor: AlwaysStoppedAnimation<Color>(color),
      ),
    );
  }
}

class _LoadChip extends StatelessWidget {
  const _LoadChip(this.label, this.val);
  final String label;
  final double val;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: NexusColors.bgCanvas,
        borderRadius: BorderRadius.circular(7),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          '$label: ${val.toStringAsFixed(2)}',
          style: TextStyle(
            fontFamily: NexusTheme.monospaceFontFamily,
            fontSize: 11.2,
            color: NexusColors.textSecondary,
          ),
        ),
      ),
    );
  }
}
