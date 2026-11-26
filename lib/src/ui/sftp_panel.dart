import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:nexus_ssh/src/models/ssh_models.dart';
import 'package:nexus_ssh/src/state/app_controller.dart';
import 'package:nexus_ssh/src/ui/app_theme.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class SftpPanel extends StatefulWidget {
  const SftpPanel({
    super.key,
    required this.controller,
    required this.session,
  });

  final AppController controller;
  final TerminalSessionItem session;

  @override
  State<SftpPanel> createState() => _SftpPanelState();
}

class _SftpPanelState extends State<SftpPanel> {
  String _currentPath = '';
  List<SftpEntry> _entries = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadDirectory(widget.session.currentSftpPath);
  }

  @override
  void didUpdateWidget(covariant SftpPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session.id != widget.session.id) {
      _loadDirectory(widget.session.currentSftpPath);
    }
  }

  Future<void> _loadDirectory(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await widget.controller.sftpListDir(
        widget.session.id,
        path: path,
      );
      if (!mounted) return;
      setState(() {
        _currentPath = res.currentPath;
        _entries = res.entries;
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

  void _navigateUp() {
    if (_currentPath.isEmpty || _currentPath == '/') return;
    final trimmed = _currentPath.endsWith('/')
        ? _currentPath.substring(0, _currentPath.length - 1)
        : _currentPath;
    final idx = trimmed.lastIndexOf('/');
    final parent = idx <= 0 ? '/' : trimmed.substring(0, idx);
    _loadDirectory(parent);
  }

  String _joinRemote(String dir, String name) {
    if (dir.isEmpty || dir == '/') return '/$name';
    return dir.endsWith('/') ? '$dir$name' : '$dir/$name';
  }

  Future<void> _promptCreateFolder() async {
    final ctrl = TextEditingController();
    final folderName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建文件夹'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
          decoration: const InputDecoration(hintText: '输入文件夹名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (folderName == null || folderName.isEmpty) return;

    try {
      await widget.controller.sftpMkdir(
        widget.session.id,
        _joinRemote(_currentPath, folderName),
      );
      await _loadDirectory(_currentPath);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _uploadFiles() async {
    try {
      final pickedList = await FilePicker.pickFiles(
        dialogTitle: '选择要上传到当前远程目录的文件',
      );
      if (pickedList.isEmpty) return;

      for (final picked in pickedList) {
        String? localPath = picked.path;
        File? tempStaged;
        if (localPath == null) {
          // Android content:// URI fallback: stage to app temp dir before streaming upload
          final tmpDir = await getTemporaryDirectory();
          tempStaged = File(p.join(tmpDir.path, picked.name));
          await tempStaged.writeAsBytes(await picked.readAsBytes());
          localPath = tempStaged.path;
        }

        try {
          await widget.controller.sftpUpload(
            sessionId: widget.session.id,
            localPath: localPath,
            remotePath: _joinRemote(_currentPath, picked.name),
          );
        } finally {
          if (tempStaged != null && tempStaged.existsSync()) {
            await tempStaged.delete();
          }
        }
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已上传 ${pickedList.length} 个文件')),
      );
      await _loadDirectory(_currentPath);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('上传失败: $e')));
    }
  }

  Future<void> _downloadEntry(SftpEntry entry) async {
    try {
      final isDesktop =
          !kIsWeb &&
          (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

      if (isDesktop) {
        final dirUri = await FilePicker.pickDirectory(
          dialogTitle: '选择保存位置 (${entry.name})',
        );
        if (dirUri == null) return;
        final savePath = p.join(dirUri.toFilePath(), entry.name);
        await widget.controller.sftpDownload(
          sessionId: widget.session.id,
          remotePath: entry.path,
          localPath: savePath,
        );
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已下载至 $savePath')));
      } else {
        // Mobile: stream to temp file first, then export via OS save sheet
        final tmpDir = await getTemporaryDirectory();
        final stagedPath = p.join(tmpDir.path, entry.name);
        await widget.controller.sftpDownload(
          sessionId: widget.session.id,
          remotePath: entry.path,
          localPath: stagedPath,
        );
        final stagedFile = File(stagedPath);
        final bytes = await stagedFile.readAsBytes();
        final savedUri = await FilePicker.saveFile(
          fileName: entry.name,
          bytes: bytes,
        );
        if (stagedFile.existsSync()) {
          await stagedFile.delete();
        }
        if (!mounted || savedUri == null) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已保存 ${entry.name}')));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('下载失败: $e')));
    }
  }

  Future<void> _promptRename(SftpEntry entry) async {
    final ctrl = TextEditingController(text: entry.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (newName == null || newName.isEmpty || newName == entry.name) return;

    try {
      await widget.controller.sftpRename(
        widget.session.id,
        entry.path,
        _joinRemote(_currentPath, newName),
      );
      await _loadDirectory(_currentPath);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _promptChmod(SftpEntry entry) async {
    int mode = entry.permissionsOctal & 0x1FF;
    final octalCtrl = TextEditingController(
      text: mode.toRadixString(8).padLeft(3, '0'),
    );

    final updated = await showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          void toggleBit(int bit) {
            mode ^= bit;
            octalCtrl.text = mode.toRadixString(8).padLeft(3, '0');
            setModalState(() {});
          }

          Widget bitBox(String label, int bit) {
            final on = (mode & bit) != 0;
            return FilterChip(
              label: Text(label, style: const TextStyle(fontSize: 11.5)),
              selected: on,
              onSelected: (_) => toggleBit(bit),
              visualDensity: VisualDensity.compact,
            );
          }

          return AlertDialog(
            title: Text('修改权限 · ${entry.name}'),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: octalCtrl,
                    maxLength: 4,
                    style: TextStyle(
                      fontFamily: NexusTheme.monospaceFontFamily,
                      fontSize: 15,
                    ),
                    decoration: const InputDecoration(
                      labelText: '八进制权限 (如 755 / 644)',
                      counterText: '',
                    ),
                    onChanged: (v) {
                      final parsed = int.tryParse(v.trim(), radix: 8);
                      if (parsed != null) {
                        setModalState(() => mode = parsed & 0xFFF);
                      }
                    },
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '所有者 (Owner)',
                    style: TextStyle(fontSize: 11.5, color: NexusColors.textMuted),
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    children: [
                      bitBox('读取 r', 0x100),
                      bitBox('写入 w', 0x080),
                      bitBox('执行 x', 0x040),
                    ],
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    '用户组 (Group)',
                    style: TextStyle(fontSize: 11.5, color: NexusColors.textMuted),
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    children: [
                      bitBox('读取 r', 0x020),
                      bitBox('写入 w', 0x010),
                      bitBox('执行 x', 0x008),
                    ],
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    '其他用户 (Other)',
                    style: TextStyle(fontSize: 11.5, color: NexusColors.textMuted),
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    children: [
                      bitBox('读取 r', 0x004),
                      bitBox('写入 w', 0x002),
                      bitBox('执行 x', 0x001),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () {
                  final parsed = int.tryParse(octalCtrl.text.trim(), radix: 8);
                  Navigator.of(ctx).pop(parsed ?? mode);
                },
                child: const Text('应用'),
              ),
            ],
          );
        },
      ),
    );

    if (updated == null) return;
    try {
      await widget.controller.sftpChmod(widget.session.id, entry.path, updated);
      await _loadDirectory(_currentPath);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _promptDelete(SftpEntry entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除${entry.isDir ? '目录' : '文件'}'),
        content: Text('确定要永久删除服务器上的「${entry.name}」吗？此操作不可撤销！'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: NexusColors.rose),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (ok != true) return;

    try {
      await widget.controller.sftpDelete(
        widget.session.id,
        entry.path,
        isDir: entry.isDir,
      );
      await _loadDirectory(_currentPath);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  static String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    return '${(mb / 1024).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final transfers = widget.controller.transfersForSession(
          widget.session.id,
        );

        return Column(
          children: [
            // Top Path Bar & Actions
            Container(
              padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
              decoration: const BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: NexusColors.borderSubtle,
                    width: 0.8,
                  ),
                ),
              ),
              child: Row(
                children: [
                  IconButton(
                    tooltip: '返回上级目录',
                    visualDensity: VisualDensity.compact,
                    onPressed: (_currentPath.isEmpty || _currentPath == '/')
                        ? null
                        : _navigateUp,
                    icon: const Icon(Icons.arrow_upward_rounded, size: 17),
                  ),
                  Expanded(
                    child: GestureDetector(
                      onTap: () async {
                        final ctrl = TextEditingController(text: _currentPath);
                        final jump = await showDialog<String>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('跳转到路径'),
                            content: TextField(
                              controller: ctrl,
                              autofocus: true,
                              style: TextStyle(
                                fontFamily: NexusTheme.monospaceFontFamily,
                              ),
                              onSubmitted: (v) =>
                                  Navigator.of(ctx).pop(v.trim()),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.of(ctx).pop(),
                                child: const Text('取消'),
                              ),
                              FilledButton(
                                onPressed: () =>
                                    Navigator.of(ctx).pop(ctrl.text.trim()),
                                child: const Text('前往'),
                              ),
                            ],
                          ),
                        );
                        if (jump != null && jump.isNotEmpty) {
                          _loadDirectory(jump);
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: NexusColors.bgSurface,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          _currentPath.isEmpty ? '...' : _currentPath,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: NexusTheme.monospaceFontFamily,
                            fontSize: 12,
                            color: NexusColors.textPrimary,
                          ),
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '刷新',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _loadDirectory(_currentPath),
                    icon: const Icon(Icons.refresh_rounded, size: 17),
                  ),
                  IconButton(
                    tooltip: '新建文件夹',
                    visualDensity: VisualDensity.compact,
                    onPressed: _promptCreateFolder,
                    icon: const Icon(
                      Icons.create_new_folder_outlined,
                      size: 17,
                    ),
                  ),
                  IconButton(
                    tooltip: '上传文件到当前目录',
                    visualDensity: VisualDensity.compact,
                    onPressed: _uploadFiles,
                    icon: const Icon(
                      Icons.upload_file_rounded,
                      size: 18,
                      color: NexusColors.emerald,
                    ),
                  ),
                ],
              ),
            ),

            // Active Upload / Download Progress Strip
            for (final t in transfers)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                color: NexusColors.bgSurface,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          t.direction == 'upload'
                              ? Icons.arrow_upward_rounded
                              : Icons.arrow_downward_rounded,
                          size: 13,
                          color: t.error != null
                              ? NexusColors.rose
                              : NexusColors.emerald,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            t.fileName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Text(
                          t.error != null
                              ? '失败'
                              : '${(t.fraction * 100).toInt()}%',
                          style: TextStyle(
                            fontFamily: NexusTheme.monospaceFontFamily,
                            fontSize: 11,
                            color: t.error != null
                                ? NexusColors.rose
                                : NexusColors.emerald,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(99),
                      child: LinearProgressIndicator(
                        value: t.fraction,
                        minHeight: 4,
                        backgroundColor: NexusColors.bgCanvas,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          t.error != null
                              ? NexusColors.rose
                              : NexusColors.emerald,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

            // Directory Entries Body
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _error!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 12.5,
                                color: NexusColors.rose,
                              ),
                            ),
                            const SizedBox(height: 12),
                            FilledButton.tonal(
                              onPressed: () => _loadDirectory(''),
                              child: const Text('回到主目录'),
                            ),
                          ],
                        ),
                      ),
                    )
                  : _entries.isEmpty
                  ? const Center(
                      child: Text(
                        '当前目录为空',
                        style: TextStyle(
                          fontSize: 13,
                          color: NexusColors.textMuted,
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      itemCount: _entries.length,
                      itemBuilder: (context, idx) {
                        final entry = _entries[idx];
                        return _SftpEntryTile(
                          entry: entry,
                          sizeLabel: entry.isDir
                              ? '目录'
                              : _formatSize(entry.size),
                          onTap: () {
                            if (entry.isDir || entry.isSymlink) {
                              _loadDirectory(entry.path);
                            } else {
                              _downloadEntry(entry);
                            }
                          },
                          onDownload: entry.isDir
                              ? null
                              : () => _downloadEntry(entry),
                          onChmod: () => _promptChmod(entry),
                          onRename: () => _promptRename(entry),
                          onDelete: () => _promptDelete(entry),
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

class _SftpEntryTile extends StatelessWidget {
  const _SftpEntryTile({
    required this.entry,
    required this.sizeLabel,
    required this.onTap,
    this.onDownload,
    required this.onChmod,
    required this.onRename,
    required this.onDelete,
  });

  final SftpEntry entry;
  final String sizeLabel;
  final VoidCallback onTap;
  final VoidCallback? onDownload;
  final VoidCallback onChmod;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final iconColor = entry.isDir
        ? NexusColors.cyan
        : (entry.isSymlink ? NexusColors.violet : NexusColors.textSecondary);
    final iconData = entry.isDir
        ? Icons.folder_rounded
        : (entry.isSymlink
              ? Icons.subdirectory_arrow_right_rounded
              : Icons.insert_drive_file_outlined);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(iconData, size: 17, color: iconColor),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13.2,
                        fontWeight: FontWeight.w500,
                        color: NexusColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$sizeLabel  ·  ${entry.permissionsRwx} (${entry.octalLabel})',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: NexusTheme.monospaceFontFamily,
                        fontSize: 10.8,
                        color: NexusColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                icon: const Icon(
                  Icons.more_horiz_rounded,
                  size: 17,
                  color: NexusColors.textMuted,
                ),
                onSelected: (act) {
                  switch (act) {
                    case 'dl':
                      onDownload?.call();
                    case 'chmod':
                      onChmod();
                    case 'rename':
                      onRename();
                    case 'del':
                      onDelete();
                  }
                },
                itemBuilder: (_) => [
                  if (onDownload != null)
                    const PopupMenuItem(value: 'dl', child: Text('下载文件')),
                  const PopupMenuItem(value: 'chmod', child: Text('修改权限 (Chmod)')),
                  const PopupMenuItem(value: 'rename', child: Text('重命名')),
                  const PopupMenuDivider(),
                  const PopupMenuItem(
                    value: 'del',
                    child: Text(
                      '删除',
                      style: TextStyle(color: NexusColors.rose),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
