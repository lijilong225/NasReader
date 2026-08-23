import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

// 引入流式 TXT 阅读器与 EPUB 阅读器
import 'stream_txt_reader_page.dart';
import 'epub_reader_page.dart';
import 'sync_database_service.dart';
import 'epub_cover_extractor.dart';

/// 本地缓存书籍模型
class CachedBookItem {
  final String bookId;
  final String fileName;
  final String extension;
  final File file;
  final int size;
  final DateTime lastModified;
  double progress;
  String locator;
  File? coverImageFile;

  CachedBookItem({
    required this.bookId,
    required this.fileName,
    required this.extension,
    required this.file,
    required this.size,
    required this.lastModified,
    this.progress = 0.0,
    this.locator = '',
    this.coverImageFile,
  });
}

class LocalBookshelfPage extends StatefulWidget {
  final Dio dio;
  final String deviceId;

  const LocalBookshelfPage({
    super.key,
    required this.dio,
    this.deviceId = 'flutter_client_01',
  });

  @override
  State<LocalBookshelfPage> createState() => _LocalBookshelfPageState();
}

class _LocalBookshelfPageState extends State<LocalBookshelfPage> {
  late SyncDatabaseService _syncService;
  List<CachedBookItem> _books = [];
  bool _isLoading = true;

  bool _isSelectionMode = false;
  final Set<String> _selectedBookIds = {};

  @override
  void initState() {
    super.initState();
    _syncService = SyncDatabaseService(widget.dio);
    _loadLocalCachedBooks();
  }

  Future<void> _loadLocalCachedBooks() async {
    setState(() => _isLoading = true);

    final appDocDir = await getApplicationDocumentsDirectory();
    final cacheDir = Directory(p.join(appDocDir.path, 'CachedBooks'));

    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }

    final entities = cacheDir.listSync();
    final List<CachedBookItem> loadedBooks = [];

    for (var entity in entities) {
      if (entity is File && !entity.path.endsWith('.tmp')) {
        final baseName = p.basename(entity.path);
        final ext = p.extension(entity.path).replaceAll('.', '').toLowerCase();
        final bookId = p.basenameWithoutExtension(entity.path);

        if (ext == 'txt' || ext == 'epub') {
          final stat = entity.statSync();
          final progressRecord = await _syncService.getLocalProgress(bookId);

          File? coverFile;
          if (ext == 'epub') {
            coverFile = await EpubCoverExtractor.extractCover(entity, bookId);
          }

          loadedBooks.add(CachedBookItem(
            bookId: bookId,
            fileName: baseName,
            extension: ext,
            file: entity,
            size: stat.size,
            lastModified: stat.modified,
            progress: progressRecord?.progress ?? 0.0,
            locator: progressRecord?.locator ?? '',
            coverImageFile: coverFile,
          ));
        }
      }
    }

    loadedBooks.sort((a, b) => b.lastModified.compareTo(a.lastModified));

    if (mounted) {
      setState(() {
        _books = loadedBooks;
        _isLoading = false;
      });
    }
  }

  void _openReader(CachedBookItem item) {
    if (_isSelectionMode) {
      _toggleSelection(item.bookId);
      return;
    }

    Map<String, dynamic>? locatorData;
    if (item.locator.isNotEmpty) {
      try {
        locatorData = jsonDecode(item.locator);
      } catch (_) {}
    }

    // 统一切换至 StreamTxtReaderPage
    if (item.extension == 'txt') {
      int initialByteOffset = 0;
      if (locatorData != null && locatorData['type'] == 'byte_offset') {
        initialByteOffset = locatorData['value'] as int? ?? 0;
      }

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => StreamTxtReaderPage(
            file: item.file,
            bookId: item.bookId,
            title: item.fileName,
            initialByteOffset: initialByteOffset,
            onProgressChanged: (byteOffset, progressPercent) {
              item.progress = progressPercent;
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
              setState(() {});
            },
          ),
        ),
      ).then((_) => _loadLocalCachedBooks());
    } else if (item.extension == 'epub') {
      String? initialCfi;
      if (locatorData != null && locatorData['type'] == 'epub_cfi') {
        initialCfi = locatorData['value'] as String?;
      }

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => EpubReaderPage(
            file: item.file,
            bookId: item.bookId,
            title: item.fileName,
            initialCfi: initialCfi,
            onProgressChanged: (cfi, progressPercent) {
              item.progress = progressPercent;
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
              setState(() {});
            },
          ),
        ),
      ).then((_) => _loadLocalCachedBooks());
    }
  }

  void _toggleSelection(String bookId) {
    setState(() {
      if (_selectedBookIds.contains(bookId)) {
        _selectedBookIds.remove(bookId);
        if (_selectedBookIds.isEmpty) _isSelectionMode = false;
      } else {
        _selectedBookIds.add(bookId);
      }
    });
  }

  Future<void> _deleteSelectedBooks() async {
    final count = _selectedBookIds.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清理确认'),
        content: Text('确定要删除选中的 $count 本本地缓存电子书吗？此操作不会影响 NAS 源文件。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      for (final bookId in _selectedBookIds) {
        final book = _books.firstWhere((b) => b.bookId == bookId);
        if (await book.file.exists()) {
          await book.file.delete();
        }
        if (book.coverImageFile != null && await book.coverImageFile!.exists()) {
          await book.coverImageFile!.delete();
        }
      }

      setState(() {
        _books.removeWhere((b) => _selectedBookIds.contains(b.bookId));
        _selectedBookIds.clear();
        _isSelectionMode = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已清理 $count 本书籍')));
      }
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
    final totalCachedSize = _books.fold<int>(0, (sum, b) => sum + b.size);

    return Scaffold(
      appBar: AppBar(
        title: Text(_isSelectionMode ? '已选中 ${_selectedBookIds.length} 项' : '本地书架'),
        leading: _isSelectionMode
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: () {
                  setState(() {
                    _isSelectionMode = false;
                    _selectedBookIds.clear();
                  });
                },
              )
            : null,
        actions: [
          if (!_isSelectionMode && _books.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.checklist),
              tooltip: '批量管理',
              onPressed: () => setState(() => _isSelectionMode = true),
            ),
          if (_isSelectionMode)
            IconButton(
              icon: const Icon(Icons.select_all),
              tooltip: '全选',
              onPressed: () {
                setState(() {
                  if (_selectedBookIds.length == _books.length) {
                    _selectedBookIds.clear();
                  } else {
                    _selectedBookIds.addAll(_books.map((b) => b.bookId));
                  }
                });
              },
            ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.3),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('共 ${_books.length} 本离线书籍', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                Text('已用空间: ${_formatSize(totalCachedSize)}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ),
          ),
          Expanded(child: _buildGridContent()),
        ],
      ),
      bottomNavigationBar: _isSelectionMode && _selectedBookIds.isNotEmpty
          ? SafeArea(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                color: Theme.of(context).colorScheme.surface,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.red,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  icon: const Icon(Icons.delete_sweep),
                  label: Text('删除选中书籍 (${_selectedBookIds.length})'),
                  onPressed: _deleteSelectedBooks,
                ),
              ),
            )
          : null,
    );
  }

  Widget _buildGridContent() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_books.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.auto_stories_outlined, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            const Text('书架暂无缓存书籍', style: TextStyle(fontSize: 16, color: Colors.grey)),
            const SizedBox(height: 8),
            const Text('可前往 NAS 书库浏览并下载书籍进行离线阅读', style: TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadLocalCachedBooks,
      child: GridView.builder(
        padding: const EdgeInsets.all(16),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          childAspectRatio: 0.52,
          crossAxisSpacing: 14,
          mainAxisSpacing: 18,
        ),
        itemCount: _books.length,
        itemBuilder: (context, index) {
          final item = _books[index];
          final isSelected = _selectedBookIds.contains(item.bookId);

          return _buildBookCard(item, isSelected);
        },
      ),
    );
  }

  Widget _buildBookCard(CachedBookItem item, bool isSelected) {
    return GestureDetector(
      onTap: () => _openReader(item),
      onLongPress: () {
        if (!_isSelectionMode) {
          setState(() {
            _isSelectionMode = true;
            _selectedBookIds.add(item.bookId);
          });
        }
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.grey[200],
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.08),
                          blurRadius: 4,
                          offset: const Offset(2, 2),
                        ),
                      ],
                    ),
                    child: item.coverImageFile != null
                        ? Image.file(
                            item.coverImageFile!,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => _buildFallbackCover(item),
                          )
                        : _buildFallbackCover(item),
                  ),
                ),
                Positioned(
                  top: 4,
                  right: 4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.65),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text(
                      item.extension.toUpperCase(),
                      style: const TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
                if (_isSelectionMode)
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        color: isSelected ? Colors.black.withOpacity(0.4) : Colors.transparent,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      alignment: Alignment.topRight,
                      padding: const EdgeInsets.all(4),
                      child: Icon(
                        isSelected ? Icons.check_circle : Icons.radio_button_unchecked,
                        color: isSelected ? Colors.blue : Colors.white70,
                        size: 22,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            item.fileName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, height: 1.2),
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: item.progress,
              minHeight: 3,
              backgroundColor: Colors.grey[200],
              valueColor: AlwaysStoppedAnimation<Color>(
                item.progress >= 1.0 ? Colors.green : const Color(0xFF382E25),
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            item.progress <= 0 ? '未读' : '${(item.progress * 100).toStringAsFixed(0)}%',
            style: const TextStyle(fontSize: 10, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _buildFallbackCover(CachedBookItem item) {
    final isTxt = item.extension == 'txt';
    final gradientColors = isTxt
        ? [const Color(0xFF2C5364), const Color(0xFF203A43), const Color(0xFF0F2027)]
        : [const Color(0xFF8A2387), const Color(0xFFE94057), const Color(0xFFF27121)];

    final firstChar = item.fileName.isNotEmpty ? item.fileName.characters.first : '书';

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: gradientColors,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            firstChar,
            style: const TextStyle(color: Colors.white70, fontSize: 28, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            item.fileName,
            maxLines: 2,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 10),
          ),
        ],
      ),
    );
  }
}