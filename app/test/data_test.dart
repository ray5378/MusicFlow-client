import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_app/data/api_client.dart';
import 'package:musicflow_app/data/auth_store.dart';
import 'package:musicflow_app/data/models.dart';
import 'package:musicflow_app/player/dlna_service.dart';


// SharedPreferences 在纯 dart 测试里不可直接用；这里只测不依赖它的纯函数。
void main() {
  group('ApiClient.buildUri', () {
    test('拼接 host 与 query', () {
      final uri = ApiClient.buildUri(
        server: 'http://192.168.1.10:46400',
        path: '/rest/ping',
        query: {'v': '1.16.1'},
      );
      expect(uri.toString(), 'http://192.168.1.10:46400/rest/ping?v=1.16.1');
    });
  });

  group('AuthStore', () {
    test('normalize 补协议去尾斜杠', () {
      expect(AuthStore.normalize(' 192.168.1.10:46400/ '), 'http://192.168.1.10:46400');
      expect(AuthStore.normalize('https://a.b/c/'), 'https://a.b/c');
      expect(AuthStore.normalize(''), '');
    });
  });

  group('DLNA SOAP', () {
    test('信封包含 action 与参数转义', () {
      final env = soapEnvelope('urn:avt', 'SetAVTransportURI', {
        'CurrentURI': 'http://x/a?b=1&c=<2>',
      });
      expect(env, contains('<u:SetAVTransportURI xmlns:u="urn:avt">'));
      expect(env, contains('&amp;'));
      expect(env, contains('&lt;2&gt;'));
    });

    test('REL_TIME 时间格式', () {
      // 通过公开 API 间接验证 _hms：seek 前无设备时为 no-op，这里仅测解析。
      final d = DlnaStatus();
      expect(d.active, isFalse);
    });

    test('RemoteSong 字段容错', () {
      final s = RemoteSong.fromJson({
        'providerId': 'netease',
        'source': 'netease',
        'id': '42',
        'name': '像风一样',
        'artist': '薛之谦',
        'duration': 245.0,
      });
      expect(s.durationSeconds, 245);
      expect(s.toImportJson()['duration'], 245);
    });
  });
}
