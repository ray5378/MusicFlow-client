// StudyProgressReporter 的回归守卫（客户端学习记录上报）：
//   * 暂停 / 换歌时用「有效进度」补报最后位置（本机与投屏统一口径）；
//   * 远端投屏/直投换歌时不能用本机残留进度覆盖远端进度；
//   * 学习歌单歌曲同时上报整单续播，普通学习内容只报单曲；
//   * 10s 心跳只在「学习音频 + 正在播放」时存在，暂停/普通音乐不持有 Timer；
//   * 非学习歌曲不上报。
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/sources/study_api.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/player/effective_playback_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/study/study_providers.dart';

import '../../features/player/test_player_notifier.dart';

class _ProgressCall {
  const _ProgressCall(this.songId, this.positionSec, this.durationSec);
  final String songId;
  final int positionSec;
  final int durationSec;
}

class _PlaylistProgressCall {
  const _PlaylistProgressCall(
    this.playlistId,
    this.songId,
    this.positionSec,
    this.durationSec,
  );
  final String playlistId;
  final String songId;
  final int positionSec;
  final int durationSec;
}

class _RecStudyApi extends StudyApi {
  _RecStudyApi() : super(SubsonicApiClient(dio: Dio()));

  final List<_ProgressCall> progress = <_ProgressCall>[];
  final List<_PlaylistProgressCall> playlistProgress =
      <_PlaylistProgressCall>[];

  @override
  Future<void> reportProgress({
    required String songId,
    required int positionSec,
    required int durationSec,
  }) async {
    progress.add(_ProgressCall(songId, positionSec, durationSec));
  }

  @override
  Future<void> reportPlaylistProgress({
    required String playlistId,
    required String songId,
    required int positionSec,
    required int durationSec,
  }) async {
    playlistProgress.add(
      _PlaylistProgressCall(playlistId, songId, positionSec, durationSec),
    );
  }
}

class _FakeCast extends CastPeerController {
  _FakeCast({this.active = false});

  final bool active;

  @override
  CastPeerState build() {
    if (!active) return const CastPeerState();
    return CastPeerState(
      activePeer: PeerInfo(
        peerId: 'peer-1',
        name: '客厅音箱',
        kind: 'player',
        available: true,
      ),
    );
  }
}

class _FakeDlna extends DlnaCastNotifier {
  @override
  DlnaCastState build() => const DlnaCastState();
}

Song _studySong(String id, {String? playlistId, String? playlistName}) => Song(
      id: id,
      title: id,
      kind: 'study',
      duration: 600,
      playlistId: playlistId,
      playlistName: playlistName,
    );

Song _musicSong(String id) => Song(id: id, title: id, kind: 'music', duration: 180);

class _Bench {
  _Bench({
    required this.initial,
    this.remote = false,
  }) : player = TestPlayerNotifier(initial);

  final PlayerState initial;
  final bool remote;
  final TestPlayerNotifier player;
  final _RecStudyApi api = _RecStudyApi();

  late final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      playerProvider.overrideWith(() => player),
      studyApiProvider.overrideWithValue(api),
      castPeerControllerProvider.overrideWith(() => _FakeCast(active: remote)),
      dlnaCastProvider.overrideWith(() => _FakeDlna()),
      effectivePositionProvider.overrideWithValue(const Duration(seconds: 30)),
      effectiveDurationProvider.overrideWithValue(const Duration(minutes: 10)),
      effectiveIsPlayingProvider.overrideWith(
        (ref) => ref.watch(playerProvider.select((s) => s.isPlaying)),
      ),
    ],
  );

  void start() {
    container.read(studyProgressReporterProvider);
  }

  void emit(PlayerState next) => player.emit(next);
}

PlayerState _playing(Song song) => PlayerState(
      currentSong: song,
      isPlaying: true,
      position: const Duration(seconds: 30),
      duration: const Duration(minutes: 10),
    );

void main() {
  testWidgets('暂停时用有效进度补报单曲 + 整单续播', (tester) async {
    final bench = _Bench(initial: _playing(_studySong('s1', playlistId: 'pl-1')));
    bench.start();

    bench.emit(bench.player.state.copyWith(isPlaying: false));
    await tester.pump();

    expect(bench.api.progress, hasLength(1));
    expect(bench.api.progress.single.songId, 's1');
    expect(bench.api.progress.single.positionSec, 30);
    expect(bench.api.progress.single.durationSec, 600);
    expect(bench.api.playlistProgress, hasLength(1));
    expect(bench.api.playlistProgress.single.playlistId, 'pl-1');
    expect(bench.api.playlistProgress.single.songId, 's1');
    expect(bench.api.playlistProgress.single.positionSec, 30);
    bench.container.dispose();
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('本机换歌：上一首用换歌前的位置补报一次', (tester) async {
    final bench = _Bench(initial: _playing(_studySong('s1')));
    bench.start();

    bench.emit(PlayerState(
      currentSong: _studySong('s2'),
      isPlaying: true,
      position: Duration.zero,
      duration: const Duration(minutes: 5),
    ));
    await tester.pump();

    expect(bench.api.progress, hasLength(1));
    expect(bench.api.progress.single.songId, 's1');
    expect(bench.api.progress.single.positionSec, 30);
    expect(bench.api.progress.single.durationSec, 600);
    expect(bench.api.playlistProgress, isEmpty);
    bench.container.dispose();
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('远端投屏换歌：不拿本机残留进度覆盖远端', (tester) async {
    final bench = _Bench(
      initial: _playing(_studySong('s1')),
      remote: true,
    );
    bench.start();

    bench.emit(PlayerState(
      currentSong: _studySong('s2'),
      isPlaying: true,
      position: const Duration(seconds: 5),
      duration: const Duration(minutes: 5),
    ));
    await tester.pump();

    expect(bench.api.progress, isEmpty);
    bench.container.dispose();
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('学习音频播放中每 10s 心跳一次，暂停后停表', (tester) async {
    final bench = _Bench(initial: _playing(_studySong('s1')));
    bench.start();

    await tester.pump(const Duration(seconds: 11));
    expect(bench.api.progress, hasLength(1));
    expect(bench.api.progress.single.positionSec, 30);

    // 暂停本身会立即补报一次（有效进度），之后心跳停表不再增加。
    bench.emit(bench.player.state.copyWith(isPlaying: false));
    await tester.pump();
    expect(bench.api.progress, hasLength(2));
    await tester.pump(const Duration(seconds: 30));
    expect(bench.api.progress, hasLength(2));
    bench.container.dispose();
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('普通音乐不持有心跳、不上报', (tester) async {
    final bench = _Bench(initial: _playing(_musicSong('m1')));
    bench.start();

    await tester.pump(const Duration(seconds: 11));
    expect(bench.api.progress, isEmpty);
    expect(bench.api.playlistProgress, isEmpty);
    bench.container.dispose();
    await tester.pump(const Duration(milliseconds: 1));
  });
}
