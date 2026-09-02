// lib/services/update_service.dart
import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'app_logger.dart';

/// 一次版本检查的结论
class UpdateCheckResult {
  /// 远端版本严格大于本地版本时才为 true
  final bool hasUpdate;
  final String currentVersion;
  final String latestVersion;

  /// 引导用户下载的落地页
  final String releaseUrl;
  final String releaseNotes;

  const UpdateCheckResult({
    required this.hasUpdate,
    required this.currentVersion,
    this.latestVersion = '',
    this.releaseUrl = UpdateService.releasePageUrl,
    this.releaseNotes = '',
  });
}

/// 基于 GitHub Releases 的版本检查
class UpdateService {
  /// 未能取到具体 Release 时的兜底落地页
  static const String releasePageUrl =
      'https://github.com/lijilong225/NasReader/releases';

  /// 该接口自动跳过 draft 与 prerelease，取到的即为正式最新版
  static const String latestReleaseApi =
      'https://api.github.com/repos/lijilong225/NasReader/releases/latest';

  static const Duration _timeout = Duration(seconds: 8);

  /// 提取版本号中的数字段，兼容 `v1.2.3`、`1.2.3+77`、`1.2.3-beta.1` 等写法
  static List<int> parseVersion(String raw) {
    final core = raw.trim().replaceFirst(RegExp(r'^[vV]'), '').split(RegExp(r'[+\-_ ]')).first;
    final numbers = <int>[];
    for (final segment in core.split('.')) {
      final value = int.tryParse(segment.trim());
      if (value == null) break; // 遇到非数字段即停止，后续片段无比较意义
      numbers.add(value);
    }
    return numbers;
  }

  /// 逐段比较：a 大于 b 返回 1，小于返回 -1，相等返回 0；缺失的段按 0 处理
  static int compareVersions(String a, String b) {
    final left = parseVersion(a);
    final right = parseVersion(b);
    final length = left.length > right.length ? left.length : right.length;
    for (var i = 0; i < length; i++) {
      final l = i < left.length ? left[i] : 0;
      final r = i < right.length ? right[i] : 0;
      if (l != r) return l > r ? 1 : -1;
    }
    return 0;
  }

  static bool isNewerVersion(String latest, String current) =>
      compareVersions(latest, current) > 0;

  /// 查询 GitHub 最新 Release 并与本地版本比对；网络或接口异常时抛出
  static Future<UpdateCheckResult> check({Dio? client, String? currentVersion}) async {
    final current = currentVersion ?? (await PackageInfo.fromPlatform()).version;

    // 必须使用独立 Dio：NetworkClient 单例会向请求注入 NAS 的 Bearer Token，
    // 不能随请求泄漏到 github.com 这一第三方域名。
    final dio = client ??
        Dio(BaseOptions(
          connectTimeout: _timeout,
          receiveTimeout: _timeout,
          headers: const {
            'Accept': 'application/vnd.github+json',
            'User-Agent': 'NasReader-App',
          },
          validateStatus: (code) => code != null && code < 500,
        ));

    try {
      final res = await dio.get(latestReleaseApi);

      // 仓库尚未发布任何 Release 时接口返回 404，视为“已是最新”而非失败
      if (res.statusCode == 404) {
        AppLogger.log('ℹ️ GitHub 暂无已发布版本，跳过更新提示');
        return UpdateCheckResult(hasUpdate: false, currentVersion: current);
      }

      final data = res.data;
      if (res.statusCode != 200 || data is! Map) {
        throw Exception('GitHub 接口返回 ${res.statusCode}');
      }

      final tag = (data['tag_name'] ?? data['name'] ?? '').toString();
      if (parseVersion(tag).isEmpty) {
        throw Exception('无法解析远端版本号: $tag');
      }

      final htmlUrl = (data['html_url'] ?? '').toString();
      final result = UpdateCheckResult(
        hasUpdate: isNewerVersion(tag, current),
        currentVersion: current,
        latestVersion: tag.replaceFirst(RegExp(r'^[vV]'), ''),
        releaseUrl: htmlUrl.startsWith('https://github.com/') ? htmlUrl : releasePageUrl,
        releaseNotes: (data['body'] ?? '').toString().trim(),
      );

      AppLogger.log('🔎 版本检查：本地 $current / 远端 $tag / 需更新 ${result.hasUpdate}');
      return result;
    } finally {
      if (client == null) dio.close();
    }
  }
}
