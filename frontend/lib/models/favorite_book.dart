import 'package:path/path.dart' as p;

/// 收藏夹条目。bookId 与阅读进度、书签共用同一套书籍标识（后端文件指纹，旧数据为文件名）
class FavoriteBook {
  final String bookId;
  final String title;
  final String fileName;

  /// NAS 远端路径，离线书籍可能为空
  final String remotePath;
  final int addedAt;

  /// 客户端毫秒时间戳，与后端做 LWW（Last-Write-Wins）合并
  final int updatedAt;

  /// 取消收藏的墓碑标记，保留一段时间以便把删除同步给其它设备
  final bool isDeleted;

  FavoriteBook({
    required this.bookId,
    required this.title,
    required this.fileName,
    required this.remotePath,
    required this.addedAt,
    int? updatedAt,
    this.isDeleted = false,
  }) : updatedAt = updatedAt ?? addedAt;

  String get extension => p.extension(fileName).toLowerCase();

  FavoriteBook copyWith({
    String? title,
    String? fileName,
    String? remotePath,
    int? addedAt,
    int? updatedAt,
    bool? isDeleted,
  }) {
    return FavoriteBook(
      bookId: bookId,
      title: title ?? this.title,
      fileName: fileName ?? this.fileName,
      remotePath: remotePath ?? this.remotePath,
      addedAt: addedAt ?? this.addedAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isDeleted: isDeleted ?? this.isDeleted,
    );
  }

  Map<String, dynamic> toJson() => {
    'book_id': bookId,
    'title': title,
    'file_name': fileName,
    'remote_path': remotePath,
    'added_at': addedAt,
    'updated_at': updatedAt,
    'is_deleted': isDeleted,
  };

  factory FavoriteBook.fromJson(Map<String, dynamic> json) {
    final addedAt = _asMillis(json['added_at']);
    final updatedAt = _asMillis(json['updated_at']);
    return FavoriteBook(
      bookId: (json['book_id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      fileName: (json['file_name'] ?? '').toString(),
      remotePath: (json['remote_path'] ?? '').toString(),
      addedAt: addedAt,
      updatedAt: updatedAt > 0 ? updatedAt : addedAt,
      isDeleted: json['is_deleted'] == true,
    );
  }

  static int _asMillis(Object? raw) {
    if (raw is num) return raw.toInt();
    return int.tryParse(raw?.toString() ?? '') ?? 0;
  }
}
