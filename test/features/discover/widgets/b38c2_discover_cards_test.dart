// Route C 补测：`lib/features/discover/widgets/discover_playlist_widgets.dart`
//
// 覆盖点：
//   * 91：`DiscoverPlaylistLoading` 的构造函数（此前全库无构造点，骨架占位从未渲染）。
//   * 354/355：封面右下角播放按钮的 MouseRegion onEnter/onExit ——
//     桌面端「悬停才浮出播放按钮」的两态切换。
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/features/discover/widgets/discover_playlist_widgets.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

/// 一律抛错的 HttpClient：让卡片里可能存在的网络封面立刻失败。
class _FailingHttpClient implements HttpClient {
  @override
  Future<HttpClientRequest> getUrl(Uri url) async =>
      throw const SocketException('测试用失败客户端');

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      throw const SocketException('测试用失败客户端');

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Widget _host(Widget child) => ProviderScope(
      child: MaterialApp(
        theme: AppTheme.light(),
        locale: const Locale('zh', 'CN'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(body: Center(child: child)),
      ),
    );

/// 桌面端默认窗口类（非 compact）下，播放按钮平时 opacity=0、悬停后 1。
Finder get _playButtonOpacity => find.byWidgetPredicate(
      (Widget widget) =>
          widget is AnimatedOpacity &&
          widget.duration == const Duration(milliseconds: 150),
    );

/// 播放按钮外层的 MouseRegion（同时带 onEnter/onExit）。
Finder get _playButtonHoverRegion => find.byWidgetPredicate(
      (Widget widget) =>
          widget is MouseRegion &&
          widget.onEnter != null &&
          widget.onExit != null &&
          widget.child is AnimatedOpacity,
    );

void main() {
  testWidgets('DiscoverPlaylistLoading 渲染骨架占位（91）', (tester) async {
    await tester.pumpWidget(
      _host(const SizedBox(width: 400, child: DiscoverPlaylistLoading())),
    );
    await tester.pump();

    // 默认 count=3：每行一条 48x48 封面骨架 + 两行文字骨架。
    expect(find.byType(DiscoverPlaylistLoading), findsOneWidget);
    expect(find.byType(MusicFlowSkeleton), findsWidgets);
    expect(
      find.byWidgetPredicate(
        (Widget widget) => widget is MusicFlowSkeleton && widget.width == 48,
      ),
      findsNWidgets(3),
      reason: '默认 count=3 → 三条封面骨架',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('DiscoverPlaylistLoading 支持自定义条数（91）', (tester) async {
    await tester.pumpWidget(
      _host(
        const SizedBox(
          width: 400,
          child: DiscoverPlaylistLoading(count: 5),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byWidgetPredicate(
        (Widget widget) => widget is MusicFlowSkeleton && widget.width == 48,
      ),
      findsNWidgets(5),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('桌面端悬停浮出封面播放按钮：onEnter/onExit（354/355）',
      (tester) async {
    debugNetworkImageHttpClientProvider = _FailingHttpClient.new;
    addTearDown(() => debugNetworkImageHttpClientProvider = null);

    var played = 0;
    await tester.pumpWidget(
      _host(
        DiscoverPlaylistCard(
          title: '每日推荐',
          subtitle: '30 首',
          onPressed: () {},
          onPlay: () => played++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 没有 coverArtId/coverUrl → 走占位图标，播放按钮仍会挂上。
    expect(_playButtonHoverRegion, findsOneWidget);

    // 未悬停：播放按钮透明（桌面端 hover 才浮出）。
    final before = tester.widget<AnimatedOpacity>(_playButtonOpacity);
    expect(before.opacity, 0);

    // 鼠标移入 → onEnter → _hovered = true → opacity 1。
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(() => gesture.removePointer());
    await gesture.addPointer(location: Offset.zero);
    await gesture.moveTo(tester.getCenter(_playButtonHoverRegion));
    await tester.pumpAndSettle();

    expect(
      tester.widget<AnimatedOpacity>(_playButtonOpacity).opacity,
      1,
      reason: '悬停后播放按钮应完全不透明（354 行 onEnter）',
    );

    // 悬停态下按钮可点击（IgnorePointer 已放行）。
    await tester.tap(find.byIcon(AppIcons.play));
    await tester.pumpAndSettle();
    expect(played, 1, reason: '悬停浮出后点击应触发 onPlay');

    // 鼠标移出 → onExit → _hovered = false → 重新透明。
    await gesture.moveTo(const Offset(0, 0));
    await tester.pumpAndSettle();
    expect(
      tester.widget<AnimatedOpacity>(_playButtonOpacity).opacity,
      0,
      reason: '移出后播放按钮应重新隐藏（355 行 onExit）',
    );
    expect(tester.takeException(), isNull);

    // 还原 painting 调试变量（否则用例末尾的 invariant 校验会报「被修改」）。
    debugNetworkImageHttpClientProvider = null;
  });
}
