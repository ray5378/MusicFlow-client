import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/utils/logger.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/sources/study_api.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/player/effective_playback_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

/// 学习模块 API（随活跃库/地址切换自动重建）。
final studyApiProvider = Provider<StudyApi>((ref) {
  return StudyApi(ref.watch(subsonicApiClientProvider));
});

/// 学习源列表（总目录根层）。
final studySourcesProvider = FutureProvider<List<StudySource>>((ref) {
  return ref.watch(studyApiProvider).fetchSources();
});

/// 继续学习（未听完的最近条目；服务端每用户最多保留最新 50 条记录）。
/// 同时带出「学习歌单续播」条目，可整单从上次位置继续。
final studyContinueProvider = FutureProvider<StudyContinueResult>((ref) {
  return ref.watch(studyApiProvider).fetchContinueAll(limit: 50);
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
/// - 进度/时长/播放态统一走 [effectivePositionProvider] 等「有效播放」入口，
///   因此本机、服务端投屏、局域网 DLNA 直投都会保留学习记录。
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
  ProviderSubscription<bool>? _effectivePlayingSub;
  DateTime _lastReportAt = DateTime.fromMillisecondsSinceEpoch(0);

  void start() {
    if (_playerSub != null) return;
    // 有效播放态(本机/投屏/直投)单独监听：远端被暂停/续播时 playerProvider
    // 不一定变化，必须由这里驱动心跳的启停。
    _effectivePlayingSub = _ref.listen<bool>(
      effectiveIsPlayingProvider,
      (_, _) => _syncHeartbeat(),
    );
    _playerSub = _ref.listen<PlayerState>(
      playerProvider,
      (previous, next) {
        if (previous != null) {
          final prevSong = previous.currentSong;
          final changedSong = prevSong?.id != next.currentSong?.id;
          final paused = previous.isPlaying && !next.isPlaying;
          if (prevSong != null && prevSong.isStudy) {
            if (changedSong) {
              // 换歌：上一首的最终进度补报一次。投屏/直投下
              // playerProvider.position 是本机残留值，改用上一拍心跳即可，
              // 不能用旧值覆盖远端进度。
              if (!_isRemoteActive()) {
                _send(
                  song: prevSong,
                  position: previous.position,
                  duration: previous.duration,
                );
              }
            } else if (paused) {
              // 暂停：用有效进度把最终位置补报一次（投屏/直投时取设备进度）。
              _send(
                song: prevSong,
                position: _ref.read(effectivePositionProvider),
                duration: _ref.read(effectiveDurationProvider),
              );
            }
          }
        }
        // 心跳只在「正在播放学习音频」时存在：普通音乐/暂停/空闲时
        // 不持有任何 Timer（既省电，也避免应用级定时器在测试里悬挂）。
        _syncHeartbeat();
      },
      fireImmediately: true,
    );
  }

  /// 是否处于远端播放（服务端投屏 / 局域网 DLNA 直投）。
  bool _isRemoteActive() {
    return _ref.read(castPeerControllerProvider).activePeer != null ||
        _ref.read(dlnaCastProvider).isCasting;
  }

  void _syncHeartbeat() {
    final song = _ref.read(playerProvider).currentSong;
    final shouldTick =
        song?.isStudy == true && _ref.read(effectiveIsPlayingProvider);
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
    final song = _ref.read(playerProvider).currentSong;
    if (song == null || !song.isStudy) return;
    if (!_ref.read(effectiveIsPlayingProvider)) return;
    final now = DateTime.now();
    if (now.difference(_lastReportAt) < _heartbeatInterval) return;
    final position = _ref.read(effectivePositionProvider);
    if (position <= Duration.zero) return;
    _send(
      song: song,
      position: position,
      duration: _ref.read(effectiveDurationProvider),
    );
  }

  void _send({
    required Song song,
    required Duration position,
    required Duration duration,
  }) {
    _lastReportAt = DateTime.now();
    final api = _ref.read(studyApiProvider);
    unawaited(
      api
          .reportProgress(
            songId: song.id,
            positionSec: position.inSeconds,
            durationSec: duration.inSeconds,
          )
          .catchError((Object e) {
        Logger.debugWithTag(_logTag, 'report progress failed: $e');
      }),
    );
    // 来自学习歌单的播放:同时记录整单续播位置(继续学习页可整单续播)。
    final playlistId = song.playlistId?.trim() ?? '';
    if (playlistId.isNotEmpty) {
      unawaited(
        api
            .reportPlaylistProgress(
              playlistId: playlistId,
              songId: song.id,
              positionSec: position.inSeconds,
              durationSec: duration.inSeconds,
            )
            .catchError((Object e) {
          Logger.debugWithTag(_logTag, 'report playlist progress failed: $e');
        }),
      );
    }
  }

  void dispose() {
    _heartbeat?.cancel();
    _heartbeat = null;
    _playerSub?.close();
    _playerSub = null;
    _effectivePlayingSub?.close();
    _effectivePlayingSub = null;
  }
}
