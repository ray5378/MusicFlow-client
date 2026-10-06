// b36c —— `lib/providers/player/playlist_auto_match_provider.dart` 补测
// （原 13/27）。
//
// 覆盖：空 playlistId 短路 / 24h 节流（isPlaylistAutoMatchThrottled +
// markPlaylistAutoMatch 幂等）/ 仓库缺失 / trigger 抛错读日志返回 0 /
// 轮询命中新歌 → appendToQueue 追加到队尾并返回新增数 / 轮询抛错 break /
// 45 轮无新增 → 返回 0。
//
// 打桩：MockPlaylistRepository + 记录型 TestPlayerNotifier（覆写 appendToQueue）；
// 轮询的 8s 间隔用 widget 测试的假时钟 pump 推进。
//
// 产品代码零改动；只读 lib。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/playlist_repository.dart';
import 'package:musicflow_client/providers/library/playlist_provider.dart';
import 'package:musicflow_client/providers/player/playlist_auto_match_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../../features/player/test_player_notifier.dart';

class _MockPlaylistRepository extends Mock implements PlaylistRepository {}

class _RecPlayer extends TestPlayerNotifier {
  _RecPlayer() : super(PlayerState());

  final List<List<String>> appended = <List<String>>[];

  @override
  Future<void> appendToQueue(List<Song> songs) async {
    appended.add(songs.map((s) => s.id).toList());
  }
}

Song _song(String id) => Song(id: id, title: 'T-$id');

void main() {
  late _MockPlaylistRepository repo;
  late _RecPlayer player;

  setUp(() {
    repo = _MockPlaylistRepository();
    player = _RecPlayer();
  });

  Future<WidgetRef> pumpRef(WidgetTester tester, List<Override> overrides) async {
    late WidgetRef ref;
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          playerProvider.overrideWith((ref) => player),
          ...overrides,
        ],
        child: Consumer(
          builder: (context, r, child) {
            ref = r;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    return ref;
  }

  testWidgets('空 playlistId 直接返回 0', (tester) async {
    final ref = await pumpRef(tester, <Override>[
      playlistRepositoryProvider.overrideWithValue(repo),
    ]);
    final result = await autoMatchAndAppendPlaylist(
      ref,
      playlistId: '',
      startedSongs: <Song>[_song('a')],
    );
    expect(result, 0);
    verifyNever(() => repo.triggerPlaylistAutoMatch('p-empty'));
  });

  testWidgets('仓库缺失返回 0', (tester) async {
    final ref = await pumpRef(tester, <Override>[
      playlistRepositoryProvider.overrideWithValue(null),
    ]);
    final result = await autoMatchAndAppendPlaylist(
      ref,
      playlistId: 'p-null-repo',
      startedSongs: <Song>[_song('a')],
    );
    expect(result, 0);
  });

  testWidgets('trigger 抛错被吞并返回 0', (tester) async {
    when(() => repo.triggerPlaylistAutoMatch('p-trigger-boom'))
        .thenThrow(Exception('boom'));
    final ref = await pumpRef(tester, <Override>[
      playlistRepositoryProvider.overrideWithValue(repo),
    ]);
    final result = await autoMatchAndAppendPlaylist(
      ref,
      playlistId: 'p-trigger-boom',
      startedSongs: <Song>[_song('a')],
    );
    expect(result, 0);
  });

  testWidgets('轮询命中新歌：追加到队尾并返回新增数', (tester) async {
    when(() => repo.triggerPlaylistAutoMatch('p-grow')).thenAnswer((_) async => true);
    when(() => repo.getAllPlaylistSongs('p-grow')).thenAnswer(
      (_) async => <Song>[_song('a'), _song('b'), _song('c')],
    );
    final ref = await pumpRef(tester, <Override>[
      playlistRepositoryProvider.overrideWithValue(repo),
    ]);

    final fut = autoMatchAndAppendPlaylist(
      ref,
      playlistId: 'p-grow',
      startedSongs: <Song>[_song('a'), _song('b')],
    );
    // 推进轮询间隔（8s），让第一次 poll 完成并 break。
    for (var i = 0; i < 3; i++) {
      await tester.pump(playlistAutoMatchPollInterval);
    }
    expect(await fut, 1);
    expect(player.appended, <List<String>>[
      <String>['c'],
    ]);
  });

  testWidgets('24h 节流：同歌单第二次调用不再触发', (tester) async {
    when(() => repo.triggerPlaylistAutoMatch('p-throttle')).thenAnswer((_) async => true);
    when(() => repo.getAllPlaylistSongs('p-throttle'))
        .thenAnswer((_) async => <Song>[]);
    final ref = await pumpRef(tester, <Override>[
      playlistRepositoryProvider.overrideWithValue(repo),
    ]);

    // 第一次：轮询 45 轮无新增 → 0（同时推进假时钟）。
    final first = autoMatchAndAppendPlaylist(
      ref,
      playlistId: 'p-throttle',
      startedSongs: <Song>[_song('a')],
    );
    for (var i = 0; i < playlistAutoMatchMaxPolls + 2; i++) {
      await tester.pump(playlistAutoMatchPollInterval);
    }
    expect(await first, 0);

    // 第二次：命中节流窗口，立即返回 0。
    final second = await autoMatchAndAppendPlaylist(
      ref,
      playlistId: 'p-throttle',
      startedSongs: <Song>[_song('a')],
    );
    expect(second, 0);
    verify(() => repo.triggerPlaylistAutoMatch('p-throttle')).called(1);
  });

  testWidgets('轮询抛错则 break 并返回 0', (tester) async {
    when(() => repo.triggerPlaylistAutoMatch('p-poll-boom')).thenAnswer((_) async => true);
    when(() => repo.getAllPlaylistSongs('p-poll-boom'))
        .thenThrow(Exception('poll boom'));
    final ref = await pumpRef(tester, <Override>[
      playlistRepositoryProvider.overrideWithValue(repo),
    ]);

    final fut = autoMatchAndAppendPlaylist(
      ref,
      playlistId: 'p-poll-boom',
      startedSongs: <Song>[_song('a')],
    );
    await tester.pump(playlistAutoMatchPollInterval);
    expect(await fut, 0);
    expect(player.appended, isEmpty);
  });
}
