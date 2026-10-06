// batch31 B 路：远程艺术家预览页 RemoteArtistPage（基线 0% 覆盖，99 行）。
// 覆盖点：加载中骨架 / 仓库未就绪 / 加载失败 + 重试 / 空态 / 有歌曲列表 /
// 播放全部 / 点击指定行起播 / 头像分支 / 当前播放行高亮 / 长按弹歌曲菜单。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:musicflow_client/core/design/components/music_flow_empty_state.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/search.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/search_repository.dart';
import 'package:musicflow_client/features/library/pages/remote_artist_page.dart';
import 'package:musicflow_client/features/library/widgets/library_collection_components.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/library/search_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/widgets/cover_art_image.dart';

import '../../../helpers/mocks.dart';
import '../../player/test_player_notifier.dart';

/// 本机播放桩：TestPlayerNotifier 未实现 playQueue（走 noSuchMethod 返回 null，
/// 会因返回类型 Future<void> 抛 _TypeError），这里补一个可断言的实现。
class _B31bPlayer extends TestPlayerNotifier {
  _B31bPlayer(super.state);

  final List<int> playQueueStartIndexes = <int>[];
  final List<int> playQueueLengths = <int>[];
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
    state = state.copyWith(
      queue: songs,
      currentIndex: safeIndex,
      currentSong: songs[safeIndex],
      position: Duration.zero,
      duration: Duration.zero,
    );
  }

  @override
  void addAllToQueue(List<Song> songs) {
    addedToQueue.addAll(songs);
  }
}

class _B31bCastPeer extends CastPeerController {
  _B31bCastPeer(super.ref);
}

class _B31bDlnaCast extends DlnaCastNotifier {
  _B31bDlnaCast(super.ref);
}

SearchArtist _artist({String avatar = 'ar-1'}) => SearchArtist(
      id: 'ar-1',
      source: 'qishui',
      name: '夜航西飞',
      avatar: avatar,
      platformLabel: '汽水音乐',
      providerId: 'qishui',
    );

const _remoteItems = <Map<String, dynamic>>[
  <String, dynamic>{
    'source': 'qishui',
    'id': 'rs-1',
    'name': '起航',
    'artist': '夜航西飞',
    'duration': 180,
  },
  <String, dynamic>{
    'source': 'qishui',
    'id': 'rs-2',
    'name': '灯塔',
    'artist': '夜航西飞',
    'duration': 200,
  },
  <String, dynamic>{
    'source': 'qishui',
    'id': 'rs-3',
    'name': '归途',
    'artist': '夜航西飞',
    'duration': 220,
  },
];

Future<void> _settle(WidgetTester tester, {int frames = 6}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// 歌曲行的可点区域 = 包含标题文本的 MusicFlowPressable。
/// 不能用 `bySemanticsLabel('^标题，')` 匹配：行本身与行内「更多操作」按钮
/// 的语义标签都以标题开头，会命中 2 个节点。
Finder _songRow(String title) => find.ancestor(
      of: find.text(title),
      matching: find.byType(MusicFlowPressable),
    );

/// 把测试期间累积的异常全部取出（含手势回调里抛的 FlutterError），避免
/// 末尾触发 "Multiple exceptions" 二次失败。
List<Object?> _drainExceptions(WidgetTester tester) {
  final errors = <Object?>[];
  for (var i = 0; i < 10; i++) {
    final e = tester.takeException();
    if (e == null) break;
    errors.add(e);
  }
  return errors;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockSubsonicApiClient api;
  late SearchRepository repository;
  late _B31bPlayer player;

  setUpAll(() {
    registerFallbackValue(<String, String>{});
  });

  setUp(() {
    api = MockSubsonicApiClient();
    repository = SearchRepository(api);
    player = _B31bPlayer(PlayerState());
    when(
      () => api.getRaw(
        any(),
        queryParameters: any(named: 'queryParameters'),
      ),
    ).thenAnswer((_) async => <String, dynamic>{'items': _remoteItems});
    when(() => api.getRemoteStreamUrl(
          provider: any(named: 'provider'),
          source: any(named: 'source'),
          id: any(named: 'id'),
          title: any(named: 'title'),
          artist: any(named: 'artist'),
          album: any(named: 'album'),
          duration: any(named: 'duration'),
          cover: any(named: 'cover'),
        )).thenReturn('https://example.test/stream-remote?song=rs-1');
    when(
      () => api.getCoverArtUrl(any(), size: any(named: 'size')),
    ).thenReturn('https://example.test/cover?id=x');
  });

  Future<ProviderContainer> _pumpPage(
    WidgetTester tester, {
    SearchRepository? repo,
    SearchArtist? artist,
    _B31bPlayer? playerOverride,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 1400);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final container = ProviderContainer(
      overrides: <Override>[
        searchRepositoryProvider.overrideWith((ref) => repo),
        playerProvider.overrideWith((ref) => playerOverride ?? player),
        castPeerControllerProvider.overrideWith((Ref ref) => _B31bCastPeer(ref)),
        dlnaCastProvider.overrideWith((Ref ref) => _B31bDlnaCast(ref)),
        // 避免真实 SubsonicApiClient 链（networkManagerProvider → HealthChecker
        // 30s 周期 Timer）在用例结束时留下 pending timer。
        subsonicApiClientProvider.overrideWithValue(api),
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
            body: RemoteArtistPage(
              artist: artist ?? _artist(),
              providerId: 'qishui',
            ),
          ),
        ),
      ),
    );
    return container;
  }

  testWidgets('远程艺术家页:数据未就绪先渲染骨架,就绪后换成头部与歌曲行', (
    tester,
  ) async {
    final gate = Completer<Map<String, dynamic>>();
    when(
      () => api.getRaw(
        any(),
        queryParameters: any(named: 'queryParameters'),
      ),
    ).thenAnswer((_) => gate.future);

    final container = await _pumpPage(tester, repo: repository);
    // 只推一帧：future 仍 pending，FutureBuilder 落在 waiting 分支。
    await tester.pump();
    expect(find.byType(MusicFlowMediaListSkeleton), findsOneWidget);
    expect(find.byType(MusicFlowErrorState), findsNothing);

    gate.complete(<String, dynamic>{'items': _remoteItems});
    await _settle(tester);

    expect(find.byType(MusicFlowMediaListSkeleton), findsNothing);
    final loc = AppLocalizations.of(
      tester.element(find.byType(RemoteArtistPage)),
    );
    expect(find.text(loc.library_play_all), findsOneWidget);
    expect(_songRow('灯塔'), findsOneWidget);
    expect(container.read(playerProvider).currentSong, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('远程艺术家页:searchRepository 为 null 直接落空态且不报错', (
    tester,
  ) async {
    final container = await _pumpPage(tester, repo: null);
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(RemoteArtistPage)),
    );
    expect(find.byType(MusicFlowEmptyState), findsOneWidget);
    expect(find.text(loc.library_no_playable_songs), findsOneWidget);
    expect(find.byType(MusicFlowMediaListSkeleton), findsNothing);
    // 空列表下「播放全部」被点击也只是早退，不应起播任何歌曲。
    await tester.tap(find.text(loc.library_play_all));
    await _settle(tester);
    expect(player.playQueueStartIndexes, isEmpty);
    expect(container.read(playerProvider).currentSong, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('远程艺术家页:拉取异常展示错误态与重试按钮', (tester) async {
    when(
      () => api.getRaw(
        any(),
        queryParameters: any(named: 'queryParameters'),
      ),
    ).thenAnswer((_) async => throw StateError('remote down'));

    await _pumpPage(tester, repo: repository);
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(RemoteArtistPage)),
    );
    expect(find.byType(MusicFlowErrorState), findsOneWidget);
    expect(find.text(loc.library_remote_load_failed), findsOneWidget);
    expect(find.text(loc.widgets_retry), findsOneWidget);
    expect(_songRow('起航'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('远程艺术家页:重试按钮触发 _reload([D-048] 现状固定)', (
    tester,
  ) async {
    when(
      () => api.getRaw(
        any(),
        queryParameters: any(named: 'queryParameters'),
      ),
    ).thenAnswer((_) async => throw StateError('remote down'));

    await _pumpPage(tester, repo: repository);
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(RemoteArtistPage)),
    );
    // 恢复仓库，重试本应重新拉取并渲染列表。
    when(
      () => api.getRaw(
        any(),
        queryParameters: any(named: 'queryParameters'),
      ),
    ).thenAnswer((_) async => <String, dynamic>{'items': _remoteItems});

    await tester.tap(find.text(loc.widgets_retry));
    await _settle(tester);

    // [D-048] remote_artist_page.dart:54 `_reload()` 的 setState 闭包把
    // `_loadSongs()` 的 Future 当作返回值交给了 setState，debug 构建下触发
    // Flutter 断言且不会 markNeedsBuild —— 重试按钮点了不刷新。此处固定现状：
    // 断言「抛了断言 + 错误态仍在」，修复后本用例应改成断言错误态消失。
    final errors = _drainExceptions(tester);
    expect(
      errors.any((e) => '$e'.contains('returned a Future')),
      isTrue,
      reason: '预期命中 D-048：setState 闭包返回 Future',
    );
    expect(find.byType(MusicFlowErrorState), findsOneWidget);
  });

  testWidgets('远程艺术家页:远程返回空列表展示空态文案', (tester) async {
    when(
      () => api.getRaw(
        any(),
        queryParameters: any(named: 'queryParameters'),
      ),
    ).thenAnswer((_) async => <String, dynamic>{'items': <dynamic>[]});

    await _pumpPage(tester, repo: repository);
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(RemoteArtistPage)),
    );
    expect(find.byType(MusicFlowEmptyState), findsOneWidget);
    expect(find.text(loc.library_no_playable_songs), findsOneWidget);
    expect(_songRow('起航'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('远程艺术家页:头部展示艺术家名/曲目数/平台标签', (tester) async {
    await _pumpPage(tester, repo: repository);
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(RemoteArtistPage)),
    );
    expect(find.text('夜航西飞'), findsWidgets);
    // 曲目数与平台标签拼进同一个 Text（' · ' 连接），只能按包含匹配。
    expect(find.textContaining(loc.discover_track_count('3')), findsOneWidget);
    expect(find.textContaining('汽水音乐'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('远程艺术家页:有头像时头部多构建一张封面图', (tester) async {
    await _pumpPage(
      tester,
      repo: repository,
      artist: _artist(avatar: ''),
      playerOverride: _B31bPlayer(PlayerState()),
    );
    await _settle(tester);
    final withoutAvatar = tester
        .widgetList<CoverArtImage>(find.byType(CoverArtImage))
        .length;

    await _pumpPage(
      tester,
      repo: repository,
      artist: _artist(avatar: 'ar-1'),
      playerOverride: _B31bPlayer(PlayerState()),
    );
    await _settle(tester);
    final withAvatar = tester
        .widgetList<CoverArtImage>(find.byType(CoverArtImage))
        .length;

    // 3 首歌曲行各一张 + 有头像时头部一张。
    expect(withoutAvatar, 3);
    expect(withAvatar, withoutAvatar + 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('远程艺术家页:点「播放全部」从第 0 首起播整队', (tester) async {
    final container = await _pumpPage(tester, repo: repository);
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(RemoteArtistPage)),
    );
    await tester.tap(find.text(loc.library_play_all));
    await _settle(tester);

    expect(player.playQueueStartIndexes, <int>[0]);
    expect(player.playQueueLengths, <int>[3]);
    final state = container.read(playerProvider);
    expect(state.currentIndex, 0);
    expect(state.currentSong?.title, '起航');
    expect(
      state.queue.map((s) => s.title).toList(),
      <String>['起航', '灯塔', '归途'],
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('远程艺术家页:点第 2 行从该行起播,不重排列表', (tester) async {
    final container = await _pumpPage(tester, repo: repository);
    await _settle(tester);

    await tester.tap(_songRow('灯塔'));
    await _settle(tester);

    expect(player.playQueueStartIndexes, <int>[1]);
    final state = container.read(playerProvider);
    expect(state.currentIndex, 1);
    expect(state.currentSong?.title, '灯塔');
    expect(
      state.queue.map((s) => s.title).toList(),
      <String>['起航', '灯塔', '归途'],
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('远程艺术家页:当前播放行带 isCurrent 标记且随播放状态重建', (
    tester,
  ) async {
    final container = await _pumpPage(tester, repo: repository);
    await _settle(tester);

    MusicFlowPressable _row(String title) => tester.widget<MusicFlowPressable>(
          _songRow(title),
        );

    await tester.tap(_songRow('起航'));
    await _settle(tester);
    expect(_row('起航').selected, isTrue);
    expect(_row('灯塔').selected, isNot(true));

    // 切到第 2 首：高亮应跟着 playerProvider 的 currentSong 迁移。
    final current = container.read(playerProvider);
    player.emit(
      current.copyWith(
        currentIndex: 1,
        currentSong: current.queue[1],
      ),
    );
    await _settle(tester);

    expect(_row('灯塔').selected, isTrue);
    expect(_row('起航').selected, isNot(true));
    expect(tester.takeException(), isNull);
  });

  testWidgets('远程艺术家页:长按歌曲行弹出歌曲操作面板', (tester) async {
    await _pumpPage(tester, repo: repository);
    await _settle(tester);

    await tester.longPress(_songRow('归途'));
    await _settle(tester);

    expect(find.byType(MusicFlowBottomSheet), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
