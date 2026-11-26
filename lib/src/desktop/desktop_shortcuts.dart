import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum ShortcutPreset {
  standard('standard', '常规习惯', '贴合 Windows / 浏览器直觉（Ctrl+T / Ctrl+W / Ctrl+1~9）'),
  terminalSafe(
    'terminal_safe',
    '终端安全模式',
    '使用 Ctrl+Shift 组合，100% 保留单 Ctrl+字母给 Bash / Vim / Tmux',
  );

  const ShortcutPreset(this.storageValue, this.label, this.description);

  final String storageValue;
  final String label;
  final String description;

  static ShortcutPreset fromStorage(String? raw) {
    return switch (raw) {
      'terminal_safe' => ShortcutPreset.terminalSafe,
      _ => ShortcutPreset.standard,
    };
  }
}

enum ShortcutAction {
  newLocalTerminal('new_local_terminal', '新建本地终端', '按上次记忆的默认 Shell 打开本地终端'),
  closeTab('close_tab', '关闭当前标签页', '仅在活动终端标签页中生效，不会误关主窗口'),
  nextTab('next_tab', '下一个标签页', '循环向后切换活动终端会话'),
  previousTab('previous_tab', '上一个标签页', '循环向前切换活动终端会话'),
  focusSearch('focus_search', '搜索主机 / 返回 Hosts', '切回主机列表并聚焦搜索与快速直连栏'),
  toggleSidebar('toggle_sidebar', '展开 / 收起侧边栏', '在完整导航与极简图标栏之间切换'),
  zoomIn('zoom_in', '放大终端字号', '增大终端文字显示尺寸'),
  zoomOut('zoom_out', '缩小终端字号', '减小终端文字显示尺寸'),
  zoomReset('zoom_reset', '重置终端字号', '恢复默认 14 pt 终端字号'),
  openSettings('open_settings', '打开设置中心', '打开常规、快捷键、云同步与更新设置');

  const ShortcutAction(this.id, this.title, this.subtitle);

  final String id;
  final String title;
  final String subtitle;

  static ShortcutAction? fromId(String id) {
    for (final a in values) {
      if (a.id == id) return a;
    }
    return null;
  }
}

@immutable
class ShortcutBinding {
  const ShortcutBinding({
    required this.keyId,
    this.ctrl = false,
    this.shift = false,
    this.alt = false,
    this.meta = false,
  });

  final int keyId;
  final bool ctrl;
  final bool shift;
  final bool alt;
  final bool meta;

  LogicalKeyboardKey get logicalKey =>
      LogicalKeyboardKey.findKeyByKeyId(keyId) ?? LogicalKeyboardKey(keyId);

  bool get hasAnyModifier => ctrl || shift || alt || meta;

  /// True for bare `Ctrl + A..Z` bindings that overlap with standard Unix shell / Vim shortcuts.
  bool get overlapsUnixTerminalControlKey {
    if (!ctrl || shift || alt || meta) return false;
    return keyId >= LogicalKeyboardKey.keyA.keyId &&
        keyId <= LogicalKeyboardKey.keyZ.keyId;
  }

  bool matches(KeyEvent event, HardwareKeyboard hw) {
    if (hw.isControlPressed != ctrl ||
        hw.isShiftPressed != shift ||
        hw.isAltPressed != alt ||
        hw.isMetaPressed != meta) {
      return false;
    }
    final pressed = event.logicalKey;
    if (pressed.keyId == keyId) return true;

    // Accept common numpad/shifted aliases for zoom shortcuts
    if (keyId == LogicalKeyboardKey.equal.keyId &&
        (pressed == LogicalKeyboardKey.add ||
            pressed == LogicalKeyboardKey.numpadAdd)) {
      return true;
    }
    if (keyId == LogicalKeyboardKey.minus.keyId &&
        pressed == LogicalKeyboardKey.numpadSubtract) {
      return true;
    }
    if (keyId == LogicalKeyboardKey.digit0.keyId &&
        pressed == LogicalKeyboardKey.numpad0) {
      return true;
    }
    return false;
  }

  /// Captures a valid shortcut binding from a [KeyDownEvent].
  /// Returns `null` for lone modifier presses or unmodified printable keys.
  static ShortcutBinding? fromKeyEvent(KeyEvent event, HardwareKeyboard hw) {
    if (event is! KeyDownEvent) return null;
    final key = event.logicalKey;
    if (_isModifierOnlyKey(key)) return null;

    final ctrl = hw.isControlPressed;
    final shift = hw.isShiftPressed;
    final alt = hw.isAltPressed;
    final meta = hw.isMetaPressed;

    final isFunctionKey =
        key.keyId >= LogicalKeyboardKey.f1.keyId &&
        key.keyId <= LogicalKeyboardKey.f12.keyId;
    if (!ctrl && !alt && !meta && !isFunctionKey) {
      return null;
    }

    return ShortcutBinding(
      keyId: key.keyId,
      ctrl: ctrl,
      shift: shift,
      alt: alt,
      meta: meta,
    );
  }

  static bool _isModifierOnlyKey(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.control ||
        key == LogicalKeyboardKey.controlLeft ||
        key == LogicalKeyboardKey.controlRight ||
        key == LogicalKeyboardKey.shift ||
        key == LogicalKeyboardKey.shiftLeft ||
        key == LogicalKeyboardKey.shiftRight ||
        key == LogicalKeyboardKey.alt ||
        key == LogicalKeyboardKey.altLeft ||
        key == LogicalKeyboardKey.altRight ||
        key == LogicalKeyboardKey.meta ||
        key == LogicalKeyboardKey.metaLeft ||
        key == LogicalKeyboardKey.metaRight ||
        key == LogicalKeyboardKey.capsLock ||
        key == LogicalKeyboardKey.numLock ||
        key == LogicalKeyboardKey.scrollLock;
  }

  String get displayLabel {
    final parts = <String>[
      if (ctrl) 'Ctrl',
      if (alt) 'Alt',
      if (shift) 'Shift',
      if (meta) 'Cmd',
      _formatKeyLabel(logicalKey),
    ];
    return parts.join(' + ');
  }

  static String _formatKeyLabel(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.tab) return 'Tab';
    if (key == LogicalKeyboardKey.comma) return ',';
    if (key == LogicalKeyboardKey.period) return '.';
    if (key == LogicalKeyboardKey.equal || key == LogicalKeyboardKey.add) {
      return '=';
    }
    if (key == LogicalKeyboardKey.minus) return '-';
    if (key == LogicalKeyboardKey.slash) return '/';
    if (key == LogicalKeyboardKey.backslash) return r'\';
    if (key == LogicalKeyboardKey.bracketLeft) return '[';
    if (key == LogicalKeyboardKey.bracketRight) return ']';
    if (key == LogicalKeyboardKey.space) return 'Space';
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      return 'Enter';
    }
    if (key == LogicalKeyboardKey.escape) return 'Esc';
    if (key == LogicalKeyboardKey.backspace) return 'Backspace';
    if (key == LogicalKeyboardKey.delete) return 'Del';
    if (key == LogicalKeyboardKey.arrowUp) return '↑';
    if (key == LogicalKeyboardKey.arrowDown) return '↓';
    if (key == LogicalKeyboardKey.arrowLeft) return '←';
    if (key == LogicalKeyboardKey.arrowRight) return '→';

    final label = key.keyLabel.trim();
    if (label.isNotEmpty) {
      return label.length == 1 ? label.toUpperCase() : label;
    }
    return key.debugName ?? 'Key';
  }

  Map<String, dynamic> toJson() => {
    'key_id': keyId,
    'ctrl': ctrl,
    'shift': shift,
    'alt': alt,
    'meta': meta,
  };

  static ShortcutBinding? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final keyId = raw['key_id'];
    if (keyId is! int) return null;
    return ShortcutBinding(
      keyId: keyId,
      ctrl: raw['ctrl'] == true,
      shift: raw['shift'] == true,
      alt: raw['alt'] == true,
      meta: raw['meta'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ShortcutBinding &&
      other.keyId == keyId &&
      other.ctrl == ctrl &&
      other.shift == shift &&
      other.alt == alt &&
      other.meta == meta;

  @override
  int get hashCode => Object.hash(keyId, ctrl, shift, alt, meta);
}

@immutable
class DesktopShortcutConfig {
  const DesktopShortcutConfig({
    this.preset = ShortcutPreset.standard,
    this.smartCtrlCCopy = true,
    this.rightClickQuickPaste = true,
    this.bindings = const {},
  });

  final ShortcutPreset preset;
  final bool smartCtrlCCopy;
  final bool rightClickQuickPaste;

  /// Action -> binding (`null` explicitly means disabled/unbound).
  final Map<ShortcutAction, ShortcutBinding?> bindings;

  static bool get _isMacOs => !kIsWeb && Platform.isMacOS;

  static DesktopShortcutConfig defaults({
    ShortcutPreset preset = ShortcutPreset.standard,
    bool? isMacOs,
  }) {
    final mac = isMacOs ?? _isMacOs;
    final safeShift = !mac && preset == ShortcutPreset.terminalSafe;

    ShortcutBinding primary(LogicalKeyboardKey key, {bool shift = false}) {
      return ShortcutBinding(
        keyId: key.keyId,
        ctrl: !mac,
        meta: mac,
        shift: shift,
      );
    }

    return DesktopShortcutConfig(
      preset: preset,
      smartCtrlCCopy: true,
      rightClickQuickPaste: true,
      bindings: {
        ShortcutAction.newLocalTerminal: primary(
          LogicalKeyboardKey.keyT,
          shift: safeShift,
        ),
        ShortcutAction.closeTab: primary(
          LogicalKeyboardKey.keyW,
          shift: safeShift,
        ),
        ShortcutAction.nextTab: ShortcutBinding(
          keyId: LogicalKeyboardKey.tab.keyId,
          ctrl: true,
        ),
        ShortcutAction.previousTab: ShortcutBinding(
          keyId: LogicalKeyboardKey.tab.keyId,
          ctrl: true,
          shift: true,
        ),
        ShortcutAction.focusSearch: primary(
          LogicalKeyboardKey.keyK,
          shift: safeShift,
        ),
        ShortcutAction.toggleSidebar: primary(
          LogicalKeyboardKey.keyB,
          shift: safeShift,
        ),
        ShortcutAction.zoomIn: primary(LogicalKeyboardKey.equal),
        ShortcutAction.zoomOut: primary(LogicalKeyboardKey.minus),
        ShortcutAction.zoomReset: primary(LogicalKeyboardKey.digit0),
        ShortcutAction.openSettings: primary(LogicalKeyboardKey.comma),
      },
    );
  }

  ShortcutBinding? bindingFor(ShortcutAction action) => bindings[action];

  /// Label for the built-in quick tab switcher (`Ctrl + 1~9`, `Alt + 1~9`, or `Cmd + 1~9`).
  String quickTabSwitchLabel({bool? isMacOs}) {
    final mac = isMacOs ?? _isMacOs;
    if (mac) return 'Cmd + 1~9';
    return preset == ShortcutPreset.terminalSafe ? 'Alt + 1~9' : 'Ctrl + 1~9';
  }

  /// Matches `Ctrl/Alt/Cmd + 1..9` and returns 0-based tab index (`0..8`), or `null`.
  int? matchQuickTabSwitch(
    KeyEvent event,
    HardwareKeyboard hw, {
    bool? isMacOs,
  }) {
    if (event is! KeyDownEvent) return null;
    final mac = isMacOs ?? _isMacOs;
    final expectCtrl = !mac && preset == ShortcutPreset.standard;
    final expectAlt = !mac && preset == ShortcutPreset.terminalSafe;
    final expectMeta = mac;

    if (hw.isControlPressed != expectCtrl ||
        hw.isAltPressed != expectAlt ||
        hw.isMetaPressed != expectMeta ||
        hw.isShiftPressed) {
      return null;
    }

    const digits = <LogicalKeyboardKey>[
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5,
      LogicalKeyboardKey.digit6,
      LogicalKeyboardKey.digit7,
      LogicalKeyboardKey.digit8,
      LogicalKeyboardKey.digit9,
    ];
    final idx = digits.indexOf(event.logicalKey);
    return idx >= 0 ? idx : null;
  }

  ShortcutAction? matchAction(KeyEvent event, HardwareKeyboard hw) {
    if (event is! KeyDownEvent) return null;
    for (final entry in bindings.entries) {
      final b = entry.value;
      if (b != null && b.matches(event, hw)) {
        return entry.key;
      }
    }
    return null;
  }

  ShortcutAction? findConflict(
    ShortcutBinding candidate, {
    required ShortcutAction excluding,
  }) {
    for (final entry in bindings.entries) {
      if (entry.key == excluding) continue;
      if (entry.value == candidate) return entry.key;
    }
    return null;
  }

  DesktopShortcutConfig copyWith({
    ShortcutPreset? preset,
    bool? smartCtrlCCopy,
    bool? rightClickQuickPaste,
    Map<ShortcutAction, ShortcutBinding?>? bindings,
  }) {
    return DesktopShortcutConfig(
      preset: preset ?? this.preset,
      smartCtrlCCopy: smartCtrlCCopy ?? this.smartCtrlCCopy,
      rightClickQuickPaste: rightClickQuickPaste ?? this.rightClickQuickPaste,
      bindings: bindings ?? this.bindings,
    );
  }

  Map<String, dynamic> toJson() => {
    'preset': preset.storageValue,
    'smart_ctrl_c_copy': smartCtrlCCopy,
    'right_click_quick_paste': rightClickQuickPaste,
    'bindings': {
      for (final entry in bindings.entries)
        entry.key.id: entry.value?.toJson(),
    },
  };

  static DesktopShortcutConfig fromJson(dynamic raw, {bool? isMacOs}) {
    if (raw is! Map) return defaults(isMacOs: isMacOs);
    final preset = ShortcutPreset.fromStorage(raw['preset'] as String?);
    final base = defaults(preset: preset, isMacOs: isMacOs);
    final merged = Map<ShortcutAction, ShortcutBinding?>.from(base.bindings);

    final rawBindings = raw['bindings'];
    if (rawBindings is Map) {
      for (final entry in rawBindings.entries) {
        final action = ShortcutAction.fromId(entry.key.toString());
        if (action == null) continue;
        if (entry.value == null) {
          merged[action] = null;
        } else {
          final parsed = ShortcutBinding.fromJson(entry.value);
          if (parsed != null) {
            merged[action] = parsed;
          }
        }
      }
    }

    return DesktopShortcutConfig(
      preset: preset,
      smartCtrlCCopy: raw['smart_ctrl_c_copy'] is bool
          ? raw['smart_ctrl_c_copy'] as bool
          : base.smartCtrlCCopy,
      rightClickQuickPaste: raw['right_click_quick_paste'] is bool
          ? raw['right_click_quick_paste'] as bool
          : base.rightClickQuickPaste,
      bindings: Map.unmodifiable(merged),
    );
  }
}
