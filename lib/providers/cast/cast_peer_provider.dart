import 'dart:async';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/utils/logger.dart';
import 'package:musicflow_client/data/models/peer.dart';
export 'package:musicflow_client/providers/cast/cast_peer_state.dart';
import 'package:musicflow_client/providers/cast/cast_peer_state.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/player/queue_origin_provider.dart';

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

/// 队列传输超时预算（**随队列规模缩放**）。
///
/// 为什么必须缩放：
/// - 后端 `POST /v1/peers/:id/queue/play` 是**同步语义**——落库整队后还要等设备
///   Stop→SetAVTransportURI→Play 完成才返回（内含最长 ~5s 的 GENA 乐观窗口）；
/// - 再叠加 MB 级 JSON 的上传/下载：单条 queue item ≈ 400B，5000 首 ≈ 2MB，
///   手机 WiFi 上行抖动时单是传完 body 就可能几十秒；
/// - Windows 有线网低延迟所以历史固定 8s 无感，安卓弱网下必然先超时。
///
/// 公式：10s 基线 + 每首 30ms，封顶 180s（≈5600 首触顶）。
/// 5000 首 ≈ 160s / 2MB，等效传输门槛仅 ~12KB/s，正常局域网不可能触顶。
///
/// 注意：只放宽 `Future.timeout()` 无效——Dio 全局 receiveTimeout/sendTimeout
/// 是 30s，会先于外层 Future 触发。调用方必须把本预算**同时**传给
/// `postRaw/getRaw` 的 `receiveTimeout`。
Duration queueTransferBudget(int itemCount) =>
    Duration(milliseconds: (10000 + itemCount * 30).clamp(10000, 180000));

/// 拉取队列快照时的保守预算（规模未知，按最坏 5000 首量级给）。
const Duration kQueueFetchBudget = Duration(seconds: 60);

/// **主通道**（`POST /rest/api/v1/play`，服务端内容点播）的超时预算。
///
/// 为什么不能像历史那样固定 15s：
/// - 该端点虽只有几百字节载荷（客户端零上传），但**语义是同步的**——后端要
///   `resolveContentSongs` 查库解析出整队 + `playFrom` 落库 + 等设备
///   Stop→SetAVTransportURI→Play 完成（含 ~5s GENA 乐观窗口）才返回；
/// - 队列规模越大，后端解析/落库/投递的耗时越长。大歌单（数千首）实测会顶穿
///   15s → 客户端误判失败 → 回落 [playQueueOnPeer] 再推 2MB 整队，**等于把
///   一件事做两遍**，用户观感是「音箱先响一下又重来」或长时间无响应。
///
/// 公式与 [queueTransferBudget] 同源（10s 基线 + 30ms/首，封顶 180s），保证
/// 两条通道对「同一规模」的耐心一致，不会出现主通道先放弃、回落通道还在等的错位。
Duration contentPlayBudget(int itemCount) =>
    queueTransferBudget(itemCount);

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
    } catch (e) {
      // 注册失败不阻塞登录;后续心跳按 local:<uid> 兜底再试。
      Logger.debugWithTag('CAST-PEER', 'register self peer failed: $e');
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
    } catch (e) {
      // 心跳失败忽略,下个周期再试。
      Logger.debugWithTag('CAST-PEER', 'heartbeat failed: $e');
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
    } catch (e) {
      Logger.debugWithTag('CAST-PEER', 'loadPeers failed: $e');
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
      } catch (e) {
        Logger.debugWithTag('CAST-PEER', 'stopCasting: stop failed: $e');
      }
      try {
        await client.postRaw('$base/queue/deactivate').timeout(const Duration(seconds: 8));
      } catch (e) {
        Logger.debugWithTag('CAST-PEER', 'stopCasting: queue/deactivate failed: $e');
      }
    }
    await backToLocal();
  }

  // ==================== 接续搬移（本机 ⇄ DLNA 设备） ====================

  /// 拉取 peer 实时队列摘要：当前曲目（歌名/歌手）+ 游标 + 是否在播。
  /// 供「选择播放器」弹窗第二行展示与「接回本机」按钮可用性判断。
  /// 请求失败（设备掉线/网络抖）返回 null，调用方按「未知」处理。
  Future<PeerNowPlaying?> fetchPeerNowPlaying(String peerId) async {
    final client = _ref.read(subsonicApiClientProvider);
    try {
      final data = await client
          .getRaw(
            '/rest/api/v1/peers/${Uri.encodeComponent(peerId)}/queue',
            receiveTimeout: kQueueFetchBudget,
          )
          .timeout(kQueueFetchBudget) as Map<String, dynamic>;
      final media = data['currentMedia'];
      return PeerNowPlaying(
        isActive: data['isActive'] == true,
        currentIndex: (data['currentIndex'] as num?)?.toInt() ?? -1,
        total: (data['total'] as num?)?.toInt() ?? 0,
        title: media is Map ? '${media['title'] ?? ''}' : '',
        artist: media is Map ? (media['artist'] as String?) : null,
      );
    } catch (e) {
      Logger.debugWithTag('CAST-PEER', 'fetchPeerNowPlaying failed: $e');
      return null;
    }
  }

  /// 推到音箱：把**本机**的播放队列 + 当前进度推给 [peer]，从同一进度接续播放，
  /// 本机暂停（接续搬移语义：搬完原边停止）。
  ///
  /// 仅在本机真正在放（无 activePeer）时可用——投屏态下本机队列只是远端镜像，
  /// 没有「本机播放现场」可搬。链路：switchTo(快照+暂停本机) → **主通道优先**。
  ///
  /// **主通道优先（2026-09-10 修复）**：本机队列若源自服务端可解析的内容
  /// （歌单/专辑/艺术家，见 [queueOriginProvider]），则只传
  /// `{type, id, songId=当前曲}` 让服务端自行查库解析队列 —— 几百字节，
  /// 且享有服务端多源优选与换源回退。
  ///
  /// 为什么搬移路径也必须走主通道（历史缺口，实测数据）：
  /// 搬移此前**只**做整队推送，payload 随队列规模线性膨胀——3251 首实测
  /// **642.3KB / 8411ms**（公网），而主通道仅 **115B / 205ms**，即缩约
  /// **5720×**、快约 **27×**。
  ///
  /// **更关键：公网入口（Lucky WAF）对大批量 POST body 有硬闸门**——
  /// 超过约 90KB（≈300 首）即被反代以 403 拒绝（`<title>403 - Lucky WAF</title>`，
  /// 不是服务端拒绝）。即整队推送在公网**不是慢，而是根本发不出去**，
  /// 大歌单搬移必然失败。主通道 body 恒为几百字节，天然不受闸门限制，因此
  /// **主通道优先是可用性要求，不是性能优化**。
  ///
  /// ⚠️ 复测注意：若闸门被临时关闭（维护期间），`tool/verify_handoff_main_channel.py`
  /// 会看到 541KB/642KB 也返回 200 —— 那是**闸门关闭态**，不能据此认为
  /// 整队推送可用，更不能据此回退主通道优先。判定闸门是否生效：看响应体是否
  /// 出现 `Lucky WAF` 或 403，而不是只看体积。
  ///
  /// 来源不可解析时（首页随机 discover / 搜索结果 search / 本地任意队列 other、
  /// 或来源 id 缺失）仍回落整队推送 —— 服务端无从重建这些队列，只能原样搬运。
  Future<bool> pushLocalToPeer(PeerInfo peer) async {
    if (peer.isLocal) return false;
    final ps = _ref.read(playerProvider);
    if (ps.queue.isEmpty) return false;
    final items = ps.queue.map(songToQueueItem).toList(growable: false);
    final start = ps.currentIndex.clamp(0, items.length - 1);
    // 本机队列的来源（播放该队列时写入；discover/search/other 的
    // serverContentType 为 null）。必须在 switchTo 之前读——切换只动控制目标，
    // 但提前取值语义更清晰，也不受后续状态变化影响。
    final origin = _ref.read(queueOriginProvider);
    final contentType = origin?.serverContentType;
    final contentId = origin?.id;
    final startSongId = start < items.length ? items[start]['songId'] as String? : null;
    if (state.activePeer?.peerId != peer.peerId) {
      final switched = await switchTo(peer);
      if (!switched) return false;
    }
    // 主通道：服务端按 {type,id} 自行解析队列，按 songId 身份定位起点（与排序无关）。
    // 失败（内容已删 / 服务端旧版无该端点 / 来源与库内不一致）→ 回落整队推送。
    if (contentType != null && contentId != null && contentId.isNotEmpty) {
      final ok = await playContentOnPeer(
        type: contentType,
        id: contentId,
        songId: startSongId,
        localItems: items,
        localStartIndex: start,
      );
      if (ok) return true;
      Logger.debugWithTag(
        'CAST-PEER',
        'pushLocalToPeer: main channel failed for '
        '${origin?.kind.name}:$contentId, fallback to full-queue push',
      );
    }
    // 兜底：整队推送（来源服务端无从解析时必须走这条）。
    return _pushQueueAndPlay(peer.peerId, items, start);
  }

  /// 接回本机：把 [peer] 的播放队列搬回本机，从当前曲开头自动接续播放，
  /// 设备停止（接续搬移语义：搬完原边停止）。不搬进度。
  ///
  /// 链路：GET queue(队列+游标) → 停设备 → 本机 playSong(同队同曲自动播)。
  Future<bool> pullPeerToLocal(PeerInfo peer) async {
    final client = _ref.read(subsonicApiClientProvider);
    final base = '/rest/api/v1/peers/${Uri.encodeComponent(peer.peerId)}';
    final Map<String, dynamic> queueData;
    try {
      queueData = await client
          .getRaw('$base/queue', receiveTimeout: kQueueFetchBudget)
          .timeout(kQueueFetchBudget) as Map<String, dynamic>;
    } catch (e) {
      Logger.debugWithTag('CAST-PEER', 'pullPeerToLocal: queue failed: $e');
      return false;
    }
    final rawItems = (queueData['items'] as List? ?? [])
        .whereType<Map<String, dynamic>>()
        .toList();
    if (rawItems.isEmpty) return false;
    final songs =
        rawItems.map(castQueueItemToSong).toList(growable: false);
    var index = (queueData['currentIndex'] as num?)?.toInt() ?? 0;
    if (index < 0 || index >= songs.length) index = 0;

    // 先停设备(数据已到手):active 时走完整 stopCasting(停+失活+切回本机),
    // 非 active 设备只尽力 stop,不影响当前投屏会话。
    if (state.activePeer?.peerId == peer.peerId) {
      await stopCasting();
    } else {
      _markUserCommand();
      try {
        await client.postRaw('$base/stop').timeout(const Duration(seconds: 8));
      } catch (_) {}
    }

    // 本机从当前曲开头自动接续(不搬进度)。
    try {
      await _ref.read(playerProvider.notifier).playSong(
            songs[index],
            queue: songs,
            index: index,
            autoPlay: true,
          );
      return true;
    } catch (e) {
      Logger.debugWithTag('CAST-PEER', 'pullPeerToLocal: local resume failed: $e');
      return false;
    }
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
    unawaited(pollOnce(fullQueue: true));
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
  Future<void> setSleepTimer(Duration? duration) async {
    final peerId = state.activePeer?.peerId;
    final client = _ref.read(subsonicApiClientProvider);
    if (peerId == null) return;
    final base = '/rest/api/v1/peers/${Uri.encodeComponent(peerId)}';
    if (duration == null || duration <= Duration.zero) {
      try {
        await client.deleteRaw('$base/sleep-timer').timeout(const Duration(seconds: 8));
      } catch (e) {
        Logger.debugWithTag('CAST-PEER', 'setSleepTimer: delete failed: $e');
      }
      return;
    }
    // 后端不可达时暴露给调用方,避免'静默不生效'。
    await client.postRaw(
      '$base/sleep-timer',
      data: <String, dynamic>{
        'durationSeconds': duration.inSeconds,
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
    } catch (e) {
      Logger.debugWithTag('CAST-PEER', 'getSleepTimerRemaining failed: $e');
    }
    return null;
  }

  Future<void> next() async {
    if (state.activePeer == null) {
      await _ref.read(playerProvider.notifier).next();
      return;
    }
    await _post('next');
    unawaited(pollOnce(fullQueue: true));
  }

  Future<void> previous() async {
    if (state.activePeer == null) {
      await _ref.read(playerProvider.notifier).previous();
      return;
    }
    await _post('prev');
    unawaited(pollOnce(fullQueue: true));
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

  /// **服务端内容点播**（投屏主通道，遥控器语义）：
  /// 只把「内容类型 + 内容 ID + 起始歌曲 ID」交给后端，由后端自行
  /// `resolveContentSongs(type, id)` 查库 → `songsToQueueItems` → 按 songId
  /// 定位起点 → `playFrom` 落库并投屏。客户端**一个字节的歌曲数据都不上传**。
  ///
  /// [type] = 服务端能自行解析的内容种类：playlist / album / artist / song / genre。
  /// （`song` 即「只播这一首」——服务端解析出的队列就只有它一首；这不代表
  /// 「歌单里只有一首」，后者应传 `type=playlist`。）
  ///
  /// 相比 [playQueueOnPeer]（整队推送）的优势：
  /// - 5000 首歌单的起播从「拉 25 页 + 推 2MB」压缩成**一个几百字节的请求**，
  ///   彻底没有大 body 超时问题（安卓弱网推流失败的真正根因）；
  /// - 服务端解析出的队列带完整元数据（track/discNumber/albumArtist/year/genre），
  ///   且享有服务端的多源优选与本地源失效回退（客户端推的是本地快照，没有这些）。
  ///
  /// **[songId] 是定位起点的方式（身份，非行号）**：服务端在解析出的队列里
  /// `findIndex(songId)`，与两侧排序无关。历史用 `startIndex`（本地列表行号）
  /// 定位时，因服务端/客户端排序不同源而静默播错歌，客户端不得不加「投后拉队列
  /// 比对槽位、不一致就回落推 2MB」的补丁——补丁比问题本身更糟，已随 songId
  /// 定位一并移除。传了 songId 但服务端队列里没有 → 服务端返 404，此处返回 false。
  ///
  /// [localItems]/[localStartIndex] 仅用于成功后的**乐观镜像**（调用方手上已有
  /// 列表时直接跟随，省一次轮询）；没有则只置起播态，队列由轮询回写后端权威。
  /// 失败返回 false，调用方应回落到 [playQueueOnPeer]。
  Future<bool> playContentOnPeer({
    required String type,
    required String id,
    String? songId,
    int? startIndex,
    List<Map<String, dynamic>>? localItems,
    int? localStartIndex,
  }) async {
    final peerId = state.activePeer?.peerId;
    if (peerId == null || type.isEmpty || id.isEmpty) return false;
    final client = _ref.read(subsonicApiClientProvider);
    _markUserCommand();
    final sw = Stopwatch()..start();
    // 超时随队列规模缩放：大歌单后端解析+投递慢，固定 15s 会误判失败并触发
    // 回落重推 2MB 整队（见 contentPlayBudget 文档）。预算同时下发给 Dio。
    final budget = contentPlayBudget(localItems?.length ?? 0);
    try {
      final resp = await client
          .postRaw(
            '/rest/api/v1/play',
            data: <String, dynamic>{
              'peerId': peerId,
              'type': type,
              'id': id,
              if (songId != null && songId.isNotEmpty) 'songId': songId,
              if (songId == null || songId.isEmpty)
                'startIndex': startIndex ?? 0,
            },
            receiveTimeout: budget,
          )
          .timeout(budget);
      if (resp is! Map || resp['success'] != true) return false;

      // 起点以服务端回执为准（它按 songId 定位出的真实下标），不用本地行号。
      final queueStart = localStartIndex ?? startIndex ?? 0;

      final items = localItems;
      if (items != null && items.isNotEmpty) {
        // 本地也按 songId 对齐游标：服务端按身份定位，本地镜像跟随同一身份，
        // 避免两边按各自行号算导致高亮/进度指向不同曲目。
        final idx = songId != null && songId.isNotEmpty
            ? items.indexWhere((e) => e['songId'] == songId)
            : -1;
        final start = idx >= 0 ? idx : queueStart.clamp(0, items.length - 1);
        _ref.read(playerProvider.notifier).syncQueueForCast(items, start);
        _lastPollPosition = -1;
        state = state.copyWith(
          castQueue: items,
          castIndex: start,
          smoothPositionSeconds: 0,
          offline: false,
          status: state.status.copyWith(
            state: 'PLAYING',
            active: true,
            positionSeconds: 0,
          ),
        );
      } else {
        _lastPollPosition = -1;
        state = state.copyWith(
          smoothPositionSeconds: 0,
          offline: false,
          status: state.status.copyWith(
            state: 'PLAYING',
            active: true,
            positionSeconds: 0,
          ),
        );
      }
      unawaited(pollOnce());
      return true;
    } catch (e) {
      Logger.warnWithTag(
        'CAST-PEER',
        'playContentOnPeer($type:$id) failed after '
        '${sw.elapsedMilliseconds}ms: $e',
      );
      return false;
    }
  }

  /// 投屏中播放专辑/歌单/列表:命令**后端**以该队列在设备上播放(对齐前端 castPlayQueue)。
  /// 客户端此时是后端的远程遥控器,不在本机播放。
  ///
  /// 这是**兜底通道**：把客户端手上的整队推给服务端。仅有主通道
  /// [playContentOnPeer] 不可用时才走（服务端无从解析的来源 discover/search/other、
  /// 内容已删、旧版服务端 404、以及主通道回落的场景）。
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
    // 超时随队列规模缩放(见 queueTransferBudget):800 首 ≈ 39s、5000 首 ≈ 165s。
    // 必须同时下发给 Dio——全局 receiveTimeout 30s 会先于外层 Future 触发。
    final budget = queueTransferBudget(items.length);
    final sw = Stopwatch()..start();
    try {
      final resp = await client
          .postRaw(
            '/rest/api/v1/peers/${Uri.encodeComponent(peerId)}/queue/play',
            data: <String, dynamic>{'items': items, 'startIndex': startIndex},
            receiveTimeout: budget,
          )
          .timeout(budget);
      final success = resp is Map && resp['success'] == true;
      if (!success) return false;

      // 同步该设备播放模式(队列替换后保持设备当前模式,对齐 pushCastQueueToBackend)。
      final mode = state.playMode;
      try {
        await client.postRaw(
          '/rest/api/v1/peers/${Uri.encodeComponent(peerId)}/play-mode',
          data: <String, dynamic>{'mode': mode},
        );
      } catch (e) {
        Logger.debugWithTag('CAST-PEER', '_pushQueueAndPlay: sync play-mode failed: $e');
      }

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
    } catch (e) {
      Logger.warnWithTag(
        'CAST-PEER',
        '_pushQueueAndPlay failed after ${sw.elapsedMilliseconds}ms '
        '(budget=${budget.inMilliseconds}ms, items=${items.length}): $e',
      );
      return false;
    }
  }

  /// 投屏中加歌:追加到后端队列(不影响当前播放)。
  Future<void> enqueueSongs(List<dynamic> songs) async {
    final peerId = state.activePeer?.peerId;
    if (peerId == null || songs.isEmpty) return;
    final items = songs.map(songToQueueItem).toList();
    await _post(
      'queue/enqueue',
      data: <String, dynamic>{'items': items},
      budget: queueTransferBudget(items.length),
    );
    unawaited(pollOnce(fullQueue: true));
  }

  /// 点歌:跳播到指定索引(即使随机模式也尊重 index,对齐后端 queue/jump)。
  Future<void> jumpTo(int index) async {
    final peerId = state.activePeer?.peerId;
    if (peerId == null) return;
    await _post('queue/jump', data: <String, dynamic>{'index': index});
    unawaited(pollOnce(fullQueue: true));
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
    } catch (e) {
      Logger.debugWithTag('CAST-PEER', 'removeQueueItem failed: $e');
    }
    unawaited(pollOnce(fullQueue: true));
  }

  /// 队列拖拽排序(from → to,对齐前端 castReorderQueue)。
  Future<void> reorderQueue(int from, int to) async {
    final peerId = state.activePeer?.peerId;
    if (peerId == null) return;
    await _post('queue/reorder', data: <String, dynamic>{'from': from, 'to': to});
    unawaited(pollOnce(fullQueue: true));
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
      } catch (e) {
        Logger.debugWithTag('CAST-PEER', 'clearCastQueue failed: $e');
      }
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

  /// 立即刷新一次。
  ///
  /// [fullQueue] = true 时强制拉**全量**队列快照；默认走轻量轮询
  /// （`?offset=start&size=1`，~0.6KB，详见 `_tick` 注释）。
  /// 本地命令改了队列结构（整队替换 / 增删 / 重排 / 跳播）后必须传 true，
  /// 否则镜像只认「服务端 total」——外部改队列且 total 不变时轻量路径抓不到。
  Future<void> pollOnce({bool fullQueue = false}) async {
    final peerId = state.activePeer?.peerId;
    if (peerId != null) await _tick(peerId, fullQueue: fullQueue);
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

  Future<void> _tick(String peerId, {bool fullQueue = false}) async {
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

      // ==================== 轻量轮询（SPEC §12.1 根治） ====================
      // 队列权威在后端，但**不必每 2s 拉整队**：`GET /peers/:id/queue` 本来就支持
      // `offset`/`size`，且 `total`/`currentIndex`/`playMode`/`ended`/`isActive`/
      // `currentMedia` 全在响应外层（不随分页丢失）。
      // 实测 100 首队列：全量 26 061B → `?offset=start&size=1` **546B（≈48×）**；
      // 5000 首量级由 ~2MB/次 降到 **<1KB/次**（此前 25s 超时就是在给 2MB 快照兜底）。
      // 拉取策略：
      //   - 常规 tick：`size=1` 只取**当前槽位那一首**（UI 的曲目/歌词/相邻关系用它）；
      //   - 补拉全量：镜像为空、或服务端 `total` ≠ 本地长度（队列被增删）、
      //     或调用方显式要求（本地刚改过队列结构 → `pollOnce(fullQueue: true)`）。
      // 残留：外部改队列且 total 不变时轻量路径抓不到（对齐前端 startCastPoll 的
      // 数据形状，需真机实测"远端设备上一曲/下一曲"后再定轮次兜底）。
      var idx = state.castIndex;
      var mode = state.playMode;
      var items = state.castQueue;
      var needFull = fullQueue || items.isEmpty;
      var knownTotal = items.length;
      // 服务端权威洗牌序列(镜像)。轻量路径也会带下来(shuffleOrder/shufflePos
      // 都在响应外层,不随分页丢失),所以每次 tick 都能对齐,不必补拉全量。
      var shuffleOrder = state.shuffleOrder;
      var shufflePos = state.shufflePos;

      /// 从快照外层解析权威洗牌序列(缺失/类型不对则保持原值)。
      void readShuffle(Map<String, dynamic> s) {
        final rawOrder = s['shuffleOrder'];
        if (rawOrder is List) {
          shuffleOrder = rawOrder
              .whereType<num>()
              .map((e) => e.toInt())
              .toList(growable: false);
        }
        final sp = s['shufflePos'];
        if (sp is num) shufflePos = sp.toInt();
      }

      Future<Map<String, dynamic>?> fetchQueue({required bool full}) async {
        final res = await client
            .getRaw(
              '$base/queue',
              queryParameters: full
                  ? null
                  : <String, String>{'offset': '$knownTotal', 'size': '1'},
            )
            .timeout(const Duration(seconds: 25));
        return res is Map ? res.cast<String, dynamic>() : null;
      }

      var snap = await fetchQueue(full: needFull);
      // 二次校验:两次 HTTP 请求期间控制目标可能已切换/回本机,再确认一次,
      // 防止把旧 peer 的队列镜像到刚恢复的本地播放状态上。
      if (state.activePeer?.peerId != peerId) return;

      if (snap != null) {
        final si = (snap['currentIndex'] as num?)?.toInt() ?? -1;
        final total = (snap['total'] as num?)?.toInt() ?? 0;
        final sm = snap['playMode'];
        if (sm is String && sm.isNotEmpty) mode = sm;
        readShuffle(snap);
        final raw = snap['items'];
        final edge = raw is List
            ? raw.whereType<Map<String, dynamic>>().toList()
            : const <Map<String, dynamic>>[];

        if (!needFull && total != items.length) {
          // 服务端队列长度变了（外部增删）→ 补拉全量重建镜像。
          needFull = true;
        } else if (!needFull &&
            edge.length == 1 &&
            si >= 0 &&
            si < items.length) {
          // 轻量路径：把**当前槽位那一首**换成服务端权威版本。
          // 注意顺序 —— si 是服务端权威游标，必须先从快照读出，再覆盖槽位值；
          // 反过来会把刚写入的权威曲目又按旧扇区取出来。
          final updated = List<Map<String, dynamic>>.of(items);
          updated[si] = edge.first;
          items = updated;
        }

        if (needFull) {
          snap = await fetchQueue(full: true);
          if (state.activePeer?.peerId != peerId) return;
          if (snap != null) {
            final rawFull = snap['items'];
            if (rawFull is List) {
              items = rawFull.whereType<Map<String, dynamic>>().toList();
            }
            final siFull = (snap['currentIndex'] as num?)?.toInt() ?? si;
            final smFull = snap['playMode'];
            if (smFull is String && smFull.isNotEmpty) mode = smFull;
            readShuffle(snap);
            if (siFull >= 0 && siFull < total && items.isNotEmpty) idx = siFull;
          }
        }

        if (si >= 0 && si < total && items.isNotEmpty) {
          idx = si;
          // 后端权威:镜像队列 + 游标到本地,迷你条/歌词/相邻关系跟随设备。
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
        shuffleOrder: shuffleOrder,
        shufflePos: shufflePos,
      );
    } on TimeoutException {
      _handlePollFailure();
    } catch (e) {
      // 网络/权限失败:退避,连续失败置离线。
      Logger.debugWithTag('CAST-PEER', 'pollOnce failed: $e');
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

  Future<dynamic> _post(
    String action, {
    Object? data,
    Duration? budget,
  }) async {
    final peerId = state.activePeer?.peerId;
    final client = _ref.read(subsonicApiClientProvider);
    if (peerId == null) return null;
    _markUserCommand();
    final timeout = budget ?? const Duration(seconds: 8);
    try {
      return await client
          .postRaw(
            '/rest/api/v1/peers/${Uri.encodeComponent(peerId)}/$action',
            data: data,
            receiveTimeout: budget,
          )
          .timeout(timeout);
    } catch (e) {
      Logger.debugWithTag('CAST-PEER', '_post($action) failed: $e');
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

/// 单个 peer 的实时队列摘要(FutureProvider.family):「选择播放器」弹窗
/// 每个设备行 watch 自己的 peerId,打开弹窗即拉、autoDispose 自动回收。
/// 刷新时 invalidate 全部条目;失败保留上一次结果(按「未知/未在播放」展示)。
///
/// **流式轮询(2026-09-10)**:原先是一次性 FutureProvider,拉一次缓存到死,
/// MINI 弹窗与桌面歌词设备行显示的都是「打开瞬间的快照」——歌曲切了界面
/// 不跟着变(用户实测反馈)。改为 StreamProvider:**有监听者期间每 5s 重拉**,
/// 弹窗关闭(autoDispose 无人监听)轮询自动停止;MINI 弹窗的 PeerCastRow
/// 直接 watch 即得实时数据,无需各处另起定时器。
final peerNowPlayingProvider = StreamProvider.autoDispose
    .family<PeerNowPlaying?, String>((ref, peerId) async* {
  final controller = ref.read(castPeerControllerProvider.notifier);
  PeerNowPlaying? last;
  while (true) {
    final now = await controller.fetchPeerNowPlaying(peerId);
    // 拉取失败(设备离线/网络抖动)保留上一次结果,不让界面闪「状态未知」。
    if (now != null) last = now;
    yield now ?? last;
    await Future<void>.delayed(const Duration(seconds: 5));
  }
});
