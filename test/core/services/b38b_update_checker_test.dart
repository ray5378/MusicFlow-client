import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/services/update_checker.dart';

void main() {
  UpdateCheckResult build(List<ReleaseAsset> assets) => UpdateCheckResult(
        hasUpdate: false,
        currentVersion: '1.0.0',
        latestVersion: '1.0.0',
        assets: assets,
      );

  ReleaseAsset a(String name) => ReleaseAsset(name: name, downloadUrl: 'u', size: 1);

  test('linux/mac fallback picks .zip', () {
    final result = build([a('app-linux.zip'), a('app.dmg')]);
    final picked = pickPlatformUpdateAsset(result, platform: TargetPlatform.linux);
    expect(picked?.name, 'app-linux.zip');
  });

  test('macOS with no zip falls back to first asset (line 46)', () {
    final result = build([a('app.apk'), a('app.exe')]);
    final picked = pickPlatformUpdateAsset(result, platform: TargetPlatform.macOS);
    expect(picked?.name, 'app.apk');
  });
}
