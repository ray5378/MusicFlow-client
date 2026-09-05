import 'dart:async';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musicflow_client/core/l10n/localizations.dart';
import 'package:just_audio/just_audio.dart' show LoopMode;

import '../core/utils/logger.dart';
import '../data/models/peer.dart';
import '../data/models/song.dart';
import 'api_provider.dart';
import 'player_provider.dart';

/// 「切换播放器」控制器 —— 对齐主项目前端 stores/player.ts 的 peer 机制:
/// - 面板列出 `GET /rest/api/v1/peers`(本机 + DLNA/AirPlay/群组);
/// - **切换播放器 = 纯 UI 控制目标切换**(对齐前端 switchPeer):只改控制目标,
///   不推本地队列、不自动投屏;此后客户端是后端的**远程遥控器** —— 点歌/专辑/歌单
///   走 [playQueueOnPeer]/[playSongOnPeer] 命令**后端**在所选设备播放,播放控件
///   直接作用于该设备;
/// - 本机模式 = 现有 just_audio 播放,不经过后端;离开本机时保存本地状态快照,
///   回本机时恢复,保证「切换前的设备」逻辑不被破坏。
///
/// 注意:后端权限为「非 admin 仅能控制自己的 `local:<uid>`」;普通账号面板只会
/// 出现本机条目,属预期表现。
///
/// 完成项(对齐 SPEC §3.5):
/// 1. 注册与保活:登录后 POST /peers/register + 每 30s heartbeat(registerAndHeartbeat)。
/// 2. 回本机语义:backToLocal=仅切换控制目标+恢复本地快照(远端继续播);stopCasting=停止设备+deactivate。
/// 3. 播放模式同步:setPlayMode/cyclePlayMode 下发,轮询回读后端 playMode。
/// 4. 投屏中加歌/点歌:enqueueSongs / jumpTo / playQueueOnPeer / playSongOnPeer。
/// 5. 队列编辑:removeQueueItem / reorderQueue(投屏队列面板)。
/// 6. 平滑进度:2s 轮询(失败退避至 15s)+ 桌面 500ms / 手机 250ms 插值 tick。
/// 7. 离线/被移除:连续 3 次轮询失败置 offline,切回/移除时停止定时器。
/// 8. 静音:setMuted 下发 /mute。
/// 9. 群组/AirPlay 差异化:switcher 按 kind 区分图标/标签(群组/离线)。
/// 10. 投屏失败:queue/play 失败返回 false,保持本机,不产生脏状态。

/// 离开本机时的本地播放状态快照:回本机时恢复,保证「切换前设备」逻辑不丢。
class LocalPlaybackSnapshot {
  const LocalPlaybackSnapshot({
    required this.queue,
    required this.currentIndex,
    required this.currentSong,
    required this.position,
    required this.isPlaying,
    required this.loopMode,
    required this.shuffleEnabled,
  });

  final List<Song> queue;
  final int currentIndex;
  final Song? currentSong;
  final Duration position;
  final bool isPlaying;
  final LoopMode loopMode;
  final bool shuffleEnabled;
}

class CastPeerState {
  const CastPeerState({
    this.activePeer,
    this.status = const PeerStatus(),
    this.loadingPeers = false,
    this.playMode = 'all',
    this.smoothPositionSeconds = 0,
    this.castQueue = const <Map<String, dynamic>>[],
    this.castIndex = -1,
    this.offline = false,
    this.endOfQueueCount = 0,
  });

  /// null = 本机播放。
  final PeerInfo? activePeer;
  final PeerStatus status;
  final bool loadingPeers;

  /// 投屏队列播放模式(order|one|all|shuffle,对齐后端),仅投屏态有效。
  final String playMode;

  /// 平滑进度(秒):250/500ms tick 插值,轮询结果回写修正。
  final double smoothPositionSeconds;

  /// 后端权威投屏队列快照(仅投屏态填充),供队列面板展示。
  final List<Map<String, dynamic>> castQueue;
  final int castIndex;

  /// 远端连续轮询失败(离线/被移除)。
  final bool offline;

  /// 队列**自然播完**计数:设备曾处于活跃播放,随后无任何客户端命令干预而
  /// 跳变为非活跃(STOPPED/空)即判定队列到底,计数 +1。
  /// 随机歌曲「播完自动换一批」等场景监听此值变化触发续播。
  final int endOfQueueCount;

  bool get isCasting => activePeer != null;

  /// 设备是否真的在播(后端 state 判定)。
  bool get devicePlaying => status.active;

  String get targetName => activePeer?.name ?? l10nNowCurrent().peer_self;

  CastPeerState copyWith({
    PeerInfo? activePeer,
    bool clearActivePeer = false,
    PeerStatus? status,
    bool? loadingPeers,
    String? playMode,
    double? smoothPositionSeconds,
    List<Map<String, dynamic>>? castQueue,
    int? castIndex,
    bool? offline,
    int? endOfQueueCount,
  }) {
    return CastPeerState(
      activePeer: clearActivePeer ? null : (activePeer ?? this.activePeer),
      status: status ?? this.status,
      loadingPeers: loadingPeers ?? this.loadingPeers,
      playMode: playMode ?? this.playMode,
      smoothPositionSeconds: smoothPositionSeconds ?? this.smoothPositionSeconds,
      castQueue: castQueue ?? this.castQueue,
      castIndex: castIndex ?? this.castIndex,
      offline: offline ?? this.offline,
      endOfQueueCount: endOfQueueCount ?? this.endOfQueueCount,
    );
  }
}

/// 本地播放模式 → 后端 PlayMode(order|one|all|shuffle)。
String mapLocalPlayMode(PlaybackMode mode) => switch (mode) {
      PlaybackMode.shuffle => 'shuffle',
      PlaybackMode.repeatOne => 'one',
      PlaybackMode.repeatAll => 'all',
    };

class CastPeerController extends StateNotifier<CastPeerState> {
  CastPeerController(this._ref) : super(const CastPeerState());

  final Ref _ref;

  Timer? _pollTimer;
  Timer? _tickTimer;
  Timer? _heartbeatTimer;
  String? _localPeerId;

  /// 连续轮询失败计数(离线判定)。
  int _failureCount = 0;

  /// 上次轮询读到的 position(用于「position 真实前进」播放态自愈判定)。
  double _lastPollPosition = -1;

  /// 队列自然播完检测:设备上一轮是否处于活跃播放。
  bool _wasActivePlaying = false;

  /// 自设备开始播放以来,客户端是否发过传输命令(stop/pause/切歌/加歌等)。
  /// 若设备从活跃播放跳变为非活跃且期间无用户命令,即判定为「队列自然播完」。
  bool _userCommandSincePlaying = false;

  /// 离开本机时的本地播放状态快照(回本机时恢复,保证「切换前设备」逻辑不丢)。
  LocalPlaybackSnapshot? _localSnapshot;

  /// 自适应轮询间隔(2s 基准,失败翻倍,上限 15s)。
  Duration _pollInterval = const Duration(seconds: 2);

  /// 平滑进度插值间隔:桌面 500ms(降低 Windows 高频重建),手机 250ms。
  int get _progressTickMs {
    if (kIsWeb) return 250;
    return switch (defaultTargetPlatform) {
      TargetPlatform.windows ||
      TargetPlatform.macOS ||
      TargetPlatform.linux =>
        500,
      _ => 250,
    };
  }

  // ==================== 注册与保活 ====================

  /// 登录后注册本机 peer(名称留给后端默认 username)并启动 30s 心跳。
  /// 对齐前端 registerLocalPeer + startHeartbeat;best-effort,失败不抛。
  Future<void> registerAndHeartbeat() async {
    final client = _ref.read(subsonicApiClientProvider);
    try {
      final resp = await client.postRaw(
        '/rest/api/v1/peers/register',
        data: <String, dynamic>{'name': ''},
      );
      if (resp is Map<String, dynamic> && resp['peer'] is Map<String, dynamic>) {
        final peer = resp['peer'] as Map<String, dynamic>;
        final pid = peer['peerId'];
        if (pid is String && pid.isNotEmpty) _localPeerId = pid;
      }
    } catch (_) {
      // 注册失败不阻塞登录;后续心跳按 local:<uid> 兜底再试。
    }
    startHeartbeat();
  }

  /// 开始心跳保活(对齐前端 30s 间隔)。
  void startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(_sendHeartbeat());
    });
    unawaited(_sendHeartbeat());
  }

  Future<void> _sendHeartbeat() async {
    final pid = _localPeerId;
    if (pid == null || pid.isEmpty) return;
    final client = _ref.read(subsonicApiClientProvider);
    try {
      await client.postRaw(
        '/rest/api/v1/peers/${Uri.encodeComponent(pid)}/heartbeat',
      );
    } catch (_) {
      // 心跳失败忽略,下个周期再试。
    }
  }

  void stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  // ==================== 播放器列表 ====================

  Future<List<PeerInfo>> loadPeers() async {
    final client = _ref.read(subsonicApiClientProvider);
    state = state.copyWith(loadingPeers: true);
    try {
      final data = await client.getRaw('/rest/api/v1/peers') as Map<String, dynamic>;
      final list = (data['peers'] as List? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(PeerInfo.fromJson)
          .toList();
      return list;
    } catch (_) {
      return const <PeerInfo>[];
    } finally {
      if (mounted) state = state.copyWith(loadingPeers: false);
    }
  }

  // ==================== 切换播放器 ====================

  /// 切换播放器 = **纯 UI 控制目标切换**(对齐主项目前端 switchPeer):
  /// 只改控制目标,不推本地队列、不自动投屏;
  /// 选中远端 peer 时开始状态轮询,由轮询拉取其队列让 UI 镜像设备当前播放。
  /// 之后在客户端点歌/专辑/歌单会走 [playQueueOnPeer]/[playSongOnPeer]
  /// 命令**后端**在该设备播放,客户端此时仅是后端的远程遥控器。
  ///
  /// 离开本机时:保存本地状态快照并暂停本机(SPEC §3.1 本机播放与投屏互斥,
  /// 避免双实例抢音频设备);回本机时经 [backToLocal] 恢复快照。
  Future<bool> switchTo(PeerInfo peer) async {
    if (peer.isLocal) {
      await backToLocal(resumeLocal: true);
      return true;
    }
    if (state.activePeer == null) {
      // 离开本机:先冻结本地状态(快照),再暂停本机。
      _saveLocalSnapshot();
      await _ref.read(playerProvider.notifier).pause();
    }
    state = state.copyWith(
      activePeer: peer,
      status: const PeerStatus(state: 'BUFFERING'),
      playMode: state.playMode,
      smoothPositionSeconds: 0,
      offline: false,
    );
    _startPolling(peer.peerId);
    return true;
  }

  /// 回本机:仅切换控制目标(远端继续播放,对齐前端 switchPeer 纯 UI 切换),
  /// 并恢复离开本机时保存的本地状态快照。
  /// 不主动 stop 设备、不清空远端队列。
  ///
  /// [resumeLocal] 为 true 且快照当时在播放时,恢复后自动续播本机
  /// (即用户主动选「本机播放」);false(如 stopCasting)则保持暂停。
  Future<void> backToLocal({bool resumeLocal = false}) async {
    _stopTimers();
    final snapshot = _localSnapshot;
    _localSnapshot = null;
    if (snapshot != null) {
      _restoreLocalSnapshot(snapshot, resume: resumeLocal);
    }
    state = state.copyWith(
      clearActivePeer: true,
      status: const PeerStatus(),
      playMode: 'all',
      smoothPositionSeconds: 0,
      castQueue: const <Map<String, dynamic>>[],
      castIndex: -1,
      offline: false,
    );
  }

  /// 保存当前本机播放状态为快照(供回本机恢复)。
  void _saveLocalSnapshot() {
    final ps = _ref.read(playerProvider);
    _localSnapshot = LocalPlaybackSnapshot(
      queue: List<Song>.of(ps.queue),
      currentIndex: ps.currentIndex,
      currentSong: ps.currentSong,
      position: ps.position,
      isPlaying: ps.isPlaying,
      loopMode: ps.loopMode,
      shuffleEnabled: ps.shuffleEnabled,
    );
  }

  /// 把快照恢复到本机播放器(不触碰远端)。
  void _restoreLocalSnapshot(LocalPlaybackSnapshot snap, {required bool resume}) {
    final notifier = _ref.read(playerProvider.notifier);
    // 仅恢复队列/游标/播放模式,不动音频会话的加载源 ——
    // 本机 just_audio 在离开时仅 pause(未卸载),恢复 currentSong 后 resume 即可续播。
    notifier.restoreStateForCast(
      queue: snap.queue,
      currentIndex: snap.currentIndex,
      currentSong: snap.currentSong,
      position: snap.position,
      loopMode: snap.loopMode,
      shuffleEnabled: snap.shuffleEnabled,
      isPlaying: resume && snap.isPlaying,
    );
  }

  /// 停止投屏:通知后端停止设备并标记队列 inactive(队列保留待恢复),然后切回本机。
  /// 区别于 backToLocal(仅切换控制目标);对齐前端 stopCast。
  Future<void> stopCasting() async {
    final peerId = state.activePeer?.peerId;
    final client = _ref.read(subsonicApiClientProvider);
    if (peerId != null) {
      final base = '/rest/api/v1/peers/${Uri.encodeComponent(peerId)}';
      _markUserCommand();
      try {
        await client.postRaw('$base/stop').timeout(const Duration(seconds: 8));
      } catch (_) {}
      try {
        await client.postRaw('$base/queue/deactivate').timeout(const Duration(seconds: 8));
      } catch (_) {}
    }
    await backToLocal();
  }

  // ==================== 传输控制 ====================

  Future<void> toggle() async {
    if (state.activePeer == null) {
      await _ref.read(playerProvider.notifier).togglePlayPause();
      return;
    }
    final target = !state.status.playing;
    await _post(target ? 'play' : 'pause');
    // 乐观置位(对齐前端 castTogglePlay):点击后按钮立即翻转,不依赖轮询/事件;
    // 轮询随后以后端权威状态修正。
    state = state.copyWith(
      status: state.status.copyWith(
        state: target ? 'PLAYING' : 'PAUSED_PLAYBACK',
        active: true,
      ),
    );
    unawaited(pollOnce());
  }

  /// 暂停（定时停止等场景显式暂停；投屏时下发远端 pause，本机走本地暂停）。
  Future<void> pause() async {
    if (state.activePeer == null) {
      await _ref.read(playerProvider.notifier).pause();
      return;
    }
    if (!state.status.playing) return;
    await _post('pause');
    state = state.copyWith(
      status: state.status.copyWith(
        state: 'PAUSED_PLAYBACK',
        active: true,
      ),
    );
    unawaited(pollOnce());
  }

  /// 服务器端定时暂停(链路 A 投屏/群组):由**服务器自己倒计时**并在到点暂停,
  /// App 关闭/掉线后定时依然生效。传 null / 时长 <= 0 取消当前定时。
  Future<void> setSleepTimer(Duration? duration, {bool finishSong = false}) async {
    final peerId = state.activePeer?.peerId;
    final client = _ref.read(subsonicApiClientProvider);
    if (peerId == null) return;
    final base = '/rest/api/v1/peers/${Uri.encodeComponent(peerId)}';
    if (duration == null || duration <= Duration.zero) {
      try {
        await client.deleteRaw('$base/sleep-timer').timeout(const Duration(seconds: 8));
      } catch (_) {}
      return;
    }
    // 后端不可达时暴露给调用方,避免'静默不生效'。
    await client.postRaw(
      '$base/sleep-timer',
      data: <String, dynamic>{
        'durationSeconds': duration.inSeconds,
        'finishSong': finishSong,
      },
    ).timeout(const Duration(seconds: 8));
  }

  /// 查询服务器端定时剩余;未设置时返回 null。
  Future<Duration?> getSleepTimerRemaining() async {
    final peerId = state.activePeer?.peerId;
    final client = _ref.read(subsonicApiClientProvider);
    if (peerId == null) return null;
    final base = '/rest/api/v1/peers/${Uri.encodeComponent(peerId)}';
    try {
      final data = await client.getRaw('$base/sleep-timer').timeout(const Duration(seconds: 8)) as Map<String, dynamic>;
      final ms = data['remainingMs'];
      if (data['active'] == true && ms is num) return Duration(milliseconds: ms.round());
    } catch (_) {}
    return null;
  }

  Future<void> next() async {
    if (state.activePeer == null) {
      await _ref.read(playerProvider.notifier).next();
      return;
    }
    await _post('next');
    unawaited(pollOnce());
  }

  Future<void> previous() async {
    if (state.activePeer == null) {
      await _ref.read(playerProvider.notifier).previous();
      return;
    }
    await _post('prev');
    unawaited(pollOnce());
  }

  Future<void> seek(Duration position) async {
    if (state.activePeer == null) {
      await _ref.read(playerProvider.notifier).seek(position);
      return;
    }
    await _post('seek', data: <String, dynamic>{'seconds': position.inSeconds});
    // 立即用目标位置对齐平滑进度,减少插值滞后。
    state = state.copyWith(smoothPositionSeconds: position.inSeconds.toDouble());
    unawaited(pollOnce());
  }

  Future<void> setVolume(int volume) async {
    if (state.activePeer == null) return;
    await _post('volume', data: <String, dynamic>{'volume': volume});
    final nextStatus = state.status.copyWith(volume: volume);
    state = state.copyWith(status: nextStatus);
  }

  /// 静音开关(投屏设备;群组/端到端由后端分发)。
  Future<void> setMuted(bool muted) async {
    if (state.activePeer == null) return;
    await _post('mute', data: <String, dynamic>{'muted': muted});
    final nextStatus = state.status.copyWith(muted: muted);
    state = state.copyWith(status: nextStatus);
  }

  // ==================== 播放模式同步 ====================

  /// 下发投屏播放模式(order|one|all|shuffle)。
  Future<void> setPlayMode(String mode) async {
    if (state.activePeer == null) return;
    await _post('play-mode', data: <String, dynamic>{'mode': mode});
    state = state.copyWith(playMode: mode);
    unawaited(pollOnce());
  }

  /// 循环切换投屏播放模式:order → one → all → shuffle(对齐前端 castCyclePlayMode)。
  Future<void> cyclePlayMode() async {
    const modes = <String>['order', 'one', 'all', 'shuffle'];
    final idx = modes.indexOf(state.playMode);
    final next = modes[(idx + 1) % modes.length];
    await setPlayMode(next);
  }

  // ==================== 投屏队列操作 ====================

  /// 投屏中播放专辑/歌单/列表:命令**后端**以该队列在设备上播放(对齐前端 castPlayQueue)。
  /// 客户端此时是后端的远程遥控器,不在本机播放。
  Future<bool> playQueueOnPeer(
    List<Song> songs, {
    int startIndex = 0,
  }) async {
    final peerId = state.activePeer?.peerId;
    if (peerId == null || songs.isEmpty) return false;
    final items = songs.map(songToQueueItem).toList();
    final start = startIndex.clamp(0, items.length - 1);
    return _pushQueueAndPlay(peerId, items, start);
  }

  /// 投屏中点歌(无队列上下文):对齐前端 castPlaySong ——
  /// 已在该设备队列则跳播,否则追加并播放。
  Future<bool> playSongOnPeer(
    Song song, {
    List<Song>? queue,
    int? index,
  }) async {
    final peerId = state.activePeer?.peerId;
    if (peerId == null) return false;

    final List<Map<String, dynamic>> items;
    final int start;
    if (queue != null && queue.isNotEmpty) {
      // 携带队列上下文(如列表页点击某行)按整队播放。
      items = queue.map(songToQueueItem).toList();
      start = (index ?? 0).clamp(0, items.length - 1);
    } else {
      final existing = state.castQueue;
      final found = existing.indexWhere((it) => it['songId'] == song.id);
      if (found >= 0) {
        items = existing;
        start = found;
      } else {
        items = <Map<String, dynamic>>[...existing, songToQueueItem(song)];
        start = items.length - 1;
      }
    }
    return _pushQueueAndPlay(peerId, items, start);
  }

  /// 把队列交给后端 queue/play 并在该设备开始播放;成功后乐观镜像队列/游标。
  Future<bool> _pushQueueAndPlay(
    String peerId,
    List<Map<String, dynamic>> items,
    int startIndex,
  ) async {
    final client = _ref.read(subsonicApiClientProvider);
    _markUserCommand();
    try {
      final resp = await client
          .postRaw(
            '/rest/api/v1/peers/${Uri.encodeComponent(peerId)}/queue/play',
            data: <String, dynamic>{'items': items, 'startIndex': startIndex},
          )
          .timeout(const Duration(seconds: 8));
      final success = resp is Map && resp['success'] == true;
      if (!success) return false;

      // 同步该设备播放模式(队列替换后保持设备当前模式,对齐 pushCastQueueToBackend)。
      final mode = state.playMode;
      try {
        await client.postRaw(
          '/rest/api/v1/peers/${Uri.encodeComponent(peerId)}/play-mode',
          data: <String, dynamic>{'mode': mode},
        );
      } catch (_) {}

      // 乐观镜像:本地队列/游标立即跟随设备,不等轮询回写;
      // 同时乐观置 PLAYING(对齐前端 startCastPlayback):点击播放后按钮立即显示
      // 「暂停」,进度由插值 tick 驱动、轮询回写修正。
      _ref.read(playerProvider.notifier).syncQueueForCast(items, startIndex);
      _lastPollPosition = -1;
      state = state.copyWith(
        castQueue: items,
        castIndex: startIndex,
        smoothPositionSeconds: 0,
        offline: false,
        status: state.status.copyWith(
          state: 'PLAYING',
          active: true,
          positionSeconds: 0,
        ),
      );
      unawaited(pollOnce());
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 投屏中加歌:追加到后端队列(不影响当前播放)。
  Future<void> enqueueSongs(List<dynamic> songs) async {
    final peerId = state.activePeer?.peerId;
    if (peerId == null || songs.isEmpty) return;
    final items = songs.map(songToQueueItem).toList();
    await _post('queue/enqueue', data: <String, dynamic>{'items': items});
    unawaited(pollOnce());
  }

  /// 点歌:跳播到指定索引(即使随机模式也尊重 index,对齐后端 queue/jump)。
  Future<void> jumpTo(int index) async {
    final peerId = state.activePeer?.peerId;
    if (peerId == null) return;
    await _post('queue/jump', data: <String, dynamic>{'index': index});
    unawaited(pollOnce());
  }

  /// 从投屏队列移除指定索引(播放保持连贯,对齐前端 castRemoveFromQueue)。
  Future<void> removeQueueItem(int index) async {
    final peerId = state.activePeer?.peerId;
    final client = _ref.read(subsonicApiClientProvider);
    if (peerId == null) return;
    try {
      await client
          .deleteRaw(
            '/rest/api/v1/peers/${Uri.encodeComponent(peerId)}/queue/$index',
          )
          .timeout(const Duration(seconds: 8));
    } catch (_) {}
    unawaited(pollOnce());
  }

  /// 队列拖拽排序(from → to,对齐前端 castReorderQueue)。
  Future<void> reorderQueue(int from, int to) async {
    final peerId = state.activePeer?.peerId;
    if (peerId == null) return;
    await _post('queue/reorder', data: <String, dynamic>{'from': from, 'to': to});
    unawaited(pollOnce());
  }

  /// 清空投屏队列并停止轮询、切回本机(对齐前端 castClearQueue)。
  Future<void> clearCastQueue() async {
    final peerId = state.activePeer?.peerId;
    final client = _ref.read(subsonicApiClientProvider);
    if (peerId != null) {
      _markUserCommand();
      try {
        await client
            .deleteRaw('/rest/api/v1/peers/${Uri.encodeComponent(peerId)}/queue')
            .timeout(const Duration(seconds: 8));
      } catch (_) {}
    }
    await backToLocal();
  }

  // ==================== 轮询与平滑进度 ====================

  void _startPolling(String peerId) {
    _stopTimers();
    _failureCount = 0;
    _pollInterval = const Duration(seconds: 2);
    _wasActivePlaying = false;
    _userCommandSincePlaying = false;
    unawaited(_tick(peerId));
    _schedulePoll(peerId);
    _tickTimer = Timer.periodic(
      Duration(milliseconds: _progressTickMs),
      (_) => _advanceSmooth(),
    );
  }

  /// 自适应轮询:失败翻倍(上限 15s),成功回落 2s(对齐前端 P2 退避)。
  void _schedulePoll(String peerId) {
    _pollTimer?.cancel();
    _pollTimer = Timer(_pollInterval, () async {
      await _tick(peerId);
      if (!mounted) return;
      // 控制目标已切换/回本机:停止该轮询链,避免孤儿定时器持续空转。
      if (state.activePeer?.peerId != peerId) return;
      _schedulePoll(peerId);
    });
  }

  void _stopTimers() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _tickTimer?.cancel();
    _tickTimer = null;
    _failureCount = 0;
    _lastPollPosition = -1;
  }

  Future<void> pollOnce() async {
    final peerId = state.activePeer?.peerId;
    if (peerId != null) await _tick(peerId);
  }

  /// 平滑进度插值:播放中按 tick 递增,轮询结果回写修正。
  void _advanceSmooth() {
    final st = state;
    final status = st.status;
    if (!status.playing || status.durationSeconds <= 0) return;
    final next = (st.smoothPositionSeconds + _progressTickMs / 1000)
        .clamp(0.0, status.durationSeconds);
    if (next == st.smoothPositionSeconds) return;
    state = st.copyWith(smoothPositionSeconds: next);
  }

  Future<void> _tick(String peerId) async {
    final client = _ref.read(subsonicApiClientProvider);
    if (!mounted) return;
    // 轮询期间用户可能已切换/回本机:控制目标不再是该 peer 时,本次结果作废。
    // 若不加此守卫,回本机恢复本地快照后,仍在途的轮询响应会把后端队列/状态再次
    // 镜像到 playerProvider,导致 UI 显示后端播放态而本机实际在播另一首歌。
    if (state.activePeer?.peerId != peerId) return;
    final base = '/rest/api/v1/peers/${Uri.encodeComponent(peerId)}';
    try {
      final st = await client.getRaw('$base/status').timeout(const Duration(seconds: 6));
      final next = PeerStatus.fromJson((st as Map).cast<String, dynamic>());

      // 播放状态自愈(对齐前端 startCastPoll):部分 DLNA 设备经「清空→重选→重新播放」
      // 后 GENA 事件缓存的 state 停留在旧值(如 STOPPED)并覆盖 SOAP 实时 PLAYING,
      // 轮询读到 state=STOPPED 却 position 仍在前进(进度条在走)。此时以「position 真实
      // 前进」作为在播的权威证据,强制 playing=true,避免按钮卡在「未播放」。
      final advancing = next.durationSeconds > 0 &&
          next.positionSeconds > _lastPollPosition &&
          next.positionSeconds < next.durationSeconds;
      _lastPollPosition = next.positionSeconds;
      final effectiveStatus = (advancing && next.state != 'PLAYING')
          ? next.copyWith(state: 'PLAYING', active: true)
          : next;

      // 队列自然播完检测:设备曾处于活跃播放,随后无任何客户端命令干预而跳变为
      // 非活跃(STOPPED/空)即判定整轮队列播放完毕,endOfQueueCount +1,
      // 供随机歌曲「播完自动换一批」等场景监听触发续播。
      if (effectiveStatus.active) {
        _wasActivePlaying = true;
        // 设备已在用户命令后恢复活跃播放:清除命令标记,恢复自然播完判定能力。
        if (_userCommandSincePlaying) _userCommandSincePlaying = false;
      } else {
        if (_wasActivePlaying && !_userCommandSincePlaying) {
          final ended = state.endOfQueueCount + 1;
          state = state.copyWith(endOfQueueCount: ended);
          Logger.infoWithTag('CAST', 'queue naturally ended, count=$ended');
        }
        _wasActivePlaying = false;
      }

      // 队列权威在后端:同步 currentIndex/playMode/队列快照(UI 曲目/歌词/队列跟随设备)。
      final snap = await client
          .getRaw('$base/queue')
          .timeout(const Duration(seconds: 6));
      // 二次校验:两次 HTTP 请求期间控制目标可能已切换/回本机,再确认一次,
      // 防止把旧 peer 的队列镜像到刚恢复的本地播放状态上。
      if (state.activePeer?.peerId != peerId) return;
      var idx = state.castIndex;
      var mode = state.playMode;
      List<Map<String, dynamic>> items = state.castQueue;
      if (snap is Map) {
        final si = (snap['currentIndex'] as num?)?.toInt() ?? -1;
        final total = (snap['total'] as num?)?.toInt() ?? 0;
        final sm = snap['playMode'];
        if (sm is String && sm.isNotEmpty) mode = sm;
        final raw = snap['items'];
        if (raw is List) {
          items = raw.whereType<Map<String, dynamic>>().toList();
        }
        if (si >= 0 && si < total && items.isNotEmpty) {
          idx = si;
          // 后端权威:镜像整队 + 游标到本地,迷你条/歌词/相邻关系跟随设备。
          // 投屏期间本地保持暂停,不触发本地播放。
          _ref.read(playerProvider.notifier).syncQueueForCast(items, si);
        }
      }

      // 成功:回落基准间隔,清除离线标记。
      _failureCount = 0;
      _pollInterval = const Duration(seconds: 2);
      if (!mounted) return;
      state = state.copyWith(
        status: effectiveStatus,
        smoothPositionSeconds: next.positionSeconds,
        castIndex: idx,
        playMode: mode,
        castQueue: items,
        offline: false,
      );
    } on TimeoutException {
      _handlePollFailure();
    } catch (_) {
      // 网络/权限失败:退避,连续失败置离线。
      _handlePollFailure();
    }
  }

  void _handlePollFailure() {
    _failureCount++;
    _pollInterval = Duration(seconds: (_pollInterval.inSeconds * 2).clamp(2, 15));
    if (_failureCount >= 3) {
      state = state.copyWith(offline: true, status: const PeerStatus());
    }
  }

  Future<dynamic> _post(String action, {Object? data}) async {
    final peerId = state.activePeer?.peerId;
    final client = _ref.read(subsonicApiClientProvider);
    if (peerId == null) return null;
    _markUserCommand();
    try {
      return await client
          .postRaw(
            '/rest/api/v1/peers/${Uri.encodeComponent(peerId)}/$action',
            data: data,
          )
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      return null;
    }
  }

  /// 标记「客户端发出过传输命令」,抑制队列自然播完的误判。
  void _markUserCommand() => _userCommandSincePlaying = true;

  @override
  void dispose() {
    _stopTimers();
    stopHeartbeat();
    super.dispose();
  }
}

final castPeerControllerProvider =
    StateNotifierProvider<CastPeerController, CastPeerState>((ref) {
  return CastPeerController(ref);
});

/// 当前控制目标名称(本机 / 设备名),供迷你条与全屏反馈。
final castTargetNameProvider = Provider<String>((ref) {
  return ref.watch(castPeerControllerProvider).targetName;
});

/// 是否处于投屏控制态(选中了远端 peer 即视为投屏控制中)。
final isCastingProvider = Provider<bool>((ref) {
  return ref.watch(
    castPeerControllerProvider.select((s) => s.activePeer != null),
  );
});
