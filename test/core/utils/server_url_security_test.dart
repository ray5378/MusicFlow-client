import 'package:musicflow_client/core/utils/server_url_security.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isSupportedServerUrl', () {
    test('accepts http and https urls', () {
      expect(isSupportedServerUrl('http://192.168.1.5:4533'), isTrue);
      expect(isSupportedServerUrl('https://music.example.com'), isTrue);
    });

    test('rejects urls without a supported scheme', () {
      expect(isSupportedServerUrl('music.example.com'), isFalse);
      expect(isSupportedServerUrl('ftp://music.example.com'), isFalse);
      expect(isSupportedServerUrl('https:///missing-host'), isFalse);
    });
  });

  group('isInsecureHttpUrl', () {
    test('detects cleartext http even with surrounding whitespace', () {
      expect(isInsecureHttpUrl('  http://nas.local:4533  '), isTrue);
    });

    test('does not flag https or invalid urls', () {
      expect(isInsecureHttpUrl('https://music.example.com'), isFalse);
      expect(isInsecureHttpUrl('not a url'), isFalse);
    });
  });

  group('normalizeServerBaseUrl', () {
    test('strips trailing slash (root-of-host deployment)', () {
      expect(
        normalizeServerBaseUrl('http://192.168.10.240:46400/'),
        'http://192.168.10.240:46400',
      );
    });

    test('trims whitespace and drops query/fragment', () {
      expect(
        normalizeServerBaseUrl('  https://music.example.com/  '),
        'https://music.example.com',
      );
      expect(
        normalizeServerBaseUrl('http://host:4533/?token=abc#frag'),
        'http://host:4533',
      );
    });

    test('preserves sub-path deployments (reverse proxy under /music)', () {
      expect(
        normalizeServerBaseUrl('http://host/music/'),
        'http://host/music',
      );
      expect(
        normalizeServerBaseUrl('https://host/music'),
        'https://host/music',
      );
    });

    test('strips trailing SPA page route copied from web login link', () {
      // 用户从浏览器复制的外网登录链接：https://music.cmct.fun:35378/login
      expect(
        normalizeServerBaseUrl('https://music.cmct.fun:35378/login'),
        'https://music.cmct.fun:35378',
      );
      expect(
        normalizeServerBaseUrl('https://host/songs'),
        'https://host',
      );
      expect(
        normalizeServerBaseUrl('https://host/settings'),
        'https://host',
      );
    });

    test('strips nested SPA routes (e.g. /admin/users)', () {
      expect(
        normalizeServerBaseUrl('https://host/admin/users'),
        'https://host',
      );
    });

    test('keeps deployment sub-path but strips SPA route under it', () {
      // 反代挂在 /music 下，前端路由 /music/login -> 基址应为 /music
      expect(
        normalizeServerBaseUrl('https://host/music/login'),
        'https://host/music',
      );
    });

    test('drops query/fragment on copied web links', () {
      expect(
        normalizeServerBaseUrl('https://host/login?redirect=%2F'),
        'https://host',
      );
      expect(
        normalizeServerBaseUrl('https://host/login#token=abc'),
        'https://host',
      );
    });

    test('empty input stays empty', () {
      expect(normalizeServerBaseUrl(''), '');
      expect(normalizeServerBaseUrl('   '), '');
    });
  });

  group('joinServerUrl (double-slash guard)', () {
    test('one slash between base and path even when base ends with slash', () {
      expect(
        joinServerUrl('http://host:46400/', '/rest/getCoverArt'),
        'http://host:46400/rest/getCoverArt',
      );
    });

    test('adds slash when path has no leading slash', () {
      expect(
        joinServerUrl('http://host:46400', 'rest/stream'),
        'http://host:46400/rest/stream',
      );
    });

    test('never produces //rest (the regression root cause)', () {
      final result = joinServerUrl('http://host:46400/', '/rest/stream');
      expect(result.contains('//rest'), isFalse);
      expect(result, 'http://host:46400/rest/stream');
    });

    test('empty base yields empty result', () {
      expect(joinServerUrl('', '/rest/ping'), '');
    });
  });
}
