class SudoPromptMatch {
  const SudoPromptMatch({
    required this.label,
    required this.promptText,
  });

  final String label;
  final String promptText;
}

/// Detects interactive `sudo` / `su` / `doas` / SSH password prompts on the
/// current terminal cursor line so the user can fill the saved host password
/// with a single tap (never auto-sending without explicit user confirmation).
class SudoPromptDetector {
  SudoPromptDetector._();

  static final List<(RegExp, String)> _patterns = [
    (
      RegExp(
        r'^\[sudo\]\s+(?:password\s+for\s+.+|.+\s*的密码)\s*[:：]\s*$',
        caseSensitive: false,
      ),
      '检测到 sudo 密码提示',
    ),
    (
      RegExp(
        r'^doas\s*\([^)]+\)\s*password\s*[:：]\s*$',
        caseSensitive: false,
      ),
      '检测到 doas 密码提示',
    ),
    (
      RegExp(
        r"^(?:sudo\s+)?password(?:\s+for\s+[^\s:：]+)?\s*[:：]\s*$",
        caseSensitive: false,
      ),
      '检测到密码输入提示',
    ),
    (
      RegExp(
        r"^[^\s@]+(?:@[^\s:：]+)?'s\s+password\s*[:：]\s*$",
        caseSensitive: false,
      ),
      '检测到密码输入提示',
    ),
    (
      RegExp(r'^(?:[^\s:：]+\s*的)?密码\s*[:：]\s*$'),
      '检测到密码输入提示',
    ),
  ];

  static SudoPromptMatch? matchLine(String currentLine) {
    final trimmed = currentLine.trim();
    if (trimmed.isEmpty || trimmed.length > 120) {
      return null;
    }
    for (final (regex, label) in _patterns) {
      if (regex.hasMatch(trimmed)) {
        return SudoPromptMatch(label: label, promptText: trimmed);
      }
    }
    return null;
  }
}
