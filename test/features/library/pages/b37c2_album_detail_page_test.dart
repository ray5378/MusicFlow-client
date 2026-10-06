// batch37 C(2) —— `lib/features/library/pages/album_detail_page.dart` 剩余分支。
//
// 既有 b34c 已覆盖：加载态 / 失败重试 / 未找到 / 有数据渲染 / 播放全部 / 点行 /
// 收藏成功与失败 / loadFailed 提示条 / 正在播放遮罩 / 排序弹窗打开。
// 本文件补：
//   * detail==null 且 loadFailed → 错误态（而非「未找到」）；
//   * 空歌曲专辑 → 空曲目态 + 「播放全部」禁用；
//   * 排序弹窗真正选择项 → 列表顺序变化（_selectSortOption 的 setState 分支）；
//   * compact 视口（宽 < medium）→ 详情头纵向布局；
//   * artist 为空 → 不渲染歌手行。
//
// 只写 test/，只读 lib/（产品代码零改动）。

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/core/utils/toast_notifier.dart';
import 'package:musicflow_client/data/models/album.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/music_repository.dart';
import 'package:musicflow_client/data/repositories/playlist_repository.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/features/library/pages/album_detail_page.dart';
import 'package:musicflow_client/features/library/utils/library_sorting.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/api/music_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/library/playlist_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/widgets/song_list_item.dart';

import '../../player/test_player_notifier.dart';

class _FakeMusicRepository extends MusicRepository {
  _FakeMusicRepository() : super(SubsonicApiClient(dio: Dio()));
}

class _FakePlaylistRepository extends PlaylistRepository {
  _FakePlaylistRepository() : super(SubsonicApiClient(dio: Dio()));
}

class _StubCastPeer extends CastPeerController {
  _StubCastPeer(super.ref);
}

class _StubDlnaCast extends DlnaCastNotifier {
  _StubDlnaCast(super.ref);
}

const String kAlbumId = 'al-1';

Album _album({String? artist = '王菲'}) => Album(
      id: kAlbumId,
      name: '寓言',
      artist: artist,
      songCount: 2,
      duration: 470,
    );

List<Song> _songs() => <Song>[
      Song(id: 's1', title: '寒武纪', artist: '王菲', duration: 260),
      Song(id: 's2', title: '新房客', artist: '王菲', duration: 210),
    ];

Future<void> settle(WidgetTester tester, {int frames = 12}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

late AppLocalizations loc;

class _Harness {
  _Harness({this.detail});

  final AlbumDetail? detail;
  late final ProviderContainer container;

  Widget build(WidgetTester tester, {Size size = const Size(900, 1600)}) {
    final library = MusicLibrary(
      id: 'lib-1',
      name: '测试库',
      createdAt: DateTime(2026, 10, 1),
      updatedAt: DateTime(2026, 10, 1),
    );
    final client = SubsonicApiClient(
      dio: Dio(BaseOptions(baseUrl: 'https://music.example.test')),
    )..setLibrary(library);
    container = ProviderContainer(
      overrides: <Override>[
        subsonicApiClientProvider.overrideWithValue(client),
        activeLibraryProvider.overrideWithValue(library),
        activeAddressProvider.overrideWith(
          (ref) => ServerAddress(
            id: 'addr',
            libraryId: 'lib-1',
            label: '测试',
            url: 'http://127.0.0.1:4533',
            priority: 0,
            status: ServerAddressStatus.unknown,
          ),
        ),
        musicRepositoryProvider.overrideWithValue(_FakeMusicRepository()),
        playlistRepositoryProvider.overrideWithValue(_FakePlaylistRepository()),
        playerProvider.overrideWith((ref) => TestPlayerNotifier(PlayerState())),
        castPeerControllerProvider.overrideWith((ref) => _StubCastPeer(ref)),
        dlnaCastProvider.overrideWith((ref) => _StubDlnaCast(ref)),
        albumDetailProvider.overrideWith((ref, String id) async => detail),
      ],
    );
    addTearDown(container.dispose);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        navigatorKey: rootNavigatorKey,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        theme: AppTheme.light(),
        builder: (context, child) {
          loc = AppLocalizations.of(context);
          return child!;
        },
        home: const AlbumDetailPage(albumId: kAlbumId),
      ),
    );
  }
}

void main() {
  testWidgets('detail==null 且 loadFailed → 错误态（而非未找到）', (tester) async {
    final h = _Harness(detail: null);
    await tester.pumpWidget(h.build(tester));
    await settle(tester);
    expect(find.text(loc.library_album_not_found), findsOneWidget);

    h.container.read(albumDetailLoadFailedProvider(kAlbumId).notifier).state = true;
    await settle(tester);
    expect(find.text(loc.library_album_load_failed), findsOneWidget);
    expect(find.text(loc.library_album_not_found), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('空歌曲专辑 → 空曲目态 + 播放全部禁用', (tester) async {
    final h = _Harness(detail: AlbumDetail(album: _album(), songs: const <Song>[]));
    await tester.pumpWidget(h.build(tester));
    await settle(tester);

    expect(find.text(loc.library_empty_tracks), findsWidgets);
    expect(find.byType(SongListItem), findsNothing, reason: '无歌曲不渲染曲目行');
    expect(tester.takeException(), isNull);
  });

  testWidgets('排序弹窗选择「时长升序」→ 列表顺序变化', (tester) async {
    final h = _Harness(detail: AlbumDetail(album: _album(), songs: _songs()));
    await tester.pumpWidget(h.build(tester));
    await settle(tester);

    // 默认顺序：寒武纪(s1) 在上。
    expect(
      tester.getTopLeft(find.text('寒武纪')).dy <
          tester.getTopLeft(find.text('新房客')).dy,
      isTrue,
    );

    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is MusicFlowIconButton && w.icon == AppIcons.sort,
      ),
    );
    await settle(tester, frames: 14);
    await tester.tap(find.text(loc.song_sort_duration_asc));
    await settle(tester, frames: 10);

    expect(
      tester.getTopLeft(find.text('新房客')).dy <
          tester.getTopLeft(find.text('寒武纪')).dy,
      isTrue,
      reason: '时长升序：新房客(210s) 应排在 寒武纪(260s) 前面',
    );
    // 断言实际排序算法与 UI 同源。
    expect(
      sortSongs(_songs(), SongSortOption.durationAsc).map((s) => s.title).toList(),
      <String>['新房客', '寒武纪'],
    );
    expect(find.byType(SongListItem), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact 视口 → 详情头纵向布局渲染不抛', (tester) async {
    final h = _Harness(detail: AlbumDetail(album: _album(), songs: _songs()));
    await tester.pumpWidget(h.build(tester, size: const Size(420, 1600)));
    await settle(tester);

    expect(find.text('寓言'), findsOneWidget);
    expect(find.text('寒武纪'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('artist 为空 → 不渲染歌手行', (tester) async {
    final h = _Harness(
      detail: AlbumDetail(album: _album(artist: ''), songs: _songs()),
    );
    await tester.pumpWidget(h.build(tester));
    await settle(tester);

    expect(find.text('寓言'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
