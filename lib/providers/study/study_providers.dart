import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/utils/logger.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/sources/study_api.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

/// 学习模块 API（随活跃库/地址切换自动重建）。
final studyApiProvider = Provider<StudyApi>((ref) {
  return StudyApi(ref.watch(subsonicApiClientProvider));
});

/// 学习源列表（总目录根层）。
final studySourcesProvider = FutureProvider<List<StudySource>>((ref) {
  return ref.watch(studyApiProvider).fetchSources();
});

/// 继续学习（未听完的最近条目）。
final studyContinueProvider = FutureProvider<List<StudyContinueItem>>((ref) {
  return ref.watch(studyApiProvider).fetchContinue();
});

/// 学习歌单列表。
final studyPlaylistsProvider = FutureProvider<List<StudyPlaylist>>((ref) {
  return ref.watch(studyApiProvider).fetchPlaylists();
});

/// 学习歌单文件夹(按课程归档)。
final studyPlaylistFoldersProvider = FutureProvider<List<String>>((ref) {
  return ref.watch(studyApiProvider).fetchPlaylistFolders();
});

/// 某个学习源的目录内容。
final studyDirProvider = FutureProvider.family<List<StudyDirEntry>,
    ({String sourceId, String path})>((ref, args) {
  return ref
      .watch(studyApiProvider)
      .fetchDir(sourceId: args.sourceId, path: args.path);
});

/// 学习歌单曲目。
final studyPlaylistTracksProvider =
    FutureProvider.family<List<Song>, String>((ref, playlistId) {
  return ref.watch(studyApiProvider).fetchPlaylistTracks(playlistId);
});

/// 学习进度上报器：应用级单例（在 MainScaffold.initState 里激活）。
///
/// - 每 10 秒心跳一次（与网页端同一节流）；
/// - 暂停 / 换歌 / 清空队列时立即补报一次；
/// - 只上报本机正在播放的学习音频（投屏/直投链路由对端自行上报）。
final studyProgressReporterProvider = Provider<StudyProgressReporter>((ref) {
  final reporter = StudyProgressReporter(ref);
  reporter.start();
  ref.onDispose(reporter.dispose);
  return reporter;
});

class StudyProgressReporter {
  StudyProgressReporter(this._ref);

  static const String _logTag = 'STUDY_PROGRESS';
  static const Duration _heartbeatInterval = Duration(seconds: 10);

  final Ref _ref;
  Timer? _heartbeat;
  ProviderSubscription<PlayerState>? _playerSub;
  DateTime _lastReportAt = DateTime.fromMillisecondsSinceEpoch(0);

  void start() {
    if (_playerSub != null) return;
    _playerSub = _ref.listen<PlayerState>(
      playerProvider,
      (previous, next) {
        if (previous != null) {
          final prevSong = previous.currentSong;
          final changedSong = prevSong?.id != next.currentSong?.id;
          final paused = previous.isPlaying && !next.isPlaying;
          if (prevSong != null && prevSong.isStudy && (changedSong || paused)) {
            // 换歌/暂停：把上一首的最终进度补报一次，刷新后能准确续播。
            _send(
              songId: prevSong.id,
              position: previous.position,
              duration: previous.duration,
            );
          }
        }
        // 心跳只在「本机正在播放学习音频」时存在：普通音乐/暂停/空闲时
        // 不持有任何 Timer（既省电，也避免应用级定时器在测试里悬挂）。
        _syncHeartbeat(next);
      },
      fireImmediately: true,
    );
  }

  void _syncHeartbeat(PlayerState state) {
    final shouldTick = state.currentSong?.isStudy == true && state.isPlaying;
    if (shouldTick) {
      _heartbeat ??= Timer.periodic(
        _heartbeatInterval,
        (_) => _reportCurrent(),
      );
    } else {
      _heartbeat?.cancel();
      _heartbeat = null;
    }
  }

  void _reportCurrent() {
    final state = _ref.read(playerProvider);
    final song = state.currentSong;
    if (song == null || !song.isStudy || !state.isPlaying) return;
    final now = DateTime.now();
    if (now.difference(_lastReportAt) < _heartbeatInterval) return;
    if (state.position <= Duration.zero) return;
    _send(songId: song.id, position: state.position, duration: state.duration);
  }

  void _send({
    required String songId,
    required Duration position,
    required Duration duration,
  }) {
    // 投屏 / 局域网直投时本机不是发声端，进度由对端上报，避免用旧进度覆盖。
    if (_ref.read(castPeerControllerProvider).activePeer != null) return;
    if (_ref.read(dlnaCastProvider).isCasting) return;
    _lastReportAt = DateTime.now();
    unawaited(
      _ref
          .read(studyApiProvider)
          .reportProgress(
            songId: songId,
            positionSec: position.inSeconds,
            durationSec: duration.inSeconds,
          )
          .catchError((Object e) {
        Logger.debugWithTag(_logTag, 'report progress failed: $e');
      }),
    );
  }

  void dispose() {
    _heartbeat?.cancel();
    _heartbeat = null;
    _playerSub?.close();
    _playerSub = null;
  }
}
