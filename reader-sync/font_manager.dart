import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class CustomFontItem {
  final String name;       // 字体展示名称
  final String fontFamily; // 注册到 Flutter 的 fontFamily 名称
  final File file;

  CustomFontItem({
    required this.name,
    required this.fontFamily,
    required this.file,
  });
}

class FontManager {
  static final FontManager instance = FontManager._();
  FontManager._();

  final List<CustomFontItem> _fonts = [];
  List<CustomFontItem> get fonts => _fonts;

  Future<Directory> _getFontDir() async {
    final docDir = await getApplicationDocumentsDirectory();
    final fontDir = Directory(p.join(docDir.path, 'CustomFonts'));
    if (!await fontDir.exists()) {
      await fontDir.create(recursive: true);
    }
    return fontDir;
  }

  /// 扫描已导入的本地字体并注册进引擎
  Future<void> loadSavedFonts() async {
    final dir = await _getFontDir();
    final list = dir.listSync();
    _fonts.clear();

    for (var entity in list) {
      if (entity is File) {
        final ext = p.extension(entity.path).toLowerCase();
        if (ext == '.ttf' || ext == '.otf') {
          final fontName = p.basenameWithoutExtension(entity.path);
          await _registerFont(fontName, entity);
          _fonts.add(CustomFontItem(
            name: fontName,
            fontFamily: fontName,
            file: entity,
          ));
        }
      }
    }
  }

  /// 导入外部字体文件
  Future<CustomFontItem?> importFont(File sourceFile) async {
    final dir = await _getFontDir();
    final baseName = p.basename(sourceFile.path);
    final fontName = p.basenameWithoutExtension(sourceFile.path);
    final targetFile = File(p.join(dir.path, baseName));

    await sourceFile.copy(targetFile.path);
    await _registerFont(fontName, targetFile);

    final fontItem = CustomFontItem(
      name: fontName,
      fontFamily: fontName,
      file: targetFile,
    );
    _fonts.add(fontItem);
    return fontItem;
  }

  /// 动态注册到 Flutter FontLoader
  Future<void> _registerFont(String fontFamily, File file) async {
    try {
      final fontLoader = FontLoader(fontFamily);
      fontLoader.addFont(() async {
        final bytes = await file.readAsBytes();
        return ByteData.view(bytes.buffer);
      }());
      await fontLoader.load();
    } catch (_) {}
  }
}