import 'package:flutter/material.dart';
import 'package:nexus_ssh/src/models/snippet_template.dart';
import 'package:nexus_ssh/src/models/ssh_models.dart';
import 'package:nexus_ssh/src/state/app_controller.dart';
import 'package:nexus_ssh/src/ui/app_theme.dart';

class SnippetsPanel extends StatefulWidget {
  const SnippetsPanel({
    super.key,
    required this.controller,
    this.activeSessionId,
    this.onAfterExecute,
  });

  final AppController controller;
  final String? activeSessionId;
  final VoidCallback? onAfterExecute;

  static Future<void> showModal(
    BuildContext context, {
    required AppController controller,
    String? activeSessionId,
  }) {
    final isMobile = MediaQuery.sizeOf(context).width < 680;
    if (isMobile) {
      return showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (ctx) => FractionallySizedBox(
          heightFactor: 0.78,
          child: SnippetsPanel(
            controller: controller,
            activeSessionId: activeSessionId,
            onAfterExecute: () => Navigator.of(ctx).pop(),
          ),
        ),
      );
    }

    return showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 500, maxHeight: 580),
          child: SnippetsPanel(
            controller: controller,
            activeSessionId: activeSessionId,
            onAfterExecute: activeSessionId != null
                ? () => Navigator.of(ctx).pop()
                : null,
          ),
        ),
      ),
    );
  }

  @override
  State<SnippetsPanel> createState() => _SnippetsPanelState();
}

class _SnippetsPanelState extends State<SnippetsPanel> {
  String _query = '';

  Future<void> _openSnippetEditor([SnippetItem? existing]) async {
    final saved = await showDialog<SnippetItem>(
      context: context,
      builder: (_) => _SnippetEditorDialog(existing: existing),
    );
    if (saved == null) return;
    await widget.controller.saveSnippet(saved);
  }

  Future<bool> _confirmDangerIfNeeded(String command, String title) async {
    final reason = SnippetTemplate.detectDangerReason(command);
    if (reason == null) return true;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(
              Icons.gpp_maybe_rounded,
              color: NexusColors.rose,
              size: 22,
            ),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                '高危命令执行确认',
                style: TextStyle(color: NexusColors.rose),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '片段「$title」$reason，请仔细核对以下即将发送到终端的完整命令：',
              style: const TextStyle(
                fontSize: 13,
                height: 1.45,
                color: NexusColors.textSecondary,
              ),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(11),
              decoration: BoxDecoration(
                color: NexusColors.bgSurface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: NexusColors.rose.withValues(alpha: 0.45),
                ),
              ),
              child: SelectableText(
                command,
                style: TextStyle(
                  fontFamily: NexusTheme.monospaceFontFamily,
                  fontSize: 12.2,
                  color: NexusColors.rose,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: NexusColors.rose),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确认执行', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _handleTapSnippet(SnippetItem item) async {
    final sid = widget.activeSessionId;
    final vars = SnippetTemplate.extractVariables(item.command);

    if (vars.isEmpty) {
      if (sid != null) {
        final ok = await _confirmDangerIfNeeded(item.command, item.title);
        if (!ok || !mounted) return;
        widget.controller.executeSnippetInSession(sid, item);
        widget.onAfterExecute?.call();
      } else {
        await widget.controller.copySensitiveText(item.command);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已复制命令: ${item.title}'),
            duration: const Duration(seconds: 1),
          ),
        );
      }
      return;
    }

    final remembered = widget.controller.getLastSnippetVariables(item.id);
    final result = await showDialog<_VariableFillResult>(
      context: context,
      builder: (_) => _SnippetVariablesDialog(
        item: item,
        variables: vars,
        initialValues: remembered,
        hasActiveSession: sid != null,
      ),
    );
    if (result == null) return;

    widget.controller.rememberSnippetVariables(item.id, result.values);
    if (sid != null) {
      if (!mounted) return;
      final ok = await _confirmDangerIfNeeded(
        result.renderedCommand,
        item.title,
      );
      if (!ok || !mounted) return;
      widget.controller.executeCommandInSession(
        sid,
        result.renderedCommand,
        autoEnter: result.autoEnter,
      );
      widget.onAfterExecute?.call();
    } else {
      await widget.controller.copySensitiveText(result.renderedCommand);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已复制渲染后的命令: ${item.title}'),
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final q = _query.trim().toLowerCase();
        final items = widget.controller.snippets.where((s) {
          if (q.isEmpty) return true;
          return s.title.toLowerCase().contains(q) ||
              s.command.toLowerCase().contains(q) ||
              s.category.toLowerCase().contains(q);
        }).toList();

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 12, 10),
              child: Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 36,
                      child: TextField(
                        onChanged: (v) => setState(() => _query = v),
                        style: const TextStyle(fontSize: 13),
                        decoration: const InputDecoration(
                          hintText: '搜索命令片段...',
                          prefixIcon: Icon(Icons.search_rounded, size: 17),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    tooltip: '新建片段',
                    onPressed: () => _openSnippetEditor(),
                    style: IconButton.styleFrom(
                      backgroundColor: NexusColors.emerald.withValues(
                        alpha: 0.16,
                      ),
                      foregroundColor: NexusColors.emerald,
                      minimumSize: const Size(36, 36),
                    ),
                    icon: const Icon(Icons.add_rounded, size: 19),
                  ),
                ],
              ),
            ),
            Expanded(
              child: items.isEmpty
                  ? const Center(
                      child: Text(
                        '暂无命令片段，点击右上角 + 添加',
                        style: TextStyle(
                          fontSize: 13,
                          color: NexusColors.textMuted,
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(12, 2, 12, 16),
                      itemCount: items.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, idx) {
                        final item = items[idx];
                        final vars = SnippetTemplate.extractVariables(
                          item.command,
                        );
                        return Material(
                          color: NexusColors.bgSurface,
                          borderRadius: BorderRadius.circular(12),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () => _handleTapSnippet(item),
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(
                                13,
                                10,
                                8,
                                10,
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Flexible(
                                              child: Text(
                                                item.title,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontSize: 13.5,
                                                  fontWeight: FontWeight.w600,
                                                  color:
                                                      NexusColors.textPrimary,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 6),
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 6,
                                                    vertical: 1,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: NexusColors.bgElevated,
                                                borderRadius:
                                                    BorderRadius.circular(5),
                                              ),
                                              child: Text(
                                                item.category,
                                                style: const TextStyle(
                                                  fontSize: 10,
                                                  color:
                                                      NexusColors.textSecondary,
                                                ),
                                              ),
                                            ),
                                            if (vars.isNotEmpty) ...[
                                              const SizedBox(width: 5),
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 6,
                                                      vertical: 1,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: NexusColors.cyan
                                                      .withValues(alpha: 0.14),
                                                  borderRadius:
                                                      BorderRadius.circular(5),
                                                ),
                                                child: Text(
                                                  '${vars.length} 变量',
                                                  style: const TextStyle(
                                                    fontSize: 10,
                                                    fontWeight: FontWeight.w600,
                                                    color: NexusColors.cyan,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          item.command,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontFamily: NexusTheme
                                                .monospaceFontFamily,
                                            fontSize: 11.5,
                                            color: NexusColors.emerald
                                                .withValues(alpha: 0.9),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  PopupMenuButton<String>(
                                    icon: const Icon(
                                      Icons.more_vert_rounded,
                                      size: 17,
                                      color: NexusColors.textMuted,
                                    ),
                                    onSelected: (act) {
                                      switch (act) {
                                        case 'copy':
                                          widget.controller.copySensitiveText(
                                            item.command,
                                          );
                                        case 'edit':
                                          _openSnippetEditor(item);
                                        case 'del':
                                          widget.controller.removeSnippet(
                                            item.id,
                                          );
                                      }
                                    },
                                    itemBuilder: (_) => const [
                                      PopupMenuItem(
                                        value: 'copy',
                                        child: Text('复制原始命令'),
                                      ),
                                      PopupMenuItem(
                                        value: 'edit',
                                        child: Text('编辑片段'),
                                      ),
                                      PopupMenuDivider(),
                                      PopupMenuItem(
                                        value: 'del',
                                        child: Text(
                                          '删除',
                                          style: TextStyle(
                                            color: NexusColors.rose,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _SnippetEditorDialog extends StatefulWidget {
  const _SnippetEditorDialog({this.existing});

  final SnippetItem? existing;

  @override
  State<_SnippetEditorDialog> createState() => _SnippetEditorDialogState();
}

class _SnippetEditorDialogState extends State<_SnippetEditorDialog> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _catCtrl;
  late final TextEditingController _cmdCtrl;
  final FocusNode _cmdFocus = FocusNode();
  late bool _autoEnter;

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController(text: widget.existing?.title ?? '');
    _catCtrl = TextEditingController(text: widget.existing?.category ?? '常用');
    _cmdCtrl = TextEditingController(text: widget.existing?.command ?? '');
    _autoEnter = widget.existing?.autoEnter ?? true;
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _catCtrl.dispose();
    _cmdCtrl.dispose();
    _cmdFocus.dispose();
    super.dispose();
  }

  void _insertVariablePlaceholder() {
    final text = _cmdCtrl.text;
    final sel = _cmdCtrl.selection;
    final start = sel.isValid && sel.start >= 0 ? sel.start : text.length;
    final end = sel.isValid && sel.end >= start ? sel.end : start;
    final selected = start < end ? text.substring(start, end) : '';
    final inner = selected.isNotEmpty ? selected : '变量名';
    final inserted = '{{$inner}}';
    final nextText = text.replaceRange(start, end, inserted);

    _cmdCtrl.value = TextEditingValue(
      text: nextText,
      selection: TextSelection(
        baseOffset: start + 2,
        extentOffset: start + 2 + inner.length,
      ),
    );
    _cmdFocus.requestFocus();
    setState(() {});
  }

  void _submit() {
    if (_titleCtrl.text.trim().isEmpty || _cmdCtrl.text.trim().isEmpty) {
      return;
    }
    Navigator.of(context).pop(
      SnippetItem(
        id: widget.existing?.id ?? '',
        title: _titleCtrl.text.trim(),
        command: _cmdCtrl.text,
        category: _catCtrl.text.trim(),
        autoEnter: _autoEnter,
        createdAtMs: widget.existing?.createdAtMs ?? 0,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final detectedVars = SnippetTemplate.extractVariables(_cmdCtrl.text);

    return AlertDialog(
      title: Text(widget.existing == null ? '新建命令片段' : '编辑命令片段'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 340, maxWidth: 460),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _titleCtrl,
                decoration: const InputDecoration(
                  labelText: '名称',
                  hintText: '例如：查看容器日志',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _catCtrl,
                decoration: const InputDecoration(
                  labelText: '分类',
                  hintText: '常用 / 运维巡检 / Docker',
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Text(
                    '命令内容',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: NexusColors.textSecondary,
                    ),
                  ),
                  const Spacer(),
                  InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: _insertVariablePlaceholder,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: NexusColors.cyan.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.data_object_rounded,
                            size: 13,
                            color: NexusColors.cyan,
                          ),
                          SizedBox(width: 4),
                          Text(
                            '插入变量 {{...}}',
                            style: TextStyle(
                              fontSize: 11.2,
                              fontWeight: FontWeight.w600,
                              color: NexusColors.cyan,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              TextField(
                controller: _cmdCtrl,
                focusNode: _cmdFocus,
                maxLines: 4,
                onChanged: (_) => setState(() {}),
                style: TextStyle(
                  fontFamily: NexusTheme.monospaceFontFamily,
                  fontSize: 12.8,
                ),
                decoration: const InputDecoration(
                  hintText:
                      '例如：docker logs -f --tail {{行数:100}} {{容器名}}',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 8),
              if (detectedVars.isEmpty)
                const Text(
                  '提示：用 {{变量名}} 或 {{变量名:默认值}} 声明动态变量，执行前会弹窗填写。',
                  style: TextStyle(
                    fontSize: 11.2,
                    color: NexusColors.textMuted,
                    height: 1.35,
                  ),
                )
              else
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    const Text(
                      '已识别变量:',
                      style: TextStyle(
                        fontSize: 11.2,
                        color: NexusColors.textMuted,
                      ),
                    ),
                    for (final v in detectedVars)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: NexusColors.cyan.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          v.defaultValue.isEmpty
                              ? v.name
                              : '${v.name} = ${v.defaultValue}',
                          style: TextStyle(
                            fontFamily: NexusTheme.monospaceFontFamily,
                            fontSize: 11,
                            color: NexusColors.cyan,
                          ),
                        ),
                      ),
                  ],
                ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '发送到终端后自动回车执行',
                      style: TextStyle(
                        fontSize: 13,
                        color: NexusColors.textSecondary,
                      ),
                    ),
                  ),
                  Switch.adaptive(
                    value: _autoEnter,
                    activeTrackColor: NexusColors.emerald,
                    onChanged: (v) => setState(() => _autoEnter = v),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('保存')),
      ],
    );
  }
}

class _VariableFillResult {
  const _VariableFillResult({
    required this.values,
    required this.renderedCommand,
    required this.autoEnter,
  });

  final Map<String, String> values;
  final String renderedCommand;
  final bool autoEnter;
}

class _SnippetVariablesDialog extends StatefulWidget {
  const _SnippetVariablesDialog({
    required this.item,
    required this.variables,
    required this.initialValues,
    required this.hasActiveSession,
  });

  final SnippetItem item;
  final List<SnippetVariable> variables;
  final Map<String, String> initialValues;
  final bool hasActiveSession;

  @override
  State<_SnippetVariablesDialog> createState() =>
      _SnippetVariablesDialogState();
}

class _SnippetVariablesDialogState extends State<_SnippetVariablesDialog> {
  late final List<TextEditingController> _controllers;
  late final List<FocusNode> _focusNodes;
  late bool _autoEnter;

  @override
  void initState() {
    super.initState();
    _autoEnter = widget.item.autoEnter;
    _controllers = widget.variables.map((v) {
      final remembered = widget.initialValues[v.name];
      final initial = (remembered != null && remembered.isNotEmpty)
          ? remembered
          : v.defaultValue;
      return TextEditingController(text: initial);
    }).toList();
    _focusNodes = List.generate(widget.variables.length, (_) => FocusNode());

    // Focus the first empty field (or the very first field) on open
    final firstEmpty = _controllers.indexWhere((c) => c.text.trim().isEmpty);
    final focusIdx = firstEmpty >= 0 ? firstEmpty : 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _focusNodes.isEmpty) return;
      _focusNodes[focusIdx].requestFocus();
      final ctrl = _controllers[focusIdx];
      if (ctrl.text.isNotEmpty) {
        ctrl.selection = TextSelection(
          baseOffset: 0,
          extentOffset: ctrl.text.length,
        );
      }
    });
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    for (final f in _focusNodes) {
      f.dispose();
    }
    super.dispose();
  }

  Map<String, String> _collectValues() {
    final map = <String, String>{};
    for (var i = 0; i < widget.variables.length; i++) {
      map[widget.variables[i].name] = _controllers[i].text;
    }
    return map;
  }

  void _submit() {
    final values = _collectValues();
    final rendered = SnippetTemplate.render(widget.item.command, values);
    Navigator.of(context).pop(
      _VariableFillResult(
        values: values,
        renderedCommand: rendered,
        autoEnter: _autoEnter,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final preview = SnippetTemplate.render(
      widget.item.command,
      _collectValues(),
      keepUnfilledPlaceholder: true,
    );

    return AlertDialog(
      title: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: NexusColors.cyan.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(9),
            ),
            child: const Icon(
              Icons.data_object_rounded,
              size: 17,
              color: NexusColors.cyan,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              widget.item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16),
            ),
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 340, maxWidth: 460),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < widget.variables.length; i++) ...[
                if (i > 0) const SizedBox(height: 12),
                TextField(
                  controller: _controllers[i],
                  focusNode: _focusNodes[i],
                  textInputAction: i == widget.variables.length - 1
                      ? TextInputAction.done
                      : TextInputAction.next,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) {
                    if (i + 1 < _focusNodes.length) {
                      _focusNodes[i + 1].requestFocus();
                    } else {
                      _submit();
                    }
                  },
                  style: TextStyle(
                    fontFamily: NexusTheme.monospaceFontFamily,
                    fontSize: 13,
                  ),
                  decoration: InputDecoration(
                    labelText: widget.variables[i].name,
                    hintText: widget.variables[i].defaultValue.isNotEmpty
                        ? '默认: ${widget.variables[i].defaultValue}'
                        : '请输入 ${widget.variables[i].name}',
                  ),
                ),
              ],
              const SizedBox(height: 14),
              const Text(
                '命令预览',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: NexusColors.textMuted,
                ),
              ),
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: NexusColors.bgSurface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: NexusColors.borderSubtle),
                ),
                child: SelectableText(
                  preview,
                  style: TextStyle(
                    fontFamily: NexusTheme.monospaceFontFamily,
                    fontSize: 12,
                    height: 1.4,
                    color: NexusColors.emerald,
                  ),
                ),
              ),
              if (widget.hasActiveSession) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '发送后自动回车执行',
                        style: TextStyle(
                          fontSize: 12.8,
                          color: NexusColors.textSecondary,
                        ),
                      ),
                    ),
                    Switch.adaptive(
                      value: _autoEnter,
                      activeTrackColor: NexusColors.emerald,
                      onChanged: (v) => setState(() => _autoEnter = v),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _submit,
          icon: Icon(
            widget.hasActiveSession
                ? Icons.send_rounded
                : Icons.content_copy_rounded,
            size: 16,
          ),
          label: Text(widget.hasActiveSession ? '发送到终端' : '复制命令'),
        ),
      ],
    );
  }
}
