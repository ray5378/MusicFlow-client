// batch32 A 路：歌单详情页 PlaylistDetailPage（约 1011 行，基线约 63.5%）。
// 覆盖点：仓库未就绪错误态+重试恢复 / 预载加载态与默认加载态 / 元数据失败+重试 /
// 空歌单 / 播放全部（含队列来源标记）/ 点行起播 / 起播失败回退单曲 /
// 选择模式全流程（进入/切换/全选/反选/退出）/ 长按进入选择 / 批量移除确认 /
// 行内更多菜单移除单曲 / 排序全量模式与恢复默认 / 加入队列 / 编辑对话框 /
// 删除歌单 / 当前播放高亮 / 分页拉取失败重试 / 歌单快照外部刷新清空过期选择。
import 'dart:async';

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
import 'package:musicflow_client/features/library/pages/playlist_detail_page.dart';
import 'package:musicflow_client/features/library/widgets/media_detail_components.dart';
import 'package:musicflow_client/features/library/widgets/playlist_detail_blocks.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/library/playlist_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/player/queue_origin_provider.dart';

import '../../../helpers/mocks.dart';
import '../../player/test_player_notifier.dart';

class _B32aPlayer extends TestPlayerNotifier {
  _B32aPlayer(super.state);

  final List<int> playQueueStartIndexes = <int>[];
  final List<int> playQueueLengths = <int>[];
  final List<String> queueTitles = <String>[];
  final List<Song> addedToQueue = <Song>[];

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
    queueTitles.add(songs[safeIndex].title);
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

class _B32aPlaylistRepository extends Mock implements PlaylistRepository {}

class _B32aCastPeer extends CastPeerController {
  _B32aCastPeer(super.ref);
}

class _B32aDlna extends DlnaCastNotifier {
  _B32aDlna(super.ref);
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

/// 时长互不相同，便于验证排序。
final _playlistSongs = <Song>[
  _song('s-1', '归途', 200),
  _song('s-2', '灯塔', 100),
  _song('s-3', '起航', 300),
];

Playlist _meta({int songCount = 3, List<Song>? songs}) => Playlist(
      id: 'pl-1',
      name: '夜间通勤',
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

MusicFlowPressable _pressableWidget(WidgetTester tester, Finder finder) =>
    tester.widget<MusicFlowPressable>(finder.first);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockSubsonicApiClient api;
  late _B32aPlaylistRepository repo;

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
    repo = _B32aPlaylistRepository();
    when(() => repo.getPlaylistMeta('pl-1')).thenAnswer((_) async => _meta());
    when(() => repo.getPlaylistTracksPage('pl-1', any(), any()))
        .thenAnswer((_) async => (items: _playlistSongs, total: 3));
    when(() => repo.getAllPlaylistSongs('pl-1'))
        .thenAnswer((_) async => _playlistSongs);
    // 自动匹配触发失败 → autoMatchAndAppendPlaylist 静默返回 0，
    // 避免其内部轮询 Timer 在 FakeAsync 下悬挂。
    when(() => repo.triggerPlaylistAutoMatch(any()))
        .thenThrow(StateError('auto match disabled'));
  });

  // playlistDetailProvider 的快照（闭包捕获变量，用例中可热替换）。
  Playlist? Function() snapshot = () => _meta(songs: _playlistSongs);

  Future<(_B32aPlayer, ProviderContainer)> pumpPage(
    WidgetTester tester, {
    PlaylistRepository? Function()? repoFn,
    _B32aPlayer? playerOverride,
    String? initialName,
    int? initialSongCount,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 1400);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final activePlayer =
        playerOverride ?? _B32aPlayer(PlayerState());
    final container = ProviderContainer(
      overrides: <Override>[
        connectivityMonitorProvider.overrideWithValue(
          ConnectivityMonitor(AddressPool(Dio())),
        ),
        subsonicApiClientProvider.overrideWithValue(api),
        playerProvider.overrideWith((ref) => activePlayer),
        castPeerControllerProvider.overrideWith(
          (Ref ref) => _B32aCastPeer(ref),
        ),
        dlnaCastProvider.overrideWith((Ref ref) => _B32aDlna(ref)),
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
          home: Scaffold(
            body: PlaylistDetailPage(
              playlistId: 'pl-1',
              initialName: initialName,
              initialSongCount: initialSongCount,
            ),
          ),
        ),
      ),
    );
    return (activePlayer, container);
  }

  testWidgets('歌单详情:元数据与曲目页加载完成后渲染头部与歌曲行', (tester) async {
    await pumpPage(tester);
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(PlaylistDetailPage)),
    );
    expect(find.text('夜间通勤'), findsOneWidget);
    expect(_row('归途'), findsOneWidget);
    expect(_row('灯塔'), findsOneWidget);
    expect(_row('起航'), findsOneWidget);
    expect(
      find.textContaining(
        loc.library_track_count_sort('3', loc.song_sort_default_order),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('歌单详情:仓库未就绪且无预载参数 → 错误态,仓库恢复并失效仓库后重试渲染', (tester) async {
    var useRepo = false;
    final (_, container) = await pumpPage(
      tester,
      repoFn: () => useRepo ? repo : null,
    );
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(PlaylistDetailPage)),
    );
    expect(find.byType(MusicFlowErrorState), findsOneWidget);
    expect(find.text(loc.library_playlist_load_failed), findsOneWidget);
    expect(find.text(loc.widgets_retry), findsOneWidget);

    useRepo = true;
    // 页面用 ref.read 缓存了仓库 null，重试前需失效仓库 Provider。
    container.invalidate(playlistRepositoryProvider);
    await tester.tap(find.text(loc.widgets_retry));
    await _settle(tester);

    expect(find.byType(MusicFlowErrorState), findsNothing);
    expect(find.text('夜间通勤'), findsOneWidget);
    expect(_row('归途'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('歌单详情:元数据加载中且有预载参数 → 用占位元数据直接渲染完整列表', (tester) async {
    when(() => repo.getPlaylistMeta('pl-1'))
        .thenAnswer((_) => Completer<Playlist?>().future);
    await pumpPage(
      tester,
      initialName: '预载歌单',
      initialSongCount: 9,
    );
    await _settle(tester);

    // [D-候选] _body 的 PlaylistLoadingPreview 分支不可达：
    // _displayMeta 在 initialName != null 时恒返回占位 Playlist，
    // displayMeta == null 必然蕴含 initialName == null（走 MediaDetailLoadingView）。
    // 现状：预载场景直接用占位元数据渲染，曲目数=9 时先出 9 个骨架槽。
    expect(find.byType(PlaylistLoadingPreview), findsNothing);
    expect(find.text('预载歌单'), findsOneWidget);
    expect(find.byType(PlaylistIdentityHeader), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('歌单详情:元数据加载中且无预载参数 → 默认详情加载态', (tester) async {
    when(() => repo.getPlaylistMeta('pl-1'))
        .thenAnswer((_) => Completer<Playlist?>().future);
    await pumpPage(tester);
    await _settle(tester);

    expect(find.byType(MediaDetailLoadingView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('歌单详情:元数据拉取失败 → 错误态,恢复后重试成功', (tester) async {
    var fail = true;
    when(() => repo.getPlaylistMeta('pl-1')).thenAnswer((_) async {
      if (fail) throw StateError('meta down');
      return _meta();
    });
    await pumpPage(tester);
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(PlaylistDetailPage)),
    );
    expect(find.byType(MusicFlowErrorState), findsOneWidget);
    expect(find.text(loc.widgets_retry), findsOneWidget);

    fail = false;
    await tester.tap(find.text(loc.widgets_retry));
    await _settle(tester);

    expect(find.text('夜间通勤'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('歌单详情:空歌单显示空态且「播放全部」禁用', (tester) async {
    when(() => repo.getPlaylistMeta('pl-1'))
        .thenAnswer((_) async => _meta(songCount: 0));
    when(() => repo.getPlaylistTracksPage('pl-1', any(), any()))
        .thenAnswer((_) async => (items: <Song>[], total: 0));
    await pumpPage(tester);
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(PlaylistDetailPage)),
    );
    expect(find.byType(MusicFlowEmptyState), findsOneWidget);
    expect(find.text(loc.library_playlist_empty), findsOneWidget);
    final playAll = tester.widget<MusicFlowButton>(
      find.ancestor(
        of: find.text(loc.library_play_all),
        matching: find.byType(MusicFlowButton),
      ),
    );
    expect(playAll.onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('歌单详情:点「播放全部」拉全量并起播,队列来源标记为该歌单', (tester) async {
    final (recPlayer, container) = await pumpPage(tester);
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(PlaylistDetailPage)),
    );
    await tester.tap(find.text(loc.library_play_all));
    await _settle(tester);

    verify(() => repo.getAllPlaylistSongs('pl-1'))
        .called(greaterThanOrEqualTo(1));
    expect(recPlayer.playQueueLengths, <int>[3]);
    expect(recPlayer.playQueueStartIndexes, <int>[0]);
    expect(recPlayer.queueTitles, <String>['归途']);
    final origin = container.read(queueOriginProvider);
    expect(origin, isNotNull);
    expect(origin!.matchesPlaylist('pl-1'), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('歌单详情:点第 2 行从该行起播整队', (tester) async {
    final (recPlayer, _) = await pumpPage(tester);
    await _settle(tester);

    await tester.tap(_row('灯塔'));
    await _settle(tester);

    expect(recPlayer.playQueueStartIndexes, <int>[1]);
    expect(recPlayer.queueTitles, <String>['灯塔']);
    expect(
      recPlayer.state.queue.map((s) => s.title).toList(),
      <String>['归途', '灯塔', '起航'],
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('歌单详情:起播拉全量失败 → 回退单曲起播该行', (tester) async {
    when(() => repo.getAllPlaylistSongs('pl-1'))
        .thenThrow(StateError('all songs down'));
    final (recPlayer, _) = await pumpPage(tester);
    await _settle(tester);

    await tester.tap(_row('起航'));
    await _settle(tester);

    expect(recPlayer.playQueueLengths, <int>[1]);
    expect(recPlayer.queueTitles, <String>['起航']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('歌单详情:进入选择模式可切换行选择、全选/反选并退出', (tester) async {
    await pumpPage(tester);
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(PlaylistDetailPage)),
    );
    await tester.tap(_pressable(loc.library_manage_playlist_songs));
    await _settle(tester);

    // 选择模式：顶栏显示已选数量，底部出现选择栏。
    expect(find.text(loc.library_selected_count('0')), findsOneWidget);
    expect(find.byType(PlaylistSelectionBar), findsOneWidget);

    await tester.tap(_row('归途'));
    await _settle(tester);
    expect(find.text(loc.library_selected_count('1')), findsOneWidget);

    await tester.tap(_row('归途'));
    await _settle(tester);
    expect(find.text(loc.library_selected_count('0')), findsOneWidget);

    await tester.tap(_pressable(loc.library_select_all));
    await _settle(tester);
    expect(find.text(loc.library_selected_count('3')), findsOneWidget);
    // 全选后按钮切换为「取消全选」。
    await tester.tap(_pressable(loc.library_deselect_all));
    await _settle(tester);
    expect(find.text(loc.library_selected_count('0')), findsOneWidget);

    await tester.tap(_pressable(loc.library_exit_song_management));
    await _settle(tester);
    expect(_pressable(loc.library_manage_playlist_songs), findsOneWidget);
    expect(find.byType(PlaylistSelectionBar), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('歌单详情:长按歌曲行直接进入选择模式并选中该行', (tester) async {
    await pumpPage(tester);
    await _settle(tester);

    await tester.longPress(_row('灯塔'));
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(PlaylistDetailPage)),
    );
    expect(find.text(loc.library_selected_count('1')), findsOneWidget);
    expect(_pressableWidget(tester, _row('灯塔')).selected, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('歌单详情:批量移除弹出确认面板,确认后调用 updatePlaylist 并退出选择', (tester) async {
    await pumpPage(tester);
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(PlaylistDetailPage)),
    );
    when(() => repo.updatePlaylist(
          playlistId: 'pl-1',
          songIndexesToRemove: any(named: 'songIndexesToRemove'),
        )).thenAnswer((_) async {});

    await tester.tap(_pressable(loc.library_manage_playlist_songs));
    await _settle(tester);
    await tester.tap(_row('归途'));
    await tester.tap(_row('起航'));
    await _settle(tester);

    await tester.tap(find.text(loc.library_remove_selected));
    await _settle(tester);

    expect(find.byType(MusicFlowBottomSheet), findsOneWidget);
    expect(find.text(loc.library_remove_songs), findsOneWidget);
    await tester.tap(find.text(loc.common_remove));
    await _settle(tester);

    verify(() => repo.updatePlaylist(
          playlistId: 'pl-1',
          songIndexesToRemove: <int>[2, 0],
        )).called(1);
    // 移除成功后选择模式退出、列表与元数据重载。
    expect(_pressable(loc.library_manage_playlist_songs), findsOneWidget);
    expect(find.byType(PlaylistSelectionBar), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('歌单详情:行内「更多」菜单含「从歌单移除」,点按后移除该单曲', (tester) async {
    await pumpPage(tester);
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(PlaylistDetailPage)),
    );
    when(() => repo.updatePlaylist(
          playlistId: 'pl-1',
          songIndexesToRemove: any(named: 'songIndexesToRemove'),
        )).thenAnswer((_) async {});

    await tester.tap(_pressable(loc.widgets_song_more_semantics('灯塔')));
    await _settle(tester);

    expect(find.byType(MusicFlowBottomSheet), findsOneWidget);
    await tester.tap(find.text(loc.library_remove_from_playlist));
    await _settle(tester);

    verify(() => repo.updatePlaylist(
          playlistId: 'pl-1',
          songIndexesToRemove: <int>[1],
        )).called(1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('歌单详情:切换按时长降序进入全量模式重排,恢复默认回到窗口化', (tester) async {
    await pumpPage(tester);
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(PlaylistDetailPage)),
    );
    await tester.tap(_pressable(
      loc.library_song_sort_option(loc.song_sort_default_order),
    ));
    await _settle(tester);
    expect(find.byType(MusicFlowBottomSheet), findsOneWidget);

    await tester.tap(find.text(loc.song_sort_duration_desc));
    await _settle(tester);

    // 全量排序模式：起航(300) > 归途(200) > 灯塔(100)。
    double dyOf(String title) => tester.getTopLeft(find.text(title)).dy;
    final dy = <String, double>{
      for (final t in <String>['归途', '灯塔', '起航']) t: dyOf(t),
    };
    expect(dy['起航']! < dy['归途']!, isTrue, reason: '时长降序应把起航排在归途之前');
    expect(dy['归途']! < dy['灯塔']!, isTrue, reason: '时长降序应把归途排在灯塔之前');

    // 恢复默认排序回到窗口化列表。
    await tester.tap(_pressable(
      loc.library_song_sort_option(loc.song_sort_duration_desc),
    ));
    await _settle(tester);
    await tester.tap(find.text(loc.song_sort_default_order));
    await _settle(tester);

    expect(
      find.textContaining(
        loc.library_track_count_sort('3', loc.song_sort_default_order),
      ),
      findsOneWidget,
    );
    expect(_row('归途'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('歌单详情:更多操作「加入队列」把全量歌曲追加进队列', (tester) async {
    final (recPlayer, _) = await pumpPage(tester);
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(PlaylistDetailPage)),
    );
    await tester.tap(_pressable(loc.library_playlist_actions));
    await _settle(tester);

    expect(find.byType(MusicFlowBottomSheet), findsOneWidget);
    await tester.tap(find.text(loc.library_add_to_queue));
    await _settle(tester);

    expect(
      recPlayer.addedToQueue.map((s) => s.title).toList(),
      <String>['归途', '灯塔', '起航'],
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('歌单详情:更多操作「编辑歌单」弹出表单,取消不落库', (tester) async {
    await pumpPage(tester);
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(PlaylistDetailPage)),
    );
    await tester.tap(_pressable(loc.library_playlist_actions));
    await _settle(tester);
    await tester.tap(find.text(loc.library_edit_playlist));
    await _settle(tester);

    expect(find.text(loc.common_save), findsOneWidget);
    await tester.tap(find.text(loc.settings_cancel));
    await _settle(tester);

    expect(find.text(loc.common_save), findsNothing);
    expect(find.text('夜间通勤'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('歌单详情:更多操作「删除歌单」确认后调用 deletePlaylist 并返回上一页', (tester) async {
    await pumpPage(tester);
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(PlaylistDetailPage)),
    );
    when(() => repo.deletePlaylist('pl-1')).thenAnswer((_) async {});

    await tester.tap(_pressable(loc.library_playlist_actions));
    await _settle(tester);
    await tester.tap(find.text(loc.library_delete_playlist));
    await _settle(tester);
    await tester.tap(find.text(loc.common_delete));
    await _settle(tester);

    verify(() => repo.deletePlaylist('pl-1')).called(1);
    // 测试环境页面是 home 路由，Navigator.pop 无处可退；断言删除已落库且无崩溃。
    expect(find.byType(PlaylistDetailPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('歌单详情:当前播放行带高亮标记', (tester) async {
    await pumpPage(
      tester,
      playerOverride: _B32aPlayer(
        PlayerState(currentSong: _playlistSongs[1]),
      ),
    );
    await _settle(tester);

    expect(_pressableWidget(tester, _row('灯塔')).selected, isTrue);
    expect(_pressableWidget(tester, _row('归途')).selected, isNot(true));
    expect(tester.takeException(), isNull);
  });

  testWidgets('歌单详情:曲目分页拉取失败且元数据有数量 → 显示重试按钮,修复后恢复', (tester) async {
    var fail = true;
    when(() => repo.getPlaylistTracksPage('pl-1', any(), any())).thenAnswer(
      (_) async {
        if (fail) throw StateError('page down');
        return (items: _playlistSongs, total: 3);
      },
    );
    await pumpPage(tester);
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(PlaylistDetailPage)),
    );
    expect(find.text(loc.library_load_failed_retry), findsOneWidget);
    expect(_row('归途'), findsNothing);

    fail = false;
    await tester.tap(find.text(loc.library_load_failed_retry));
    await _settle(tester);

    expect(_row('归途'), findsOneWidget);
    expect(find.text(loc.library_load_failed_retry), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('歌单详情:选择期间歌单快照被外部刷新 → 自动清空过期选择', (tester) async {
    final (recPlayer, container) = await pumpPage(tester);
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(PlaylistDetailPage)),
    );
    await tester.tap(_pressable(loc.library_manage_playlist_songs));
    await _settle(tester);
    await tester.tap(_row('归途'));
    await _settle(tester);
    expect(find.text(loc.library_selected_count('1')), findsOneWidget);

    // 外部刷新：快照内容变化（新增一首）。
    final refreshed = _meta(
      songs: <Song>[..._playlistSongs, _song('s-4', '新歌', 240)],
    );
    snapshot = () => refreshed;
    container.invalidate(playlistDetailProvider('pl-1'));
    await _settle(tester);

    // 过期选择被自动清空并退出选择模式。
    expect(_pressable(loc.library_manage_playlist_songs), findsOneWidget);
    expect(find.byType(PlaylistSelectionBar), findsNothing);
    expect(find.text(loc.library_selected_count('1')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
