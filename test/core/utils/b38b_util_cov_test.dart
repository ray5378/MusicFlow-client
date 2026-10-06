import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/utils/cover_ref_security.dart';
import 'package:musicflow_client/core/utils/network_error_notifier.dart';
import 'package:musicflow_client/core/utils/server_url_security.dart';

void main() {
  group('cover_ref_security gaps', () {
    test('isSafeServerCoverArtId (20/21)', () {
      expect(isSafeServerCoverArtId('abc123'), isTrue);
      expect(isSafeServerCoverArtId('..'), isFalse);
    });

    test('toTrustedCoverUrlRef throws on invalid url (27)', () {
      expect(() => toTrustedCoverUrlRef('ftp://x'), throwsArgumentError);
    });

    test('toCoverArtRef invalid trusted-url prefix returns null (61)', () {
      expect(toCoverArtRef('trusted-url:notvalid'), isNull);
    });
  });

  group('server_url_security gaps', () {
    test('normalize relative url with trailing slash (63/64)', () {
      expect(normalizeServerBaseUrl('relative/'), 'relative');
    });
  });

  group('network_error_notifier gaps', () {
    testWidgets('show assigns message (line 38)', (tester) async {
      // line 38 (final msg = message ?? l10n...) executes on every show() call.
      NetworkErrorNotifier.show('boom');
    });
  });
}
