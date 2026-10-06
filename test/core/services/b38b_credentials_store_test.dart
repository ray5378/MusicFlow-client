import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/services/credentials_store.dart';

void main() {
  test('_supported evaluates all platform comparisons on non-android (30/31/32)',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      // Triggers the `_supported` getter; on linux it short-circuits past
      // android and evaluates the windows/iOS/macOS comparisons.
      await CredentialsStore.writeAll('server_config', 'id', {});
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
