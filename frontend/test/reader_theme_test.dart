import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nas_reader/core/reader_theme.dart';

void main() {
  test('羊皮纸1 保持纯色，羊皮纸2 携带纹理背景图', () {
    expect(ReaderThemes.parchment.name, '羊皮纸1');
    expect(ReaderThemes.parchment.backgroundImage, isNull);

    expect(ReaderThemes.parchment2.name, '羊皮纸2');
    expect(ReaderThemes.parchment2.backgroundImage, 'assets/readbg_01.jpg');
    // 图片加载失败时以底色兜底，两个羊皮纸观感需保持一致
    expect(ReaderThemes.parchment2.bgColor, ReaderThemes.parchment.bgColor);
    expect(ReaderThemes.parchment2.textColor, ReaderThemes.parchment.textColor);
  });

  test('主题名称唯一，选中判定可仅依赖 name', () {
    final names = ReaderThemes.all.map((t) => t.name).toList();
    expect(names.toSet().length, names.length);
    expect(names, ['羊皮纸1', '羊皮纸2', '暗黑', '纯白']);
  });

  test('除羊皮纸2 外其余主题均为纯色', () {
    final withImage = ReaderThemes.all.where((t) => t.backgroundImage != null);
    expect(withImage.map((t) => t.name), ['羊皮纸2']);
  });

  test('羊皮纸2 声明的背景图已打进 asset bundle', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final data = await rootBundle.load(ReaderThemes.parchment2.backgroundImage!);
    expect(data.lengthInBytes, greaterThan(0));
  });
}
