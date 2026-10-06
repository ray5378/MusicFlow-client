// batch36-B —— `lib/features/library/widgets/playlist_detail_blocks.dart` 补测。
//
// 现有 b32a/b35a 只在「歌单详情整页」里间接渲染这三个组件，宽窄两套布局、
// 文本放大堆叠、removing 禁用态、comment 空/非空、公开/私有、正在播放遮罩、
// 加载占位预览等分支都摸不到。本文件**直接单测组件本身**，逐个打满分支。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/features/library/widgets/media_detail_components.dart';
import 'package:musicflow_client/features/library/widgets/playlist_detail_blocks.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

Playlist _playlist({
  String id = 'p1',
  String name = '测试歌单',
  String? comment,
  bool public = false,
  int songCount = 0,
  int duration = 0,
  String? coverArt,
}) =>
    Playlist(
      id: id,
      name: name,
      comment: comment,
      public: public,
      songCount: songCount,
      duration: duration,
      coverArt: coverArt,
    );

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(800, 1000),
  double textScale = 1.0,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: AppTheme.light(),
        locale: const Locale('zh', 'CN'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: TextScaler.linear(textScale),
            ),
            child: child,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('PlaylistSelectionBar', () {
    testWidgets('宽屏 + 未移除中 → 行布局，点删除触发 onRemove', (tester) async {
      var removed = 0;
      await _pump(
        tester,
        PlaylistSelectionBar(
          selectedCount: 3,
          removing: false,
          onRemove: () => removed++,
        ),
        size: const Size(800, 400),
      );

      final loc = AppLocalizations.of(
        tester.element(find.byType(PlaylistSelectionBar)),
      );
      expect(find.text(loc.library_remove_selected), findsOneWidget);
      expect(find.text(loc.library_selected_count_rationale('3')), findsOneWidget);
      await tester.tap(find.text(loc.library_remove_selected));
      await tester.pump();
      expect(removed, 1);
    });

    testWidgets('removing=true → 显示「移除中」且按钮禁用', (tester) async {
      var removed = 0;
      await _pump(
        tester,
        PlaylistSelectionBar(
          selectedCount: 2,
          removing: true,
          onRemove: () => removed++,
        ),
        size: const Size(800, 400),
      );
      final loc = AppLocalizations.of(
        tester.element(find.byType(PlaylistSelectionBar)),
      );
      expect(find.text(loc.library_removing), findsOneWidget);
      expect(find.text(loc.library_remove_selected), findsNothing);
      await tester.tap(find.text(loc.library_removing));
      await tester.pump();
      expect(removed, 0, reason: '移除中按钮必须禁用，不得再次触发');
    });

    testWidgets('onRemove 为 null（不可用）也能渲染，不崩', (tester) async {
      await _pump(
        tester,
        const PlaylistSelectionBar(
          selectedCount: 1,
          removing: false,
          onRemove: null,
        ),
        size: const Size(800, 400),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('窄屏(<380) → 计数与按钮垂直堆叠', (tester) async {
      await _pump(
        tester,
        PlaylistSelectionBar(
          selectedCount: 5,
          removing: false,
          onRemove: () {},
        ),
        size: const Size(340, 600),
      );
      final loc = AppLocalizations.of(
        tester.element(find.byType(PlaylistSelectionBar)),
      );
      final countRect = tester.getRect(
        find.text(loc.library_remove_from_current_playlist),
      );
      final btnRect = tester.getRect(find.text(loc.library_remove_selected));
      expect(countRect.bottom, lessThanOrEqualTo(btnRect.top));
    });

    testWidgets('大字号(>1.3) 即使宽屏也堆叠', (tester) async {
      await _pump(
        tester,
        PlaylistSelectionBar(
          selectedCount: 5,
          removing: false,
          onRemove: () {},
        ),
        size: const Size(800, 600),
        textScale: 1.5,
      );
      final loc = AppLocalizations.of(
        tester.element(find.byType(PlaylistSelectionBar)),
      );
      final countRect = tester.getRect(
        find.text(loc.library_remove_from_current_playlist),
      );
      final btnRect = tester.getRect(find.text(loc.library_remove_selected));
      expect(countRect.bottom, lessThanOrEqualTo(btnRect.top));
    });
  });

  group('PlaylistIdentityHeader', () {
    testWidgets('宽屏(≥680) → 封面 176 且信息行渲染', (tester) async {
      await _pump(
        tester,
        PlaylistIdentityHeader(
          playlist: _playlist(songCount: 12, duration: 3600, public: true),
          songCount: 12,
        ),
        size: const Size(900, 900),
      );

      final loc = AppLocalizations.of(
        tester.element(find.byType(PlaylistIdentityHeader)),
      );
      expect(find.text('测试歌单'), findsOneWidget);
      expect(find.text(loc.library_song_count('12')), findsOneWidget);
      expect(find.text(loc.library_public_playlist), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('窄屏(<680) → 私有歌单标签,无 comment 不渲染描述', (tester) async {
      await _pump(
        tester,
        PlaylistIdentityHeader(
          playlist: _playlist(public: false),
          songCount: 0,
        ),
        size: const Size(420, 900),
      );
      final loc = AppLocalizations.of(
        tester.element(find.byType(PlaylistIdentityHeader)),
      );
      expect(find.text(loc.library_private_playlist), findsOneWidget);
      expect(find.text(loc.library_public_playlist), findsNothing);
    });

    testWidgets('有 comment → 渲染描述文本', (tester) async {
      await _pump(
        tester,
        PlaylistIdentityHeader(
          playlist: _playlist(comment: '这是我的私人精选'),
          songCount: 3,
        ),
        size: const Size(900, 900),
      );
      expect(find.text('这是我的私人精选'), findsOneWidget);
    });

    testWidgets('comment 全空白(trim 后为空) → 不渲染描述', (tester) async {
      await _pump(
        tester,
        PlaylistIdentityHeader(
          playlist: _playlist(comment: '   '),
          songCount: 3,
        ),
        size: const Size(900, 900),
      );
      expect(find.text('   '), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('isNowPlaying=true → 渲染正在播放遮罩叠加', (tester) async {
      await _pump(
        tester,
        PlaylistIdentityHeader(
          playlist: _playlist(),
          songCount: 1,
          isNowPlaying: true,
        ),
        size: const Size(900, 900),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(PlaylistIdentityHeader), findsOneWidget);
    });
  });

  group('PlaylistLoadingPreview', () {
    testWidgets('无封面 → 占位封面 + 名称 + 数量 + 加载指示器', (tester) async {
      await _pump(
        tester,
        const PlaylistLoadingPreview(name: '加载中的歌单', songCount: 8),
        size: const Size(800, 900),
      );
      final loc = AppLocalizations.of(
        tester.element(find.byType(PlaylistLoadingPreview)),
      );
      expect(find.text('加载中的歌单'), findsOneWidget);
      expect(find.text(loc.library_song_count('8')), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('封面占位头内确实渲染了 MediaDetailArtwork', (tester) async {
      await _pump(
        tester,
        const PlaylistLoadingPreview(name: '带封面歌单', songCount: 0),
        size: const Size(800, 900),
      );
      expect(find.text('带封面歌单'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(MediaDetailArtwork), findsOneWidget);
    });
  });
}
