import 'dart:io';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../services/app_logger.dart';
import '../readers/stream_txt_reader_page.dart';
import '../readers/epub_reader_page.dart';

enum SortField { name, modTime, size }
enum SortOrder { ascending, descending }

class FileItem {
  final String name;
  final String path;
  final bool isDir;
  final int size;
  final int modTime; // 毫秒时间戳

  FileItem({
    required this.name,
    required this.path,
    required this.isDir,
    required this.size,
    required this.modTime,
  });

  factory FileItem.fromJson(Map<String, dynamic> json) {
    return FileItem(
      name: json['name']?.toString() ?? '',
      path: json['path']?.toString() ?? '',
      isDir: json['is_dir'] == true || json['isDir'] == true,
      size: (json['size'] as num?)?.toInt() ?? 0,
      modTime: (json['mod_time'] as num?)?.toInt() ?? 0,
    );
  }
}

class FileBrowserPage extends StatefulWidget {
  final Dio dio;

  const FileBrowserPage({super.key, required this.dio});

  @override
  State<FileBrowserPage> createState() => _FileBrowserPageState();
}

class _FileBrowserPageState extends State<FileBrowserPage> {
  String _currentPath = '/';
  List<FileItem> _items = [];
  bool _isLoading = false;
  String? _errorMessage;

  // 排序状态（默认按名称升序）
  SortField _sortField = SortField.name;
  SortOrder _sortOrder = SortOrder.ascending;

  @override
  void initState() {
    super.initState();
    _fetchDirectory(_currentPath);
  }

  void _showToast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  // 对列表执行内存排序（文件夹优先置顶）
  void _applySorting() {
    setState(() {
      _items.sort((a, b) {
        // 1. 文件夹始终排在最前面
        if (a.isDir && !b.isDir) return -1;
        if (!a.isDir && b.isDir) return 1;

        int compareResult = 0;
        switch (_sortField) {
          case SortField.name:
            compareResult = a.name.toLowerCase().compareTo(b.name.toLowerCase());
            break;
          case SortField.modTime:
            compareResult = a.modTime.compareTo(b.modTime);
            break;
          case SortField.size:
            compareResult = a.size.compareTo(b.size);
            break;
        }

        return _sortOrder == SortOrder.ascending ? compareResult : -compareResult;
      });
    });
  }

  Future<void> _fetchDirectory(String path) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final res = await widget.dio.get(
        '/api/v1/files/browse',
        queryParameters: {'path': path},
      );

      AppLogger.log('[FileBrowser] 响应: ${res.data}');

      if (res.statusCode == 200 && res.data != null) {
        List<dynamic> rawList = [];
        if (res.data is Map) {
          if (res.data['items'] is List) {
            rawList = res.data['items'];
          } else if (res.data['data'] is List) {
            rawList = res.data['data'];
          }
        } else if (res.data is List) {
          rawList = res.data;
        }

        _items = rawList
            .map((item) => FileItem.fromJson(Map<String, dynamic>.from(item)))
            .toList();

        _currentPath = res.data is Map && res.data['current_path'] != null
            ? res.data['current_path'].toString()
            : path;

        _applySorting();
      } else {
        final err = res.data?['error'] ?? res.data?['msg'] ?? '获取目录失败';
        _showToast(err);
        setState(() => _errorMessage = err);
      }
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      final serverError = e.response?.data?['error'] ?? e.response?.data?['msg'];
      final err = serverError ?? '网络请求失败 [$status]';
      _showToast(err);
      setState(() => _errorMessage = err);
      AppLogger.log('❌ 获取目录失败: $err');
    } catch (e, stack) {
      final err = '数据解析异常: $e';
      _showToast(err);
      setState(() => _errorMessage = err);
      AppLogger.log('❌ 目录解析崩溃: $e\n$stack');
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  // 弹出排序选择弹窗
  void _showSortDialog() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('文件排序方式', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('文件名'),
                      selected: _sortField == SortField.name,
                      onSelected: (selected) {
                        if (selected) {
                          setModalState(() => _sortField = SortField.name);
                          _applySorting();
                        }
                      },
                    ),
                    ChoiceChip(
                      label: const Text('修改时间'),
                      selected: _sortField == SortField.modTime,
                      onSelected: (selected) {
                        if (selected) {
                          setModalState(() => _sortField = SortField.modTime);
                          _applySorting();
                        }
                      },
                    ),
                    ChoiceChip(
                      label: const Text('文件大小'),
                      selected: _sortField == SortField.size,
                      onSelected: (selected) {
                        if (selected) {
                          setModalState(() => _sortField = SortField.size);
                          _applySorting();
                        }
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Text('排列顺序', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.grey)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.arrow_upward, size: 18),
                        label: const Text('正序 (升序)'),
                        style: OutlinedButton.styleFrom(
                          backgroundColor: _sortOrder == SortOrder.ascending ? Theme.of(context).colorScheme.primaryContainer : null,
                        ),
                        onPressed: () {
                          setModalState(() => _sortOrder = SortOrder.ascending);
                          _applySorting();
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.arrow_downward, size: 18),
                        label: const Text('倒序 (降序)'),
                        style: OutlinedButton.styleFrom(
                          backgroundColor: _sortOrder == SortOrder.descending ? Theme.of(context).colorScheme.primaryContainer : null,
                        ),
                        onPressed: () {
                          setModalState(() => _sortOrder = SortOrder.descending);
                          _applySorting();
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _downloadAndOpenBook(FileItem item) async {
    final fileName = item.name;
    final ext = p.extension(fileName).toLowerCase();

    if (ext != '.txt' && ext != '.epub') {
      _showToast('暂不支持该文件格式');
      return;
    }

    try {
      final appDir = await getApplicationDocumentsDirectory();
      final localDir = Directory(p.join(appDir.path, 'books'));
      if (!localDir.existsSync()) localDir.createSync(recursive: true);

      final savePath = p.join(localDir.path, fileName);
      final targetFile = File(savePath);

      if (!targetFile.existsSync() || targetFile.lengthSync() == 0) {
        _showToast('正在下载: $fileName ...');
        final downloadPath = item.path.startsWith('/') ? item.path : '/${item.path}';
        await widget.dio.download(
          '/api/v1/files/download',
          savePath,
          queryParameters: {'path': downloadPath},
        );
      }

      if (!mounted) return;

      if (ext == '.txt') {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => StreamTxtReaderPage(
              bookId: fileName,
              file: targetFile,
              title: p.basenameWithoutExtension(fileName),
            ),
          ),
        );
      } else if (ext == '.epub') {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => EpubReaderPage(
              bookId: fileName,
              file: targetFile,
              title: p.basenameWithoutExtension(fileName),
            ),
          ),
        );
      }
    } catch (e) {
      _showToast('打开书籍失败: $e');
    }
  }

  bool _canGoBack() => _currentPath != '/' && _currentPath.isNotEmpty;

  void _goBack() {
    if (!_canGoBack()) return;
    final parent = p.dirname(_currentPath);
    _fetchDirectory(parent == '.' ? '/' : parent);
  }

  String _formatDate(int timestamp) {
    if (timestamp <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_canGoBack(),
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _goBack();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            _currentPath == '/' ? 'NAS 书库根目录' : p.basename(_currentPath),
            overflow: TextOverflow.ellipsis,
          ),
          leading: _canGoBack()
              ? IconButton(icon: const Icon(Icons.arrow_back), onPressed: _goBack)
              : null,
          actions: [
            IconButton(
              icon: const Icon(Icons.sort),
              tooltip: '排序',
              onPressed: _showSortDialog,
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: '刷新',
              onPressed: () => _fetchDirectory(_currentPath),
            ),
          ],
        ),
        body: SafeArea(child: _buildBody()),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 56, color: Colors.redAccent),
              const SizedBox(height: 16),
              Text(_errorMessage!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 14)),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
                onPressed: () => _fetchDirectory(_currentPath),
              ),
            ],
          ),
        ),
      );
    }

    if (_items.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.folder_open, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            Text(
              '当前目录为空或未包含 .txt / .epub 书籍\n(路径: $_currentPath)',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey, height: 1.5),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: _items.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final item = _items[index];
        final ext = p.extension(item.name).toLowerCase();
        final dateStr = _formatDate(item.modTime);
        final sizeStr = '${(item.size / 1024).toStringAsFixed(1)} KB';

        return ListTile(
          leading: Icon(
            item.isDir
                ? Icons.folder
                : (ext == '.txt'
                    ? Icons.description
                    : (ext == '.epub' ? Icons.menu_book : Icons.insert_drive_file)),
            color: item.isDir
                ? Colors.amber.shade700
                : (ext == '.epub' ? Colors.green : Colors.blue),
          ),
          title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: item.isDir
              ? (dateStr.isNotEmpty ? Text(dateStr, style: const TextStyle(fontSize: 12, color: Colors.grey)) : null)
              : Text('$sizeStr ${dateStr.isNotEmpty ? "· $dateStr" : ""}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
          onTap: () {
            if (item.isDir) {
              final nextPath = _currentPath == '/' ? '/${item.name}' : '$_currentPath/${item.name}';
              _fetchDirectory(nextPath);
            } else {
              _downloadAndOpenBook(item);
            }
          },
        );
      },
    );
  }
}