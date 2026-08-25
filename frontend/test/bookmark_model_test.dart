import 'package:flutter_test/flutter_test.dart';
import 'package:nas_reader/models/bookmark_model.dart';

void main() {
  Map<String, dynamic> base() => {
        'id': 'bm-1',
        'bookId': 'book-1',
        'title': '第一章',
        'snippet': '正文片段',
        'progressPercent': 0.25,
        'byteOffset': 1024,
        'cfi': 'epubcfi(/6/4!/4/2)',
        'createdAt': 1700000000000,
        'updatedAt': 1700000001000,
        'isDeleted': false,
      };

  test('toJson/fromJson 往返保持字段一致', () {
    final restored = Bookmark.fromJson(base());
    expect(restored.toJson(), base());
  });

  test('时间戳兼容数字字符串与 ISO 格式', () {
    final fromNumericString =
        Bookmark.fromJson(base()..['createdAt'] = '1700000000000');
    expect(fromNumericString.createdAt, 1700000000000);

    final fromIso =
        Bookmark.fromJson(base()..['updatedAt'] = '2023-11-14T22:13:20.000Z');
    expect(fromIso.updatedAt,
        DateTime.parse('2023-11-14T22:13:20.000Z').millisecondsSinceEpoch);
  });

  test('缺失字段回退为安全默认值', () {
    final b = Bookmark.fromJson({});
    expect(b.id, '');
    expect(b.bookId, '');
    expect(b.progressPercent, 0.0);
    expect(b.byteOffset, isNull);
    expect(b.cfi, isNull);
    expect(b.isDeleted, isFalse);
  });

  test('isDeleted 只认布尔 true', () {
    expect(Bookmark.fromJson(base()..['isDeleted'] = 'true').isDeleted, isFalse);
    expect(Bookmark.fromJson(base()..['isDeleted'] = 1).isDeleted, isFalse);
    expect(Bookmark.fromJson(base()..['isDeleted'] = true).isDeleted, isTrue);
  });

  test('copyWith 保留 id/bookId/createdAt，仅覆盖指定字段', () {
    final original = Bookmark.fromJson(base());
    final updated = original.copyWith(isDeleted: true, updatedAt: 1800000000000);

    expect(updated.id, original.id);
    expect(updated.bookId, original.bookId);
    expect(updated.createdAt, original.createdAt);
    expect(updated.title, original.title);
    expect(updated.isDeleted, isTrue);
    expect(updated.updatedAt, 1800000000000);
  });
}
