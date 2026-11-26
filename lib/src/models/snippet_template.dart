class SnippetVariable {
  const SnippetVariable({
    required this.name,
    this.defaultValue = '',
  });

  final String name;
  final String defaultValue;
}

/// Parses and renders template variables in command snippets.
///
/// Supported syntax:
/// - `{{var}}`
/// - `{{var:default}}` or `{{var=default}}`
///
/// Deliberately ignores Go-template dot expressions such as `{{.Names}}`
/// (commonly used in `docker ps --format`) and standard shell `$VAR` / `${VAR}`.
class SnippetTemplate {
  SnippetTemplate._();

  static final RegExp _varPattern = RegExp(
    r'\{\{\s*([^.{}:=\s][^:=}]*?)\s*(?:[:=]([^}]*))?\}\}',
  );

  /// Extracts unique template variables in order of first appearance.
  static List<SnippetVariable> extractVariables(String command) {
    final seen = <String, int>{};
    final result = <SnippetVariable>[];

    for (final match in _varPattern.allMatches(command)) {
      final rawName = match.group(1)?.trim() ?? '';
      if (rawName.isEmpty) continue;
      final defaultVal = (match.group(2) ?? '').trim();

      final existingIdx = seen[rawName];
      if (existingIdx == null) {
        seen[rawName] = result.length;
        result.add(SnippetVariable(name: rawName, defaultValue: defaultVal));
      } else if (result[existingIdx].defaultValue.isEmpty &&
          defaultVal.isNotEmpty) {
        result[existingIdx] = SnippetVariable(
          name: rawName,
          defaultValue: defaultVal,
        );
      }
    }

    return result;
  }

  static bool hasVariables(String command) =>
      _varPattern.hasMatch(command);

  /// Substitutes all template variable placeholders using [values].
  /// Falls back to each placeholder's default value (or keeps the placeholder
  /// untouched if both are empty and [keepUnfilledPlaceholder] is true).
  static String render(
    String command,
    Map<String, String> values, {
    bool keepUnfilledPlaceholder = false,
  }) {
    return command.replaceAllMapped(_varPattern, (match) {
      final name = match.group(1)?.trim() ?? '';
      final fallback = (match.group(2) ?? '').trim();
      final hasKey = values.containsKey(name);
      final provided = values[name] ?? '';
      if (provided.isNotEmpty) {
        return provided;
      }
      if (hasKey) {
        return keepUnfilledPlaceholder ? '{{$name}}' : '';
      }
      if (fallback.isNotEmpty) {
        return fallback;
      }
      return keepUnfilledPlaceholder ? (match.group(0) ?? '') : '';
    });
  }

  static final List<(RegExp, String)> _dangerRules = [
    (
      RegExp(
        r'(^|[;&|]\s*)(sudo\s+)?rm\s+[^\n;|&]*(-[a-zA-Z]*r[a-zA-Z]*f|-[a-zA-Z]*f[a-zA-Z]*r|--recursive)',
      ),
      '包含强制递归删除（rm -rf），误操作可能导致数据不可恢复',
    ),
    (
      RegExp(r'(^|[;&|]\s*)(sudo\s+)?(mkfs(\.[a-z0-9]+)?|wipefs|fdisk|parted)\b'),
      '包含磁盘格式化或分区修改指令',
    ),
    (
      RegExp(r'(^|[;&|]\s*)(sudo\s+)?dd\s+[^\n;|&]*\bof=/dev/'),
      '包含直接写入底层块设备（dd of=/dev/...）操作',
    ),
    (
      RegExp(r'>\s*/dev/(sd[a-z]|nvme\d|vd[a-z]|xvd[a-z])'),
      '包含向磁盘设备文件重定向写入的操作',
    ),
    (
      RegExp(
        r'(^|[;&|]\s*)(sudo\s+)?(shutdown|reboot|poweroff|halt|init\s+[06]|systemctl\s+(reboot|poweroff|halt))\b',
      ),
      '将触发服务器关机或重启，当前 SSH 会话会立即中断',
    ),
    (
      RegExp(r'(^|[;&|]\s*)(sudo\s+)?chmod\s+[^\n;|&]*-R[^\n;|&]*\b777\s+/'),
      '将递归开放根目录或系统路径的 777 权限',
    ),
    (
      RegExp(r':\(\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:'),
      '检测到 Fork 炸弹模式，可能导致系统瞬间耗尽资源',
    ),
    (
      RegExp(r'\b(DROP\s+(DATABASE|TABLE)|TRUNCATE\s+TABLE)\b', caseSensitive: false),
      '包含高危数据库删库/删表/清空指令',
    ),
  ];

  /// Returns a concise human-readable warning if [command] matches a high-risk
  /// destructive pattern, or `null` for normal operational commands.
  static String? detectDangerReason(String command) {
    final trimmed = command.trim();
    if (trimmed.isEmpty) return null;
    for (final (pattern, reason) in _dangerRules) {
      if (pattern.hasMatch(trimmed)) {
        return reason;
      }
    }
    return null;
  }
}
