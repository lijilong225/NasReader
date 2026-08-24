import 'dart:io';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../readers/stream_txt_reader_page.dart';
import '../readers/epub_reader_page.dart';
import '../services/progress_sync_service.dart';
import '../services/app_logger.dart';

enum FileSortType {
  nameAsc('名称 (A-Z)'),
  nameDesc('名称 (Z-A)'),
  timeDesc('时间 (从新到旧)'),
  timeAsc('时间 (从旧到新)'),
  sizeAsc('体积 (从小到大)'),
  sizeDesc('体积 (从大到小)'),
  type('按文件类型');

  final String label;
  const FileSortType(this.label);
}

class NasFileItem {
  final String name;
  final String path;
  final bool isDir;
  final int size;
  final String? bookId;
  final int modTime; // 毫秒时间戳

  NasFileItem({
    required this.name,
    required this.path,
    required this.isDir,
    required this.size,
    this.bookId,
    required this.modTime,
  });

  factory NasFileItem.fromJson(Map<String, dynamic> json) {
    String rawPath = (json['path'] ?? '').toString();
    if (!rawPath.startsWith('/')) {
      rawPath = '/$rawPath';
    }

    final rawModTime = json['mod_time'] ?? json['ModTime'] ?? 0;
    final modTime = (rawModTime is num)
        ? rawModTime.toInt()
        : (int.tryParse(rawModTime.toString()) ?? 0);

    return NasFileItem(
      name: json['name'] ?? '',
      path: rawPath,
      isDir: json['is_dir'] == true,
      size: (json['size'] as num?)?.toInt() ?? 0,
      bookId: json['book_id']?.toString(),
      modTime: modTime,
    );
  }
}

class FileBrowserPage extends StatefulWidget {
  final Dio dio;

  const FileBrowserPage({super.key, required this.dio});

  @override
  State<FileBrowserPage> createState() => FileBrowserPageState();
}

class FileBrowserPageState extends State<FileBrowserPage> {
  static const String _sortPrefKey = 'nas_file_sort_type';

  String _currentPath = '/';
  List<NasFileItem> _items = [];
  bool _isLoading = true;
  String? _errorMessage;

  // 默认排序：按时间从新到旧
  FileSortType _currentSort = FileSortType.timeDesc;

  final Set<String> _cachedFileNames = {};

  @override
  void initState() {
    super.initState();
    _initAndLoad();
  }

  Future<void> _initAndLoad() async {
    await _loadSavedSortPreference();
    await _loadDirectory(_currentPath);
  }

  // 1. 读取上次持久化的排序规则
  Future<void> _loadSavedSortPreference() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedSortName = prefs.getString(_sortPrefKey);
      if (savedSortName != null) {
        _currentSort = FileSortType.values.firstWhere(
          (e) => e.name == savedSortName,
          orElse: () => FileSortType.timeDesc,
        );
      }
    } catch (_) {}
  }

  // 2. 切换并持久化排序规则
  Future<void> _changeSort(FileSortType newSort) async {
    setState(() {
      _currentSort = newSort;
      _applySort();
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_sortPrefKey, newSort.name);
    } catch (e) {
      AppLogger.log('❌ 保存排序配置失败: $e');
    }
  }

  // 3. 排序执行逻辑（文件夹置顶）
  void _applySort() {
    _items.sort((a, b) {
      if (a.isDir && !b.isDir) return -1;
      if (!a.isDir && b.isDir) return 1;

      switch (_currentSort) {
        case FileSortType.nameAsc:
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case FileSortType.nameDesc:
          return b.name.toLowerCase().compareTo(a.name.toLowerCase());
        case FileSortType.timeDesc:
          final comp = b.modTime.compareTo(a.modTime);
          return comp != 0 ? comp : a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case FileSortType.timeAsc:
          final comp = a.modTime.compareTo(b.modTime);
          return comp != 0 ? comp : a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case FileSortType.sizeAsc:
          final comp = a.size.compareTo(b.size);
          return comp != 0 ? comp : a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case FileSortType.sizeDesc:
          final comp = b.size.compareTo(a.size);
          return comp != 0 ? comp : a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case FileSortType.type:
          final extA = p.extension(a.name).toLowerCase();
          final extB = p.extension(b.name).toLowerCase();
          final comp = extA.compareTo(extB);
          return comp != 0 ? comp : a.name.toLowerCase().compareTo(b.name.toLowerCase());
      }
    });
  }

  Future<void> _updateCachedFiles() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final booksDir = Directory(p.join(appDir.path, 'books'));
      if (!booksDir.existsSync()) {
        booksDir.createSync(recursive: true);
      }

      final files = booksDir.listSync();
      _cachedFileNames.clear();
      for (var f in files) {
        if (f is File && f.lengthSync() > 0) {
          _cachedFileNames.add(p.basename(f.path));
        }
      }
    } catch (e) {
      AppLogger.log('❌ 扫描本地已缓存文件失败: $e');
    }
  }

  Future<void> _loadDirectory(String targetPath) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await _updateCachedFiles();

      final res = await widget.dio.get(
        '/api/v1/files/browse',
        queryParameters: {'path': targetPath},
      );

      AppLogger.log('📂 请求目录: ${res.data}');

      if (res.statusCode == 200 && res.data != null) {
        List<dynamic> rawList = [];

        if (res.data is Map && res.data['items'] is List) {
          rawList = res.data['items'];
        } else if (res.data is Map && res.data['data'] is List) {
          rawList = res.data['data'];
        } else if (res.data is List) {
          rawList = res.data;
        }

        AppLogger.log('📂 成功加载目录 $targetPath, 解析到文件数: ${rawList.length}');

        _items = rawList
            .map((e) => NasFileItem.fromJson(Map<String, dynamic>.from(e)))
            .toList();

        _applySort();

        if (mounted) {
          setState(() {
            _currentPath = targetPath;
            _isLoading = false;
          });
        }
      } else {
        throw Exception('获取文件列表失败: ${res.statusCode}');
      }
    } catch (e) {
      AppLogger.log('❌ 加载目录失败: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = '加载失败: $e';
        });
      }
    }
  }

  Future<void> _handleItemTap(NasFileItem item) async {
    if (item.isDir) {
      _loadDirectory(item.path);
      return;
    }

    final ext = p.extension(item.name).toLowerCase();
    if (ext != '.txt' && ext != '.epub') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('暂不支持此格式阅读，目前支持 TXT / EPUB')),
      );
      return;
    }

    final appDir = await getApplicationDocumentsDirectory();
    final localFilePath = p.join(appDir.path, 'books', item.name);
    final targetFile = File(localFilePath);

    if (targetFile.existsSync() && targetFile.lengthSync() > 0) {
      _openReader(targetFile, item);
      return;
    }

    final ValueNotifier<double> downloadProgress = ValueNotifier<double>(0.0);
    final CancelToken cancelToken = CancelToken();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, result) {
            cancelToken.cancel('用户取消下载');
          },
          child: Dialog(
            backgroundColor: Theme.of(context).cardColor,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 48,
                    height: 48,
                    child: CircularProgressIndicator(strokeWidth: 3.5),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    '正在下载《${p.basenameWithoutExtension(item.name)}》',
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                  const SizedBox(height: 12),
                  ValueListenableBuilder<double>(
                    valueListenable: downloadProgress,
                    builder: (context, progress, _) {
                      return Column(
                        children: [
                          LinearProgressIndicator(
                            value: progress > 0 ? progress : null,
                            minHeight: 6,
                            borderRadius: BorderRadius.circular(3),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            progress > 0
                                ? '${(progress * 100).toStringAsFixed(1)}%'
                                : '正在从 NAS 建立传输连接...',
                            style: const TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed: () {
                      cancelToken.cancel('用户取消');
                      Navigator.pop(ctx);
                    },
                    child: const Text('取消下载'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );

    try {
      await widget.dio.download(
        '/api/v1/files/download',
        localFilePath,
        queryParameters: {'path': item.path},
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) {
          if (total > 0) {
            downloadProgress.value = (received / total).clamp(0.0, 1.0);
          }
        },
      );

      if (mounted && Navigator.canPop(context)) {
        Navigator.pop(context);
      }

      setState(() {
        _cachedFileNames.add(item.name);
      });

      if (mounted) {
        _openReader(targetFile, item);
      }
    } catch (e) {
      if (mounted && Navigator.canPop(context)) {
        Navigator.pop(context);
      }
      if (!CancelToken.isCancel(e as DioException)) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('下载失败: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _openReader(File file, NasFileItem item) async {
    final progressList = await ProgressSyncService.getAllLocalProgress();
    final savedRecord = progressList.firstWhere(
      (p) => p.bookId == item.name,
      orElse: () => BookProgress(
        bookId: item.name,
        title: p.basenameWithoutExtension(item.name),
        filePath: item.path,
        progress: 0.0,
        locator: '',
        clientUpdatedAt: 0,
      ),
    );

    final ext = p.extension(item.name).toLowerCase();
    if (!mounted) return;
    final initialOffset = savedRecord.txtByteOffset ?? 0;
    final initialCfi = savedRecord.epubCfi;
    if (ext == '.txt') {
      Navigator.push(
        context,
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 120),
          pageBuilder: (context, animation, secondaryAnimation) => StreamTxtReaderPage(
            bookId: item.name,
            file: file,
            title: p.basenameWithoutExtension(item.name),
            initialByteOffset: initialOffset,
            onProgressChanged: (byteOffset, progress) {
              ProgressSyncService.updateProgress(
                dio: widget.dio,
                bookId: item.name,
                title: p.basenameWithoutExtension(item.name),
                filePath: item.path,
                progressPercent: progress,
                locator: byteOffset.toString(),
              );
            },
          ),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(opacity: animation, child: child);
          },
        ),
      ).then((_) => _updateCachedFiles());
    } else if (ext == '.epub') {
      Navigator.push(
        context,
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 120),
          pageBuilder: (context, animation, secondaryAnimation) => EpubReaderPage(
            bookId: item.name,
            file: file,
            title: p.basenameWithoutExtension(item.name),
            initialCfi: initialCfi,
            onProgressChanged: (cfi, progress) {
              ProgressSyncService.updateProgress(
                dio: widget.dio,
                bookId: item.name,
                title: p.basenameWithoutExtension(item.name),
                filePath: item.path,
                progressPercent: progress,
                locator: cfi,
              );
            },
          ),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(opacity: animation, child: child);
          },
        ),
      ).then((_) => _updateCachedFiles());
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
    final isRoot = _currentPath == '/' || _currentPath.isEmpty;

    return PopScope(
      canPop: isRoot,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && !isRoot) {
          final parent = p.dirname(_currentPath);
          _loadDirectory(parent.isEmpty ? '/' : parent);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            isRoot ? 'NAS 书库' : p.basename(_currentPath),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          leading: !isRoot
              ? IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () {
                    final parent = p.dirname(_currentPath);
                    _loadDirectory(parent.isEmpty ? '/' : parent);
                  },
                )
              : null,
          actions: [
            PopupMenuButton<FileSortType>(
              icon: const Icon(Icons.sort),
              tooltip: '排序方式',
              onSelected: _changeSort,
              itemBuilder: (context) => FileSortType.values.map((type) {
                final isSelected = type == _currentSort;
                return PopupMenuItem<FileSortType>(
                  value: type,
                  child: Row(
                    children: [
                      Icon(
                        isSelected ? Icons.check : Icons.radio_button_unchecked,
                        size: 18,
                        color: isSelected ? Theme.of(context).primaryColor : Colors.grey,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        type.label,
                        style: TextStyle(
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                          color: isSelected ? Theme.of(context).primaryColor : null,
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: '刷新当前目录',
              onPressed: () => _loadDirectory(_currentPath),
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
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.redAccent),
              const SizedBox(height: 12),
              Text(_errorMessage!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
                onPressed: () => _loadDirectory(_currentPath),
              ),
            ],
          ),
        ),
      );
    }

    if (_items.isEmpty) {
      return const Center(
        child: Text('当前目录为空', style: TextStyle(color: Colors.grey)),
      );
    }

    return RefreshIndicator(
      onRefresh: () => _loadDirectory(_currentPath),
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _items.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final item = _items[index];
          final ext = p.extension(item.name).toLowerCase();
          final isCached = !item.isDir && _cachedFileNames.contains(item.name);

          IconData iconData = Icons.insert_drive_file_outlined;
          Color iconColor = Colors.grey;

          if (item.isDir) {
            iconData = Icons.folder;
            iconColor = Colors.amber.shade700;
          } else if (ext == '.epub') {
            iconData = Icons.menu_book;
            iconColor = Colors.green;
          } else if (ext == '.txt') {
            iconData = Icons.description;
            iconColor = Colors.blue;
          }

          return ListTile(
            leading: Icon(iconData, color: iconColor, size: 28),
            title: Row(
              children: [
                Expanded(
                  child: Text(
                    item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                ),
                if (isCached)
                  Container(
                    margin: const EdgeInsets.only(left: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: 0.15),
                      border: Border.all(color: Colors.green, width: 0.8),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(
                      '已缓存',
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.green,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
              ],
            ),
            subtitle: item.isDir
                ? const Text('文件夹', style: TextStyle(fontSize: 12, color: Colors.grey))
                : Text(
                    _formatSize(item.size),
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
            trailing: Icon(
              item.isDir
                  ? Icons.chevron_right
                  : (isCached ? Icons.check_circle_outline : Icons.cloud_download_outlined),
              size: 20,
              color: isCached ? Colors.green : Colors.grey,
            ),
            onTap: () => _handleItemTap(item),
          );
        },
      ),
    );
  }
}