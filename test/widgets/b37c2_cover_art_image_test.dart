// batch37 C(2) —— `lib/widgets/cover_art_image.dart` 剩余未覆盖分支。
//
// 既有 cover_art_image_test / b34c_cover_art_image_gate_test 已覆盖安全策略、
// 并发闸门、失败重试、离线命中、requestSize 优先级。本文件补：
//   * _getIconSize：size==null → 48、size 无穷 → 48、size 有限 → size*0.5（432-437）；
//   * _resolveCoverSize 兜底：requestSize=0 → 回落 size*dpr；size==null → 500（269-279）。
//
// 踩坑：链上网络封面会留 pending 状态，用例尾部统一卸载组件树释放槽位/控制器；
//       debugNetworkImageHttpClientProvider 用后复位。
//
// 只写 test/，只读 lib/（产品代码零改动）。

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/utils/cover_ref_security.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/widgets/cover_art_image.dart';

/// 永不完成的 HttpClient：网络封面停在加载态。
class _PendingHttpClient implements HttpClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Widget _scope({required Widget child}) {
  final now = DateTime(2026, 10, 1);
  final library = MusicLibrary(
    id: 'lib-cover',
    name: '封面测试库',
    createdAt: now,
    updatedAt: now,
  );
  final client = SubsonicApiClient(
    dio: Dio(BaseOptions(baseUrl: 'https://music.example.test')),
  )..setLibrary(library);
  return ProviderScope(
    overrides: <Override>[
      activeLibraryProvider.overrideWithValue(library),
      subsonicApiClientProvider.overrideWithValue(client),
      activeAddressProvider.overrideWith(
        (ref) => ServerAddress(
          id: 'addr-ok',
          libraryId: library.id,
          label: '测试地址',
          url: 'https://music.example.test',
          priority: 0,
          status: ServerAddressStatus.ok,
        ),
      ),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: Scaffold(body: Center(child: child)),
    ),
  );
}

void main() {
  testWidgets('占位图标尺寸：size 空/无穷 → 48，有限 → 一半', (tester) async {
    // coverArtId 空 → 直接占位（AppIcons.music），不触发任何网络/地址逻辑。
    await tester.pumpWidget(_scope(child: const CoverArtImage(coverArtId: null)));
    await tester.pump();
    Icon icon = tester.widget<Icon>(find.byIcon(AppIcons.music));
    expect(icon.size, 48, reason: 'size==null → 48');

    await tester.pumpWidget(
      _scope(child: const CoverArtImage(coverArtId: null, size: double.infinity)),
    );
    await tester.pump();
    icon = tester.widget<Icon>(find.byIcon(AppIcons.music));
    expect(icon.size, 48, reason: 'size 无穷 → 48');

    await tester.pumpWidget(
      _scope(child: const CoverArtImage(coverArtId: null, size: 40)),
    );
    await tester.pump();
    icon = tester.widget<Icon>(find.byIcon(AppIcons.music));
    expect(icon.size, 20, reason: 'size=40 → 40*0.5');
    expect(tester.takeException(), isNull);
  });

  testWidgets('解码尺寸兜底：requestSize=0 → size*dpr；size 空 → 500', (tester) async {
    debugNetworkImageHttpClientProvider = _PendingHttpClient.new;
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _scope(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox.square(
              dimension: 120,
              child: CoverArtImage(
                coverArtId: toTrustedCoverUrlRef('https://img.example.com/a.jpg'),
                size: 40,
                requestSize: 0, // 非正数 → 回落 size*dpr
              ),
            ),
            SizedBox.square(
              dimension: 120,
              child: CoverArtImage(
                coverArtId: toTrustedCoverUrlRef('https://img.example.com/b.jpg'),
                // size 与 requestSize 均空 → 兜底 500
              ),
            ),
          ],
        ),
      ),
    );
    await tester.pump();

    final images = tester.widgetList<Image>(find.byType(Image)).toList();
    expect(images.length, 2);
    expect((images[0].image as ResizeImage).width, 80,
        reason: 'requestSize=0 被忽略 → size=40 * dpr=2 = 80');
    expect((images[1].image as ResizeImage).width, 500,
        reason: 'size/requestSize 均空 → 500');
    expect(tester.takeException(), isNull);

    debugNetworkImageHttpClientProvider = null;
    await tester.pumpWidget(const SizedBox());
  });
}
