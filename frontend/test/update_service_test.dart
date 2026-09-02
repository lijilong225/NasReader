import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nas_reader/services/update_service.dart';

/// 固定返回预设响应的假适配器，避免测试真实请求 GitHub
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.body, this.statusCode);

  final String body;
  final int statusCode;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async =>
      ResponseBody.fromString(
        body,
        statusCode,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );

  @override
  void close({bool force = false}) {}
}

Dio _dioWith(String body, {int statusCode = 200}) {
  final dio = Dio(BaseOptions(validateStatus: (_) => true));
  dio.httpClientAdapter = _FakeAdapter(body, statusCode);
  return dio;
}

void main() {
  test('parseVersion 兼容 v 前缀、构建号与预发布后缀', () {
    expect(UpdateService.parseVersion('v0.7.3'), [0, 7, 3]);
    expect(UpdateService.parseVersion('0.7.3+77'), [0, 7, 3]);
    expect(UpdateService.parseVersion(' V1.2.0-beta.1 '), [1, 2, 0]);
    expect(UpdateService.parseVersion('latest'), isEmpty);
  });

  test('compareVersions 逐段比较且缺失段按 0 处理', () {
    expect(UpdateService.compareVersions('1.0.0', '1.0'), 0);
    expect(UpdateService.compareVersions('0.10.0', '0.9.9'), 1);
    expect(UpdateService.compareVersions('0.7.3', '0.7.4'), -1);
  });

  test('isNewerVersion 仅在远端严格更高时为 true', () {
    expect(UpdateService.isNewerVersion('v0.8.0', '0.7.3'), isTrue);
    expect(UpdateService.isNewerVersion('v0.7.3', '0.7.3'), isFalse);
    expect(UpdateService.isNewerVersion('v0.7.2', '0.7.3'), isFalse);
  });

  test('check 在远端更高时返回更新信息与 Release 链接', () async {
    final result = await UpdateService.check(
      client: _dioWith(
        '{"tag_name":"v0.8.0","html_url":"https://github.com/lijilong225/NasReader/releases/tag/v0.8.0","body":"修复若干问题"}',
      ),
      currentVersion: '0.7.3',
    );

    expect(result.hasUpdate, isTrue);
    expect(result.latestVersion, '0.8.0');
    expect(result.releaseUrl, 'https://github.com/lijilong225/NasReader/releases/tag/v0.8.0');
    expect(result.releaseNotes, '修复若干问题');
  });

  test('check 对非 github.com 的 html_url 回落到官方 Release 页', () async {
    final result = await UpdateService.check(
      client: _dioWith('{"tag_name":"v0.9.0","html_url":"https://evil.example.com/x"}'),
      currentVersion: '0.7.3',
    );

    expect(result.hasUpdate, isTrue);
    expect(result.releaseUrl, UpdateService.releasePageUrl);
  });

  test('check 在版本相同时判定无更新', () async {
    final result = await UpdateService.check(
      client: _dioWith('{"tag_name":"v0.7.3"}'),
      currentVersion: '0.7.3',
    );

    expect(result.hasUpdate, isFalse);
    expect(result.currentVersion, '0.7.3');
  });

  test('check 在仓库无 Release(404) 时视为已是最新', () async {
    final result = await UpdateService.check(
      client: _dioWith('{"message":"Not Found"}', statusCode: 404),
      currentVersion: '0.7.3',
    );

    expect(result.hasUpdate, isFalse);
  });

  test('check 在版本号无法解析时抛出异常', () async {
    expect(
      () => UpdateService.check(
        client: _dioWith('{"tag_name":"nightly"}'),
        currentVersion: '0.7.3',
      ),
      throwsA(isA<Exception>()),
    );
  });
}
