import 'dart:async';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/peer.dart';
import 'api_provider.dart';
import 'player_provider.dart';

/// 「切换播放器」控制器 —— 对齐主项目前端 stores/player.ts 的 peer 机制:
/// - 面板列出 `GET /rest/api/v1/peers`(本机 + DLNA/AirPlay/群组);
/// - 选中远端 peer → 把本地队列 POST /peers/:id/queue/play,由**后端**负责向设备投流;
///   客户端只保留控制面(播放/暂停/切歌/seek/音量/静音/播放模式/队列编辑)与状态轮询;
/// - 本机模式 = 现有 just_audio 播放,不经过后端。
///
/// 注意:后端权限为「非 admin 仅能控制自己的 `local:<uid>`」;普通账号面板只会
/// 出现本机条目,属预期表现。
///
/// 完成项(对齐 SPEC §3.5):
/// 1. 注册与保活:登录后 POST /peers/register + 每 30s heartbeat(registerAndHeartbeat)。
/// 2. 回本机语义:backToLocal=仅切换控制目标(远端继续播);stopCasting=停止设备+deactivate。
/// 3. 播放模式同步:setPlayMode/cyclePlayMode 下发,轮询回读后端 playMode。
/// 4. 投屏中加歌/点歌:enqueueSongs / jumpTo。
/// 5. 队列编辑:removeQueueItem / reorderQueue(投屏队列面板)。
/// 6. 平滑进度:2s 轮询(失败退避至 15s)+ 桌面 500ms / 手机 250ms 插值 tick。
/// 7. 离线/被移除:连续 3 次轮询失败置 offline,切回/移除时停止定时器。
/// 8. 静音:setMuted 下发 /mute。
/// 9. 群组/AirPlay 差异化:switcher 按 kind 区分图标/标签(群组/离线)。
/// 10. 投屏失败:queue/play 失败返回 false,保持本机,不产生脏状态。

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

  bool get isCasting => activePeer != null;

  /// 设备是否真的在播(后端 state 判定)。
  bool get devicePlaying => status.active;

  String get targetName => activePeer?.name ?? '本机';

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

  /// 切到指定 peer:推送当前队列给后端并开始投流;本机则停轮询恢复本地。
  /// 失败返回 false(投屏失败回滚:保持本机,无脏状态)。
  Future<bool> switchTo(PeerInfo peer) async {
    final client = _ref.read(subsonicApiClientProvider);
    final player = _ref.read(playerProvider.notifier);
    final playerState = _ref.read(playerProvider);

    if (peer.isLocal) {
      await backToLocal();
      return true;
    }
    if (playerState.queue.isEmpty || playerState.currentSong == null) {
      return false;
    }

    final items = playerState.queue.map(songToQueueItem).toList();
    final startIndex = playerState.currentIndex.clamp(0, items.length - 1);
    final ok = await client.postRaw(
      '/rest/api/v1/peers/${Uri.encodeComponent(peer.peerId)}/queue/play',
      data: <String, dynamic>{'items': items, 'startIndex': startIndex},
    );
    final success = ok is Map && ok['success'] == true;
    if (!success) return false;

    // 同步本地播放模式到后端(对齐前端 pushCastQueueToBackend)。
    final mode = mapLocalPlayMode(player.playbackMode);
    try {
      await client.postRaw(
        '/rest/api/v1/peers/${Uri.encodeComponent(peer.peerId)}/play-mode',
        data: <String, dynamic>{'mode': mode},
      );
    } catch (_) {
      // 播放模式同步失败不影响投屏主流程。
    }

    // 后端已接管:暂停本地,记录投屏队列快照,启动状态轮询。
    await player.pause();
    state = state.copyWith(
      activePeer: peer,
      status: const PeerStatus(state: 'BUFFERING'),
      playMode: mode,
      castQueue: items,
      castIndex: startIndex,
      smoothPositionSeconds: 0,
      offline: false,
    );
    _startPolling(peer.peerId);
    return true;
  }

  /// 回本机:仅切换控制目标(远端继续播放,对齐前端 switchPeer 纯 UI 切换)。
  /// 不主动 stop 设备、不清空远端队列。
  Future<void> backToLocal() async {
    _stopTimers();
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

  /// 停止投屏:通知后端停止设备并标记队列 inactive(队列保留待恢复),然后切回本机。
  /// 区别于 backToLocal(仅切换控制目标);对齐前端 stopCast。
  Future<void> stopCasting() async {
    final peerId = state.activePeer?.peerId;
    final client = _ref.read(subsonicApiClientProvider);
    if (peerId != null) {
      final base = '/rest/api/v1/peers/${Uri.encodeComponent(peerId)}';
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
    await _post(state.status.playing ? 'pause' : 'play');
    unawaited(pollOnce());
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
      _schedulePoll(peerId);
    });
  }

  void _stopTimers() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _tickTimer?.cancel();
    _tickTimer = null;
    _failureCount = 0;
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
    final base = '/rest/api/v1/peers/${Uri.encodeComponent(peerId)}';
    try {
      final st = await client.getRaw('$base/status').timeout(const Duration(seconds: 6));
      final next = PeerStatus.fromJson((st as Map).cast<String, dynamic>());

      // 队列权威在后端:同步 currentIndex/playMode/队列快照(UI 曲目/歌词/队列跟随设备)。
      final snap = await client
          .getRaw('$base/queue')
          .timeout(const Duration(seconds: 6));
      var idx = state.castIndex;
      var mode = state.playMode;
      List<Map<String, dynamic>> items = state.castQueue;
      if (snap is Map) {
        final si = (snap['currentIndex'] as num?)?.toInt() ?? -1;
        final total = (snap['total'] as num?)?.toInt() ?? 0;
        if (si >= 0 && si < total) {
          idx = si;
          _ref.read(playerProvider.notifier).syncCursorForCast(index: si);
        }
        final sm = snap['playMode'];
        if (sm is String && sm.isNotEmpty) mode = sm;
        final raw = snap['items'];
        if (raw is List) {
          items = raw.whereType<Map<String, dynamic>>().toList();
        }
      }

      // 成功:回落基准间隔,清除离线标记。
      _failureCount = 0;
      _pollInterval = const Duration(seconds: 2);
      if (!mounted) return;
      state = state.copyWith(
        status: next,
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
