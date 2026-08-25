import 'package:flutter_test/flutter_test.dart';
import 'package:nas_reader/core/book_fingerprint.dart';

void main() {
  const fingerprint =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

  group('buildFileName', () {
    test('指纹合法时拼接为 <指纹>__<原始名>', () {
      expect(
        BookCacheNaming.buildFileName(
            bookId: fingerprint, originalName: '三体.txt'),
        '${fingerprint}__三体.txt',
      );
    });

    test('bookId 为空或非指纹时退化为原始名', () {
      expect(
        BookCacheNaming.buildFileName(bookId: null, originalName: '三体.txt'),
        '三体.txt',
      );
      expect(
        BookCacheNaming.buildFileName(bookId: '', originalName: '三体.txt'),
        '三体.txt',
      );
      expect(
        BookCacheNaming.buildFileName(bookId: '三体.txt', originalName: '三体.txt'),
        '三体.txt',
      );
    });
  });

  group('extract', () {
    test('新版命名可还原 bookId 与原始名', () {
      final name = '${fingerprint}__三体.txt';
      expect(BookCacheNaming.extractBookId(name), fingerprint);
      expect(BookCacheNaming.extractOriginalName(name), '三体.txt');
    });

    test('旧版无前缀命名退化为以文件名作为 bookId', () {
      expect(BookCacheNaming.extractBookId('三体.txt'), '三体.txt');
      expect(BookCacheNaming.extractOriginalName('三体.txt'), '三体.txt');
    });

    test('原始名自身含分隔符时只按首个合法指纹切分', () {
      final name = '${fingerprint}__a__b.txt';
      expect(BookCacheNaming.extractBookId(name), fingerprint);
      expect(BookCacheNaming.extractOriginalName(name), 'a__b.txt');
    });

    test('前缀不是 64 位小写 hex 时不视为指纹', () {
      expect(BookCacheNaming.extractBookId('deadbeef__x.txt'), 'deadbeef__x.txt');
      expect(
        BookCacheNaming.extractBookId('${fingerprint.toUpperCase()}__x.txt'),
        '${fingerprint.toUpperCase()}__x.txt',
      );
    });

    test('分隔符后为空时不切分', () {
      expect(BookCacheNaming.extractBookId('${fingerprint}__'),
          '${fingerprint}__');
    });
  });

  test('isFingerprint 只接受 64 位小写 hex', () {
    expect(BookCacheNaming.isFingerprint(fingerprint), isTrue);
    expect(BookCacheNaming.isFingerprint(fingerprint.substring(1)), isFalse);
    expect(BookCacheNaming.isFingerprint('${fingerprint}0'), isFalse);
    expect(BookCacheNaming.isFingerprint(fingerprint.toUpperCase()), isFalse);
  });
}
