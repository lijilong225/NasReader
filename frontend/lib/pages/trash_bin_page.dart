import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:nas_reader/core/network_client.dart';
import 'package:path/path.dart' as p;

import '../core/book_format.dart';
import '../services/app_logger.dart';
import 'file_browser_page.dart' show NasFileItem;

/// NAS 垃圾箱浏览页：只读地列出 .trashBin 下的目录与书籍
class TrashBinPage extends StatefulWidget {
  final Dio? dio;

  const TrashBinPage({super.key, this.dio});

  @override
  State<TrashBinPage> createState() => TrashBinPageState();
}

class TrashBinPageState extends State<TrashBinPage> {
  static const String _trashRoot = '/.trashBin';

  late Dio _dio;
  String _currentPath = _trashRoot;
  List<NasFileItem> _items = [];
  bool _isLoading = true;
  String? _errorMessage;

  bool get _isRoot => _currentPath == _trashRoot;

  @override
  void initState() {
    super.initState();
    _dio = widget.dio ?? NetworkClient.getDio();
    _loadDirectory(_currentPath, prune: true);
  }

  // NAS 文件管理器可能直接删掉垃圾箱里的文件，留下空目录，进入时让后端清一次
  Future<void> _pruneTrashBin() async {
    try {
      await _dio.post('/api/v1/files/trash/refresh');
    } catch (e) {
      AppLogger.log('刷新垃圾箱失败: $e');
    }
  }

  Future<void> _loadDirectory(String targetPath, {bool prune = false}) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    if (prune) await _pruneTrashBin();

    try {
      final resp = await _dio.get(
        '/api/v1/files/browse',
        queryParameters: {'path': targetPath},
      );

      final data = resp.data;
      List rawList;
      if (data is Map && data['items'] is List) {
        rawList = data['items'] as List;
      } else if (data is Map && data['data'] is List) {
        rawList = data['data'] as List;
      } else if (data is List) {
        rawList = data;
      } else {
        rawList = const [];
      }

      final items = rawList
          .whereType<Map>()
          .map((e) => NasFileItem.fromJson(Map<String, dynamic>.from(e)))
          .toList();

      // 目录优先，其余按名称排序，便于在扁平列表中定位
      items.sort((a, b) {
        if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

      if (!mounted) return;
      setState(() {
        _currentPath = targetPath;
        _items = items;
        _isLoading = false;
      });
    } catch (e) {
      AppLogger.log('加载垃圾箱目录失败: $targetPath -> $e');
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = '无法加载垃圾箱内容';
      });
    }
  }

  void _goUp() {
    if (_isRoot) return;
    final parent = p.dirname(_currentPath);
    _loadDirectory(parent.isEmpty ? _trashRoot : parent);
  }

  Future<void> _confirmRestore(NasFileItem item) async {
    final title = p.basenameWithoutExtension(item.name);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('恢复到书库'),
        content: Text('确定要把《$title》恢复到它在书库中的原始目录吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );

    if (confirm != true || !mounted) return;

    try {
      final resp = await _dio.post(
        '/api/v1/files/trash/restore',
        data: {'path': item.path},
      );
      if (!mounted) return;
      final restored = (resp.data is Map ? resp.data['restored_path'] : null)?.toString();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            restored == null || restored.isEmpty
                ? '已恢复《$title》'
                : '已恢复到 ${p.dirname(restored)}',
          ),
        ),
      );
      await _loadDirectory(_currentPath);
    } catch (e) {
      AppLogger.log('从垃圾箱恢复失败: ${item.path} -> $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('恢复失败，请检查网络或服务端权限'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  String _formatSize(int bytes) {
    if (bytes <= 0) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _isRoot,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _goUp();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_isRoot ? '垃圾箱' : p.basename(_currentPath)),
          leading: _isRoot
              ? null
              : IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: _goUp,
                ),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _isLoading
                  ? null
                  : () => _loadDirectory(_currentPath, prune: true),
            ),
          ],
        ),
        body: _buildContent(),
      ),
    );
  }

  Widget _buildContent() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 48, color: Colors.grey),
            const SizedBox(height: 12),
            Text(_errorMessage!, style: const TextStyle(color: Colors.grey)),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () => _loadDirectory(_currentPath),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }

    if (_items.isEmpty) {
      return const Center(
        child: Text('垃圾箱是空的', style: TextStyle(color: Colors.grey)),
      );
    }

    return RefreshIndicator(
      onRefresh: () => _loadDirectory(_currentPath, prune: true),
      child: ListView.separated(
        itemCount: _items.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final item = _items[index];
          final ext = p.extension(item.name).toLowerCase();
          final format = item.isDir ? null : BookFormat.fromExtension(ext);
          final isBook = format != null;
          return ListTile(
            leading: Icon(
              item.isDir
                  ? Icons.folder_outlined
                  : (format?.outlinedIcon ?? Icons.insert_drive_file_outlined),
              color: item.isDir ? Colors.amber : Colors.grey,
              size: 28,
            ),
            title: Text(
              item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: item.isDir
                ? const Text('文件夹', style: TextStyle(fontSize: 12, color: Colors.grey))
                : Text(
                    _formatSize(item.size),
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
            trailing: item.isDir
                ? const Icon(Icons.chevron_right, size: 20)
                : (isBook
                    ? IconButton(
                        icon: const Icon(Icons.restore_from_trash_outlined),
                        tooltip: '恢复到书库',
                        onPressed: () => _confirmRestore(item),
                      )
                    : null),
            onTap: item.isDir
                ? () => _loadDirectory(item.path)
                : (isBook ? () => _confirmRestore(item) : null),
          );
        },
      ),
    );
  }
}
