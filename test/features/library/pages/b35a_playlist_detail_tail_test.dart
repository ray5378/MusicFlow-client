// b35a —— playlist_detail_page.dart 深水区补测（Route A 尾部攻坚）。
//
// batch32 已覆盖主干；本文件打剩余的错误路径与生命周期分支：
//   * didUpdateWidget（playlistId 变化 → 全量重置并重载）；
//   * 排序并列（同标题）保持原始顺序（_sortPlaylistEntries 的 tie-break）；
//   * 曲目拉取失败且歌单为空 → 顶部缓存提示（MediaLoadNotice）+ 底部重试；
//   * 排序全量拉取失败 → 重试按钮，恢复后重排成功；
//   * 排序时仓库未就绪 → _fullFailed；
//   * 全量模式「加入队列」用排序后结果；加入队列为空 → 提示；
//   * 批量移除确认面板「取消」不落库；
//   * 移除失败：SubsonicException code=50 无权限 / 其他 code 服务端拒绝；
//   * 播放全部拉全量失败 → 提示（NetworkErrorNotifier 20s 节流，只断言副作用）；
//   * 编辑歌单：表单未变更直接返回 / 修改成功落库 / 失败提示；
//   * 删除歌单失败提示。
//
// D-049（死代码）不可测，按既定纪律绕开；发现的疑似缺陷只注释记录。

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/network/address_pool.dart';
import 'package:musicflow_client/core/network/connectivity_monitor.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/playlist_repository.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/features/library/pages/playlist_detail_page.dart';
import 'package:musicflow_client/features/library/widgets/media_detail_components.dart';
import 'package:musicflow_client/features/library/widgets/playlist_detail_blocks.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/library/playlist_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../../../helpers/mocks.dart';
import '../../player/test_player_notifier.dart';

class _B35aPlayer extends TestPlayerNotifier {
  _B35aPlayer(super.state);

  final List<Song> addedToQueue = <Song>[];
  final List<int> playQueueStartIndexes = <int>[];
  final List<int> playQueueLengths = <int>[];

  @override
  Future<void> playQueue(
    List<Song> songs, {
    int startIndex = 0,
    bool shuffleRandomStart = false,
    Duration? initialPosition,
  }) async {
    if (songs.isEmpty) return;
    final safeIndex = startIndex.clamp(0, songs.length - 1);
    playQueueStartIndexes.add(safeIndex);
    playQueueLengths.add(songs.length);
    state = state.copyWith(
      queue: songs,
      currentIndex: safeIndex,
      currentSong: songs[safeIndex],
    );
  }

  @override
  void addAllToQueue(List<Song> songs) {
    addedToQueue.addAll(songs);
  }
}

class _B35aPlaylistRepository extends Mock implements PlaylistRepository {}

class _B35aCastPeer extends CastPeerController {
  _B35aCastPeer(super.ref);
}

class _B35aDlna extends DlnaCastNotifier {
  _B35aDlna(super.ref);
}

Song _song(String id, String title, int duration) => Song(
      id: id,
      title: title,
      artist: '夜航西飞',
      album: '专辑一',
      albumId: 'al-1',
      track: 1,
      duration: duration,
    );

final _playlistSongs = <Song>[
  _song('s-1', '归途', 200),
  _song('s-2', '灯塔', 100),
  _song('s-3', '起航', 300),
];

Playlist _meta({String id = 'pl-1', int songCount = 3, List<Song>? songs}) =>
    Playlist(
      id: id,
      name: id == 'pl-1' ? '夜间通勤' : '健身节奏',
      songCount: songCount,
      duration: 600,
      songs: songs,
    );

Future<void> _settle(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Finder _row(String title) => find.ancestor(
      of: find.text(title),
      matching: find.byType(MusicFlowPressable),
    );

Finder _pressable(String label) => find.byWidgetPredicate(
      (w) => w is MusicFlowPressable && w.semanticLabel == label,
    );

/// 供 didUpdateWidget 用例切换 playlistId 的宿主。
class _IdSwitchHost extends StatefulWidget {
  const _IdSwitchHost();

  @override
  State<_IdSwitchHost> createState() => _IdSwitchHostState();
}

class _IdSwitchHostState extends State<_IdSwitchHost> {
  String id = 'pl-1';

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        ElevatedButton(
          key: const ValueKey<String>('b35a_switch_playlist'),
          onPressed: () => setState(() => id = 'pl-2'),
          child: const Text('switch'),
        ),
        Expanded(child: PlaylistDetailPage(playlistId: id)),
      ],
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockSubsonicApiClient api;
  late _B35aPlaylistRepository repo;

  setUpAll(() {
    registerFallbackValue(0);
    registerFallbackValue(<int>[]);
    registerFallbackValue(<Song>[]);
  });

  setUp(() {
    api = MockSubsonicApiClient();
    when(
      () => api.getCoverArtUrl(any(), size: any(named: 'size')),
    ).thenReturn('https://example.test/cover?id=x');
    repo = _B35aPlaylistRepository();
    when(() => repo.getPlaylistMeta('pl-1'))
        .thenAnswer((_) async => _meta());
    when(() => repo.getPlaylistMeta('pl-2'))
        .thenAnswer((_) async => _meta(id: 'pl-2', songCount: 1));
    when(() => repo.getPlaylistTracksPage('pl-1', any(), any()))
        .thenAnswer((_) async => (items: _playlistSongs, total: 3));
    when(() => repo.getPlaylistTracksPage('pl-2', any(), any()))
        .thenAnswer(
            (_) async => (items: <Song>[_playlistSongs.first], total: 1));
    when(() => repo.getAllPlaylistSongs('pl-1'))
        .thenAnswer((_) async => _playlistSongs);
    when(() => repo.getAllPlaylistSongs('pl-2'))
        .thenAnswer((_) async => <Song>[_playlistSongs.first]);
    when(() => repo.triggerPlaylistAutoMatch(any()))
        .thenThrow(StateError('auto match disabled'));
  });

  // playlistDetailProvider 的快照（闭包捕获变量，用例中可热替换）。
  Playlist? Function() snapshot = () => _meta(songs: _playlistSongs);

  Future<(_B35aPlayer, ProviderContainer)> pumpPage(
    WidgetTester tester, {
    PlaylistRepository? Function()? repoFn,
    _B35aPlayer? playerOverride,
    Widget? home,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 1400);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final activePlayer =
        playerOverride ?? _B35aPlayer(PlayerState());
    final container = ProviderContainer(
      overrides: <Override>[
        connectivityMonitorProvider.overrideWithValue(
          ConnectivityMonitor(AddressPool(Dio())),
        ),
        subsonicApiClientProvider.overrideWithValue(api),
        playerProvider.overrideWith((ref) => activePlayer),
        castPeerControllerProvider.overrideWith(
          (Ref ref) => _B35aCastPeer(ref),
        ),
        dlnaCastProvider.overrideWith((Ref ref) => _B35aDlna(ref)),
        playlistRepositoryProvider.overrideWith(
          (ref) => repoFn == null ? repo : repoFn(),
        ),
        ensureActiveAddressProvider.overrideWith(
          (ref) async => const ServerAddress(
            id: 'addr-1',
            libraryId: 'lib-1',
            label: '主线路',
            url: 'https://example.test',
            priority: 0,
          ),
        ),
        playlistDetailProvider.overrideWith(
          (ref, String playlistId) => Future<Playlist?>.value(snapshot()),
        ),
        playlistsProvider.overrideWith((ref) async => const <Playlist>[]),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          theme: AppTheme.light(),
          home: home ?? Scaffold(body: const PlaylistDetailPage(playlistId: 'pl-1')),
        ),
      ),
    );
    return (activePlayer, container);
  }

  testWidgets('歌单详情:playlistId 变化走 didUpdateWidget 全量重置并重载', (tester) async {
    await pumpPage(
      tester,
      home: const Scaffold(body: _IdSwitchHost()),
    );
    await _settle(tester);
    expect(find.text('夜间通勤'), findsOneWidget);
    expect(_row('灯塔'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('b35a_switch_playlist')));
    await _settle(tester, frames: 12);

    // 新歌单的元数据与曲目被重新加载。
    expect(find.text('健身节奏'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('歌单详情:标题排序并列时保持原始顺序(tie-break)', (tester) async {
    snapshot = () => _meta(
          songs: <Song>[
            _song('s-1', '同曲', 200),
            _song('s-2', '同曲', 100),
            _song('s-3', '安河', 300),
          ],
        );
    when(() => repo.getAllPlaylistSongs('pl-1')).thenAnswer(
      (_) async => <Song>[
        _song('s-1', '同曲', 200),
        _song('s-2', '同曲', 100),
        _song('s-3', '安河', 300),
      ],
    );
    await pumpPage(tester);
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(PlaylistDetailPage)),
    );
    await tester.tap(_pressable(
      loc.library_song_sort_option(loc.song_sort_default_order),
    ));
    await _settle(tester);
    await tester.tap(find.text(loc.song_sort_title_asc));
    await _settle(tester, frames: 12);

    // 全量模式行 key 用原始歌单索引:安河(原 index 2)在前,两个「同曲」保持 0→1。
    double dyOfKey(int index) =>
        tester.getTopLeft(find.byKey(ValueKey<String>('playlist-song-$index'))).dy;
    expect(dyOfKey(2) < dyOfKey(0), isTrue, reason: '安河应排在同曲之前');
    expect(dyOfKey(0) < dyOfKey(1), isTrue, reason: '同标题并列应保持原始顺序');
    expect(tester.takeException(), isNull);
  });

  testWidgets('歌单详情:曲目拉取失败且歌单为空 → 顶部缓存提示 + 底部重试按钮', (tester) async {
    when(() => repo.getPlaylistMeta('pl-1'))
        .thenAnswer((_) async => _meta(songCount: 0));
    when(() => repo.getPlaylistTracksPage('pl-1', any(), any()))
        .thenThrow(StateError('page down'));
    await pumpPage(tester);
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(PlaylistDetailPage)),
    );
    // 顶部缓存提示（hasError && count==0 分支）确认渲染。
    // 注：底部「加载失败,点击重试」按钮(408-418)在 count==0 时被更早的
    // 空态分支(397)遮蔽,本用例钉住现状,详见缺陷报告。
    expect(find.byType(MediaLoadNotice), findsOneWidget);
    expect(find.text(loc.library_playlist_empty), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('歌单详情:排序全量拉取失败 → 重试按钮,恢复后成功重排', (tester) async {
    final failBox = <bool>[true];
    when(() => repo.getAllPlaylistSongs('pl-1')).thenAnswer((_) async {
      if (failBox[0]) throw StateError('all songs down');
      return _playlistSongs;
    });
    await pumpPage(tester);
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(PlaylistDetailPage)),
    );
    await tester.tap(_pressable(
      loc.library_song_sort_option(loc.song_sort_default_order),
    ));
    await _settle(tester);
    await tester.tap(find.text(loc.song_sort_duration_desc));
    await _settle(tester, frames: 12);

    // [D-055 已修复]：_fullFailed 时空态分支不再遮蔽重试按钮 ——
    // 失败优先展示重试入口；点击重试、仓库恢复后重排成功。
    expect(find.text(loc.library_playlist_empty), findsNothing,
        reason: '[D-055 已修复] 失败态不再被空态遮蔽');
    expect(find.text(loc.library_load_failed_retry), findsOneWidget,
        reason: '[D-055 已修复] 重试入口可见');

    failBox[0] = false;
    await tester.tap(find.text(loc.library_load_failed_retry));
    await _settle(tester, frames: 12);

    expect(_row('起航'), findsOneWidget,
        reason: '[D-055 已修复] 重试后重排成功');
    expect(tester.takeException(), isNull);
  });

  testWidgets('歌单详情:切排序时仓库未就绪 → 全量标记失败,无崩溃', (tester) async {
    final useRepoBox = <bool>[false];
    await pumpPage(tester, repoFn: () => useRepoBox[0] ? repo : null);
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(PlaylistDetailPage)),
    );
    await tester.tap(_pressable(
      loc.library_song_sort_option(loc.song_sort_default_order),
    ));
    await _settle(tester);
    await tester.tap(find.text(loc.song_sort_duration_desc));
    await _settle(tester, frames: 10);

    expect(tester.takeException(), isNull);
  });

  testWidgets('歌单详情:全量模式「加入队列」使用排序后的结果', (tester) async {
    final (recPlayer, _) = await pumpPage(tester);
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(PlaylistDetailPage)),
    );
    await tester.tap(_pressable(
      loc.library_song_sort_option(loc.song_sort_default_order),
    ));
    await _settle(tester);
    await tester.tap(find.text(loc.song_sort_duration_desc));
    await _settle(tester, frames: 12);

    await tester.tap(_pressable(loc.library_playlist_actions));
    await _settle(tester);
    await tester.tap(find.text(loc.library_add_to_queue));
    await _settle(tester);

    expect(
      recPlayer.addedToQueue.map((s) => s.title).toList(),
      <String>['起航', '归途', '灯塔'],
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('歌单详情:加入队列无可加入歌曲 → 提示且不入队', (tester) async {
    when(() => repo.getAllPlaylistSongs('pl-1'))
        .thenAnswer((_) async => <Song>[]);
    final (recPlayer, _) = await pumpPage(tester);
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(PlaylistDetailPage)),
    );
    await tester.tap(_pressable(loc.library_playlist_actions));
    await _settle(tester);
    await tester.tap(find.text(loc.library_add_to_queue));
    await _settle(tester);

    expect(recPlayer.addedToQueue, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('歌单详情:批量移除确认面板点「取消」不落库', (tester) async {
    await pumpPage(tester);
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(PlaylistDetailPage)),
    );
    await tester.tap(_pressable(loc.library_manage_playlist_songs));
    await _settle(tester);
    await tester.tap(_row('归途'));
    await _settle(tester);

    await tester.tap(find.text(loc.library_remove_selected));
    await _settle(tester);
    expect(find.byType(MusicFlowBottomSheet), findsOneWidget);

    await tester.tap(find.text(loc.settings_cancel));
    await _settle(tester);

    verifyNever(() => repo.updatePlaylist(
          playlistId: any(named: 'playlistId'),
          songIndexesToRemove: any(named: 'songIndexesToRemove'),
        ));
    // 取消后仍留在选择模式。
    expect(find.byType(PlaylistSelectionBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('歌单详情:移除失败(无权限 code=50) → 提示且不崩溃', (tester) async {
    when(() => repo.updatePlaylist(
          playlistId: any(named: 'playlistId'),
          songIndexesToRemove: any(named: 'songIndexesToRemove'),
        )).thenThrow(SubsonicException('否决', 50));
    await pumpPage(tester);
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(PlaylistDetailPage)),
    );
    await tester.tap(_pressable(loc.widgets_song_more_semantics('灯塔')));
    await _settle(tester);
    await tester.tap(find.text(loc.library_remove_from_playlist));
    await _settle(tester, frames: 12);

    verify(() => repo.updatePlaylist(
          playlistId: 'pl-1',
          songIndexesToRemove: <int>[1],
        )).called(1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('歌单详情:移除失败(服务端拒绝,带消息) → 提示且不崩溃', (tester) async {
    when(() => repo.updatePlaylist(
          playlistId: any(named: 'playlistId'),
          songIndexesToRemove: any(named: 'songIndexesToRemove'),
        )).thenThrow(SubsonicException('服务器拒绝', 10));
    await pumpPage(tester);
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(PlaylistDetailPage)),
    );
    await tester.tap(_pressable(loc.widgets_song_more_semantics('归途')));
    await _settle(tester);
    await tester.tap(find.text(loc.library_remove_from_playlist));
    await _settle(tester, frames: 12);

    expect(tester.takeException(), isNull);
  });

  testWidgets('歌单详情:播放全部拉全量失败 → 提示,不起播', (tester) async {
    when(() => repo.getAllPlaylistSongs('pl-1'))
        .thenThrow(StateError('all songs down'));
    final (recPlayer, _) = await pumpPage(tester);
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(PlaylistDetailPage)),
    );
    await tester.tap(find.text(loc.library_play_all));
    await _settle(tester);

    expect(recPlayer.playQueueLengths, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('歌单详情:编辑表单未变更直接返回,不落库', (tester) async {
    await pumpPage(tester);
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(PlaylistDetailPage)),
    );
    await tester.tap(_pressable(loc.library_playlist_actions));
    await _settle(tester);
    await tester.tap(find.text(loc.library_edit_playlist));
    await _settle(tester);

    // 不做任何修改,直接保存。
    await tester.tap(find.text(loc.common_save));
    await _settle(tester, frames: 12);

    verifyNever(() => repo.updatePlaylist(
          playlistId: any(named: 'playlistId'),
          name: any(named: 'name'),
        ));
    expect(tester.takeException(), isNull);
  });

  testWidgets('歌单详情:编辑歌单改名成功 → 落库并刷新元数据', (tester) async {
    when(() => repo.updatePlaylist(
          playlistId: any(named: 'playlistId'),
          name: any(named: 'name'),
          comment: any(named: 'comment'),
          public: any(named: 'public'),
        )).thenAnswer((_) async {});
    await pumpPage(tester);
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(PlaylistDetailPage)),
    );
    await tester.tap(_pressable(loc.library_playlist_actions));
    await _settle(tester);
    await tester.tap(find.text(loc.library_edit_playlist));
    await _settle(tester);

    final nameField = find.widgetWithText(TextField, '夜间通勤');
    expect(nameField, findsOneWidget);
    await tester.enterText(nameField, '深夜通勤');
    await tester.pump();
    await tester.tap(find.text(loc.common_save));
    await _settle(tester, frames: 12);

    verify(() => repo.updatePlaylist(
          playlistId: 'pl-1',
          name: '深夜通勤',
          comment: any(named: 'comment'),
          public: any(named: 'public'),
        )).called(1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('歌单详情:编辑落库失败 → 提示且不崩溃', (tester) async {
    when(() => repo.updatePlaylist(
          playlistId: any(named: 'playlistId'),
          name: any(named: 'name'),
          comment: any(named: 'comment'),
          public: any(named: 'public'),
        )).thenThrow(StateError('edit down'));
    await pumpPage(tester);
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(PlaylistDetailPage)),
    );
    await tester.tap(_pressable(loc.library_playlist_actions));
    await _settle(tester);
    await tester.tap(find.text(loc.library_edit_playlist));
    await _settle(tester);

    final nameField = find.widgetWithText(TextField, '夜间通勤');
    await tester.enterText(nameField, '深夜通勤');
    await tester.pump();
    await tester.tap(find.text(loc.common_save));
    await _settle(tester, frames: 12);

    expect(tester.takeException(), isNull);
  });

  testWidgets('歌单详情:删除歌单失败 → 提示且页面保留', (tester) async {
    when(() => repo.deletePlaylist('pl-1')).thenThrow(StateError('del down'));
    await pumpPage(tester);
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(PlaylistDetailPage)),
    );
    await tester.tap(_pressable(loc.library_playlist_actions));
    await _settle(tester);
    await tester.tap(find.text(loc.library_delete_playlist));
    await _settle(tester);
    await tester.tap(find.text(loc.common_delete));
    await _settle(tester, frames: 12);

    expect(find.byType(PlaylistDetailPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
