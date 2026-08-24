class Bookmark {
  final String id;
  final String bookId;
  final String title;
  final String snippet;
  final double progressPercent;
  final int? byteOffset;
  final String? cfi;
  final int createdAt; // 毫秒时间戳
  final int updatedAt; // 毫秒时间戳
  final bool isDeleted;

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

  Bookmark copyWith({
    String? title,
    String? snippet,
    double? progressPercent,
    int? byteOffset,
    String? cfi,
    int? updatedAt,
    bool? isDeleted,
  }) {
    return Bookmark(
      id: id,
      bookId: bookId,
      title: title ?? this.title,
      snippet: snippet ?? this.snippet,
      progressPercent: progressPercent ?? this.progressPercent,
      byteOffset: byteOffset ?? this.byteOffset,
      cfi: cfi ?? this.cfi,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isDeleted: isDeleted ?? this.isDeleted,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'bookId': bookId,
    'title': title,
    'snippet': snippet,
    'progressPercent': progressPercent,
    'byteOffset': byteOffset,
    'cfi': cfi,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    'isDeleted': isDeleted,
  };

  factory Bookmark.fromJson(Map<String, dynamic> json) {
    // 兼容可能存在的旧 ISO 字符串或数字类型
    int parseTimestamp(dynamic val) {
      if (val is num) return val.toInt();
      if (val is String) {
        final parsedNum = int.tryParse(val);
        if (parsedNum != null) return parsedNum;
        final date = DateTime.tryParse(val);
        if (date != null) return date.millisecondsSinceEpoch;
      }
      return DateTime.now().millisecondsSinceEpoch;
    }

    return Bookmark(
      id: json['id']?.toString() ?? '',
      bookId: json['bookId']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      snippet: json['snippet']?.toString() ?? '',
      progressPercent: (json['progressPercent'] as num?)?.toDouble() ?? 0.0,
      byteOffset: (json['byteOffset'] as num?)?.toInt(),
      cfi: json['cfi']?.toString(),
      createdAt: parseTimestamp(json['createdAt']),
      updatedAt: parseTimestamp(json['updatedAt']),
      isDeleted: json['isDeleted'] == true,
    );
  }
}