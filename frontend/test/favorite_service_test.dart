import 'package:flutter_test/flutter_test.dart';
import 'package:nas_reader/models/favorite_book.dart';
import 'package:nas_reader/services/favorite_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FavoriteService.resetCacheForTest();
  });

  group('FavoriteBook', () {
    test('toJson/fromJson 往返保持字段一致', () {
      final json = {
        'book_id': 'fp-1',
        'title': '示例书',
        'file_name': '示例书.epub',
        'remote_path': '/books/示例书.epub',
        'added_at': 1700000000000,
        'updated_at': 1700000009999,
        'is_deleted': false,
      };
      expect(FavoriteBook.fromJson(json).toJson(), json);
    });

    test('缺省 updatedAt 时回落到 addedAt', () {
      final book = FavoriteBook.fromJson({
        'book_id': 'a',
        'added_at': 1700000000000,
      });
      expect(book.updatedAt, 1700000000000);
    });

    test('extension 从文件名推导并转小写', () {
      final book = FavoriteBook.fromJson({'book_id': 'a', 'file_name': 'A.EPUB'});
      expect(book.extension, '.epub');
    });

    test('缺失字段回退为安全默认值', () {
      final book = FavoriteBook.fromJson({});
      expect(book.bookId, '');
      expect(book.remotePath, '');
      expect(book.addedAt, 0);
      expect(book.updatedAt, 0);
      expect(book.isDeleted, isFalse);
    });
  });

  group('FavoriteService', () {
    test('add 后可查询到收藏状态', () async {
      await FavoriteService.add(
        bookId: 'fp-1',
        title: '示例书',
        fileName: '示例书.txt',
        remotePath: '/books/示例书.txt',
      );

      expect(await FavoriteService.isFavorite('fp-1'), isTrue);
      expect(await FavoriteService.getFavoriteIds(), {'fp-1'});
    });

    test('toggle 在收藏与取消收藏之间切换', () async {
      final added = await FavoriteService.toggle(
        bookId: 'fp-1',
        title: '书',
        fileName: '书.txt',
      );
      expect(added, isTrue);

      final removed = await FavoriteService.toggle(
        bookId: 'fp-1',
        title: '书',
        fileName: '书.txt',
      );
      expect(removed, isFalse);
      expect(await FavoriteService.isFavorite('fp-1'), isFalse);
    });

    test('空 bookId 不写入收藏', () async {
      await FavoriteService.add(bookId: '', title: '书', fileName: '书.txt');
      expect(await FavoriteService.getFavoriteIds(), isEmpty);
    });

    test('getAll 按收藏时间倒序返回', () async {
      await FavoriteService.add(bookId: 'a', title: 'A', fileName: 'A.txt');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await FavoriteService.add(bookId: 'b', title: 'B', fileName: 'B.txt');

      final list = await FavoriteService.getAll();
      expect(list.map((e) => e.bookId).toList(), ['b', 'a']);
    });

    test('数据变更时递增 revision 通知监听者', () async {
      final before = FavoriteService.revision.value;
      await FavoriteService.add(bookId: 'a', title: 'A', fileName: 'A.txt');
      expect(FavoriteService.revision.value, before + 1);

      await FavoriteService.remove('a');
      expect(FavoriteService.revision.value, before + 2);
    });

    test('收藏数据可从持久化存储恢复', () async {
      await FavoriteService.add(
        bookId: 'fp-1',
        title: '示例书',
        fileName: '示例书.epub',
        remotePath: '/books/示例书.epub',
      );

      FavoriteService.resetCacheForTest();

      final list = await FavoriteService.getAll();
      expect(list, hasLength(1));
      expect(list.first.title, '示例书');
      expect(list.first.remotePath, '/books/示例书.epub');
    });

    test('损坏的存储内容按空集合处理', () async {
      SharedPreferences.setMockInitialValues({
        'local_favorite_books_map': 'not-a-json',
      });
      FavoriteService.resetCacheForTest();

      expect(await FavoriteService.getAll(), isEmpty);
    });

    test('remove 写入墓碑而非物理删除，供后续同步传播', () async {
      await FavoriteService.add(bookId: 'fp-1', title: 'A', fileName: 'A.txt');
      await FavoriteService.remove('fp-1');

      // 对外不可见
      expect(await FavoriteService.isFavorite('fp-1'), isFalse);
      expect(await FavoriteService.getAll(), isEmpty);

      // 但墓碑仍留在持久化存储中
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('local_favorite_books_map') ?? '';
      expect(raw, contains('"is_deleted":true'));
    });

    test('重复 remove 不再触发额外通知', () async {
      await FavoriteService.add(bookId: 'fp-1', title: 'A', fileName: 'A.txt');
      await FavoriteService.remove('fp-1');
      final after = FavoriteService.revision.value;

      await FavoriteService.remove('fp-1');
      expect(FavoriteService.revision.value, after);
    });

    test('取消后重新收藏会刷新收藏时间', () async {
      await FavoriteService.add(bookId: 'fp-1', title: 'A', fileName: 'A.txt');
      final firstAddedAt = (await FavoriteService.getAll()).first.addedAt;

      await FavoriteService.remove('fp-1');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await FavoriteService.add(bookId: 'fp-1', title: 'A', fileName: 'A.txt');

      final list = await FavoriteService.getAll();
      expect(list, hasLength(1));
      expect(list.first.addedAt, greaterThan(firstAddedAt));
    });

    test('未登录时 syncWithServer 静默回退本地数据', () async {
      await FavoriteService.add(bookId: 'fp-1', title: 'A', fileName: 'A.txt');

      final list = await FavoriteService.syncWithServer();
      expect(list.map((e) => e.bookId).toList(), ['fp-1']);
    });

    test('clearLocal 清空本地收藏并通知刷新', () async {
      await FavoriteService.add(bookId: 'fp-1', title: 'A', fileName: 'A.txt');
      final before = FavoriteService.revision.value;

      await FavoriteService.clearLocal();

      expect(FavoriteService.revision.value, before + 1);
      expect(await FavoriteService.getAll(), isEmpty);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('local_favorite_books_map'), isNull);
    });
  });
}
