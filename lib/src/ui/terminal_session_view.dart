import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nexus_ssh/src/models/ssh_models.dart';
import 'package:nexus_ssh/src/state/app_controller.dart';
import 'package:nexus_ssh/src/terminal/command_autocomplete.dart';
import 'package:nexus_ssh/src/ui/app_theme.dart';
import 'package:nexus_ssh/src/ui/session_side_drawer.dart';
import 'package:nexus_ssh/src/ui/terminal_palettes.dart';
import 'package:xterm3/xterm.dart';

class TerminalSessionView extends StatefulWidget {
  const TerminalSessionView({
    super.key,
    required this.controller,
    required this.session,
    this.isMobile = false,
    this.onShowSessionSwitcher,
  });

  final AppController controller;
  final TerminalSessionItem session;
  final bool isMobile;
  final VoidCallback? onShowSessionSwitcher;

  @override
  State<TerminalSessionView> createState() => _TerminalSessionViewState();
}

class _TerminalSessionViewState extends State<TerminalSessionView> {
  final FocusNode _terminalFocus = FocusNode();
  final GlobalKey<TerminalViewState> _terminalViewKey =
      GlobalKey<TerminalViewState>();
  Timer? _delayedFocusTimer;
  SessionPhase? _lastObservedPhase;
  bool _hadHostKeyPrompt = false;
  DateTime? _lastMobileTapAt;
  Offset? _lastMobileTapPos;

  @override
  void initState() {
    super.initState();
    _lastObservedPhase = widget.session.phase;
    _hadHostKeyPrompt = widget.controller.nextHostKeyPrompt != null;
    _scheduleTerminalFocus();
  }

  @override
  void didUpdateWidget(covariant TerminalSessionView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session.id != widget.session.id) {
      _lastMobileTapAt = null;
      _lastMobileTapPos = null;
      _scheduleTerminalFocus();
    }
  }

  void _scheduleTerminalFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.controller.notifyTerminalViewLaidOut(
        widget.session.id,
        cols: widget.session.terminal.viewWidth,
        rows: widget.session.terminal.viewHeight,
      );
      _activateKeyboard();
    });
    _delayedFocusTimer?.cancel();
    _delayedFocusTimer = Timer(const Duration(milliseconds: 220), () {
      if (!mounted) return;
      _activateKeyboard();
    });
  }

  void _activateKeyboard() {
    _terminalFocus.requestFocus();
    _terminalViewKey.currentState?.requestKeyboard();
  }

  void _handleTerminalTapUp(TapUpDetails details, CellOffset offset) {
    // Termius-style mobile gesture: double-tapping the terminal canvas sends
    // Tab for native shell path/command completion. Desktop keeps word-select.
    if (!widget.isMobile) return;
    final session = widget.session;
    if (session.phase != SessionPhase.connected) return;
    if (session.terminal.buffer.isAltBuffer) return;

    if (session.terminal.hyperlinkAt(offset) != null ||
        session.terminal.urlAt(offset) != null) {
      _lastMobileTapAt = null;
      _lastMobileTapPos = null;
      return;
    }

    final now = DateTime.now();
    final prevAt = _lastMobileTapAt;
    final prevPos = _lastMobileTapPos;
    if (prevAt != null &&
        prevPos != null &&
        now.difference(prevAt) <= const Duration(milliseconds: 340) &&
        (details.localPosition - prevPos).distance <= 40.0) {
      _lastMobileTapAt = null;
      _lastMobileTapPos = null;
      session.controller.clearSelection();
      _terminalViewKey.currentState?.commitComposing();
      HapticFeedback.selectionClick();
      widget.controller.sendVirtualKey(session.id, TerminalKey.tab);
      _activateKeyboard();
      return;
    }

    _lastMobileTapAt = now;
    _lastMobileTapPos = details.localPosition;
  }

  @override
  void dispose() {
    _delayedFocusTimer?.cancel();
    _terminalFocus.dispose();
    super.dispose();
  }

  Future<void> _copySelectionOrNotify() async {
    final selection = widget.session.controller.selection;
    if (selection == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('在终端拖拽选中文本即可复制'),
          duration: Duration(seconds: 1),
        ),
      );
      return;
    }
    final text = widget.session.terminal.buffer.getText(selection);
    await widget.controller.copySensitiveText(text);
    widget.session.controller.clearSelection();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          widget.controller.clipboardAutoClearEnabled
              ? '已复制到剪贴板（30 秒后自动清空）'
              : '已复制到剪贴板',
        ),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  Future<void> _pasteClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    widget.session.terminal.paste(text);
    _activateKeyboard();
  }

  void _openAppearanceSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final currentPalette = widget.controller.palette;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 22),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: NexusColors.borderActive,
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      const Text(
                        '终端外观',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: NexusColors.textPrimary,
                        ),
                      ),
                      const Spacer(),
                      // Font Size Stepper Pill
                      Container(
                        decoration: BoxDecoration(
                          color: NexusColors.bgSurface,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              onPressed: () =>
                                  widget.controller.adjustFontSize(-1),
                              icon: const Icon(Icons.remove_rounded, size: 17),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                              ),
                              child: Text(
                                '${widget.controller.fontSize.toInt()} pt',
                                style: TextStyle(
                                  fontFamily: NexusTheme.monospaceFontFamily,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              onPressed: () =>
                                  widget.controller.adjustFontSize(1),
                              icon: const Icon(Icons.add_rounded, size: 17),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    height: 76,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: NexusTerminalPalettes.all.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 10),
                      itemBuilder: (context, idx) {
                        final p = NexusTerminalPalettes.all[idx];
                        final selected = p.id == currentPalette.id;
                        return GestureDetector(
                          onTap: () => widget.controller.setPalette(p.id),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            width: 136,
                            padding: const EdgeInsets.all(11),
                            decoration: BoxDecoration(
                              color: p.theme.background,
                              borderRadius: BorderRadius.circular(13),
                              border: Border.all(
                                color: selected
                                    ? NexusColors.emerald
                                    : NexusColors.borderActive,
                                width: selected ? 2 : 1,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    _colorDot(p.theme.green),
                                    const SizedBox(width: 5),
                                    _colorDot(p.theme.blue),
                                    const SizedBox(width: 5),
                                    _colorDot(p.theme.magenta),
                                    const SizedBox(width: 5),
                                    _colorDot(p.theme.yellow),
                                  ],
                                ),
                                Text(
                                  p.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: p.theme.foreground,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '命令智能提示',
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w500,
                                color: NexusColors.textPrimary,
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              '结合历史命令、片段库与高频词典实时联想补全',
                              style: TextStyle(
                                fontSize: 11.5,
                                color: NexusColors.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Switch.adaptive(
                        value: widget.controller.autocompleteEnabled,
                        activeTrackColor: NexusColors.emerald,
                        onChanged: (_) => widget.controller.toggleAutocomplete(),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ).whenComplete(() {
      if (mounted) _activateKeyboard();
    });
  }

  Widget _colorDot(Color c) {
    return Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(color: c, shape: BoxShape.circle),
    );
  }

  Color _phaseColor(SessionPhase phase) {
    return switch (phase) {
      SessionPhase.connecting || SessionPhase.verifyHostKey => NexusColors.amber,
      SessionPhase.connected || SessionPhase.sftpProgress => NexusColors.emerald,
      SessionPhase.disconnected => NexusColors.textMuted,
      SessionPhase.error => NexusColors.rose,
    };
  }

  void _openOrToggleDrawer(SessionDrawerTab tab) {
    if (widget.isMobile) {
      SessionSideDrawer.showMobileSheet(
        context,
        controller: widget.controller,
        session: widget.session,
        initialTab: tab,
      ).whenComplete(() {
        if (mounted) _activateKeyboard();
      });
    } else {
      widget.controller.toggleSessionDrawer(widget.session.id, tab);
      _activateKeyboard();
    }
  }

  Widget _topBarActionIcon({
    required String tooltip,
    required IconData icon,
    required VoidCallback onPressed,
    bool active = false,
    Color? color,
    double size = 16.5,
  }) {
    return IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      padding: const EdgeInsets.all(6),
      icon: Icon(
        icon,
        size: size,
        color:
            color ??
            (active ? NexusColors.emerald : NexusColors.textSecondary),
      ),
      onPressed: onPressed,
    );
  }

  ({double left, double top})? _computeCursorPopupPosition({
    required TerminalSessionItem session,
    required double canvasWidth,
    required double canvasHeight,
    required double popupWidth,
    required double popupHeight,
    int colOffsetBack = 0,
  }) {
    const double margin = 10;
    const double gap = 6;
    final state = _terminalViewKey.currentState;
    if (state != null) {
      try {
        final rt = state.renderTerminal;
        final cursorTopLeft = rt.cursorOffset;
        final cellSize = rt.cellSize;
        final lineH = cellSize.height > 0 ? cellSize.height : rt.lineHeight;

        if (cursorTopLeft.dy + lineH < 0 || cursorTopLeft.dy > canvasHeight) {
          return null;
        }

        final anchorDx = cursorTopLeft.dx - colOffsetBack * cellSize.width;
        final maxLeft = math.max(margin, canvasWidth - popupWidth - margin);
        final left = anchorDx.clamp(margin, maxLeft);

        final belowTop = cursorTopLeft.dy + lineH + gap;
        final aboveTop = cursorTopLeft.dy - popupHeight - gap;
        final maxTop = math.max(margin, canvasHeight - popupHeight - margin);

        double top;
        if (belowTop + popupHeight <= canvasHeight - margin) {
          top = belowTop;
        } else if (aboveTop >= margin) {
          top = aboveTop;
        } else {
          final spaceBelow = canvasHeight - belowTop;
          final spaceAbove = cursorTopLeft.dy;
          top = (spaceBelow >= spaceAbove ? belowTop : aboveTop)
              .clamp(margin, maxTop);
        }

        return (left: left, top: top);
      } catch (_) {
        // Fallback when RenderTerminal hasn't completed its first layout pass yet
      }
    }

    final fallbackTop = math.max(margin, canvasHeight - popupHeight - 12);
    return (left: 12, top: fallbackTop);
  }

  KeyEventResult _handleTerminalKeyEvent(FocusNode node, KeyEvent event) {
    final session = widget.session;
    final popupVisible =
        session.phase == SessionPhase.connected &&
        widget.controller.autocompleteEnabled &&
        session.sudoPromptLabel == null &&
        session.autocompleteSuggestions.isNotEmpty;

    if (!popupVisible) {
      return KeyEventResult.ignored;
    }

    // Do not hijack keys when Ctrl / Alt / Meta modifiers are held
    final hw = HardwareKeyboard.instance;
    if (hw.isControlPressed || hw.isAltPressed || hw.isMetaPressed) {
      return KeyEventResult.ignored;
    }

    final isPressOrRepeat =
        event is KeyDownEvent || event is KeyRepeatEvent;
    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.arrowDown) {
      if (isPressOrRepeat) {
        widget.controller.moveAutocompleteSelection(session.id, 1);
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowUp) {
      if (isPressOrRepeat) {
        widget.controller.moveAutocompleteSelection(session.id, -1);
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowRight &&
        widget.controller.isAutocompleteCursorAtLineEnd(session.id)) {
      if (isPressOrRepeat) {
        widget.controller.acceptSelectedAutocomplete(session.id);
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.tab) {
      // Keep Tab 100% native for shell path/argument completion; dismiss our popup so it won't obscure completions.
      if (isPressOrRepeat) {
        widget.controller.dismissAutocomplete(session.id);
      }
      return KeyEventResult.ignored;
    }

    if (key == LogicalKeyboardKey.escape) {
      if (isPressOrRepeat) {
        widget.controller.dismissAutocomplete(session.id);
      }
      return KeyEventResult.handled;
    }

    if ((key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter) &&
        session.autocompleteNavigated) {
      if (isPressOrRepeat) {
        widget.controller.acceptSelectedAutocomplete(session.id);
      }
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  Widget? _buildCursorFloatingOverlay({
    required TerminalSessionItem session,
    required bool isConnected,
    required double canvasWidth,
    required double canvasHeight,
  }) {
    if (!isConnected) return null;

    // 1. Termius-style Floating sudo Password Autofill Pill (never shifts terminal height)
    if (session.sudoPromptLabel != null &&
        session.profile.hasStoredPassword) {
      final popupWidth = math.min(320.0, math.max(220.0, canvasWidth - 20));
      const popupHeight = 46.0;
      final pos = _computeCursorPopupPosition(
        session: session,
        canvasWidth: canvasWidth,
        canvasHeight: canvasHeight,
        popupWidth: popupWidth,
        popupHeight: popupHeight,
      );
      if (pos == null) return null;

      return Positioned(
        left: pos.left,
        top: pos.top,
        width: popupWidth,
        child: _FloatingSudoPill(
          label: session.sudoPromptLabel!,
          username: session.profile.username,
          onFill: () {
            HapticFeedback.lightImpact();
            widget.controller.fillSudoPassword(session.id);
            _activateKeyboard();
          },
          onDismiss: () {
            widget.controller.dismissSudoPrompt(session.id);
            _activateKeyboard();
          },
        ),
      );
    }

    // 2. Termius-style Cursor-Following Command Autocomplete Floating Card
    final suggestions = session.autocompleteSuggestions;
    if (widget.controller.autocompleteEnabled && suggestions.isNotEmpty) {
      const rowHeight = 34.0;
      const verticalPad = 10.0;
      final footerHeight = widget.isMobile ? 0.0 : 22.0;
      final visibleRows = math.min(5, suggestions.length);
      final popupHeight = visibleRows * rowHeight + verticalPad + footerHeight;
      final popupWidth = math.min(360.0, math.max(220.0, canvasWidth - 20));
      final pos = _computeCursorPopupPosition(
        session: session,
        canvasWidth: canvasWidth,
        canvasHeight: canvasHeight,
        popupWidth: popupWidth,
        popupHeight: popupHeight,
        colOffsetBack: suggestions.first.matchedPrefixLength,
      );
      if (pos == null) return null;

      return Positioned(
        left: pos.left,
        top: pos.top,
        width: popupWidth,
        height: popupHeight,
        child: _FloatingAutocompletePopup(
          suggestions: suggestions,
          selectedIndex: session.autocompleteSelectedIndex,
          isNavigated: session.autocompleteNavigated,
          showKeyboardHints: !widget.isMobile,
          onSelect: (suggestion) {
            HapticFeedback.selectionClick();
            widget.controller.acceptAutocompleteSuggestion(
              session.id,
              suggestion,
            );
            _activateKeyboard();
          },
        ),
      );
    }

    return null;
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final hasPrompt = widget.controller.nextHostKeyPrompt != null;
    if ((_hadHostKeyPrompt && !hasPrompt) ||
        (_lastObservedPhase != SessionPhase.connected &&
            session.phase == SessionPhase.connected &&
            !hasPrompt)) {
      _scheduleTerminalFocus();
    }
    _hadHostKeyPrompt = hasPrompt;
    _lastObservedPhase = session.phase;

    final palette = widget.controller.palette;
    final statusColor = _phaseColor(session.phase);
    final isConnected = session.phase == SessionPhase.connected;
    final canReconnect =
        session.phase == SessionPhase.disconnected ||
        session.phase == SessionPhase.error;

    return Column(
      children: [
        // Clean Termius-style Immersive Top Bar
        Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: const BoxDecoration(
            color: NexusColors.bgSidebar,
            border: Border(
              bottom: BorderSide(color: NexusColors.borderSubtle, width: 0.8),
            ),
          ),
          child: Row(
            children: [
              if (widget.isMobile) ...[
                TextButton.icon(
                  onPressed: widget.controller.showHostsVault,
                  style: TextButton.styleFrom(
                    foregroundColor: NexusColors.textSecondary,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    minimumSize: const Size(0, 32),
                  ),
                  icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 13),
                  label: const Text('Hosts', style: TextStyle(fontSize: 12.5)),
                ),
                const SizedBox(width: 2),
              ] else
                const SizedBox(width: 6),

              // Host Identity / Session Switcher Pill
              Expanded(
                child: Align(
                  alignment: widget.isMobile
                      ? Alignment.centerLeft
                      : Alignment.centerLeft,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(9),
                    onTap: widget.onShowSessionSwitcher,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 5,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 7.5,
                            height: 7.5,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: statusColor,
                            ),
                          ),
                          const SizedBox(width: 7),
                          if (!session.isLocal &&
                              session.profile.usesProxyJump) ...[
                            Tooltip(
                              message: () {
                                final hops = widget.controller
                                    .resolveProxyJumpChain(session.profile);
                                if (hops.isEmpty) return 'ProxyJump';
                                return 'ProxyJump: ${hops.map((h) => h.name).join(' → ')} → ${session.profile.name}';
                              }(),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5,
                                  vertical: 1.5,
                                ),
                                decoration: BoxDecoration(
                                  color: NexusColors.emerald.withValues(
                                    alpha: 0.12,
                                  ),
                                  borderRadius: BorderRadius.circular(5),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.alt_route_rounded,
                                      size: 11,
                                      color: NexusColors.emerald,
                                    ),
                                    SizedBox(width: 3),
                                    Text(
                                      'ProxyJump',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w600,
                                        color: NexusColors.emerald,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                          ],
                          Flexible(
                            child: Text(
                              session.isLocal
                                  ? '本地终端 · ${session.localShellName.isNotEmpty ? session.localShellName : session.tabTitle}'
                                  : (widget.isMobile
                                        ? session.tabTitle
                                        : '${session.profile.addressLabel}'
                                              '${session.latencyMs != null ? '  ·  ${session.latencyMs} ms' : ''}'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: NexusTheme.monospaceFontFamily,
                                fontSize: 12.2,
                                fontWeight: (widget.isMobile || session.isLocal)
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                                color: (widget.isMobile || session.isLocal)
                                    ? NexusColors.textPrimary
                                    : NexusColors.textSecondary,
                              ),
                            ),
                          ),
                          if (widget.isMobile &&
                              widget.controller.sessions.length > 1) ...[
                            const SizedBox(width: 4),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: NexusColors.bgElevated,
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: Text(
                                '${widget.controller.sessions.length}',
                                style: const TextStyle(
                                  fontSize: 10.5,
                                  color: NexusColors.emerald,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),

              // Collapsible Session Tools (SFTP / Monitor / Snippets)
              if (isConnected) ...[
                if (!session.isLocal) ...[
                  _topBarActionIcon(
                    tooltip: 'SFTP 文件管理',
                    icon: Icons.folder_open_rounded,
                    active:
                        !widget.isMobile &&
                        session.desktopDrawerTab == SessionDrawerTab.sftp,
                    onPressed: () => _openOrToggleDrawer(SessionDrawerTab.sftp),
                  ),
                  _topBarActionIcon(
                    tooltip: '服务器状态监控',
                    icon: Icons.speed_rounded,
                    active:
                        !widget.isMobile &&
                        session.desktopDrawerTab == SessionDrawerTab.monitor,
                    onPressed: () =>
                        _openOrToggleDrawer(SessionDrawerTab.monitor),
                  ),
                ],
                _topBarActionIcon(
                  tooltip: '命令片段',
                  icon: Icons.code_rounded,
                  active:
                      !widget.isMobile &&
                      session.desktopDrawerTab == SessionDrawerTab.snippets,
                  onPressed: () =>
                      _openOrToggleDrawer(SessionDrawerTab.snippets),
                ),
                Container(
                  width: 1,
                  height: 15,
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  color: NexusColors.borderSubtle,
                ),
              ],

              // Minimal Action Icons (Paste, Aa Appearance, Keybar toggle, Reconnect/Close)
              if (!widget.isMobile)
                _topBarActionIcon(
                  tooltip: '复制选中文本',
                  icon: Icons.copy_rounded,
                  size: 16,
                  onPressed: _copySelectionOrNotify,
                ),
              if (!widget.isMobile)
                _topBarActionIcon(
                  tooltip: '粘贴',
                  icon: Icons.content_paste_rounded,
                  size: 16,
                  onPressed: _pasteClipboard,
                ),
              _topBarActionIcon(
                tooltip: '字体与配色 (Aa)',
                icon: Icons.text_fields_rounded,
                size: 16.5,
                onPressed: _openAppearanceSheet,
              ),
              _topBarActionIcon(
                tooltip: '扩展快捷按键栏',
                icon: Icons.keyboard_rounded,
                size: 16.5,
                active: widget.controller.showVirtualKeys,
                onPressed: () {
                  widget.controller.toggleVirtualKeys();
                  _activateKeyboard();
                },
              ),
              const SizedBox(width: 2),
              if (canReconnect)
                TextButton.icon(
                  onPressed: () =>
                      widget.controller.reconnectSession(session.id),
                  style: TextButton.styleFrom(
                    foregroundColor: NexusColors.emerald,
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  icon: const Icon(Icons.refresh_rounded, size: 15),
                  label: Text(
                    session.isLocal ? '重启' : '重连',
                    style: const TextStyle(fontSize: 12),
                  ),
                )
              else if (!session.isLocal)
                _topBarActionIcon(
                  tooltip: widget.isMobile ? '关闭当前会话' : '断开连接',
                  icon: Icons.power_settings_new_rounded,
                  size: 16.5,
                  color: NexusColors.rose,
                  onPressed: () {
                    if (widget.isMobile) {
                      widget.controller.closeSessionTab(session.id);
                    } else {
                      widget.controller.disconnectSession(session.id);
                    }
                  },
                ),
            ],
          ),
        ),

        // Main xterm3 Terminal Canvas + Cursor-Following Floating Popups + Optional Desktop Side Drawer
        Expanded(
          child: Row(
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final overlay = _buildCursorFloatingOverlay(
                      session: session,
                      isConnected: isConnected,
                      canvasWidth: constraints.maxWidth,
                      canvasHeight: constraints.maxHeight,
                    );
                    return Stack(
                      fit: StackFit.expand,
                      clipBehavior: Clip.none,
                      children: [
                        ColoredBox(
                          color: palette.theme.background,
                          child: TerminalView(
                            session.terminal,
                            key: _terminalViewKey,
                            controller: session.controller,
                            focusNode: _terminalFocus,
                            autofocus: true,
                            onKeyEvent: _handleTerminalKeyEvent,
                            onTapUp: _handleTerminalTapUp,
                            deleteDetection:
                                !kIsWeb &&
                                (Platform.isAndroid || Platform.isIOS),
                            theme: palette.theme,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            textStyle: TerminalStyle(
                              fontFamily: NexusTheme.monospaceFontFamily,
                              fontSize: widget.controller.fontSize,
                              height: 1.28,
                            ),
                            onSecondaryTapDown: (details, offset) async {
                              final selection = session.controller.selection;
                              if (selection != null) {
                                await _copySelectionOrNotify();
                              } else {
                                await _pasteClipboard();
                              }
                            },
                          ),
                        ),
                        ?overlay,
                        if (session.browserAuthUrl != null)
                          Positioned(
                            top: 12,
                            left: 14,
                            right: 14,
                            child: Center(
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 560,
                                ),
                                child: _BrowserAuthFloatingBanner(
                                  url: session.browserAuthUrl!,
                                  onOpen: () async {
                                    final url = session.browserAuthUrl!;
                                    final opened = await widget.controller
                                        .openExternalUrl(url);
                                    if (!context.mounted) return;
                                    if (!opened) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(
                                          content: Text(
                                            '已复制验证链接，请在浏览器中粘贴打开',
                                          ),
                                        ),
                                      );
                                    }
                                  },
                                  onCopy: () async {
                                    final url = session.browserAuthUrl!;
                                    await Clipboard.setData(
                                      ClipboardData(text: url),
                                    );
                                    if (!context.mounted) return;
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text('已复制浏览器验证链接'),
                                        duration: Duration(seconds: 1),
                                      ),
                                    );
                                  },
                                  onDismiss: () {
                                    widget.controller.dismissBrowserAuthUrl(
                                      session.id,
                                    );
                                    _activateKeyboard();
                                  },
                                ),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
              if (!widget.isMobile &&
                  isConnected &&
                  session.desktopDrawerTab != null)
                SessionSideDrawer(
                  controller: widget.controller,
                  session: session,
                  initialTab: session.desktopDrawerTab!,
                  onRefocusTerminal: _activateKeyboard,
                  onClose: () {
                    widget.controller.closeSessionDrawer(session.id);
                    _activateKeyboard();
                  },
                ),
            ],
          ),
        ),

        // Termius-style Tactile Extra-Keys Accessory Bar
        if (widget.controller.showVirtualKeys)
          _TermiusKeyToolbar(
            controller: widget.controller,
            sessionId: session.id,
            onPaste: _pasteClipboard,
            onRefocus: _activateKeyboard,
          ),
      ],
    );
  }
}

class _BrowserAuthFloatingBanner extends StatelessWidget {
  const _BrowserAuthFloatingBanner({
    required this.url,
    required this.onOpen,
    required this.onCopy,
    required this.onDismiss,
  });

  final String url;
  final VoidCallback onOpen;
  final VoidCallback onCopy;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: NexusColors.bgElevated,
      elevation: 10,
      shadowColor: Colors.black54,
      borderRadius: BorderRadius.circular(13),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 9, 8, 9),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(13),
          border: Border.all(
            color: NexusColors.cyan.withValues(alpha: 0.5),
            width: 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: NexusColors.cyan.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                Icons.open_in_browser_rounded,
                size: 17,
                color: NexusColors.cyan,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '需要浏览器身份验证 (Tailscale SSH)',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.2,
                      fontWeight: FontWeight.w600,
                      color: NexusColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    url,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: NexusTheme.monospaceFontFamily,
                      fontSize: 11,
                      color: NexusColors.cyan,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: onOpen,
              style: FilledButton.styleFrom(
                backgroundColor: NexusColors.cyan,
                foregroundColor: const Color(0xFF042233),
                minimumSize: const Size(0, 30),
                padding: const EdgeInsets.symmetric(horizontal: 11),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: const Text(
                '打开浏览器',
                style: TextStyle(fontSize: 11.8, fontWeight: FontWeight.w700),
              ),
            ),
            IconButton(
              tooltip: '复制链接',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              padding: EdgeInsets.zero,
              onPressed: onCopy,
              icon: const Icon(
                Icons.copy_rounded,
                size: 15,
                color: NexusColors.textSecondary,
              ),
            ),
            IconButton(
              tooltip: '隐藏',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
              padding: EdgeInsets.zero,
              onPressed: onDismiss,
              icon: const Icon(
                Icons.close_rounded,
                size: 15,
                color: NexusColors.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FloatingAutocompletePopup extends StatefulWidget {
  const _FloatingAutocompletePopup({
    required this.suggestions,
    required this.selectedIndex,
    required this.isNavigated,
    required this.showKeyboardHints,
    required this.onSelect,
  });

  final List<AutocompleteSuggestion> suggestions;
  final int selectedIndex;
  final bool isNavigated;
  final bool showKeyboardHints;
  final ValueChanged<AutocompleteSuggestion> onSelect;

  @override
  State<_FloatingAutocompletePopup> createState() =>
      _FloatingAutocompletePopupState();
}

class _FloatingAutocompletePopupState
    extends State<_FloatingAutocompletePopup> {
  static const double _itemExtent = 34.0;
  final ScrollController _scrollController = ScrollController();

  @override
  void didUpdateWidget(covariant _FloatingAutocompletePopup oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedIndex != widget.selectedIndex) {
      _ensureSelectedVisible();
    }
  }

  void _ensureSelectedVisible() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    final itemTop = widget.selectedIndex * _itemExtent;
    final itemBottom = itemTop + _itemExtent;
    final viewTop = pos.pixels;
    final viewBottom = viewTop + pos.viewportDimension;

    if (itemTop < viewTop) {
      _scrollController.jumpTo(itemTop.clamp(0.0, pos.maxScrollExtent));
    } else if (itemBottom > viewBottom) {
      final target = (itemBottom - pos.viewportDimension).clamp(
        0.0,
        pos.maxScrollExtent,
      );
      _scrollController.jumpTo(target);
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  IconData _sourceIcon(SuggestionSource source) {
    return switch (source) {
      SuggestionSource.localHistory ||
      SuggestionSource.remoteHistory => Icons.history_rounded,
      SuggestionSource.snippet => Icons.code_rounded,
      SuggestionSource.builtin => Icons.terminal_rounded,
    };
  }

  Color _sourceColor(SuggestionSource source) {
    return switch (source) {
      SuggestionSource.localHistory ||
      SuggestionSource.remoteHistory => NexusColors.cyan,
      SuggestionSource.snippet => NexusColors.emerald,
      SuggestionSource.builtin => NexusColors.textMuted,
    };
  }

  String _sourceTag(SuggestionSource source) {
    return switch (source) {
      SuggestionSource.localHistory ||
      SuggestionSource.remoteHistory => '历史',
      SuggestionSource.snippet => '片段',
      SuggestionSource.builtin => '常用',
    };
  }

  @override
  Widget build(BuildContext context) {
    final safeIdx = widget.suggestions.isEmpty
        ? 0
        : widget.selectedIndex.clamp(0, widget.suggestions.length - 1);

    return Material(
      color: NexusColors.bgElevated.withValues(alpha: 0.96),
      elevation: 10,
      shadowColor: Colors.black.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(11),
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(11),
          border: Border.all(
            color: NexusColors.borderActive.withValues(alpha: 0.9),
            width: 0.9,
          ),
        ),
        child: Column(
          children: [
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: widget.suggestions.length,
                itemExtent: _itemExtent,
                itemBuilder: (context, idx) {
                  final s = widget.suggestions[idx];
                  final isActiveSelected = widget.isNavigated && idx == safeIdx;
                  final isSoftPreview = !widget.isNavigated && idx == 0;
                  final splitAt = s.matchedPrefixLength.clamp(
                    0,
                    s.fullText.length,
                  );
                  final typed = s.fullText.substring(0, splitAt);
                  final rest = s.fullText.substring(splitAt);
                  final color = _sourceColor(s.source);

                  return InkWell(
                    onTap: () => widget.onSelect(s),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: isActiveSelected
                            ? NexusColors.emerald.withValues(alpha: 0.16)
                            : (isSoftPreview
                                  ? Colors.white.withValues(alpha: 0.045)
                                  : Colors.transparent),
                        border: Border(
                          left: BorderSide(
                            color: isActiveSelected
                                ? NexusColors.emerald
                                : (isSoftPreview
                                      ? NexusColors.borderActive
                                      : Colors.transparent),
                            width: 2.5,
                          ),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(_sourceIcon(s.source), size: 13.5, color: color),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text.rich(
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              TextSpan(
                                style: TextStyle(
                                  fontFamily: NexusTheme.monospaceFontFamily,
                                  fontSize: 12.2,
                                ),
                                children: [
                                  TextSpan(
                                    text: typed,
                                    style: const TextStyle(
                                      color: NexusColors.textMuted,
                                    ),
                                  ),
                                  TextSpan(
                                    text: rest,
                                    style: TextStyle(
                                      color: isActiveSelected
                                          ? NexusColors.emerald
                                          : NexusColors.textPrimary,
                                      fontWeight: isActiveSelected
                                          ? FontWeight.w600
                                          : FontWeight.w400,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          if (isSoftPreview && widget.showKeyboardHints) ...[
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4.5,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: NexusColors.bgSidebar,
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                  color: NexusColors.borderSubtle,
                                  width: 0.7,
                                ),
                              ),
                              child: const Text(
                                '→',
                                style: TextStyle(
                                  fontSize: 9.5,
                                  color: NexusColors.textSecondary,
                                  height: 1.1,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                          ],
                          Text(
                            _sourceTag(s.source),
                            style: TextStyle(
                              fontSize: 10,
                              color: color.withValues(alpha: 0.85),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            if (widget.showKeyboardHints)
              Container(
                height: 22,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: const BoxDecoration(
                  color: NexusColors.bgSidebar,
                  border: Border(
                    top: BorderSide(
                      color: NexusColors.borderSubtle,
                      width: 0.6,
                    ),
                  ),
                ),
                alignment: Alignment.centerLeft,
                child: Text(
                  widget.isNavigated
                      ? '↑↓ 切换 · Enter 上屏 · Tab 原生补全 · Esc 关闭'
                      : '→ 采纳首项 · ↑↓ 选择 · Tab 原生补全 · Esc 关闭',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 10,
                    color: NexusColors.textMuted,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _FloatingSudoPill extends StatelessWidget {
  const _FloatingSudoPill({
    required this.label,
    required this.username,
    required this.onFill,
    required this.onDismiss,
  });

  final String label;
  final String username;
  final VoidCallback onFill;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: NexusColors.bgElevated.withValues(alpha: 0.97),
      elevation: 10,
      shadowColor: Colors.black.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(11),
      child: Container(
        height: 46,
        padding: const EdgeInsets.only(left: 10, right: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(11),
          border: Border.all(
            color: NexusColors.emerald.withValues(alpha: 0.45),
            width: 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                color: NexusColors.emerald.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(7),
              ),
              child: const Icon(
                Icons.key_rounded,
                size: 14,
                color: NexusColors.emerald,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '$label ($username)',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: NexusColors.textPrimary,
                ),
              ),
            ),
            const SizedBox(width: 6),
            FilledButton(
              onPressed: onFill,
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 28),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(7),
                ),
              ),
              child: const Text(
                '填入主机密码',
                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
              ),
            ),
            IconButton(
              tooltip: '忽略本次提示',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
              padding: const EdgeInsets.all(2),
              onPressed: onDismiss,
              icon: const Icon(
                Icons.close_rounded,
                size: 15,
                color: NexusColors.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TermiusKeyToolbar extends StatelessWidget {
  const _TermiusKeyToolbar({
    required this.controller,
    required this.sessionId,
    required this.onPaste,
    required this.onRefocus,
  });

  final AppController controller;
  final String sessionId;
  final VoidCallback onPaste;
  final VoidCallback onRefocus;

  @override
  Widget build(BuildContext context) {
    void tapKey(TerminalKey key) {
      HapticFeedback.selectionClick();
      controller.sendVirtualKey(sessionId, key);
      onRefocus();
    }

    void tapBytes(List<int> bytes) {
      HapticFeedback.selectionClick();
      controller.sendRawSequence(sessionId, bytes);
      onRefocus();
    }

    return Container(
      height: 46,
      decoration: const BoxDecoration(
        color: NexusColors.bgSidebar,
        border: Border(
          top: BorderSide(color: NexusColors.borderSubtle, width: 0.8),
        ),
      ),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        children: [
          _TactileKeycap(label: 'ESC', onTap: () => tapKey(TerminalKey.escape)),
          _TactileKeycap(label: 'TAB', onTap: () => tapKey(TerminalKey.tab)),
          _TactileKeycap(
            label: 'CTRL',
            active: controller.ctrlArmed,
            onTap: () {
              HapticFeedback.selectionClick();
              controller.toggleCtrlArmed();
              onRefocus();
            },
          ),
          _TactileKeycap(
            label: 'ALT',
            active: controller.altArmed,
            onTap: () {
              HapticFeedback.selectionClick();
              controller.toggleAltArmed();
              onRefocus();
            },
          ),
          _TactileKeycap(label: '←', onTap: () => tapKey(TerminalKey.arrowLeft)),
          _TactileKeycap(label: '↓', onTap: () => tapKey(TerminalKey.arrowDown)),
          _TactileKeycap(label: '↑', onTap: () => tapKey(TerminalKey.arrowUp)),
          _TactileKeycap(
            label: '→',
            onTap: () => tapKey(TerminalKey.arrowRight),
          ),
          _TactileKeycap(label: '-', onTap: () => tapBytes(utf8.encode('-'))),
          _TactileKeycap(label: '/', onTap: () => tapBytes(utf8.encode('/'))),
          _TactileKeycap(label: '|', onTap: () => tapBytes(utf8.encode('|'))),
          _TactileKeycap(label: '~', onTap: () => tapBytes(utf8.encode('~'))),
          _TactileKeycap(label: '^C', onTap: () => tapBytes(const [0x03])),
          _TactileKeycap(label: '^D', onTap: () => tapBytes(const [0x04])),
          _TactileKeycap(label: 'HOME', onTap: () => tapKey(TerminalKey.home)),
          _TactileKeycap(label: 'END', onTap: () => tapKey(TerminalKey.end)),
        ],
      ),
    );
  }
}

class _TactileKeycap extends StatelessWidget {
  const _TactileKeycap({
    required this.label,
    required this.onTap,
    this.active = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Material(
        color: active ? NexusColors.emerald : NexusColors.bgKeycap,
        borderRadius: BorderRadius.circular(8),
        elevation: 1.5,
        shadowColor: const Color(0x55000000),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minWidth: 38),
            padding: const EdgeInsets.symmetric(horizontal: 11),
            alignment: Alignment.center,
            child: Text(
              label,
              style: TextStyle(
                fontFamily: NexusTheme.monospaceFontFamily,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: active
                    ? const Color(0xFF062819)
                    : NexusColors.textPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
