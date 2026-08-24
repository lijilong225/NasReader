// lib/models/bookmark_model.dart
class Bookmark {
  final String id;
  final String bookId;
  final String title;          // 章节名或书签名
  final String snippet;        // 正文摘录（前50字）
  final double progressPercent;// 进度 0.0 ~ 1.0
  final int? byteOffset;       // TXT 专用定位
  final String? cfi;           // EPUB 专用定位
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool isDeleted;        // 软删除标记，用于支持跨端同步删除

  Bookmark({
    required this.id,
    required this.bookId,
    required this.title,
    required this.snippet,
    required this.progressPercent,
    this.byteOffset,
    this.cfi,
    required this.createdAt,
    required this.updatedAt,
    this.isDeleted = false,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'bookId': bookId,
    'title': title,
    'snippet': snippet,
    'progressPercent': progressPercent,
    'byteOffset': byteOffset,
    'cfi': cfi,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'isDeleted': isDeleted,
  };

  factory Bookmark.fromJson(Map<String, dynamic> json) => Bookmark(
    id: json['id'] as String,
    bookId: json['bookId'] as String,
    title: json['title'] as String? ?? '未命名书签',
    snippet: json['snippet'] as String? ?? '',
    progressPercent: (json['progressPercent'] as num?)?.toDouble() ?? 0.0,
    byteOffset: json['byteOffset'] as int?,
    cfi: json['cfi'] as String?,
    createdAt: DateTime.tryParse(json['createdAt'] ?? '') ?? DateTime.now(),
    updatedAt: DateTime.tryParse(json['updatedAt'] ?? '') ?? DateTime.now(),
    isDeleted: json['isDeleted'] as bool? ?? false,
  );

  Bookmark copyWith({
    String? title,
    String? snippet,
    DateTime? updatedAt,
    bool? isDeleted,
  }) => Bookmark(
    id: id,
    bookId: bookId,
    title: title ?? this.title,
    snippet: snippet ?? this.snippet,
    progressPercent: progressPercent,
    byteOffset: byteOffset,
    cfi: cfi,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    isDeleted: isDeleted ?? this.isDeleted,
  );
}