// b38c3 —— Route C 补测：远程预览页剩余缺口。
//   * remote_album_page.dart：47（仓库未就绪 → 空列表）、66（_playAll → playEffectiveQueue）、
//     69/70（_addToLibrary → importSearchAlbum）、131/132（歌曲行 onTap）、136（歌曲行 onLongPress）。
//   * remote_playlist_page.dart：46（仓库未就绪）、59-61（_playAll）、64/65（_addToLibrary）、
//     95（onPlayAll 闭包）、123-125（歌曲行 onTap）。
//
// 手法：SearchRepository 用子类覆写（getCollectionSongs/getPlaylistSongs/importAlbum/
// importPlaylist/waitTask），页面不触网；播放入口走 TestPlayerNotifier 子类覆写 playQueue，
// 记录调用即可。cast/dlna provider 打桩避免真 Manager。
// 注：本文件**不点**错误态重试按钮 —— `_reload` 的箭头体 setState（[D-057] 已知缺陷）
//     会抛 "setState() callback argument returned a Future"，属既有已记录缺陷，不在本轮范围。
//
// 只写 test/，只读 lib/（产品代码零改动）。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/search.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/search_repository.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/features/library/pages/remote_album_page.dart';
import 'package:musicflow_client/features/library/pages/remote_playlist_page.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/library/search_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../../player/test_player_notifier.dart';

class _FakeSearchRepo extends SearchRepository {
  _FakeSearchRepo() : super(SubsonicApiClient(dio: Dio()));

  final List<String> calls = <String>[];
  List<Song> songs = const <Song>[];

  @override
  Future<List<Song>> getCollectionSongs(
    SearchEntityKind kind,
    String providerId,
    SearchSongLike item,
  ) async {
    calls.add('getCollectionSongs:${kind.name}:$providerId');
    return songs;
  }

  @override
  Future<List<Song>> getPlaylistSongs(
    String providerId,
    SearchPlaylist pl,
  ) async {
    calls.add('getPlaylistSongs:$providerId');
    return songs;
  }

  @override
  Future<String> importAlbum(String providerId, SearchAlbum album) async {
    calls.add('importAlbum:$providerId');
    return 'task-album';
  }

  @override
  Future<String> startPlaylistImport(
    String providerId,
    SearchPlaylist pl,
  ) async {
    calls.add('startPlaylistImport:$providerId');
    return 'task-playlist';
  }

  @override
  Future<Map<String, dynamic>> waitTask(
    String taskId, {
    int maxAttempts = 375,
    Duration interval = const Duration(milliseconds: 800),
  }) async {
    calls.add('waitTask:$taskId');
    return <String, dynamic>{'done': true};
  }
}

class _RecordingPlayer extends TestPlayerNotifier {
  _RecordingPlayer(super.state);

  final List<String> calls = <String>[];

  @override
  Future<void> playQueue(
    List<Song> songs, {
    int startIndex = 0,
    bool shuffleRandomStart = false,
    Duration? initialPosition,
  }) async {
    calls.add('playQueue:${songs.length}:$startIndex');
    if (songs.isEmpty) return;
    final idx = startIndex.clamp(0, songs.length - 1);
    state = state.copyWith(
      queue: songs,
      currentIndex: idx,
      currentSong: songs[idx],
    );
  }
}

class _StubCastPeer extends CastPeerController {
  _StubCastPeer(super.ref);
}

class _StubDlnaCast extends DlnaCastNotifier {
  _StubDlnaCast(super.ref);
}

late AppLocalizations loc;

Future<void> settle(WidgetTester tester, {int frames = 10}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Song _song(String id, String title) => Song(id: id, title: title);

SearchAlbum _album({String id = 'ra-1', String name = '远程专辑'}) =>
    SearchAlbum(
      id: id,
      source: 'plugin-a',
      name: name,
      artist: '远程歌手',
      providerId: 'prov-1',
      platformLabel: '网易云',
      trackCount: '3',
    );

SearchPlaylist _playlist({String id = 'rp-1', String name = '远程歌单'}) =>
    SearchPlaylist(
      id: id,
      source: 'plugin-a',
      name: name,
      creator: '远程用户',
      providerId: 'prov-1',
      platformLabel: '网易云',
      trackCount: '3',
    );

class _Harness {
  _Harness({
    required this.page,
    this.repo,
    this.player,
  });

  final Widget page;
  final _FakeSearchRepo? repo;
  final _RecordingPlayer? player;

  late ProviderContainer container;

  Widget build(WidgetTester tester) {
    container = ProviderContainer(
      overrides: <Override>[
        searchRepositoryProvider.overrideWithValue(repo),
        playerProvider.overrideWith(
          (ref) => player ?? _RecordingPlayer(PlayerState()),
        ),
        castPeerControllerProvider.overrideWith((Ref ref) => _StubCastPeer(ref)),
        dlnaCastProvider.overrideWith((Ref ref) => _StubDlnaCast(ref)),
      ],
    );
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(container.dispose);
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        theme: AppTheme.light(),
        builder: (context, child) {
          loc = AppLocalizations.of(context);
          return child!;
        },
        home: page,
      ),
    );
  }
}

void main() {
  // ---------------- remote_album_page ----------------

  testWidgets('remote_album：仓库未就绪 → 空结果（47）', (tester) async {
    final h = _Harness(page: RemoteAlbumPage(album: _album(), providerId: 'prov-1'));
    await tester.pumpWidget(h.build(tester));
    await settle(tester);

    expect(find.text(loc.library_no_playable_songs), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('remote_album：播全部/加入库/点行/长按行（66/69/70/131/132/136）',
      (tester) async {
    final repo = _FakeSearchRepo()
      ..songs = <Song>[_song('rs1', '远程曲一'), _song('rs2', '远程曲二')];
    final player = _RecordingPlayer(PlayerState());
    final h = _Harness(
      page: RemoteAlbumPage(album: _album(), providerId: 'prov-1'),
      repo: repo,
      player: player,
    );
    await tester.pumpWidget(h.build(tester));
    await settle(tester);

    expect(find.text('远程曲一'), findsOneWidget);

    // 播放全部（66 + onPlayAll 闭包）
    await tester.tap(find.text(loc.library_play_all));
    await settle(tester);
    expect(player.calls, contains('playQueue:2:0'));

    // 加入库（69/70 → importSearchAlbum）
    await tester.tap(find.text(loc.library_add_to_library));
    await settle(tester);
    expect(repo.calls, contains('importAlbum:prov-1'));

    // 点歌曲行（131/132）
    player.calls.clear();
    await tester.tap(find.text('远程曲一'));
    await settle(tester);
    expect(player.calls, contains('playQueue:2:0'));

    // 长按歌曲行（136 → showSongOptionsSheet）
    await tester.longPress(find.text('远程曲二'));
    await settle(tester, frames: 14);
    expect(find.byType(MusicFlowBottomSheet), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // ---------------- remote_playlist_page ----------------

  testWidgets('remote_playlist：仓库未就绪 → 空结果（46）', (tester) async {
    final h = _Harness(
      page: RemotePlaylistPage(playlist: _playlist(), providerId: 'prov-1'),
    );
    await tester.pumpWidget(h.build(tester));
    await settle(tester);

    expect(find.text(loc.library_no_playable_songs), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('remote_playlist：播全部/加入库/点行（59-61/64/65/95/123-125）',
      (tester) async {
    final repo = _FakeSearchRepo()
      ..songs = <Song>[_song('ps1', '歌单曲一'), _song('ps2', '歌单曲二')];
    final player = _RecordingPlayer(PlayerState());
    final h = _Harness(
      page: RemotePlaylistPage(playlist: _playlist(), providerId: 'prov-1'),
      repo: repo,
      player: player,
    );
    await tester.pumpWidget(h.build(tester));
    await settle(tester);

    expect(find.text('歌单曲一'), findsOneWidget);

    // 播放全部（59-61 + 95）
    await tester.tap(find.text(loc.library_play_all));
    await settle(tester);
    expect(player.calls, contains('playQueue:2:0'));

    // 加入库（64/65）
    await tester.tap(find.text(loc.library_add_to_library));
    await settle(tester);
    expect(repo.calls, contains('startPlaylistImport:prov-1'));

    // 点歌曲行（123-125）
    player.calls.clear();
    await tester.tap(find.text('歌单曲二'));
    await settle(tester);
    expect(player.calls, contains('playQueue:2:1'));
    expect(tester.takeException(), isNull);
  });
}
