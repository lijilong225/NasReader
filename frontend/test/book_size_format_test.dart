import 'package:flutter_test/flutter_test.dart';
import 'package:nas_reader/pages/local_bookshelf_page.dart';

void main() {
  test('未下载或空文件不显示体积', () {
    expect(formatBookSize(0), '');
    expect(formatBookSize(-1), '');
  });

  test('小文件降级为 KB，避免显示 0.0MB', () {
    expect(formatBookSize(2048), '2KB');
    expect(formatBookSize(100 * 1024), '100KB');
  });

  test('达到 0.1MB 起按 MB 显示', () {
    expect(formatBookSize(1024 * 1024 ~/ 10), '0.1MB');
    expect(formatBookSize(3 * 1024 * 1024), '3.0MB');
    expect(formatBookSize(15 * 1024 * 1024 + 512 * 1024), '15.5MB');
  });
}
