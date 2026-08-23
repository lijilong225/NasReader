import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

class LocalBookCacheManager {
  final Dio _dio;

  LocalBookCacheManager(this._dio);

  // 获取本地电子书沙盒目录: ~/Documents/CachedBooks/
  Future<Directory> _getCacheDirectory() async {
    final appDocDir = await getApplicationDocumentsDirectory();
    final cacheDir = Directory(p.join(appDocDir.path, 'CachedBooks'));
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }
    return cacheDir;
  }

  // 根据 bookId 和后缀获取本地存储路径
  Future<File> getLocalFile(String bookId, String extension) async {
    final cacheDir = await _getCacheDirectory();
    return File(p.join(cacheDir.path, '$bookId.$extension'));
  }

  // 检查书籍是否已被完整缓存
  Future<bool> isBookCached(String bookId, String extension) async {
    final file = await getLocalFile(bookId, extension);
    return await file.exists();
  }

  // 从 NAS 后端下载并缓存到本地（支持进度回调）
  Future<File> downloadAndCacheBook({
    required String remoteRelPath,
    required String bookId,
    required String extension,
    required Function(int received, int total) onProgress,
  }) async {
    final localFile = await getLocalFile(bookId, extension);
    final tempFilePath = '${localFile.path}.tmp';

    // 经由 Gin 后端接口下载
    await _dio.download(
      '/api/v1/files/download',
      tempFilePath,
      queryParameters: {'path': remoteRelPath},
      onReceiveProgress: onProgress,
    );

    // 下载完毕后重命名为正式缓存文件
    final tempFile = File(tempFilePath);
    return await tempFile.rename(localFile.path);
  }

  // 删除本地单本书籍缓存
  Future<void> removeCache(String bookId, String extension) async {
    final file = await getLocalFile(bookId, extension);
    if (await file.exists()) {
      await file.delete();
    }
  }
}