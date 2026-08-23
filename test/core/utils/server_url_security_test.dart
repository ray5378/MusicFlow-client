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
