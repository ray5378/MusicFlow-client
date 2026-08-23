import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/peer.dart';
import 'api_provider.dart';
import 'player_provider.dart';

/// 「切换播放器」控制器 —— 对齐主项目前端 stores/player.ts 的 peer 机制:
/// - 面板列出 `GET /rest/api/v1/peers`(本机 + DLNA/AirPlay/群组);
/// - 选中远端 peer → 把本地队列 POST /peers/:id/queue/play,由**后端**负责向设备投流;
///   客户端只保留控制面(播放/暂停/切歌/seek/音量)与状态轮询;
/// - 本机模式 = 现有 just_audio 播放,不经过后端。
///
/// 注意:后端权限为「非 admin 仅能控制自己的 `local:<uid>`」;普通账号面板只会
/// 出现本机条目,属预期表现。

class CastPeerState {
  const CastPeerState({
    this.activePeer,
    this.status = const PeerStatus(),
    this.loadingPeers = false,
  });

  /// null = 本机播放。
  final PeerInfo? activePeer;
  final PeerStatus status;
  final bool loadingPeers;

  bool get isCasting => activePeer != null && status.active;

  String get targetName => activePeer?.name ?? '本机';

  CastPeerState copyWith({
    PeerInfo? activePeer,
    bool clearActivePeer = false,
    PeerStatus? status,
    bool? loadingPeers,
  }) {
    return CastPeerState(
      activePeer: clearActivePeer ? null : (activePeer ?? this.activePeer),
      status: status ?? this.status,
      loadingPeers: loadingPeers ?? this.loadingPeers,
    );
  }
}

class CastPeerController extends StateNotifier<CastPeerState> {
  CastPeerController(this._ref) : super(const CastPeerState());

  final Ref _ref;
  Timer? _pollTimer;

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

  /// 切到指定 peer:推送当前队列给后端并开始投流;本机则停轮询恢复本地。
  Future<bool> switchTo(PeerInfo peer) async {
    final client = _ref.read(subsonicApiClientProvider);
    final player = _ref.read(playerProvider.notifier);
    final playerState = _ref.read(playerProvider);

    if (peer.isLocal) {
      await backToLocal(resumeLocal: true);
      return true;
    }
    if (playerState.queue.isEmpty || playerState.currentSong == null) {
      return false;
    }

    final items = playerState.queue.map(songToQueueItem).toList();
    final ok = await client.postRaw(
      '/rest/api/v1/peers/${Uri.encodeComponent(peer.peerId)}/queue/play',
      data: <String, dynamic>{
        'items': items,
        'startIndex': playerState.currentIndex.clamp(0, items.length - 1),
      },
    );
    final success = ok is Map && ok['success'] == true;
    if (!success) return false;

    // 后端已接管:暂停本地,启动状态轮询。
    await player.pause();
    state = state.copyWith(activePeer: peer, status: const PeerStatus(state: 'BUFFERING'));
    _startPolling(peer.peerId);
    return true;
  }

  /// 回本机:停止对远端的控制(不主动 stop 设备——对齐前端「仅切换控制目标」),
  /// 本地从队列当前位置继续可播。
  Future<void> backToLocal({bool resumeLocal = false}) async {
    _pollTimer?.cancel();
    _pollTimer = null;
    state = state.copyWith(clearActivePeer: true, status: const PeerStatus());
  }

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
    unawaited(pollOnce());
  }

  Future<void> setVolume(int volume) async {
    if (state.activePeer == null) return;
    await _post('volume', data: <String, dynamic>{'volume': volume});
  }

  // ==================== 轮询 ====================

  void _startPolling(String peerId) {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_tick(peerId));
    });
  }

  Future<void> pollOnce() async {
    final peerId = state.activePeer?.peerId;
    if (peerId != null) await _tick(peerId);
  }

  Future<void> _tick(String peerId) async {
    final client = _ref.read(subsonicApiClientProvider);
    if (!mounted) return;
    try {
      final st = await client
          .getRaw('/rest/api/v1/peers/${Uri.encodeComponent(peerId)}/status')
          .timeout(const Duration(seconds: 6));
      final next = PeerStatus.fromJson((st as Map).cast<String, dynamic>());

      // 队列权威在后端:同步 currentIndex 让 UI 曲目/歌词跟随设备。
      final snap = await client
          .getRaw('/rest/api/v1/peers/${Uri.encodeComponent(peerId)}/queue')
          .timeout(const Duration(seconds: 6));
      if (snap is Map) {
        final idx = (snap['currentIndex'] as num?)?.toInt() ?? -1;
        final total = (snap['total'] as num?)?.toInt() ?? 0;
        if (idx >= 0 && idx < total) {
          _ref.read(playerProvider.notifier).syncCursorForCast(index: idx);
        }
      }
      if (!mounted) return;
      state = state.copyWith(status: next);
    } on TimeoutException {
      state = state.copyWith(status: const PeerStatus());
    } catch (_) {
      // 网络/权限失败:保持上次状态,下一轮再试。
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
    _pollTimer?.cancel();
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
