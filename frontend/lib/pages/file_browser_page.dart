import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

// 引入流式 TXT 阅读器与 EPUB 阅读器
import '../readers/stream_txt_reader_page.dart';
import '../readers/epub_reader_page.dart';
import '../services/sync_database_service.dart';

/// 目录节点数据模型
class FileNode {
  final String name;
  final String path;
  final bool isDir;
  final int size;
  final String extension;
  final String bookId;
  final int modTime;

  FileNode({
    required this.name,
    required this.path,
    required this.isDir,
    required this.size,
    required this.extension,
    required this.bookId,
    required this.modTime,
  });

  factory FileNode.fromJson(Map<String, dynamic> json) {
    return FileNode(
      name: json['name'] ?? '',
      path: json['path'] ?? '',
      isDir: json['is_dir'] ?? false,
      size: json['size'] ?? 0,
      extension: json['extension'] ?? '',
      bookId: json['book_id'] ?? '',
      modTime: json['mod_time'] ?? 0,
    );
  }
}

/// 本地沙盒缓存管理器
class LocalBookCacheManager {
  final Dio dio;

  LocalBookCacheManager(this.dio);

  Future<Directory> _getCacheDirectory() async {
    final appDocDir = await getApplicationDocumentsDirectory();
    final cacheDir = Directory(p.join(appDocDir.path, 'CachedBooks'));
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }
    return cacheDir;
  }

  Future<File> getLocalFile(String bookId, String extension) async {
    final cacheDir = await _getCacheDirectory();
    return File(p.join(cacheDir.path, '$bookId.$extension'));
  }

  Future<bool> isBookCached(String bookId, String extension) async {
    if (bookId.isEmpty) return false;
    final file = await getLocalFile(bookId, extension);
    return await file.exists();
  }

  Future<File> downloadAndCacheBook({
    required String remoteRelPath,
    required String bookId,
    required String extension,
    required ProgressCallback onProgress,
    CancelToken? cancelToken,
  }) async {
    final localFile = await getLocalFile(bookId, extension);
    final tempFilePath = '${localFile.path}.tmp';

    await dio.download(
      '/api/v1/files/download',
      tempFilePath,
      queryParameters: {'path': remoteRelPath},
      onReceiveProgress: onProgress,
      cancelToken: cancelToken,
    );

    final tempFile = File(tempFilePath);
    return await tempFile.rename(localFile.path);
  }

  Future<void> deleteCache(String bookId, String extension) async {
    final file = await getLocalFile(bookId, extension);
    if (await file.exists()) {
      await file.delete();
    }
  }
}

/// 文件浏览器主页面
class FileBrowserPage extends StatefulWidget {
  final Dio dio;
  final String deviceId;

  const FileBrowserPage({
    super.key,
    required this.dio,
    this.deviceId = 'flutter_client_01',
  });

  @override
  State<FileBrowserPage> createState() => _FileBrowserPageState();
}

class _FileBrowserPageState extends State<FileBrowserPage> {
  late LocalBookCacheManager _cacheManager;
  late SyncDatabaseService _syncService;

  String _currentPath = '/';
  List<FileNode> _items = [];
  bool _isLoading = false;
  String? _errorMessage;

  final Map<String, bool> _cachedStatusMap = {};

  @override
  void initState() {
    super.initState();
    _cacheManager = LocalBookCacheManager(widget.dio);
    _syncService = SyncDatabaseService(widget.dio);
    _loadDirectory(_currentPath);
  }

  @override
  void dispose() {
    _syncService.dispose();
    super.dispose();
  }

  Future<void> _loadDirectory(String path) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final response = await widget.dio.get(
        '/api/v1/files/browse',
        queryParameters: {'path': path},
      );

      final List rawItems = response.data['items'] ?? [];
      final items = rawItems.map((e) => FileNode.fromJson(e)).toList();

      items.sort((a, b) {
        if (a.isDir && !b.isDir) return -1;
        if (!a.isDir && b.isDir) return 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

      for (var item in items) {
        if (!item.isDir && item.bookId.isNotEmpty) {
          _cachedStatusMap[item.bookId] =
              await _cacheManager.isBookCached(item.bookId, item.extension);
        }
      }

      setState(() {
        _currentPath = response.data['current_path'] ?? path;
        _items = items;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
        _errorMessage = '加载目录失败: $e';
      });
    }
  }

  void _navigateUp() {
    if (_currentPath == '/' || _currentPath == '.') return;
    final parent = p.dirname(_currentPath);
    _loadDirectory(parent == '.' ? '/' : parent);
  }

  void _onItemTapped(FileNode item) async {
    if (item.isDir) {
      _loadDirectory(item.path);
    } else {
      final isCached = _cachedStatusMap[item.bookId] ?? false;
      if (isCached) {
        final file = await _cacheManager.getLocalFile(item.bookId, item.extension);
        _openReader(file, item);
      } else {
        _showDownloadDialog(item);
      }
    }
  }

  void _showDownloadDialog(FileNode item) {
    double progress = 0.0;
    int receivedBytes = 0;
    int totalBytes = item.size;
    final cancelToken = CancelToken();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('缓存书籍到本地'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 16),
                  LinearProgressIndicator(value: progress > 0 ? progress : null),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('${(progress * 100).toStringAsFixed(1)}%'),
                      Text(
                        '${_formatSize(receivedBytes)} / ${_formatSize(totalBytes)}',
                        style: const TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                    ],
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    cancelToken.cancel();
                    Navigator.pop(dialogCtx);
                  },
                  child: const Text('取消'),
                ),
              ],
            );
          },
        );
      },
    );

    _cacheManager.downloadAndCacheBook(
      remoteRelPath: item.path,
      bookId: item.bookId,
      extension: item.extension,
      cancelToken: cancelToken,
      onProgress: (received, total) {
        if (!mounted) return;
        receivedBytes = received;
        if (total > 0) {
          totalBytes = total;
          progress = received / total;
        }
        (context as Element).markNeedsBuild();
      },
    ).then((file) {
      if (Navigator.canPop(context)) {
        Navigator.pop(context);
      }
      setState(() {
        _cachedStatusMap[item.bookId] = true;
      });
      _openReader(file, item);
    }).catchError((err) {
      if (Navigator.canPop(context)) {
        Navigator.pop(context);
      }
      if (!cancelToken.isCancelled) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('下载失败: $err')),
        );
      }
    });
  }

  Future<void> _openReader(File file, FileNode item) async {
    Map<String, dynamic>? locatorData;

    final localRec = await _syncService.getLocalProgress(item.bookId);
    if (localRec != null) {
      try {
        locatorData = jsonDecode(localRec.locator);
      } catch (_) {}
    }

    try {
      final res = await widget.dio.get('/api/v1/sync/progress/${item.bookId}');
      if (res.data != null && res.data['locator'] != null) {
        final remoteUpdated = res.data['client_updated_at'] as int? ?? 0;
        if (localRec == null || remoteUpdated > localRec.clientUpdatedAt) {
          final rawLocator = res.data['locator'];
          locatorData = rawLocator is String ? jsonDecode(rawLocator) : rawLocator;
        }
      }
    } catch (_) {}

    if (!mounted) return;

    final ext = item.extension.toLowerCase();

    // 统一切换至 StreamTxtReaderPage
    if (ext == 'txt') {
      int initialByteOffset = 0;
      if (locatorData != null && locatorData['type'] == 'byte_offset') {
        initialByteOffset = locatorData['value'] as int? ?? 0;
      }

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => StreamTxtReaderPage(
            file: file,
            bookId: item.bookId,
            title: item.name,
            initialByteOffset: initialByteOffset,
            onProgressChanged: (byteOffset, progressPercent) {
              _syncService.saveAndSyncProgress(
                bookId: item.bookId,
                progress: progressPercent,
                locator: jsonEncode({
                  'type': 'byte_offset',
                  'value': byteOffset,
                }),
                deviceId: widget.deviceId,
                deviceName: Platform.operatingSystem,
              );
            },
          ),
        ),
      );
    } else if (ext == 'epub') {
      String? initialCfi;
      if (locatorData != null && locatorData['type'] == 'epub_cfi') {
        initialCfi = locatorData['value'] as String?;
      }

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => EpubReaderPage(
            file: file,
            bookId: item.bookId,
            title: item.name,
            initialCfi: initialCfi,
            onProgressChanged: (cfi, progressPercent) {
              _syncService.saveAndSyncProgress(
                bookId: item.bookId,
                progress: progressPercent,
                locator: jsonEncode({
                  'type': 'epub_cfi',
                  'value': cfi,
                }),
                deviceId: widget.deviceId,
                deviceName: Platform.operatingSystem,
              );
            },
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('暂不支持此格式: ${item.name}')),
      );
    }
  }

  String _formatSize(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final canGoBack = _currentPath != '/' && _currentPath != '.';

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _currentPath == '/' ? 'NAS 书库' : p.basename(_currentPath),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        leading: canGoBack
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: _navigateUp,
              )
            : null,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _loadDirectory(_currentPath),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.4),
            child: Text(
              '当前路径: $_currentPath',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            child: _buildListContent(),
          ),
        ],
      ),
    );
  }

  Widget _buildListContent() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: 12),
            Text(_errorMessage!),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => _loadDirectory(_currentPath),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }

    if (_items.isEmpty) {
      return const Center(child: Text('当前目录为空或无支持的电子书 (TXT/EPUB)'));
    }

    return RefreshIndicator(
      onRefresh: () => _loadDirectory(_currentPath),
      child: ListView.separated(
        itemCount: _items.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final item = _items[index];
          final isCached = _cachedStatusMap[item.bookId] ?? false;

          return ListTile(
            leading: Icon(
              item.isDir
                  ? Icons.folder
                  : (item.extension.toLowerCase() == 'epub'
                      ? Icons.menu_book
                      : Icons.description),
              color: item.isDir
                  ? Colors.amber
                  : (item.extension.toLowerCase() == 'epub'
                      ? Colors.blue
                      : Colors.teal),
              size: 32,
            ),
            title: Text(
              item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: item.isDir
                ? null
                : Text(
                    '${item.extension.toUpperCase()} · ${_formatSize(item.size)}',
                    style: const TextStyle(fontSize: 12),
                  ),
            trailing: item.isDir
                ? const Icon(Icons.chevron_right, color: Colors.grey)
                : (isCached
                    ? const Chip(
                        label: Text('已缓存',
                            style: TextStyle(fontSize: 10, color: Colors.green)),
                        backgroundColor: Color(0xFFE8F5E9),
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                      )
                    : const Icon(Icons.cloud_download_outlined, color: Colors.grey)),
            onTap: () => _onItemTapped(item),
          );
        },
      ),
    );
  }
}