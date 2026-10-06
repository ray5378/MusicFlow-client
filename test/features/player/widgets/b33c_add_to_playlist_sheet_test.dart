// batch33 C 路 —— `lib/features/player/widgets/add_to_playlist_sheet.dart` 补测。
//
// 该 sheet 是公开 `ConsumerWidget`，直接渲染即可（无需走 show 入口）。用嵌套
// Navigator 把 sheet 推成独立路由：行内 `Navigator.of(context).pop()` 只关闭该
// 路由（sheet 自身），而成功 toast 经 `hostContext` 落到根导航 overlay。
// 覆盖：加载中 / 空态(无失败) / 空态(加载失败带重试) / 加载报错 / 有数据点击
// 添加 / 无仓库分支 / updatePlaylist 异常分支。
import 'dart:async';

import 'package:musicflow_client/core/utils/toast_notifier.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/playlist_repository.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/features/player/widgets/add_to_playlist_sheet.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/library/playlist_provider.dart';

const Size kSheetView = Size(520, 1000);

final ServerAddress kAddress = ServerAddress(
  id: 'addr1',
  libraryId: 'lib1',
  label: 'Home',
  url: 'http://127.0.0.1:4533',
  priority: 0,
);

final Song kSong = Song(id: 's1', title: '曲目一', artist: '测试艺术家', albumId: 'al1');

final List<Playlist> kPlaylists = <Playlist>[
  Playlist(id: 'p1', name: '歌单一', songCount: 3, duration: 100),
  Playlist(id: 'p2', name: '歌单二', songCount: 7, duration: 200),
];

/// 歌单仓库桩：只实现本 sheet 用到的 `updatePlaylist`。
class FakePlaylistRepository extends PlaylistRepository {
  FakePlaylistRepository() : super(SubsonicApiClient(dio: Dio()));

  Object? updateError;
  final List<String> addedPlaylistIds = <String>[];
  final List<List<String>> addedSongIds = <List<String>>[];

  @override
  Future<void> updatePlaylist({
    required String playlistId,
    String? name,
    String? comment,
    bool? public,
    List<String>? songIdsToAdd,
    List<int>? songIndexesToRemove,
  }) async {
    addedPlaylistIds.add(playlistId);
    addedSongIds.add(songIdsToAdd ?? const <String>[]);
    if (updateError != null) throw updateError!;
  }
}

/// 探针：把外层 context 递出当作 hostContext，并渲染嵌套 Navigator 承载 sheet。
class _RefProbe extends ConsumerWidget {
  const _RefProbe({required this.onReady, required this.builder});

  final void Function(BuildContext context) onReady;
  final Widget Function(BuildContext context) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    onReady(context);
    return builder(context);
  }
}

Future<void> settle(WidgetTester tester, {int frames = 12}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> drain(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

class SheetHarness {
  SheetHarness({
    this.repository,
    this.playlists,
    this.playlistsError,
    this.playlistsPending = false,
    this.playlistsLoadFailed = false,
  });

  final FakePlaylistRepository? repository;
  final List<Playlist>? playlists;
  final Object? playlistsError;
  final bool playlistsPending;
  final bool playlistsLoadFailed;

  ProviderContainer? container;
  AppLocalizations? loc;
  BuildContext? hostContext;
  final Completer<List<Playlist>> pending = Completer<List<Playlist>>();

  Widget build() {
    final container = ProviderContainer(
      overrides: <Override>[
        playlistRepositoryProvider.overrideWith((Ref ref) => repository),
        playlistsProvider.overrideWith((Ref ref) {
          if (playlistsPending) return pending.future;
          if (playlistsError != null) throw playlistsError!;
          return playlists ?? kPlaylists;
        }),
        playlistsLoadFailedProvider.overrideWith(
          (Ref ref) => playlistsLoadFailed,
        ),
        ensureActiveAddressProvider.overrideWith((Ref ref) async => kAddress),
        playlistDetailProvider.overrideWith((Ref ref, String id) async => null),
      ],
    );
    this.container = container;
    return UncontrolledProviderScope(
      container: container,
      child: MediaQuery(
        data: const MediaQueryData(size: kSheetView, devicePixelRatio: 1),
        child: MaterialApp(
          navigatorKey: rootNavigatorKey,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          theme: AppTheme.light(),
          home: _RefProbe(
            onReady: (BuildContext ctx) => hostContext = ctx,
            builder: (BuildContext ctx) => Navigator(
              onGenerateRoute: (_) => MaterialPageRoute<void>(
                builder: (_) => Scaffold(
                  body: AddToPlaylistSheet(hostContext: ctx, song: kSong),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> pump(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = kSheetView;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() => container?.dispose());
    await tester.pumpWidget(build());
    await settle(tester, frames: 6);
      loc = AppLocalizations.of(tester.element(find.byType(AddToPlaylistSheet)));
  }
}

Finder _row(String name) => find.text(name);

void main() {
  group('add_to_playlist_sheet · 三态', () {
    testWidgets('加载中 → 骨架占位，不渲染歌单行', (WidgetTester tester) async {
      final h = SheetHarness(playlistsPending: true);
      await h.pump(tester);
      expect(find.byType(PlaylistOptionsLoading), findsWidgets);
      expect(_row('歌单一'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('空列表且无失败 → 空态(无重试)', (WidgetTester tester) async {
      final h = SheetHarness(playlists: const <Playlist>[]);
      await h.pump(tester);
      expect(find.byType(MusicFlowEmptyState), findsWidgets);
      expect(find.text(h.loc!.song_option_no_playlists), findsWidgets);
      expect(find.text(h.loc!.song_option_create_playlist_hint), findsWidgets);
      expect(find.text(h.loc!.widgets_retry), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('空列表且加载失败 → 空态带重试', (WidgetTester tester) async {
      final h = SheetHarness(
        playlists: const <Playlist>[],
        playlistsLoadFailed: true,
      );
      await h.pump(tester);
      expect(find.text(h.loc!.song_option_playlist_load_failed), findsWidgets);
      expect(find.text(h.loc!.widgets_retry), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('加载报错 → 错误态 + 重试', (WidgetTester tester) async {
      final h = SheetHarness(playlistsError: StateError('boom'));
      await h.pump(tester);
      expect(find.byType(MusicFlowErrorState), findsWidgets);
      expect(find.text(h.loc!.song_option_playlist_load_failed), findsWidgets);
      expect(find.text(h.loc!.song_option_load_failed_desc), findsWidgets);
      expect(find.text(h.loc!.widgets_retry), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });

  group('add_to_playlist_sheet · 添加交互', () {
    testWidgets('有数据 → 渲染歌单行，点歌单调 updatePlaylist 并弹成功提示', (
      WidgetTester tester,
    ) async {
      final repo = FakePlaylistRepository();
      final h = SheetHarness(repository: repo);
      await h.pump(tester);

      expect(_row('歌单一'), findsOneWidget);
      expect(_row('歌单二'), findsOneWidget);
      expect(
        find.text(h.loc!.song_option_song_count(3)),
        findsOneWidget,
        reason: '歌单一显示曲目数 3',
      );

      await tester.tap(_row('歌单二'));
      await drain(tester);

      expect(repo.addedPlaylistIds, <String>['p2']);
      expect(repo.addedSongIds, <List<String>>[<String>['s1']]);
      expect(find.byType(MusicFlowMessage), findsWidgets, reason: '成功 toast');
    });

    testWidgets('无仓库 → 走 NetworkErrorNotifier 分支，无成功提示', (
      WidgetTester tester,
    ) async {
      // 仓库为 null 但歌单数据正常（行仍渲染），点行进入 repository==null 分支。
      final h = SheetHarness(repository: null);
      await h.pump(tester);
      expect(_row('歌单一'), findsOneWidget);

      await tester.tap(_row('歌单一'));
      await drain(tester);

      expect(
        find.text(h.loc!.song_option_added_to_playlist('歌单一')),
        findsNothing,
        reason: '无仓库不弹成功提示',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('updatePlaylist 抛异常 → 请求已发出，不弹成功提示', (
      WidgetTester tester,
    ) async {
      final repo = FakePlaylistRepository()
        ..updateError = StateError('update boom');
      final h = SheetHarness(repository: repo);
      await h.pump(tester);

      await tester.tap(_row('歌单一'));
      await drain(tester);

      expect(repo.addedPlaylistIds, <String>['p1'], reason: '请求确实发出过');
      expect(
        find.text(h.loc!.song_option_added_to_playlist('歌单一')),
        findsNothing,
        reason: '失败不弹成功提示',
      );
      expect(tester.takeException(), isNull);
    });
  });
}
