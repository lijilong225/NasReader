import 'package:flutter_test/flutter_test.dart';
import 'package:nas_reader/pages/file_browser_page.dart';

void main() {
  group('全库搜索结果的目录标注', () {
    test('根目录下的书籍标注为书库根目录', () {
      expect(formatSearchLocation('/三体.epub'), '书库根目录');
    });

    test('多层目录返回完整父目录路径', () {
      expect(formatSearchLocation('/科幻/外国/沙丘.pdf'), '/科幻/外国');
      expect(formatSearchLocation('/科幻/三体.epub'), '/科幻');
    });

    test('路径异常时不抛错，退化为书库根目录', () {
      expect(formatSearchLocation(''), '书库根目录');
      expect(formatSearchLocation('三体.epub'), '书库根目录');
    });
  });

  group('NasFileItem 解析搜索结果', () {
    test('缺少前导斜杠时自动补齐，并保留后端指纹', () {
      final item = NasFileItem.fromJson({
        'name': '三体.epub',
        'path': '科幻/三体.epub',
        'is_dir': false,
        'size': 2048,
        'book_id': 'fp-abc',
        'mod_time': 1700000000000,
      });

      expect(item.path, '/科幻/三体.epub');
      expect(item.syncBookId, 'fp-abc');
      expect(formatSearchLocation(item.path), '/科幻');
    });

    test('后端未返回指纹时退化为文件名，避免同步键为空', () {
      final item = NasFileItem.fromJson({
        'name': '三体.epub',
        'path': '/科幻/三体.epub',
        'is_dir': false,
        'size': 2048,
      });

      expect(item.syncBookId, '三体.epub');
    });
  });
}
