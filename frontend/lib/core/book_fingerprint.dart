/// 本地缓存文件命名规则：`<指纹>__<原始文件名>`
///
/// 指纹（后端 `book_id`，SHA256 十六进制）作为前缀，使同名不同源的书籍不再互相覆盖，
/// 保留原始文件名便于推导扩展名与排查。旧版本缓存无前缀，此时退化为以文件名作为书籍 ID。
class BookCacheNaming {
  static const String separator = '__';
  static final RegExp _fingerprintPattern = RegExp(r'^[0-9a-f]{64}$');

  static String buildFileName({String? bookId, required String originalName}) {
    if (bookId == null || bookId.isEmpty) return originalName;
    if (!isFingerprint(bookId)) return originalName;
    return '$bookId$separator$originalName';
  }

  /// bookId 是否为 64 位十六进制指纹（区别于旧版直接用文件名做 bookId）
  static bool isFingerprint(String value) => _fingerprintPattern.hasMatch(value);

  static int _separatorIndex(String cacheFileName) {
    final idx = cacheFileName.indexOf(separator);
    if (idx <= 0) return -1;
    if (!_fingerprintPattern.hasMatch(cacheFileName.substring(0, idx))) return -1;
    if (idx + separator.length >= cacheFileName.length) return -1;
    return idx;
  }

  static String extractBookId(String cacheFileName) {
    final idx = _separatorIndex(cacheFileName);
    return idx > 0 ? cacheFileName.substring(0, idx) : cacheFileName;
  }

  static String extractOriginalName(String cacheFileName) {
    final idx = _separatorIndex(cacheFileName);
    return idx > 0 ? cacheFileName.substring(idx + separator.length) : cacheFileName;
  }
}
