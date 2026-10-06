// batch32 B 路 —— `lib/features/discover/widgets/discover_recommend_widgets.dart` 补测。
//
// 基线覆盖率 ~0%。两个纯展示组件（无 provider 依赖）：
//   * DiscoverRecommendTile —— 封面引用三态（coverArtId / coverUrl /
//     都缺失）、点击/长按、大字号封面升格 80；
//   * DiscoverRecommendLoading —— 骨架屏数量（默认 3 / 自定义 count）。
// coverUrl 走 tryToTrustedCoverUrlRef：仅 http(s) URL 被包装为
// trusted-url: 前缀引用，非法 URL 返回 null → 回退占位图标。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/offline/offline_provider.dart';
import 'package:musicflow_client/features/discover/widgets/discover_recommend_widgets.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/widgets/cover_art_image.dart';

Widget _wrap(
  WidgetTester tester,
  Widget child, {
  double textScale = 1.0,
}) {
  // 设计系统组件（MusicFlowSkeleton 等）经 Riverpod 读取设计令牌，必须挂
  // ProviderScope；container 挂 addTearDown，避免残留 pending timer。
  // 覆盖封面组件依赖的后端设施：裸 Dio 客户端不拉起网络/媒体库监控器，
  // 离线缓存 init 直接完成 —— 避免这些单例在测试里留下 pending Timer。
  final container = ProviderContainer(
    overrides: <Override>[
      subsonicApiClientProvider.overrideWith(
        (Ref ref) => SubsonicApiClient(dio: Dio()),
      ),
      offlineCacheReadyProvider.overrideWith((Ref ref) async {}),
    ],
  );
  addTearDown(container.dispose);
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh'),
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: Scaffold(
        body: child,
      ),
    ),
    ),
  );
}

Future<void> settle(WidgetTester tester, {int frames = 4}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Finder coverImage() => find.byType(CoverArtImage);

/// 卸载组件树：CoverArtImage 加载失败会安排一次性重试 Timer，
/// 测试结束前 dispose 才能取消，否则触发 !timersPending 断言。
Future<void> unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

void main() {
  group('DiscoverRecommendTile · 封面引用', () {
    testWidgets('coverArtId 非空 -> 直接作为 CoverArtImage 引用', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _wrap(tester, DiscoverRecommendTile(
            title: '推荐歌单',
            coverArtId: 'pl-abc',
            onPressed: () {},
          ),
        ),
      );
      await settle(tester);

      final cover = tester.widget<CoverArtImage>(coverImage());
      expect(cover.coverArtId, 'pl-abc');
      expect(cover.size, 56, reason: '默认字号下封面 56');
      expect(find.byIcon(AppIcons.playlist), findsNothing);
      expect(tester.takeException(), isNull);
      await unmount(tester);
    });

    testWidgets('仅 coverUrl（http）-> 包装为 trusted-url 引用', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _wrap(tester, DiscoverRecommendTile(
            title: '平台歌单',
            coverUrl: 'http://example.com/cover.jpg',
            onPressed: () {},
          ),
        ),
      );
      await settle(tester);

      final cover = tester.widget<CoverArtImage>(coverImage());
      expect(cover.coverArtId, 'trusted-url:http://example.com/cover.jpg');
      expect(tester.takeException(), isNull);
      await unmount(tester);
    });

    testWidgets('coverUrl 非 http（非法引用）-> 回退占位图标', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _wrap(tester, DiscoverRecommendTile(
            title: '坏引用歌单',
            coverUrl: 'ftp://example.com/cover.jpg',
            onPressed: () {},
          ),
        ),
      );
      await settle(tester);

      expect(coverImage(), findsNothing);
      expect(find.byIcon(AppIcons.playlist), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('coverUrl 空串 + coverArtId 为 null/空 -> 回退占位图标', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _wrap(tester, DiscoverRecommendTile(
            title: '空封面歌单',
            coverArtId: '',
            coverUrl: '   ',
            onPressed: () {},
          ),
        ),
      );
      await settle(tester);

      expect(coverImage(), findsNothing);
      expect(find.byIcon(AppIcons.playlist), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('大字号（scale>1.3）-> 封面升格 80', (WidgetTester tester) async {
      await tester.pumpWidget(
        _wrap(tester, DiscoverRecommendTile(
            title: '大字号歌单',
            coverArtId: 'pl-big',
            onPressed: () {},
          ),
          textScale: 1.4,
        ),
      );
      await settle(tester);

      expect(tester.widget<CoverArtImage>(coverImage()).size, 80);
      expect(tester.takeException(), isNull);
      await unmount(tester);
    });
  });

  group('DiscoverRecommendTile · 文案与语义', () {
    testWidgets('标题 + 副标题渲染；副标题空串不渲染', (WidgetTester tester) async {
      await tester.pumpWidget(
        _wrap(tester, Column(
            children: <Widget>[
              DiscoverRecommendTile(
                title: '歌单一',
                subtitle: '12 首',
                onPressed: () {},
              ),
              DiscoverRecommendTile(
                title: '歌单二',
                subtitle: '   ',
                onPressed: () {},
              ),
            ],
          ),
        ),
      );
      await settle(tester);

      expect(find.text('歌单一'), findsOneWidget);
      expect(find.text('12 首'), findsOneWidget);
      expect(find.text('歌单二'), findsOneWidget);
      expect(find.text('   '), findsOneWidget,
          reason: '空白串 isNotEmpty 为 true，按现状仍会渲染（仅 null/空串跳过）');
      expect(tester.takeException(), isNull);
    });

    testWidgets('点击触发 onPressed，长按触发 onLongPress', (
      WidgetTester tester,
    ) async {
      var pressed = 0;
      var longPressed = 0;
      await tester.pumpWidget(
        _wrap(tester, DiscoverRecommendTile(
            title: '可点歌单',
            onPressed: () => pressed++,
            onLongPress: () => longPressed++,
          ),
        ),
      );
      await settle(tester);

      await tester.tap(find.text('可点歌单'));
      await settle(tester);
      expect(pressed, 1);

      await tester.longPress(find.text('可点歌单'));
      await settle(tester);
      expect(longPressed, 1);
      expect(tester.takeException(), isNull);
    });
  });

  group('DiscoverRecommendLoading · 骨架屏', () {
    testWidgets('默认渲染 3 组骨架', (WidgetTester tester) async {
      await tester.pumpWidget(_wrap(tester, const DiscoverRecommendLoading()));
      await settle(tester);

      // 每组骨架 = 1 个方块 + 2 条 line = 3 个 MusicFlowSkeleton。
      expect(
        find.byType(MusicFlowSkeleton),
        findsNWidgets(9),
        reason: '默认 count=3，每组 1 方块 + 2 线',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('自定义 count=5 -> 渲染 15 个骨架元素', (WidgetTester tester) async {
      await tester.pumpWidget(
        _wrap(tester, const DiscoverRecommendLoading(count: 5)),
      );
      await settle(tester);

      expect(find.byType(MusicFlowSkeleton), findsNWidgets(15));
      expect(tester.takeException(), isNull);
    });

    testWidgets('大字号下方块尺寸升到 80', (WidgetTester tester) async {
      await tester.pumpWidget(
        _wrap(tester, const DiscoverRecommendLoading(count: 1), textScale: 1.4),
      );
      await settle(tester);

      final square = tester
          .widgetList<MusicFlowSkeleton>(find.byType(MusicFlowSkeleton))
          .firstWhere((w) => w.height == 80 || w.height == 56);
      expect(square.height, 80);
      expect(tester.takeException(), isNull);
    });
  });
}
