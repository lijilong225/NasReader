import 'package:flutter_test/flutter_test.dart';
import 'package:nas_reader/config/api_config.dart';

void main() {
  group('AuthUser.fromJson', () {
    test('保留后端 32 位 hex 用户 ID（不再被解析成数字）', () {
      const hexId = '9f8e7d6c5b4a39281706f5e4d3c2b1a0';
      final user = AuthUser.fromJson({'id': hexId, 'username': 'alice'});
      expect(user.id, hexId);
      expect(user.username, 'alice');
    });

    test('兼容 user_id / userId 别名', () {
      expect(AuthUser.fromJson({'user_id': 'abc'}).id, 'abc');
      expect(AuthUser.fromJson({'userId': 'abc'}).id, 'abc');
    });

    test('历史数据中的数字 ID 转为字符串', () {
      expect(AuthUser.fromJson({'id': 42}).id, '42');
    });

    test('缺失字段回退为空字符串', () {
      final user = AuthUser.fromJson({});
      expect(user.id, '');
      expect(user.username, '');
      expect(user.email, isNull);
      expect(user.nickname, isNull);
    });
  });
}
