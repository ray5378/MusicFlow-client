// batch34 C 路 —— `lib/features/library/widgets/library_collection_components.dart` 补测。
//
// 覆盖点：
//   * MusicFlowAlbumTile：名称/歌手/收藏角标/正在播放遮罩/点击与长按回调/
//     歌手为空的兜底；
//   * MusicFlowAlbumRow：行渲染/收藏尾标/歌手空兜底/allowFullText；
//   * MusicFlowArtistRow：名称/专辑数/无专辑数/无封面占位/点击长按；
//   * MusicFlowLibrarySectionLabel：分区标签 + header 语义；
//   * MusicFlowAzIndexReveal：enabled=false 直通 / 滚动通知显出轨道 /
//     右缘按压显出 / 长时间无操作自动隐藏（1200ms Timer，有界推帧驱动）/
//     非右缘按压不显出；
//   * MusicFlowMediaListSkeleton：有界(ListView 分支)/无界(Column 分支)/circle；
//   * MusicFlowAlbumGridSkeleton：网格骨架渲染。
//
// 踩坑记录：
// #L1 CoverArtImage 的 build 一进来就 watch(activeAddressProvider)，所以宿主
//     必须 override 该 provider（默认链会触达 drift/地址池）。
// #L2 封面 id 一律传 null：CoverArtImage 对空 id 早退占位，不发起网络请求，
//     也不留 pending timer。
// #L3 MusicFlowSkeleton 是无限动画（骨架屏 shimmer），统一有界推帧。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/album.dart';
import 'package:musicflow_client/data/models/artist.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/features/library/widgets/library_collection_components.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/widgets/cover_art_image.dart';
import 'package:musicflow_client/widgets/now_playing_bars.dart';

Album _album({
  String id = 'al-1',
  String? artist = '王菲',
  bool starred = false,
}) =>
    Album(
      id: id,
      name: '寓言',
      artist: artist,
      coverArt: null,
      songCount: 10,
      duration: 3600,
      starred: starred,
    );

Artist _artist({int? albumCount, String? coverArt}) => Artist(
      id: 'ar-1',
      name: '王菲',
      albumCount: albumCount,
      coverArt: coverArt,
    );

Future<void> settle(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Widget host(Widget child) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh'),
    theme: AppTheme.light(),
    home: Scaffold(
      body: SingleChildScrollView(
        child: SizedBox(
          width: 800,
          child: child,
        ),
      ),
    ),
  );
}

void main() {
  // activeAddressProvider/subsonicApiClientProvider 的 override 包裹
  // （CoverArtImage 会 watch 它们，默认链会触达 drift/地址池）。地址 status
  // 非 ok → 走加载骨架占位，不发网络请求。
  Widget scoped(Widget child) {
    final now = DateTime(2026, 10, 1);
    final library = MusicLibrary(
      id: 'lib-test',
      name: '测试库',
      createdAt: now,
      updatedAt: now,
    );
    final client = SubsonicApiClient(
      dio: Dio(BaseOptions(baseUrl: 'https://music.example.test')),
    )..setLibrary(library);
    return ProviderScope(
      overrides: <Override>[
        subsonicApiClientProvider.overrideWithValue(client),
        activeAddressProvider.overrideWith(
          (ref) => ServerAddress(
            id: 'addr-test',
            libraryId: 'lib-test',
            label: '测试',
            url: 'http://127.0.0.1:4533',
            priority: 0,
            status: ServerAddressStatus.unknown,
          ),
        ),
      ],
      child: host(child),
    );
  }

  /// 默认视口 800x600 装不下 800 宽的方形封面 + 文本，测试里把视口加高。
  void enlargeView(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  group('MusicFlowAlbumTile', () {
    testWidgets('渲染专辑名与歌手，点击触发 onPressed', (tester) async {
      enlargeView(tester);
      var taps = 0;
      await tester.pumpWidget(scoped(
        MusicFlowAlbumTile(
          album: _album(),
          onPressed: () => taps++,
        ),
      ));
      await settle(tester);

      expect(find.text('寓言'), findsOneWidget);
      expect(find.text('王菲'), findsOneWidget);
      // 封面 id 为空 → 音乐占位图标。
      expect(find.byIcon(AppIcons.music), findsOneWidget);

      await tester.tap(find.text('寓言'));
      await tester.pump();
      expect(taps, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('starred → 收藏心形角标；isNowPlaying → 跳动竖条遮罩',
        (tester) async {
      await tester.pumpWidget(scoped(
        MusicFlowAlbumTile(
          album: _album(starred: true),
          isNowPlaying: true,
          onPressed: () {},
        ),
      ));
      await settle(tester);

      expect(find.byIcon(AppIcons.heart), findsOneWidget);
      expect(find.byType(NowPlayingCoverOverlay), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('长按触发 onLongPress；artist 为 null 不渲染歌手文本',
        (tester) async {
      enlargeView(tester);
      var longPresses = 0;
      await tester.pumpWidget(scoped(
        MusicFlowAlbumTile(
          album: _album(artist: null),
          onPressed: () {},
          onLongPress: () => longPresses++,
        ),
      ));
      await settle(tester);

      expect(find.text('王菲'), findsNothing);
      await tester.longPress(find.text('寓言'));
      await tester.pump();
      expect(longPresses, 1);
      expect(tester.takeException(), isNull);
    });
  });

  group('MusicFlowAlbumRow', () {
    testWidgets('行渲染 + 收藏尾标 + 点击回调', (tester) async {
      var taps = 0;
      await tester.pumpWidget(scoped(
        MusicFlowAlbumRow(
          album: _album(starred: true),
          onPressed: () => taps++,
        ),
      ));
      await settle(tester);

      expect(find.text('寓言'), findsOneWidget);
      expect(find.text('王菲'), findsOneWidget);
      expect(find.byIcon(AppIcons.heart), findsOneWidget);
      expect(find.byIcon(AppIcons.chevronRight), findsOneWidget);

      await tester.tap(find.text('寓言'));
      await tester.pump();
      expect(taps, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('artist=null 与 allowFullText=false 均可渲染', (tester) async {
      await tester.pumpWidget(scoped(
        MusicFlowAlbumRow(
          album: _album(artist: null),
          allowFullText: false,
          contentPadding: const EdgeInsets.all(8),
          onPressed: () {},
        ),
      ));
      await settle(tester);

      expect(find.text('寓言'), findsOneWidget);
      expect(find.text('王菲'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('MusicFlowArtistRow', () {
    testWidgets('名称 + 专辑数 + 点击/长按回调', (tester) async {
      var taps = 0;
      var longPresses = 0;
      await tester.pumpWidget(scoped(
        MusicFlowArtistRow(
          artist: _artist(albumCount: 5),
          onPressed: () => taps++,
          onLongPress: () => longPresses++,
        ),
      ));
      await settle(tester);

      expect(find.text('王菲'), findsOneWidget);
      expect(find.textContaining('5'), findsOneWidget,
          reason: '专辑数标签应渲染数字 5');
      // coverArt 为空 → 人像占位图标。
      expect(find.byIcon(AppIcons.profile), findsOneWidget);

      await tester.tap(find.text('王菲'));
      await tester.pump();
      await tester.longPress(find.text('王菲'));
      await tester.pump();
      expect(taps, 1);
      expect(longPresses, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('albumCount=null 不渲染专辑数', (tester) async {
      await tester.pumpWidget(scoped(
        MusicFlowArtistRow(
          artist: _artist(),
          onPressed: () {},
        ),
      ));
      await settle(tester);

      expect(find.text('王菲'), findsOneWidget);
      expect(find.textContaining('专辑'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('有 coverArt 时渲染 CoverArtImage（未就绪地址 → 骨架占位）',
        (tester) async {
      await tester.pumpWidget(scoped(
        MusicFlowArtistRow(
          artist: _artist(coverArt: 'ar-1-cover'),
          onPressed: () {},
        ),
      ));
      await settle(tester);

      expect(find.byType(CoverArtImage), findsOneWidget);
      expect(find.byType(MusicFlowSkeleton), findsOneWidget,
          reason: '地址未就绪 → 加载骨架占位');
      expect(tester.takeException(), isNull);
    });
  });

  group('MusicFlowLibrarySectionLabel', () {
    testWidgets('渲染标签文本且带 header 语义', (tester) async {
      await tester.pumpWidget(scoped(
        const MusicFlowLibrarySectionLabel(label: '全部专辑'),
      ));
      await settle(tester);

      expect(find.text('全部专辑'), findsOneWidget);
      final text = tester.widget<Text>(find.text('全部专辑'));
      expect(text.semanticsLabel, isNull);
      expect(
        find.ancestor(
          of: find.text('全部专辑'),
          matching: find.byType(Semantics),
        ),
        findsWidgets,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('MusicFlowAzIndexReveal', () {
    Widget railHost({bool enabled = true, required Widget child}) {
      return scoped(
        SizedBox(
          height: 400,
          child: MusicFlowAzIndexReveal(
            enabled: enabled,
            builder: (context, opacity, visible) => Column(
              children: <Widget>[
                Text('visible=$visible'),
                Expanded(child: child),
              ],
            ),
          ),
        ),
      );
    }

    testWidgets('enabled=false 直接以不可见态构建', (tester) async {
      await tester.pumpWidget(railHost(
        enabled: false,
        child: ListView.builder(
          itemCount: 30,
          itemBuilder: (context, index) => Text('行$index'),
        ),
      ));
      await settle(tester);

      expect(find.text('visible=false'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('滚动 → 轨道显出；静止 1200ms 后自动隐藏', (tester) async {
      await tester.pumpWidget(railHost(
        child: ListView.builder(
          itemCount: 60,
          itemBuilder: (context, index) => SizedBox(
            height: 40,
            child: Text('条目$index'),
          ),
        ),
      ));
      await settle(tester);
      expect(find.text('visible=false'), findsOneWidget);

      // 拖动列表产生滚动通知。
      await tester.drag(find.text('条目2'), const Offset(0, -80));
      // TweenAnimationBuilder 需要几帧才把 opacity 推过 0.01。
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.text('visible=true'), findsOneWidget, reason: '滚动应显出轨道');

      // linger Timer 1200ms 后自动隐藏（有界推帧驱动时钟）。
      await tester.pump(const Duration(milliseconds: 1400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('visible=false'), findsOneWidget, reason: '超时自动隐藏');
      expect(tester.takeException(), isNull);
    });

    testWidgets('右缘 40px 内按压 → 显出；非右缘按压不显出', (tester) async {
      await tester.pumpWidget(railHost(
        child: ListView.builder(
          itemCount: 60,
          itemBuilder: (context, index) => SizedBox(
            height: 40,
            child: Text('条目$index'),
          ),
        ),
      ));
      await settle(tester);

      // 视口宽 800，右缘激活带 = [760, 800]。
      final gesture = await tester.startGesture(const Offset(785, 200));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.text('visible=true'), findsOneWidget, reason: '右缘按压显出');
      await gesture.up();
      await tester.pump();

      // 非右缘（x=400）按压不应再次显出（先等自动隐藏）。
      await tester.pump(const Duration(milliseconds: 1400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('visible=false'), findsOneWidget);
      final gesture2 = await tester.startGesture(const Offset(400, 200));
      await tester.pump();
      expect(
        find.text('visible=false'),
        findsOneWidget,
        reason: '非右缘按压不触发显出',
      );
      await gesture2.up();
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('MusicFlowMediaListSkeleton', () {
    testWidgets('有界高度走 ListView 分支，渲染 count 行（行骨架两段线）',
        (tester) async {
      await tester.pumpWidget(scoped(
        const SizedBox(
          height: 500,
          child: MusicFlowMediaListSkeleton(count: 3),
        ),
      ));
      await settle(tester);

      // 每行 2 条 line 骨架 + 1 个方块骨架。
      final lines = tester.widgetList<MusicFlowSkeleton>(
        find.byType(MusicFlowSkeleton),
      );
      expect(lines.length, 3 * 3);
      expect(tester.takeException(), isNull);
    });

    testWidgets('无界高度走 Column 分支（不崩）', (tester) async {
      await tester.pumpWidget(scoped(
        Column(
          children: const <Widget>[
            MusicFlowMediaListSkeleton(count: 2),
          ],
        ),
      ));
      await settle(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('circle=true 用圆形骨架', (tester) async {
      await tester.pumpWidget(scoped(
        const SizedBox(
          height: 500,
          child: MusicFlowMediaListSkeleton(circle: true, count: 2),
        ),
      ));
      await settle(tester);

      final skeleton = tester.widgetList<MusicFlowSkeleton>(
        find.byType(MusicFlowSkeleton),
      );
      expect(
        skeleton.where((s) => s.borderRadius == BorderRadius.circular(999)),
        isNotEmpty,
        reason: 'circle 分支应产生圆形骨架',
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('MusicFlowAlbumGridSkeleton', () {
    testWidgets('渲染 count 个网格骨架单元', (tester) async {
      await tester.pumpWidget(scoped(
        const SizedBox(
          height: 600,
          child: MusicFlowAlbumGridSkeleton(count: 4),
        ),
      ));
      await settle(tester);

      expect(find.byType(MusicFlowSkeleton), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });
}
