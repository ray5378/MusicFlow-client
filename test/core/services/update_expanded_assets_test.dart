import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/services/update_checker.dart';

/// v5.17.16:检查更新走 releases.atom 兜底时,atom 里没有资源列表,
/// assets 为空 ⇒ Android 内置更新挑不到 apk ⇒ 点「下载」直接跳去 GitHub
/// 发布页(Windows 才该有的行为)。修复方式是用 `releases/expanded_assets`
/// 补齐,**必须在数据源补**,否则下游 5 个消费点各打一次补丁迟早漂移。
///
/// 这里钉住纯解析函数:它从 HTML 片段里拿回「文件名 + 直链」。
void main() {
  group('UpdateChecker.parseExpandedAssets', () {
    // 取自真实响应(2026-11-17, v5.17.15)的结构精简版。
    const html = '<ul>'
        '<li class="Box-row"><div>'
        '<a href="/ray5378/MusicFlow-client/releases/download/v5.17.15/'
        'MusicFlow-v51715-android.apk" rel="nofollow">MusicFlow-v51715-android.apk</a>'
        '</div><div>46.9 MB</div></li>'
        '<li class="Box-row"><div>'
        '<a href="/ray5378/MusicFlow-client/releases/download/v5.17.15/'
        'MusicFlow-v51715-windows-setup.exe" rel="nofollow">'
        'MusicFlow-v51715-windows-setup.exe</a>'
        '</div><div>32 MB</div></li>'
        '</ul>';

    test('解析出全部资源,文件名取路径末段,直链补上域名', () {
      final assets = UpdateChecker.parseExpandedAssets(html);
      expect(assets.map((a) => a.name).toList(), <String>[
        'MusicFlow-v51715-android.apk',
        'MusicFlow-v51715-windows-setup.exe',
      ]);
      expect(
        assets.first.downloadUrl,
        'https://github.com/ray5378/MusicFlow-client/releases/download/'
        'v5.17.15/MusicFlow-v51715-android.apk',
      );
    });

    test('体积置 0(HTML 里只有人类可读串,反解成字节没意义)', () {
      final assets = UpdateChecker.parseExpandedAssets(html);
      expect(assets.every((a) => a.size == 0), isTrue);
    });

    test('没有下载链接时返回空列表(只有 Source code 的页面)', () {
      const sourceOnly = '<li><a href="/ray5378/MusicFlow-client/archive/'
          'refs/tags/v5.17.15.zip">Source code (zip)</a></li>';
      expect(UpdateChecker.parseExpandedAssets(sourceOnly), isEmpty);
      expect(UpdateChecker.parseExpandedAssets(''), isEmpty);
    });

    test('同名资源只保留第一条(页面重复渲染不产生重复项)', () {
      final doubled = '<a href="/o/r/releases/download/v1/a.apk">a</a>'
          '<a href="/o/r/releases/download/v1/a.apk">a</a>'
          '<a href="/o/r/releases/download/v1/b.apk">b</a>';
      final assets = UpdateChecker.parseExpandedAssets(doubled);
      expect(assets.map((a) => a.name).toList(), <String>['a.apk', 'b.apk']);
    });

    test('文件名做 URL 解码,链接上的查询串不混进文件名', () {
      const encoded = '<a href="/o/r/releases/download/v1/MusicFlow%20v1.apk'
          '?download=1">x</a>';
      final assets = UpdateChecker.parseExpandedAssets(encoded);
      expect(assets, hasLength(1));
      expect(assets.single.name, 'MusicFlow v1.apk');
      expect(
        assets.single.downloadUrl,
        'https://github.com/o/r/releases/download/v1/MusicFlow%20v1.apk',
      );
    });

    test('挑平台资产:补齐后的列表能被 pickPlatformUpdateAsset 挑中 apk', () {
      final assets = UpdateChecker.parseExpandedAssets(html);
      final result = UpdateCheckResult(
        hasUpdate: true,
        currentVersion: '5.17.14',
        latestVersion: '5.17.15',
        assets: assets,
      );
      final picked = pickPlatformUpdateAsset(
        result,
        platform: TargetPlatform.android,
      );
      expect(picked?.name, 'MusicFlow-v51715-android.apk');
    });
  });
}
