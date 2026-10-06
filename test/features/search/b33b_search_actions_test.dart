import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:musicflow_client/core/utils/toast_notifier.dart';
import 'package:musicflow_client/core/dlna/dlna_manager.dart';
import 'package:musicflow_client/data/models/search.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/search_repository.dart';
import 'package:musicflow_client/features/search/search_actions.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/library/search_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../../helpers/mocks.dart';
import '../player/test_player_notifier.dart';

/// b33b: search_actions.dart 逻辑层补测。
/// 覆盖: 仓库缺失/来源未指定/空结果/异常/成功播放路径,以及入库触发-后台完成链路。

class _FakeCastPeerController extends CastPeerController {
  _FakeCastPeerController(super.ref);
}

class _FakeDlnaManager extends DlnaManager {
  @override
  bool get isCasting => false;

  @override
  Future<void> init({
    required Future<String> Function(String songId) streamUrlBuilder,
    Future<bool> Function(String songId)? probeSong,
  }) async {}
}

/// 记录型播放器桩:不触音频栈,只记录调用。
class _RecordingPlayer extends TestPlayerNotifier {
  _RecordingPlayer() : super(PlayerState());

  final List<Song> playedPreviews = <Song>[];
  final List<List<Song>> playedQueues = <List<Song>>[];

  @override
  Future<void> playPreviewSong(Song song) async {
    playedPreviews.add(song);
  }

  @override
  Future<void> playQueue(
    List<Song> songs, {
    int startIndex = 0,
    bool shuffleRandomStart = false,
    Duration? initialPosition,
  }) async {
    playedQueues.add(songs);
  }
}

void _stubRawItems(MockSubsonicApiClient api, List<dynamic> items) {
  when(() => api.getRaw(any(),
          queryParameters: any(named: 'queryParameters')))
      .thenAnswer((_) async => <String, dynamic>{'items': items});
}

void _stubRawThrows(MockSubsonicApiClient api) {
  when(() => api.getRaw(any(),
          queryParameters: any(named: 'queryParameters')))
      .thenThrow(Exception('net down'));
}

void _stubPostOk(MockSubsonicApiClient api, String taskId) {
  when(() => api.postRaw(any(),
          data: any(named: 'data'),
          queryParameters: any(named: 'queryParameters')))
      .thenAnswer(
          (_) async => <String, dynamic>{'success': true, 'taskId': taskId});
}

void _stubPostThrows(MockSubsonicApiClient api) {
  when(() => api.postRaw(any(),
          data: any(named: 'data'),
          queryParameters: any(named: 'queryParameters')))
      .thenThrow(Exception('post failed'));
}

void _stubTaskPoll(MockSubsonicApiClient api, int okAfter) {
  var n = 0;
  when(() => api.getRaw(any(),
          queryParameters: any(named: 'queryParameters'))).thenAnswer(
    (_) async => <String, dynamic>{
      'success': true,
      'task': <String, dynamic>{
        'status': ++n >= okAfter ? 'ok' : 'running',
        'result': <String, dynamic>{},
      },
    },
  );
}

SearchSong _remoteSong() => SearchSong(
      id: 'r1',
      source: 'netease',
      name: 'Remote Song',
      artist: 'Artist A',
      album: 'Album A',
      duration: 180,
      providerId: 'netease',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(SearchSongLike());
    registerFallbackValue(<String, dynamic>{});
  });

  late MockSubsonicApiClient api;
  late _RecordingPlayer player;
  WidgetRef? capturedRef; // ignore: unused_local_variable

  setUp(() {
    api = MockSubsonicApiClient();
    player = _RecordingPlayer();
    capturedRef = null;
    when(() => api.getRemoteStreamUrl(
          provider: any(named: 'provider'),
          source: any(named: 'source'),
          id: any(named: 'id'),
          title: any(named: 'title'),
          artist: any(named: 'artist'),
          album: any(named: 'album'),
          duration: any(named: 'duration'),
          cover: any(named: 'cover'),
        )).thenReturn('http://stream.test/x');
  });

  Future<void> pumpHost(
    WidgetTester tester, {
    required void Function(BuildContext context, WidgetRef ref) action,
    SearchRepository? repo,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          if (repo != null)
            searchRepositoryProvider.overrideWithValue(repo)
          else
            searchRepositoryProvider.overrideWith((ref) => null),
          playerProvider.overrideWith((ref) => player),
          castPeerControllerProvider.overrideWith(
            (ref) => _FakeCastPeerController(ref),
          ),
          dlnaManagerProvider.overrideWith((ref) => _FakeDlnaManager()),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          navigatorKey: rootNavigatorKey,
          home: Scaffold(
            body: Center(
              child: Consumer(
                builder: (context, ref, _) {
                  capturedRef = ref;
                  return FilledButton(
                    onPressed: () => action(context, ref),
                    child: const Text('trigger'),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  group('playRemoteSearchSong', () {
    testWidgets('仓库为 null → 不播放、不报错', (tester) async {
      await pumpHost(
        tester,
        repo: null,
        action: (context, ref) =>
            playRemoteSearchSong(context, ref, _remoteSong()),
      );
      await tester.tap(find.text('trigger'));
      await tester.pump(const Duration(milliseconds: 100));

      expect(player.playedPreviews, isEmpty);
      expect(find.textContaining('播放失败'), findsNothing);
    });

    testWidgets('成功 → playPreviewSong 收到远程构造的 Song', (tester) async {
      await pumpHost(
        tester,
        repo: SearchRepository(api),
        action: (context, ref) =>
            playRemoteSearchSong(context, ref, _remoteSong()),
      );
      await tester.tap(find.text('trigger'));
      await tester.pump(const Duration(milliseconds: 100));

      expect(player.playedPreviews.length, 1);
      final played = player.playedPreviews.single;
      expect(played.id, 'remote:netease:netease:r1');
      expect(played.isPreview, isTrue);
      expect(played.previewStreamUrl, 'http://stream.test/x');
      expect(find.textContaining('播放失败'), findsNothing);
    });

    testWidgets('构造流地址抛异常 → 播放失败错误 Toast', (tester) async {
      when(() => api.getRemoteStreamUrl(
            provider: any(named: 'provider'),
            source: any(named: 'source'),
            id: any(named: 'id'),
            title: any(named: 'title'),
            artist: any(named: 'artist'),
            album: any(named: 'album'),
            duration: any(named: 'duration'),
            cover: any(named: 'cover'),
          )).thenThrow(Exception('boom'));
      await pumpHost(
        tester,
        repo: SearchRepository(api),
        action: (context, ref) =>
            playRemoteSearchSong(context, ref, _remoteSong()),
      );
      await tester.tap(find.text('trigger'));
      await tester.pump(const Duration(milliseconds: 100));

      expect(player.playedPreviews, isEmpty);
      expect(find.textContaining('播放失败'), findsOneWidget);
    });
  });

  group('playRemoteSearchCollection', () {
    testWidgets('仓库为 null → 无动作', (tester) async {
      await pumpHost(
        tester,
        repo: null,
        action: (context, ref) => playRemoteSearchCollection(
          context,
          ref,
          SearchEntityKind.album,
          'netease',
          SearchSongLike(id: 'a1', source: 'netease'),
        ),
      );
      await tester.tap(find.text('trigger'));
      await tester.pump(const Duration(milliseconds: 100));

      expect(player.playedQueues, isEmpty);
      expect(find.textContaining('播放失败'), findsNothing);
    });

    testWidgets('providerId 为空 → 未指定来源插件 Toast', (tester) async {
      await pumpHost(
        tester,
        repo: SearchRepository(api),
        action: (context, ref) => playRemoteSearchCollection(
          context,
          ref,
          SearchEntityKind.album,
          '',
          SearchSongLike(id: 'a1', source: 'netease'),
        ),
      );
      await tester.tap(find.text('trigger'));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.textContaining('未指定来源插件'), findsOneWidget);
      expect(player.playedQueues, isEmpty);
    });

    testWidgets('四种 kind 拉取为空 → 暂无可播放 Toast(覆盖 _kindLabel 全分支)',
        (tester) async {
      _stubRawItems(api, <dynamic>[]);
      final repo = SearchRepository(api);

      // 与 search_result_card.dart 调用点一致: playlist kind 需显式传
      // playlist: 参数(item 始终是 SearchSongLike)。
      final pl = SearchPlaylist(
        id: 'p1',
        source: 'netease',
        name: 'PL',
        providerId: 'netease',
      );
      final cases = <(SearchEntityKind, SearchSongLike)>[
        (SearchEntityKind.song, SearchSongLike(id: 's1', source: 'netease')),
        (SearchEntityKind.album, SearchSongLike(id: 'a1', source: 'netease')),
        (SearchEntityKind.artist, SearchSongLike(name: 'Artist A')),
        (SearchEntityKind.playlist, SearchSongLike(id: 'p1', source: 'netease')),
      ];
      for (final (kind, item) in cases) {
        await pumpHost(
          tester,
          repo: repo,
          action: (context, ref) => playRemoteSearchCollection(
              context, ref, kind, 'netease', item,
              playlist:
                  kind == SearchEntityKind.playlist ? pl : null),
        );
        await tester.tap(find.text('trigger'));
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.textContaining('暂无可播放'), findsWidgets,
            reason: 'kind=$kind 应提示暂无可播放');
        await tester.pump(const Duration(seconds: 5));
      }
      expect(player.playedQueues, isEmpty);
    });

    testWidgets('拉取抛异常 → 播放失败 Toast', (tester) async {
      _stubRawThrows(api);
      await pumpHost(
        tester,
        repo: SearchRepository(api),
        action: (context, ref) => playRemoteSearchCollection(
          context,
          ref,
          SearchEntityKind.album,
          'netease',
          SearchSongLike(id: 'a1', source: 'netease'),
        ),
      );
      await tester.tap(find.text('trigger'));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.textContaining('播放失败'), findsOneWidget);
    });

    testWidgets('成功 → 经 playEffectiveQueue 走本机 playQueue', (tester) async {
      _stubRawItems(api, <dynamic>[
        <String, dynamic>{
          'id': 'r-1',
          'source': 'netease',
          'name': 'N1',
          'artist': 'A1',
        },
        <String, dynamic>{
          'id': 'r-2',
          'source': 'netease',
          'name': 'N2',
          'artist': 'A2',
        },
      ]);
      await pumpHost(
        tester,
        repo: SearchRepository(api),
        action: (context, ref) => playRemoteSearchCollection(
          context,
          ref,
          SearchEntityKind.album,
          'netease',
          SearchSongLike(id: 'a1', source: 'netease'),
        ),
      );
      await tester.tap(find.text('trigger'));
      await tester.pump(const Duration(milliseconds: 300));

      expect(player.playedQueues.length, 1);
      expect(player.playedQueues.single.length, 2);
      expect(player.playedQueues.single.first.id, 'remote:netease:netease:r-1');
    });
  });

  group('importSearchSong', () {
    testWidgets('成功: 提交即 Toast,后台完成后通知', (tester) async {
      _stubPostOk(api, 't-1');
      _stubTaskPoll(api, 2);
      await pumpHost(
        tester,
        repo: SearchRepository(api),
        action: (context, ref) =>
            importSearchSong(context, ref, _remoteSong()),
      );
      await tester.tap(find.text('trigger'));
      await tester.pump();
      expect(find.textContaining('已提交入库任务'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 800));
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pump(const Duration(milliseconds: 800));
      expect(find.textContaining('入库完成'), findsOneWidget);
    });

    testWidgets('提交失败 → 错误 Toast', (tester) async {
      _stubPostThrows(api);
      await pumpHost(
        tester,
        repo: SearchRepository(api),
        action: (context, ref) =>
            importSearchSong(context, ref, _remoteSong()),
      );
      await tester.tap(find.text('trigger'));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.textContaining('失败'), findsOneWidget);
      expect(find.textContaining('已提交入库任务'), findsNothing);
    });
  });

  group('importSearchAlbum / importSearchPlaylist', () {
    testWidgets('专辑入库: 提交成功并后台完成通知', (tester) async {
      _stubPostOk(api, 't-al');
      _stubTaskPoll(api, 2);
      final album = SearchAlbum(
        id: 'al-1',
        source: 'netease',
        name: 'Great Album',
        providerId: 'netease',
      );
      await pumpHost(
        tester,
        repo: SearchRepository(api),
        action: (context, ref) => importSearchAlbum(context, ref, album),
      );
      await tester.tap(find.text('trigger'));
      await tester.pump();
      expect(find.textContaining('已提交入库任务'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 800));
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pump(const Duration(milliseconds: 800));
      expect(find.textContaining('入库完成'), findsOneWidget);
    });

    testWidgets('歌单入库 providerId 为空 → 未指定来源插件 Toast', (tester) async {
      final pl = SearchPlaylist(
        id: 'p-1',
        source: 'netease',
        name: 'PL',
        providerId: '',
      );
      await pumpHost(
        tester,
        repo: SearchRepository(api),
        action: (context, ref) => importSearchPlaylist(context, ref, pl),
      );
      await tester.tap(find.text('trigger'));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.textContaining('未指定来源插件'), findsOneWidget);
      expect(find.textContaining('已提交入库任务'), findsNothing);
    });
  });
}
