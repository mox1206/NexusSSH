import 'package:flutter/material.dart';
import 'package:nexus_ssh/src/models/ssh_models.dart';
import 'package:nexus_ssh/src/state/app_controller.dart';
import 'package:nexus_ssh/src/ui/app_theme.dart';

/// Non-imperative overlay card rendered when `controller.nextHostKeyPrompt` is non-null,
/// ensuring zero duplicate dialog routes and smooth mobile/desktop adaptation.
class HostKeyVerificationOverlay extends StatefulWidget {
  const HostKeyVerificationOverlay({
    super.key,
    required this.controller,
    required this.prompt,
  });

  final AppController controller;
  final HostKeyPromptEvent prompt;

  @override
  State<HostKeyVerificationOverlay> createState() =>
      _HostKeyVerificationOverlayState();
}

class _HostKeyVerificationOverlayState
    extends State<HostKeyVerificationOverlay> {
  bool _rememberInKnownHosts = true;

  @override
  Widget build(BuildContext context) {
    final p = widget.prompt;
    final accent = p.isMismatch ? NexusColors.rose : NexusColors.emerald;

    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.62),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Material(
              color: NexusColors.bgCanvas,
              borderRadius: BorderRadius.circular(20),
              child: Container(
                padding: const EdgeInsets.all(22),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: p.isMismatch
                        ? NexusColors.rose.withValues(alpha: 0.5)
                        : NexusColors.borderActive,
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            p.isMismatch
                                ? Icons.gpp_bad_rounded
                                : Icons.verified_user_outlined,
                            color: accent,
                            size: 22,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                p.isMismatch ? '警告：主机密钥已变更！' : '确认远程主机指纹',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  color: p.isMismatch
                                      ? NexusColors.rose
                                      : NexusColors.textPrimary,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                p.hostLabel,
                                style: TextStyle(
                                  fontFamily: NexusTheme.monospaceFontFamily,
                                  fontSize: 12.5,
                                  color: NexusColors.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      p.isMismatch
                          ? '服务器返回的公钥与本机已信任记录不一致！这可能是服务器重装了系统，也可能是中间人攻击，请核对后再继续。'
                          : '首次连接该主机，请核对服务端公钥指纹是否可信：',
                      style: const TextStyle(
                        fontSize: 13,
                        height: 1.45,
                        color: NexusColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(13),
                      decoration: BoxDecoration(
                        color: NexusColors.bgSurface,
                        borderRadius: BorderRadius.circular(13),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Text(
                                '算法',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: NexusColors.textMuted,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                p.algorithm,
                                style: TextStyle(
                                  fontFamily: NexusTheme.monospaceFontFamily,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: accent,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          SelectableText(
                            p.fingerprint,
                            style: TextStyle(
                              fontFamily: NexusTheme.monospaceFontFamily,
                              fontSize: 12,
                              color: NexusColors.textPrimary,
                            ),
                          ),
                          if (p.previousFingerprint != null) ...[
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 8),
                              child: Divider(height: 1),
                            ),
                            const Text(
                              '原已信任指纹:',
                              style: TextStyle(
                                fontSize: 11,
                                color: NexusColors.textMuted,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              p.previousFingerprint!,
                              style: TextStyle(
                                fontFamily: NexusTheme.monospaceFontFamily,
                                fontSize: 11.5,
                                color: NexusColors.textSecondary,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    GestureDetector(
                      onTap: () => setState(
                        () => _rememberInKnownHosts = !_rememberInKnownHosts,
                      ),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 22,
                            height: 22,
                            child: Checkbox(
                              value: _rememberInKnownHosts,
                              onChanged: (v) => setState(
                                () => _rememberInKnownHosts = v ?? true,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            p.isMismatch
                                ? '更新本地 known_hosts 信任记录'
                                : '加入 known_hosts，下次不再询问',
                            style: const TextStyle(
                              fontSize: 12.8,
                              color: NexusColors.textSecondary,
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
                                widget.controller.respondHostKeyPrompt(
                                  p.requestId,
                                  accept: false,
                                ),
                            style: TextButton.styleFrom(
                              backgroundColor: NexusColors.bgSurface,
                              foregroundColor: NexusColors.textPrimary,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: const Text('断开连接'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: FilledButton(
                            onPressed: () =>
                                widget.controller.respondHostKeyPrompt(
                                  p.requestId,
                                  accept: true,
                                  persist: _rememberInKnownHosts,
                                ),
                            style: FilledButton.styleFrom(
                              backgroundColor: accent,
                              foregroundColor: p.isMismatch
                                  ? Colors.white
                                  : const Color(0xFF062819),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                            child: Text(p.isMismatch ? '更新并继续' : '信任并连接'),
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
