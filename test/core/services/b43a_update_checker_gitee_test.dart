// b43a —— 更新通道：Gitee 解析 + check() 回退编排的行为测试。
//
// Gitee 分支的字段形状按真机实测钉住（html_url=null / assets[].size=null /
// 自动追加的 tag 归档资产）；回退编排在 check() 上以 fetcher 注入验证，
// 不发真实网络请求。
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/services/update_checker.dart';

void main() {
  group('parseGiteeRelease（真机实测字段形状）', () {
    final realShapedData = <String, dynamic>{
      'tag_name': 'v5.16.3',
      'name': 'MusicFlow Client v5.16.3',
      'body': '## 更新内容\n- 修复中文/空格文件名\n',
      'html_url': null,
      'prerelease': false,
      'assets': <dynamic>[
        <String, dynamic>{
          'name': 'MusicFlow-v5163-android.apk',
          'browser_download_url':
              'https://gitee.com/ray5378/music-flow-client/releases/download/'
              'v5.16.3/MusicFlow-v5163-android.apk',
          'size': null,
        },
        <String, dynamic>{
          'name': 'MusicFlow-v5163-windows-setup.exe',
          'browser_download_url':
              'https://gitee.com/ray5378/music-flow-client/releases/download/'
              'v5.16.3/MusicFlow-v5163-windows-setup.exe',
          'size': null,
        },
        // Gitee 自动追加的 tag 归档资产（无 size）。
        <String, dynamic>{
          'name': 'v5.16.3.zip',
          'browser_download_url':
              'https://gitee.com/ray5378/music-flow-client/archive/refs/tags/'
              'v5.16.3.zip',
          'size': null,
        },
      ],
    };

    test('html_url=null → 拼接发布页；size=null → 0；hasUpdate 判定正确', () {
      final result = UpdateChecker.parseGiteeRelease(
        realShapedData,
        currentVersion: '5.16.2',
      );
      expect(result.hasUpdate, isTrue);
      expect(result.currentVersion, '5.16.2');
      expect(result.latestVersion, '5.16.3');
      expect(
        result.releaseUrl,
        'https://gitee.com/ray5378/music-flow-client/releases/tag/v5.16.3',
      );
      expect(result.releaseNotes, isNotNull);
      expect(result.viaFallback, isFalse);
      expect(result.assets.length, 3);
      expect(result.assets.every((asset) => asset.size == 0), isTrue);
      expect(result.assets.first.name, 'MusicFlow-v5163-android.apk');
    });

    test('同版本 → hasUpdate=false；旧版本 tag 不带 v 前缀也能解析', () {
      final same = UpdateChecker.parseGiteeRelease(
        realShapedData,
        currentVersion: '5.16.3',
      );
      expect(same.hasUpdate, isFalse);

      final noV = Map<String, dynamic>.from(realShapedData)
        ..['tag_name'] = '5.17.0';
      final result = UpdateChecker.parseGiteeRelease(
        noV,
        currentVersion: '5.16.3',
      );
      expect(result.latestVersion, '5.17.0');
      expect(result.releaseUrl, contains('/releases/tag/5.17.0'));
    });

    test('html_url 非空时直接使用（不拼接）', () {
      final withUrl = Map<String, dynamic>.from(realShapedData)
        ..['html_url'] = 'https://gitee.com/ray5378/music-flow-client/releases';
      final result = UpdateChecker.parseGiteeRelease(
        withUrl,
        currentVersion: '5.16.2',
      );
      expect(result.releaseUrl, 'https://gitee.com/ray5378/music-flow-client/releases');
    });

    test('空 tag_name → FormatException', () {
      expect(
        () => UpdateChecker.parseGiteeRelease(
          <String, dynamic>{'tag_name': ''},
          currentVersion: '5.16.2',
        ),
        throwsFormatException,
      );
    });
  });

  group('check() 通道选择与回退编排（fetcher 注入，不发网络请求）', () {
    UpdateCheckResult resultFrom(String url) => UpdateCheckResult(
          hasUpdate: true,
          currentVersion: '1.0.0',
          latestVersion: '1.1.0',
          releaseUrl: url,
        );

    test('gitee 成功 → 直接返回，不触 GitHub，无回退标注', () async {
      var githubCalled = false;
      final result = await UpdateChecker.check(
        channel: UpdateChannel.gitee,
        currentVersionOverride: '1.0.0',
        giteeFetcher: () async => resultFrom('gitee-url'),
        githubFetcher: () async {
          githubCalled = true;
          return resultFrom('github-url');
        },
      );
      expect(result.releaseUrl, 'gitee-url');
      expect(result.viaFallback, isFalse);
      expect(githubCalled, isFalse);
    });

    test('gitee 失败 → 自动回退 GitHub，结果带 viaFallback 标注', () async {
      final result = await UpdateChecker.check(
        channel: UpdateChannel.gitee,
        currentVersionOverride: '1.0.0',
        giteeFetcher: () async => throw StateError('gitee offline'),
        githubFetcher: () async => resultFrom('github-url'),
      );
      expect(result.releaseUrl, 'github-url');
      expect(result.viaFallback, isTrue);
    });

    test('gitee 与 GitHub 都失败 → UpdateChannelsExhaustedException', () async {
      await expectLater(
        UpdateChecker.check(
          channel: UpdateChannel.gitee,
          currentVersionOverride: '1.0.0',
          giteeFetcher: () async => throw StateError('gitee offline'),
          githubFetcher: () async => throw StateError('github offline'),
        ),
        throwsA(
          isA<UpdateChannelsExhaustedException>()
              .having((e) => e.giteeError, 'giteeError', isA<StateError>())
              .having((e) => e.githubError, 'githubError', isA<StateError>()),
        ),
      );
    });

    test('显式 github 通道 → 只走 GitHub，giteeFetcher 不被调用', () async {
      var giteeCalled = false;
      final result = await UpdateChecker.check(
        channel: UpdateChannel.github,
        currentVersionOverride: '1.0.0',
        giteeFetcher: () async {
          giteeCalled = true;
          return resultFrom('gitee-url');
        },
        githubFetcher: () async => resultFrom('github-url'),
      );
      expect(result.releaseUrl, 'github-url');
      expect(result.viaFallback, isFalse);
      expect(giteeCalled, isFalse);
    });
  });
}
