import 'dart:io';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:nas_reader/core/book_fingerprint.dart';
import 'package:nas_reader/core/network_client.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../readers/stream_txt_reader_page.dart';
import '../readers/epub_reader_page.dart';
import '../services/progress_sync_service.dart';
import '../services/favorite_service.dart';
import '../services/app_logger.dart';
import '../widgets/book_leading_icon.dart';

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
  final int modTime;

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

  /// 同步用书籍唯一标识：优先使用后端文件指纹，缺失时退化为文件名
  String get syncBookId => (bookId != null && bookId!.isNotEmpty) ? bookId! : name;

  /// 本地缓存文件名，带指纹前缀以避免同名书籍互相覆盖
  String get cacheFileName =>
      BookCacheNaming.buildFileName(bookId: bookId, originalName: name);
}

class FileBrowserPage extends StatefulWidget {
  final Dio? dio; // 👈 优化为可选，内部自动从 NetworkClient / ApiConfig 回退

  const FileBrowserPage({super.key, this.dio});

  @override
  State<FileBrowserPage> createState() => FileBrowserPageState();
}

class FileBrowserPageState extends State<FileBrowserPage> {
  static const String _sortPrefKey = 'nas_file_sort_type';

  late Dio _dio;
  String _currentPath = '/';
  List<NasFileItem> _items = [];
  bool _isLoading = true;
  String? _errorMessage;

  FileSortType _currentSort = FileSortType.timeDesc;
  final Set<String> _cachedFileNames = {};
  Set<String> _favoriteIds = {};
  Set<String> _shelfBookIds = {};

  @override
  void initState() {
    super.initState();
    // 优先使用传入的 Dio，默认从 NetworkClient 获取（自动包含 ApiConfig.baseUrl 与 JWT Token）
    _dio = widget.dio ?? NetworkClient.getDio();
    FavoriteService.revision.addListener(_refreshFavoriteIds);
    _initAndLoad();
  }

  @override
  void dispose() {
    FavoriteService.revision.removeListener(_refreshFavoriteIds);
    super.dispose();
  }

  Future<void> _refreshFavoriteIds() async {
    final ids = await FavoriteService.getFavoriteIds();
    if (mounted) setState(() => _favoriteIds = ids);
  }

  Future<void> _toggleFavorite(NasFileItem item) async {
    final title = p.basenameWithoutExtension(item.name);
    final added = await FavoriteService.toggle(
      bookId: item.syncBookId,
      title: title,
      fileName: item.name,
      remotePath: item.path,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(added ? '已收藏《$title》' : '已取消收藏《$title》'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _initAndLoad() async {
    await _loadSavedSortPreference();
    await _loadDirectory(_currentPath);
  }

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
    } catch (e) {
      AppLogger.log('⚠️ 排序偏好读取失败，使用默认排序: $e');
    }
  }

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

  /// 新命名（带指纹前缀）与旧命名（纯文件名）都视为已缓存
  bool _isItemCached(NasFileItem item) =>
      _cachedFileNames.contains(item.cacheFileName) ||
      _cachedFileNames.contains(item.name);

  /// 书架与本地书架页保持一致：有本地阅读记录或已缓存即视为在书架
  bool _isOnShelf(NasFileItem item) =>
      _shelfBookIds.contains(item.syncBookId) || _isItemCached(item);

  Future<void> _refreshShelfBookIds() async {
    final list = await ProgressSyncService.getAllLocalProgress();
    _shelfBookIds = list.map((e) => e.bookId).toSet();
  }

  Future<void> _loadDirectory(String targetPath) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await _updateCachedFiles();
      _favoriteIds = await FavoriteService.getFavoriteIds();
      await _refreshShelfBookIds();

      final res = await _dio.get(
        '/api/v1/files/browse',
        queryParameters: {'path': targetPath},
      );

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

  /// 定位书籍的本地缓存文件：优先带指纹前缀的新命名，
  /// 若只存在旧版无前缀文件则就地重命名迁移。
  Future<File> _resolveLocalFile(NasFileItem item) async {
    final appDir = await getApplicationDocumentsDirectory();
    final booksDir = p.join(appDir.path, 'books');
    final target = File(p.join(booksDir, item.cacheFileName));

    if (target.existsSync() || item.cacheFileName == item.name) return target;

    final legacy = File(p.join(booksDir, item.name));
    if (legacy.existsSync() && legacy.lengthSync() > 0) {
      try {
        return await legacy.rename(target.path);
      } catch (e) {
        AppLogger.log('❌ 迁移旧缓存文件失败，继续沿用旧文件: $e');
        return legacy;
      }
    }
    return target;
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

    final targetFile = await _resolveLocalFile(item);
    final localFilePath = targetFile.path;

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
      await _dio.download(
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
        _cachedFileNames.add(p.basename(localFilePath));
      });

      if (mounted) {
        _openReader(targetFile, item);
      }
    } catch (e) {
      if (mounted && Navigator.canPop(context)) {
        Navigator.pop(context);
      }
      final isCanceled = e is DioException && CancelToken.isCancel(e);
      if (!isCanceled && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('下载失败: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _openReader(File file, NasFileItem item) async {
    final bookId = item.syncBookId;
    final title = p.basenameWithoutExtension(item.name);

    // 旧版本用文件名作为 bookId，此处把历史记录迁移到指纹键
    if (bookId != item.name) {
      await ProgressSyncService.migrateLegacyBookId(
        legacyBookId: item.name,
        newBookId: bookId,
      );
    }

    // 曾从书架移除过的书，重新打开时把云端进度拉回本地
    await ProgressSyncService.restoreToShelf(bookId, _dio);

    final progressList = await ProgressSyncService.getAllLocalProgress();
    final savedRecord = progressList.firstWhere(
      (p) => p.bookId == bookId,
      orElse: () => BookProgress(
        bookId: bookId,
        title: title,
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
            bookId: bookId,
            file: file,
            title: title,
            initialByteOffset: initialOffset,
            onProgressChanged: (byteOffset, progress) {
              ProgressSyncService.updateProgress(
                dio: _dio,
                bookId: bookId,
                title: title,
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
            bookId: bookId,
            file: file,
            title: title,
            initialCfi: initialCfi,
            initialProgress: savedRecord.progress,
            onProgressChanged: (cfi, progress) {
              ProgressSyncService.updateProgress(
                dio: _dio,
                bookId: bookId,
                title: title,
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

  Future<void> _confirmMoveToTrash(NasFileItem item) async {
    final title = p.basenameWithoutExtension(item.name);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移动到垃圾箱'),
        content: Text(
          '确定要把《$title》移动到 NAS 垃圾箱吗？\n\n'
          '• 书架缓存、阅读进度、书签与收藏将一并清除\n'
          '• 可在“设置 - 垃圾箱”中查看或恢复文件',
          style: const TextStyle(fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('移动', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );

    if (confirm != true || !mounted) return;

    try {
      await _dio.post('/api/v1/files/trash', data: {'path': item.path});
      await _purgeBookTraces(item);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已把《$title》移动到垃圾箱')),
      );
      await _loadDirectory(_currentPath);
    } catch (e) {
      AppLogger.log('移动到垃圾箱失败: ${item.path} -> $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('移动失败，请检查网络或服务端权限'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  /// 书籍已进垃圾箱，书架缓存与它的进度、书签、收藏一并清掉（云端记录同步删除）
  Future<void> _purgeBookTraces(NasFileItem item) async {
    try {
      final localFile = await _resolveLocalFile(item);
      if (localFile.existsSync()) await localFile.delete();
    } catch (e) {
      AppLogger.log('清理本地缓存文件失败: ${item.name} -> $e');
    }

    await FavoriteService.remove(item.syncBookId);
    await ProgressSyncService.deleteBookEverything(item.syncBookId, _dio);
  }

  /// 加入书架：不预先下载文件，先建立一条零进度记录，书架以“云端记录”展示
  Future<void> _handleAddToShelf(NasFileItem item) async {
    final title = p.basenameWithoutExtension(item.name);
    try {
      await ProgressSyncService.restoreToShelf(item.syncBookId, _dio);
      if (!_shelfBookIds.contains(item.syncBookId)) {
        await ProgressSyncService.updateProgress(
          dio: _dio,
          bookId: item.syncBookId,
          title: title,
          filePath: item.path,
          progressPercent: 0.0,
          locator: '0',
        );
      }
      await _refreshShelfBookIds();
      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已把《$title》加入书架'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      AppLogger.log('❌ 加入书架失败: ${item.path} -> $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('加入书架失败: $e'), backgroundColor: Colors.redAccent),
      );
    }
  }

  /// 移出书架：清本地缓存与本地进度/书签，云端记录保留
  Future<void> _handleRemoveFromShelf(NasFileItem item) async {
    final title = p.basenameWithoutExtension(item.name);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移出书架', style: TextStyle(fontWeight: FontWeight.bold)),
        content: Text(
          '确定要把《$title》从书架移出吗？\n\n'
          '• 本地缓存文件与本地阅读进度、书签将被清理\n'
          '• 云端阅读进度与书签保留，重新加入书架后可继续阅读\n'
          '• NAS 原始文件不受影响',
          style: const TextStyle(fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('移出书架', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );

    if (confirm != true || !mounted) return;

    try {
      final localFile = await _resolveLocalFile(item);
      if (localFile.existsSync()) await localFile.delete();
      await ProgressSyncService.removeFromShelfLocally(item.syncBookId);
      await _updateCachedFiles();
      await _refreshShelfBookIds();
      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已把《$title》移出书架'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      AppLogger.log('❌ 移出书架失败: ${item.path} -> $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('移出书架失败: $e'), backgroundColor: Colors.redAccent),
      );
    }
  }

  /// 行尾三点菜单：收藏、书架、扔到垃圾箱
  Widget _buildBookActionMenu(NasFileItem item) {
    final isFavorite = _favoriteIds.contains(item.syncBookId);
    final onShelf = _isOnShelf(item);
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert, color: Colors.grey),
      tooltip: '更多操作',
      onSelected: (action) async {
        switch (action) {
          case 'favorite':
            await _toggleFavorite(item);
            break;
          case 'shelf':
            if (onShelf) {
              await _handleRemoveFromShelf(item);
            } else {
              await _handleAddToShelf(item);
            }
            break;
          case 'trash':
            await _confirmMoveToTrash(item);
            break;
        }
      },
      itemBuilder: (ctx) => [
        PopupMenuItem(
          value: 'favorite',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              isFavorite ? Icons.star_border : Icons.star,
              color: Colors.amber.shade700,
            ),
            title: Text(isFavorite ? '移出收藏' : '加入收藏'),
          ),
        ),
        PopupMenuItem(
          value: 'shelf',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              onShelf ? Icons.delete_sweep_outlined : Icons.library_add_outlined,
              color: onShelf ? Colors.orange : Colors.blue,
            ),
            title: Text(onShelf ? '移出书架' : '加入书架'),
          ),
        ),
        const PopupMenuItem(
          value: 'trash',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.delete_outline, color: Colors.redAccent),
            title: Text('扔到垃圾箱'),
          ),
        ),
      ],
    );
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
          final isCached = !item.isDir && _isItemCached(item);
          final isBook = !item.isDir && (ext == '.txt' || ext == '.epub');

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
            // 48px 的三点按钮内部自带 12px 视觉留白，右侧内边距取 4px 即为 16px
            contentPadding: isBook
                ? const EdgeInsets.only(left: 16, right: 4)
                : const EdgeInsets.symmetric(horizontal: 16),
            leading: isBook
                ? BookLeadingIcon(
                    icon: iconData,
                    iconColor: iconColor,
                    isFavorite: _favoriteIds.contains(item.syncBookId),
                  )
                : Icon(iconData, color: iconColor, size: 28),
            title: Text(
              item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
            subtitle: item.isDir
                ? const Text('文件夹', style: TextStyle(fontSize: 12, color: Colors.grey))
                : Text(
                    _formatSize(item.size),
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  item.isDir
                      ? Icons.chevron_right
                      : (isCached ? Icons.check_circle_outline : Icons.cloud_download_outlined),
                  size: 20,
                  color: isCached ? Colors.green : Colors.grey,
                ),
                if (isBook) _buildBookActionMenu(item),
              ],
            ),
            onTap: () => _handleItemTap(item),
          );
        },
      ),
    );
  }
}