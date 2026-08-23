import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:xml/xml.dart';

class EpubCoverExtractor {
  /// 获取封面缩略图缓存目录: ~/Documents/CoverThumbnails/
  static Future<Directory> _getCoverDirectory() async {
    final appDocDir = await getApplicationDocumentsDirectory();
    final coverDir = Directory(p.join(appDocDir.path, 'CoverThumbnails'));
    if (!await coverDir.exists()) {
      await coverDir.create(recursive: true);
    }
    return coverDir;
  }

  /// 提取 EPUB 封面图片并保存为本地缩略图文件
  /// 若已存在则直接返回缓存路径；若提取失败或无封面则返回 null
  static Future<File?> extractCover(File epubFile, String bookId) async {
    final coverDir = await _getCoverDirectory();
    final targetCoverFile = File(p.join(coverDir.path, '$bookId.cover'));

    if (await targetCoverFile.exists()) {
      return targetCoverFile;
    }

    try {
      final bytes = await epubFile.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      // 1. 读取 META-INF/container.xml 找到 rootfile (opf 路径)
      ArchiveFile? containerFile;
      for (final file in archive.files) {
        if (file.name == 'META-INF/container.xml') {
          containerFile = file;
          break;
        }
      }

      if (containerFile == null) return null;

      final containerXml = XmlDocument.parse(String.fromCharCodes(containerFile.content as List<int>));
      final rootfileElem = containerXml.findAllElements('rootfile').firstOrNull;
      final opfPath = rootfileElem?.getAttribute('full-path');
      if (opfPath == null) return null;

      final opfDir = p.dirname(opfPath);

      // 2. 读取 OPF 文件
      ArchiveFile? opfFile;
      for (final file in archive.files) {
        if (file.name == opfPath) {
          opfFile = file;
          break;
        }
      }

      if (opfFile == null) return null;

      final opfXml = XmlDocument.parse(String.fromCharCodes(opfFile.content as List<int>));

      // 3. 寻找封面图片项 ID (支持 EPUB 2/3 标准)
      String? coverItemId;

      // 方式 A: EPUB 3 标准 properties="cover-image"
      for (final item in opfXml.findAllElements('item')) {
        final properties = item.getAttribute('properties');
        if (properties != null && properties.contains('cover-image')) {
          coverItemId = item.getAttribute('id');
          break;
        }
      }

      // 方式 B: EPUB 2 标准 <meta name="cover" content="item_id"/>
      if (coverItemId == null) {
        for (final meta in opfXml.findAllElements('meta')) {
          if (meta.getAttribute('name') == 'cover') {
            coverItemId = meta.getAttribute('content');
            break;
          }
        }
      }

      // 4. 根据 ID 查找对应的 href 路径
      String? coverHref;
      for (final item in opfXml.findAllElements('item')) {
        final id = item.getAttribute('id');
        final href = item.getAttribute('href');
        final mediaType = item.getAttribute('media-type') ?? '';

        if (id == coverItemId) {
          coverHref = href;
          break;
        }

        // 方式 C: 兜底启发式匹配 id 或 href 包含 cover 的图片
        if (coverItemId == null &&
            mediaType.startsWith('image/') &&
            (id?.toLowerCase().contains('cover') == true || href?.toLowerCase().contains('cover') == true)) {
          coverHref = href;
          break;
        }
      }

      if (coverHref == null) return null;

      // 计算封面图片在 Zip 中的完整路径
      final fullCoverPath = (opfDir == '.' || opfDir.isEmpty)
          ? coverHref
          : p.normalize(p.join(opfDir, coverHref)).replaceAll(r'\', '/');

      ArchiveFile? coverImageFile;
      for (final file in archive.files) {
        if (file.name == fullCoverPath || file.name.endsWith(coverHref)) {
          coverImageFile = file;
          break;
        }
      }

      if (coverImageFile == null) return null;

      // 5. 保存封面图片至沙盒缩略图目录
      final coverBytes = coverImageFile.content as List<int>;
      await targetCoverFile.writeAsBytes(coverBytes);
      return targetCoverFile;
    } catch (_) {
      return null;
    }
  }
}