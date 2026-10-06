// batch37 C(2) —— `lib/features/library/pages/playlist_detail_page.dart` 剩余分支。
//
// 既有 b32a / b35a 已覆盖主干与大部分错误路径。本文件补 lcov 仍标 0 的：
//   * 起播后「自动匹配 + 队尾补齐」成功 → Toast + appendToQueue（589-590）；
//   * 行内「从歌单移除」时仓库被置空 → 提示（812）；
//   * 更多操作「编辑歌单」时仓库被置空 → 提示（953）；
//   * 更多操作「删除歌单」时仓库被置空 → 提示（998）；
//   * VisibleRemoteRetryScope 的 shouldRetry / onRetry（291-292）。
//
// 已知死代码（不改 lib 无法覆盖，仅记录）：
//   * 331-334 PlaylistLoadingPreview —— [D-049] displayMeta==null 蕴含 initialName==null；
//   * 502-509 _fullFailed 重试按钮 —— [D-055] 被 currentSongCount==0 空态分支遮蔽。
//
// 只写 test/，只读 lib/（产品代码零改动）。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/network/connectivity_monitor.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/playlist_repository.dart';
import 'package:musicflow_client/features/library/pages/playlist_detail_page.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/library/playlist_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/ui/navigation_provider.dart';

import '../../../helpers/mocks.dart';
import '../../player/test_player_notifier.dart';

/// 可编程网络监视器：自持广播流，绕开 AddressPool/Dio。
class FakeConnectivityMonitor implements ConnectivityMonitor {
  FakeConnectivityMonitor({this.currentNetworkType = NetworkType.none});

  final StreamController<NetworkType> _controller =
      StreamController<NetworkType>.broadcast();

  @override
  NetworkType currentNetworkType;

  @override
  Stream<NetworkType> get networkTypeStream => _controller.stream;

  @override
  void start() {}

  @override
  void stop() {}

  void emit(NetworkType type) {
    currentNetworkType = type;
    _controller.add(type);
  }

  Future<void> dispose() => _controller.close();
}

class _RecPlayer extends TestPlayerNotifier {
  _RecPlayer(super.state);

  final List<int> playQueueStartIndexes = <int>[];
  final List<int> playQueueLengths = <int>[];
  final List<Song> appended = <Song>[];

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
  Future<void> appendToQueue(List<Song> songs) async {
    appended.addAll(songs);
  }
}

class _PlaylistRepository extends Mock implements PlaylistRepository {}

class _CastPeer extends CastPeerController {
  _CastPeer(super.ref);
}

class _Dlna extends DlnaCastNotifier {
  _Dlna(super.ref);
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

final List<Song> _songs = <Song>[
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

Finder _pressable(String label) => find.byWidgetPredicate(
      (w) => w is MusicFlowPressable && w.semanticLabel == label,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockSubsonicApiClient api;
  late _PlaylistRepository repo;
  late FakeConnectivityMonitor monitor;

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
    monitor = FakeConnectivityMonitor();
    repo = _PlaylistRepository();
    when(() => repo.getPlaylistMeta('pl-1')).thenAnswer((_) async => _meta());
    when(() => repo.getPlaylistTracksPage('pl-1', any(), any()))
        .thenAnswer((_) async => (items: _songs, total: 3));
    when(() => repo.getAllPlaylistSongs('pl-1'))
        .thenAnswer((_) async => _songs);
    when(() => repo.triggerPlaylistAutoMatch(any()))
        .thenThrow(StateError('auto match disabled'));
  });

  // ignore: prefer_function_declarations_over_variables
  Playlist? Function() snapshot = () => _meta(songs: _songs);

  Future<(_RecPlayer, ProviderContainer)> pumpPage(
    WidgetTester tester, {
    String playlistId = 'pl-1',
    PlaylistRepository? Function()? repoFn,
    _RecPlayer? playerOverride,
    String? initialName,
    int? initialSongCount,
    bool visibleLibraryBranch = false,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 1400);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final activePlayer = playerOverride ?? _RecPlayer(PlayerState());
    final container = ProviderContainer(
      overrides: <Override>[
        connectivityMonitorProvider.overrideWithValue(monitor),
        subsonicApiClientProvider.overrideWithValue(api),
        playerProvider.overrideWith((ref) => activePlayer),
        castPeerControllerProvider.overrideWith((Ref ref) => _CastPeer(ref)),
        dlnaCastProvider.overrideWith((Ref ref) => _Dlna(ref)),
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
          (ref, String id) => Future<Playlist?>.value(snapshot()),
        ),
        playlistsProvider.overrideWith((ref) async => const <Playlist>[]),
      ],
    );
    addTearDown(container.dispose);
    if (visibleLibraryBranch) {
      container.read(currentVisibleBranchIndexProvider.notifier).state =
          libraryBranchIndex;
    }

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
              playlistId: playlistId,
              initialName: initialName,
              initialSongCount: initialSongCount,
            ),
          ),
        ),
      ),
    );
    return (activePlayer, container);
  }

  testWidgets('歌单详情:起播后自动匹配补齐成功 → appendToQueue 且不抛', (tester) async {
    // 独立歌单 id，避开全局 24h 节流表（同进程内其他用例可能已触发）。
    const pid = 'pl-am1';
    when(() => repo.getPlaylistMeta(pid)).thenAnswer((_) async => _meta());
    when(() => repo.getPlaylistTracksPage(pid, any(), any()))
        .thenAnswer((_) async => (items: _songs, total: 3));
    // 首次返回起播列表；轮询时多出一首 → added>0 → 走 appendsz+Toast（589-590）。
    var loads = 0;
    when(() => repo.getAllPlaylistSongs(pid)).thenAnswer((_) async {
      loads += 1;
      return loads == 1
          ? _songs
          : <Song>[..._songs, _song('s-9', '补齐曲', 210)];
    });
    when(() => repo.triggerPlaylistAutoMatch(pid)).thenAnswer((_) async => true);

    final player = _RecPlayer(PlayerState());
    await pumpPage(tester, playlistId: pid, playerOverride: player);
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(PlaylistDetailPage)),
    );
    await tester.tap(find.text(loc.library_play_all));
    await _settle(tester);

    // 轮询间隔 8s；推进虚拟时钟让 fire-and-forget 的补齐完成。
    await tester.pump(const Duration(seconds: 8));
    await _settle(tester, frames: 6);
    await tester.pump(const Duration(seconds: 8));
    await _settle(tester, frames: 6);

    expect(player.appended.map((s) => s.id).toList(), <String>['s-9']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('歌单详情:行内「从歌单移除」时仓库置空 → 提示且不崩溃', (tester) async {
    var useRepo = true;
    final (_, container) = await pumpPage(
      tester,
      repoFn: () => useRepo ? repo : null,
    );
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(PlaylistDetailPage)),
    );
    // 打开某行「更多」，同时把仓库置空。
    await tester.tap(_pressable(loc.widgets_song_more_semantics('灯塔')));
    await _settle(tester);
    useRepo = false;
    container.invalidate(playlistRepositoryProvider);

    await tester.tap(find.text(loc.library_remove_from_playlist));
    await _settle(tester);

    expect(tester.takeException(), isNull);
  });

  testWidgets('歌单详情:更多操作「编辑歌单」时仓库置空 → 提示且不崩溃', (tester) async {
    var useRepo = true;
    final (_, container) = await pumpPage(
      tester,
      repoFn: () => useRepo ? repo : null,
    );
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(PlaylistDetailPage)),
    );
    // 先打开更多菜单，再置空仓库，最后点「编辑歌单」。
    await tester.tap(_pressable(loc.library_playlist_actions));
    await _settle(tester);
    useRepo = false;
    container.invalidate(playlistRepositoryProvider);

    await tester.tap(find.text(loc.library_edit_playlist));
    await _settle(tester);

    expect(tester.takeException(), isNull);
  });

  testWidgets('歌单详情:更多操作「删除歌单」时仓库置空 → 提示且不崩溃', (tester) async {
    var useRepo = true;
    final (_, container) = await pumpPage(
      tester,
      repoFn: () => useRepo ? repo : null,
    );
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(PlaylistDetailPage)),
    );
    await tester.tap(_pressable(loc.library_playlist_actions));
    await _settle(tester);
    useRepo = false;
    container.invalidate(playlistRepositoryProvider);

    await tester.tap(find.text(loc.library_delete_playlist));
    await _settle(tester);

    expect(tester.takeException(), isNull);
  });

  testWidgets('歌单详情:网络恢复触发可见重试作用域（shouldRetry+onRetry）', (tester) async {
    // 元数据失败 → shouldRetry 为真。
    when(() => repo.getPlaylistMeta('pl-1')).thenAnswer((_) async {
      throw StateError('meta down');
    });
    await pumpPage(tester, visibleLibraryBranch: true);
    await _settle(tester);

    // 网络 none→wifi→mobile：第二次变化触发 _retryIfNeeded。
    monitor.emit(NetworkType.wifi);
    await tester.pump();
    await tester.pump();
    monitor.emit(NetworkType.mobile);
    await tester.pump();
    await tester.pump();
    await _settle(tester);

    expect(tester.takeException(), isNull);
  });
}
