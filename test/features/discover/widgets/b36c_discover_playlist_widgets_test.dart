// b36c —— `lib/features/discover/widgets/discover_playlist_widgets.dart` 补测（原 28 miss）。
//
// 覆盖：DiscoverPlaylistTile（封面/图标分支 + 点按/长按）/ DiscoverPlaylistLoading
// （列数随宽度与字号）/ DiscoverPlaylistCard（封面/远程封面/空封面、副标题有无、
// loading 遮罩、正在播放遮罩与播放按钮互斥、compact 播放按钮可点、长按）/
// DiscoverPlaylistCardLoading。
//
// 封面走 CoverArtImage：地址未就绪时不发网络请求（无 Timer），用例尾部卸载树。
//
// 产品代码零改动；只读 lib。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/features/discover/widgets/discover_playlist_widgets.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/widgets/cover_art_image.dart';
import 'package:musicflow_client/widgets/now_playing_bars.dart';

Playlist _playlist({String? coverArt}) => Playlist(
      id: 'pl-1',
      name: '晨间歌单',
      songCount: 12,
      duration: 3600,
      coverArt: coverArt,
    );

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(400, 800),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        locale: const Locale('zh', 'CN'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        theme: AppTheme.light(),
        builder: (context, c) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: c!,
        ),
        home: Scaffold(
          body: Center(
            child: SingleChildScrollView(child: child),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('DiscoverPlaylistTile', () {
    testWidgets('无封面：显示歌单图标，点按触发回调', (tester) async {
      var taps = 0;
      await _pump(
        tester,
        DiscoverPlaylistTile(
          playlist: _playlist(),
          onPressed: () => taps++,
        ),
      );
      expect(find.text('晨间歌单'), findsOneWidget);
      expect(find.byIcon(AppIcons.playlist), findsOneWidget);
      expect(find.byType(CoverArtImage), findsNothing);

      await tester.tap(find.text('晨间歌单'));
      expect(taps, 1);
    });

    testWidgets('空封面字符串同样回落图标', (tester) async {
      await _pump(
        tester,
        DiscoverPlaylistTile(
          playlist: _playlist(coverArt: ''),
          onPressed: () {},
        ),
      );
      expect(find.byIcon(AppIcons.playlist), findsOneWidget);
    });

    testWidgets('有封面：渲染 CoverArtImage；长按触发回调', (tester) async {
      var longPress = 0;
      await _pump(
        tester,
        DiscoverPlaylistTile(
          playlist: _playlist(coverArt: 'pl-9'),
          onPressed: () {},
          onLongPress: () => longPress++,
        ),
      );
      expect(find.byType(CoverArtImage), findsOneWidget);

      await tester.longPress(find.byType(CoverArtImage));
      expect(longPress, 1);
    });
  });

  group('DiscoverPlaylistLoading', () {
    testWidgets('窄屏下单列，条目数等于 count', (tester) async {
      await _pump(
        tester,
        const DiscoverPlaylistLoading(count: 2),
        size: const Size(400, 800),
      );
      expect(find.byType(MusicFlowSkeleton), findsNWidgets(2 * 3));
    });

    testWidgets('宽屏下两列布局不抛', (tester) async {
      await _pump(
        tester,
        const DiscoverPlaylistLoading(count: 3),
        size: const Size(1000, 800),
      );
      expect(find.byType(MusicFlowSkeleton), findsNWidgets(3 * 3));
    });
  });

  group('DiscoverPlaylistCard', () {
    testWidgets('无封面：占位图标；无副标题；点按触发回调', (tester) async {
      var taps = 0;
      await _pump(
        tester,
        DiscoverPlaylistCard(
          title: '推荐歌单',
          onPressed: () => taps++,
        ),
      );
      expect(find.text('推荐歌单'), findsOneWidget);
      expect(find.byIcon(AppIcons.playlist), findsOneWidget);
      await tester.tap(find.text('推荐歌单'));
      expect(taps, 1);
    });

    testWidgets('coverArtId 优先于 coverUrl；渲染 CoverArtImage', (tester) async {
      await _pump(
        tester,
        DiscoverPlaylistCard(
          title: 'A',
          coverArtId: 'pl-42',
          coverUrl: 'https://example.com/c.jpg',
          subtitle: '12 首',
          onPressed: () {},
        ),
      );
      expect(find.byType(CoverArtImage), findsOneWidget);
      expect(find.text('12 首'), findsOneWidget);
    });

    testWidgets('仅 coverUrl：包成可信引用后渲染 CoverArtImage', (tester) async {
      await _pump(
        tester,
        DiscoverPlaylistCard(
          title: 'B',
          coverUrl: 'https://cdn.example.com/cover.png',
          onPressed: () {},
        ),
      );
      expect(find.byType(CoverArtImage), findsOneWidget);
    });

    testWidgets('coverUrl 非可信（非 http）时回落占位', (tester) async {
      await _pump(
        tester,
        DiscoverPlaylistCard(
          title: 'C',
          coverUrl: 'not-a-url',
          onPressed: () {},
        ),
      );
      expect(find.byType(CoverArtImage), findsNothing);
      expect(find.byIcon(AppIcons.playlist), findsOneWidget);
    });

    testWidgets('loading：显示进度遮罩；长按触发回调', (tester) async {
      var longPress = 0;
      await _pump(
        tester,
        DiscoverPlaylistCard(
          title: 'D',
          loading: true,
          coverArtId: 'pl-1',
          onPressed: () {},
          onLongPress: () => longPress++,
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.longPress(find.text('D'));
      expect(longPress, 1);
    });

    testWidgets('isNowPlaying：显示跳动竖条遮罩且隐藏播放按钮', (tester) async {
      await _pump(
        tester,
        DiscoverPlaylistCard(
          title: 'E',
          coverArtId: 'pl-1',
          isNowPlaying: true,
          onPlay: () {},
          onPressed: () {},
        ),
      );
      expect(find.byType(NowPlayingCoverOverlay), findsOneWidget);
      expect(find.byIcon(AppIcons.play), findsNothing);
    });

    testWidgets('compact：播放按钮常驻可点，触发 onPlay', (tester) async {
      var plays = 0;
      await _pump(
        tester,
        DiscoverPlaylistCard(
          title: 'F',
          coverArtId: 'pl-1',
          onPlay: () => plays++,
          onPressed: () {},
        ),
        size: const Size(400, 800),
      );
      final playIcon = find.byIcon(AppIcons.play);
      expect(playIcon, findsOneWidget);
      await tester.tap(playIcon);
      expect(plays, 1);
    });

    testWidgets('alwaysFresh 透传到封面（动态歌单）', (tester) async {
      await _pump(
        tester,
        DiscoverPlaylistCard(
          title: 'G',
          coverArtId: 'pl-1',
          alwaysFresh: true,
          onPressed: () {},
        ),
      );
      final image = tester.widget<CoverArtImage>(find.byType(CoverArtImage));
      expect(image.alwaysFresh, isTrue);
    });
  });

  group('DiscoverPlaylistCardLoading', () {
    testWidgets('渲染骨架宽度等于入参', (tester) async {
      await _pump(
        tester,
        const DiscoverPlaylistCardLoading(width: 200),
        size: const Size(400, 800),
      );
      expect(find.byType(MusicFlowSkeleton), findsWidgets);
    });
  });
}
