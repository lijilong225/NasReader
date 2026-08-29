import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nas_reader/services/server_endpoint_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 按 baseUrl 前缀决定可达性的假适配器，避免测试发起真实网络请求
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.reachable);

  final Set<String> reachable;
  final List<String> requested = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final url = options.uri.toString();
    requested.add(url);
    if (reachable.any(url.startsWith)) {
      return ResponseBody.fromString('{}', 200);
    }
    throw DioException.connectionError(
      requestOptions: options,
      reason: 'host unreachable',
    );
  }

  @override
  void close({bool force = false}) {}
}

Dio _dioWith(Set<String> reachable) {
  final dio = Dio(BaseOptions(validateStatus: (_) => true));
  dio.httpClientAdapter = _FakeAdapter(reachable);
  return dio;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('normalizeUrl 复用 profile 的归一化规则', () {
    expect(ServerEndpointService.normalizeUrl(' http://nas:6088// '), 'http://nas:6088');
  });

  test('isReachableStatus 把 4xx 也视为服务可达', () {
    expect(ServerEndpointService.isReachableStatus(200), isTrue);
    expect(ServerEndpointService.isReachableStatus(404), isTrue);
    expect(ServerEndpointService.isReachableStatus(500), isFalse);
    expect(ServerEndpointService.isReachableStatus(null), isFalse);
  });

  test('active 在无备用地址时始终回落主地址', () {
    const withoutBackup = ServerEndpoints(
      primary: 'http://nas:6088',
      usingBackup: true,
    );
    expect(withoutBackup.hasBackup, isFalse);
    expect(withoutBackup.active, 'http://nas:6088');
  });

  test('active 在标记使用备用且备用存在时返回备用地址', () {
    const withBackup = ServerEndpoints(
      primary: 'http://nas:6088',
      backup: 'http://backup:6088',
      usingBackup: true,
    );
    expect(withBackup.active, 'http://backup:6088');

    const primaryActive = ServerEndpoints(
      primary: 'http://nas:6088',
      backup: 'http://backup:6088',
    );
    expect(primaryActive.active, 'http://nas:6088');
  });

  test('probe 对空地址直接返回不可用，不发起请求', () async {
    expect(await ServerEndpointService.probe('   '), isFalse);
  });

  test('pickAvailable 在主备均为空时返回 null', () async {
    expect(await ServerEndpointService.pickAvailable(primary: ''), isNull);
  });

  group('ensureActiveEndpoint', () {
    test('主服务器不可达时切换到备用并持久化', () async {
      await ServerEndpointService.save(
        primary: 'http://nas:6088',
        backup: 'http://backup:6088',
        usingBackup: false,
      );

      final pick = await ServerEndpointService.ensureActiveEndpoint(
        currentUrl: 'http://nas:6088',
        client: _dioWith({'http://backup:6088'}),
      );

      expect(pick, isNotNull);
      expect(pick!.url, 'http://backup:6088');
      expect(pick.usingBackup, isTrue);
      expect((await ServerEndpointService.load()).usingBackup, isTrue);
    });

    test('备用运行期间主服务器恢复时切回主服务器', () async {
      await ServerEndpointService.save(
        primary: 'http://nas:6088',
        backup: 'http://backup:6088',
        usingBackup: true,
      );

      final pick = await ServerEndpointService.ensureActiveEndpoint(
        currentUrl: 'http://backup:6088',
        client: _dioWith({'http://nas:6088', 'http://backup:6088'}),
      );

      expect(pick!.url, 'http://nas:6088');
      expect(pick.usingBackup, isFalse);
      expect((await ServerEndpointService.load()).usingBackup, isFalse);
    });

    test('当前地址已可用且无需切换时返回 null', () async {
      await ServerEndpointService.save(
        primary: 'http://nas:6088',
        backup: 'http://backup:6088',
        usingBackup: false,
      );

      final pick = await ServerEndpointService.ensureActiveEndpoint(
        currentUrl: 'http://nas:6088',
        client: _dioWith({'http://nas:6088'}),
      );

      expect(pick, isNull);
    });

    test('主备均不可达时保持原地址', () async {
      await ServerEndpointService.save(
        primary: 'http://nas:6088',
        backup: 'http://backup:6088',
        usingBackup: false,
      );

      final pick = await ServerEndpointService.ensureActiveEndpoint(
        currentUrl: 'http://nas:6088',
        client: _dioWith(const {}),
      );

      expect(pick, isNull);
      expect((await ServerEndpointService.load()).usingBackup, isFalse);
    });

    test('未配置备用地址时不做多余探测', () async {
      await ServerEndpointService.save(
        primary: 'http://nas:6088',
        backup: '',
        usingBackup: false,
      );

      final dio = _dioWith(const {});
      final pick = await ServerEndpointService.ensureActiveEndpoint(
        currentUrl: 'http://nas:6088',
        client: dio,
      );

      expect(pick, isNull);
      expect((dio.httpClientAdapter as _FakeAdapter).requested, isEmpty);
    });
  });
}
