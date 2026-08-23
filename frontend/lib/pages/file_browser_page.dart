import 'dart:io';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:open_file/open_file.dart';

import '../readers/stream_txt_reader_page.dart';
import '../readers/epub_reader_page.dart';
import '../services/sync_database_service.dart';

enum SortField {
  name('文件名'),
  createdTime('创建时间'),
  modifiedTime('修改时间');

  final String label;
  const SortField(this.label);
}

enum SortOrder {
  ascending('正序'),
  descending('倒序');

  final String label;
  const SortOrder(this.label);
}

class FileBrowserPage extends StatefulWidget {
  final Dio dio;

  const FileBrowserPage({Key? key, required this.dio}) : super(key: key);

  @override
  State<FileBrowserPage> createState() => _FileBrowserPageState();
}

class _FileBrowserPageState extends State<FileBrowserPage> {
  String _currentPath = "/";
  List<dynamic> _items = [];
  bool _isLoading = false;
  
  // 排序状态控制
  SortField _currentSortField = SortField.name;
  SortOrder _currentSortOrder = SortOrder.ascending;

  @override
  void initState() {
    super.initState();
    _fetchDirectory(_currentPath);
  }

  Future<void> _fetchDirectory(String path) async {
    setState(() => _isLoading = true);
    try {
      final res = await widget.dio.get('/api/files/list', queryParameters: {'path': path});
      if (res.statusCode == 200 && res.data['code'] == 0) {
        setState(() {
          _currentPath = path;
          _items = res.data['data'] ?? [];
        });
      } else {
        _showToast(res.data['msg'] ?? '获取目录失败');
      }
    } catch (e) {
      _showToast('网络请求异常: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // 排序处理核心：保持文件夹置顶，子项按选定规则排序
  List<dynamic> get _sortedItems {
    final list = List<dynamic>.from(_items);
    list.sort((a, b) {
      final bool isDirA = a['is_dir'] ?? false;
      final bool isDirB = b['is_dir'] ?? false;

      // 1. 文件夹永远排在文件前面
      if (isDirA && !isDirB) return -1;
      if (!isDirA && isDirB) return 1;

      // 2. 根据选定的字段比较
      int comparison = 0;
      switch (_currentSortField) {
        case SortField.name:
          final String nameA = a['name']?.toString().toLowerCase() ?? '';
          final String nameB = b['name']?.toString().toLowerCase() ?? '';
          comparison = nameA.compareTo(nameB);
          break;
        case SortField.createdTime:
          final int tA = a['created_at'] ?? 0;
          final int tB = b['created_at'] ?? 0;
          comparison = tA.compareTo(tB);
          break;
        case SortField.modifiedTime:
          final int tA = a['updated_at'] ?? a['modified_at'] ?? 0;
          final int tB = b['updated_at'] ?? b['modified_at'] ?? 0;
          comparison = tA.compareTo(tB);
          break;
      }

      // 3. 应用正序或倒序
      return _currentSortOrder == SortOrder.ascending ? comparison : -comparison;
    });
    return list;
  }

  void _showSortBottomSheet() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('排序方式', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                        TextButton.icon(
                          onPressed: () {
                            setState(() {
                              _currentSortOrder = _currentSortOrder == SortOrder.ascending
                                  ? SortOrder.descending
                                  : SortOrder.ascending;
                            });
                            setModalState(() {});
                          },
                          icon: Icon(
                            _currentSortOrder == SortOrder.ascending
                                ? Icons.arrow_upward
                                : Icons.arrow_downward,
                            size: 18,
                          ),
                          label: Text(_currentSortOrder.label),
                        ),
                      ],
                    ),
                    const Divider(),
                    ...SortField.values.map((field) {
                      final isSelected = _currentSortField == field;
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          field == SortField.name
                              ? Icons.sort_by_alpha
                              : (field == SortField.createdTime ? Icons.schedule : Icons.edit_calendar),
                          color: isSelected ? Theme.of(context).primaryColor : Colors.grey,
                        ),
                        title: Text(
                          field.label,
                          style: TextStyle(
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                            color: isSelected ? Theme.of(context).primaryColor : null,
                          ),
                        ),
                        trailing: isSelected ? Icon(Icons.check, color: Theme.of(context).primaryColor) : null,
                        onTap: () {
                          setState(() => _currentSortField = field);
                          Navigator.pop(ctx);
                        },
                      );
                    }).toList(),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _onItemTap(Map<String, dynamic> item) {
    final bool isDir = item['is_dir'] ?? false;
    final String name = item['name'] ?? '';
    final String fullPath = _currentPath == "/" ? "/$name" : "$_currentPath/$name";

    if (isDir) {
      _fetchDirectory(fullPath);
    } else {
      _downloadAndOpenFile(fullPath, name);
    }
  }

  Future<void> _downloadAndOpenFile(String remotePath, String fileName) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final localDir = Directory(p.join(appDir.path, 'books'));
      if (!localDir.existsSync()) {
        localDir.createSync(recursive: true);
      }

      final savePath = p.join(localDir.path, fileName);
      final file = File(savePath);

      // 如果尚未缓存，则发起远程下载
      if (!file.existsSync()) {
        _showLoadingDialog('正在从 NAS 下载...');
        await widget.dio.download(
          '/api/files/download',
          savePath,
          queryParameters: {'path': remotePath},
        );
        if (mounted) Navigator.pop(context); // 关闭 loading 弹窗
      }

      // 更新本地缓存标识集合
      setState(() {
        _cachedFileNames.add(fileName);
      });

      final ext = p.extension(fileName).toLowerCase();
      final title = p.basenameWithoutExtension(fileName);

      if (ext == '.txt') {
        if (!mounted) return;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (ctx) => StreamTxtReaderPage(
              file: file,
              bookTitle: title,
              dio: widget.dio,
            ),
          ),
        ).then((_) => _syncLocalCachedFiles());
      } else if (ext == '.epub') {
        if (!mounted) return;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (ctx) => EpubReaderPage(
              file: file,
              bookTitle: title,
              dio: widget.dio,
            ),
          ),
        ).then((_) => _syncLocalCachedFiles());
      } else {
        OpenFile.open(savePath);
      }
    } catch (e) {
      if (mounted && Navigator.canPop(context)) {
        Navigator.pop(context);
      }
      _showToast('打开或下载文件失败: $e');
    }
  }

  void _navigateBack() {
    if (_currentPath == "/" || _currentPath.isEmpty) return;
    final parts = _currentPath.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.isNotEmpty) {
      parts.removeLast();
      final parent = parts.isEmpty ? "/" : "/${parts.join('/')}";
      _fetchDirectory(parent);
    }
  }

  void _showLoadingDialog(String msg) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(width: 20),
              Text(msg),
            ],
          ),
        ),
      ),
    );
  }

  void _showToast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final sorted = _sortedItems;

    return WillPopScope(
      onWillPop: () async {
        if (_currentPath != "/") {
          _navigateBack();
          return false;
        }
        return true;
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            _currentPath == "/" ? "NAS 文件根目录" : p.basename(_currentPath),
            style: const TextStyle(fontSize: 16),
          ),
          leading: _currentPath != "/"
              ? IconButton(icon: const Icon(Icons.arrow_back), onPressed: _navigateBack)
              : null,
          actions: [
            IconButton(
              icon: const Icon(Icons.sort),
              tooltip: '排序',
              onPressed: _showSortBottomSheet,
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: '刷新',
              onPressed: () => _fetchDirectory(_currentPath),
            ),
          ],
        ),
        body: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : sorted.isEmpty
                ? const Center(child: Text("当前目录为空", style: TextStyle(color: Colors.grey)))
                : ListView.separated(
                    itemCount: sorted.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final item = sorted[index];
                      final bool isDir = item['is_dir'] ?? false;
                      final String name = item['name'] ?? '未知文件';
                      final ext = p.extension(name).toLowerCase();

                      IconData iconData = Icons.insert_drive_file;
                      Color iconColor = Colors.grey;

                      if (isDir) {
                        iconData = Icons.folder;
                        iconColor = Colors.amber;
                      } else if (ext == '.txt') {
                        iconData = Icons.description;
                        iconColor = Colors.blue;
                      } else if (ext == '.epub') {
                        iconData = Icons.menu_book;
                        iconColor = Colors.green;
                      }

                      return ListTile(
                        leading: Icon(iconData, color: iconColor),
                        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          isDir
                              ? '文件夹'
                              : '${((item['size'] ?? 0) / 1024 / 1024).toStringAsFixed(2)} MB',
                          style: const TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                        trailing: const Icon(Icons.chevron_right, size: 18, color: Colors.grey),
                        onTap: () => _onItemTap(item),
                      );
                    },
                  ),
      ),
    );
  }
}