import 'dart:io';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import '../readers/stream_txt_reader_page.dart';
import '../readers/epub_reader_page.dart';
import '../services/progress_sync_service.dart';
import '../services/app_logger.dart';

class NasFileItem {
  final String name;
  final String path;
  final bool isDir;
  final int size;

  NasFileItem({
    required this.name,
    required this.path,
    required this.isDir,
    required this.size,
  });

  factory NasFileItem.fromJson(Map<String, dynamic> json) {
    return NasFileItem(
      name: json['name'] ?? '',
      path: json['path'] ?? '',
      isDir: json['is_dir'] ?? false,
      size: (json['size'] as num?)?.toInt() ?? 0,
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
  String _currentPath = '/';
  List<NasFileItem> _items = [];
  bool _isLoading = true;
  String? _errorMessage;

  // 记录本地已缓存的文件名集合
  final Set<String> _cachedFileNames = {};

  @override
  void initState() {
    super.initState();
    _loadDirectory(_currentPath);
  }

  // 1. 扫描本地 books 目录，更新已缓存集合
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

  // 2. 加载 NAS 目录列表并比对本地缓存
  Future<void> _loadDirectory(String targetPath) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await _updateCachedFiles();

      final res = await widget.dio.get(
        '/api/v1/files/list',
        queryParameters: {'path': targetPath},
      );

      if (res.statusCode == 200 && res.data != null) {
        List<dynamic> rawList = [];
        if (res.data is Map && res.data['data'] is List) {
          rawList = res.data['data'];
        } else if (res.data is List) {
          rawList = res.data;
        }

        final items = rawList.map((e) => NasFileItem.fromJson(e)).toList();

        // 排序：文件夹在前，按字母排序
        items.sort((a, b) {
          if (a.isDir && !b.isDir) return -1;
          if (!a.isDir && b.isDir) return 1;
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });

        if (mounted) {
          setState(() {
            _items = items;
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

  // 3. 处理文件点击：已缓存则秒开，未缓存则居中展示加载弹窗并下载
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

    // 情况 A：已经存在本地缓存，直接打开
    if (targetFile.existsSync() && targetFile.lengthSync() > 0) {
      _openReader(targetFile, item);
      return;
    }

    // 情况 B：未缓存，弹出居中加载动画并执行下载
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

      // 下载完成，关闭弹窗
      if (mounted && Navigator.canPop(context)) {
        Navigator.pop(context);
      }

      // 更新已缓存列表
      setState(() {
        _cachedFileNames.add(item.name);
      });

      // 自动打开阅读器
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

  // 4. 打开阅读器并注入进度同步
  Future<void> _openReader(File file, NasFileItem item) async {
    final progressList = await ProgressSyncService.getAllLocalProgress();
    final savedRecord = progressList.firstWhere(
      (p) => p.bookId == item.name,
      orElse: () => BookProgress(
        bookId: item.name,
        title: p.basenameWithoutExtension(item.name),
        filePath: item.path,
        progressPercent: 0.0,
        lastReadTime: 0,
      ),
    );

    final ext = p.extension(item.name).toLowerCase();
    if (!mounted) return;

    if (ext == '.txt') {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => StreamTxtReaderPage(
            bookId: item.name,
            file: file,
            title: p.basenameWithoutExtension(item.name),
            initialByteOffset: savedRecord.txtByteOffset ?? 0,
            onProgressChanged: (byteOffset, progress) {
              ProgressSyncService.updateProgress(
                dio: widget.dio,
                bookId: item.name,
                title: p.basenameWithoutExtension(item.name),
                filePath: item.path,
                progressPercent: progress,
                txtByteOffset: byteOffset,
              );
            },
          ),
        ),
      ).then((_) => _updateCachedFiles());
    } else if (ext == '.epub') {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => EpubReaderPage(
            bookId: item.name,
            file: file,
            title: p.basenameWithoutExtension(item.name),
            initialCfi: savedRecord.epubCfi,
            onProgressChanged: (cfi, progress) {
              ProgressSyncService.updateProgress(
                dio: widget.dio,
                bookId: item.name,
                title: p.basenameWithoutExtension(item.name),
                filePath: item.path,
                progressPercent: progress,
                epubCfi: cfi,
              );
            },
          ),
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
                // 绿色的「已缓存」标签
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