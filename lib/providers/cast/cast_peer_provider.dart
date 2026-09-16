import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/utils/logger.dart';
import 'package:musicflow_client/data/models/peer.dart';
export 'package:musicflow_client/providers/cast/cast_peer_state.dart';
import 'package:musicflow_client/providers/cast/cast_peer_state.dart';
import 'package:musicflow_client/providers/cast/peer_remote_control_provider.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/player/queue_origin_provider.dart';

/// 「流转播放」控制器 —— 对齐主项目前端 stores/player.ts 的 peer 机制:
/// - 面板列出 `GET /rest/api/v1/peers`(本机 + DLNA/AirPlay/群组);
/// - **流转播放 = 纯 UI 控制目标切换**(对齐前端 switchPeer):只改控制目标,
///   不推本地队列、不自动投屏;此后客户端是后端的**远程遥控器** —— 点歌/专辑/歌单
///   走 [playQueueOnPeer]/[playSongOnPeer] 命令**后端**在所选设备播放,播放控件
///   直接作用于该设备;
/// - 本机模式 = 现有 just_audio 播放(播放本身不经过后端);但**队列会镜像到服务端**
///   本端那一行(见「本机队列上报」),服务端预探测因此也能替本机链路预扫坏源,
///   且同账号多个播放端互不覆盖。离开本机时保存本地状态快照,回本机时恢复。
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
/// 11. 本机队列上报 + 自动注册:队列/游标/模式变化防抖镜像到服务端本端那一行
///     (每端一个临时端 ID,服务端隔离;投屏中不上报);未注册成功时心跳周期内
///     自动补注册(服务端重启/断线重连后无需用户操作)。

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

/// 「命令影子」保护窗口:本端下发控制命令后,在该窗口内忽略**采样早于命令**的
/// 滞后上报字段(音量 / 静音 / 进度)。
///
/// 取值依据:远端客户端的状态上报周期实测约 4s(见 `_projectPolledPosition`),
/// 取 8s = 一个上报周期 + 一倍余量,既覆盖最坏延迟,又不会在命令真的没生效时
/// 长时间掩盖真实状态(超时后自动恢复采纳服务端值)。
const int kCommandShadowWindowMs = 8000;

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

  /// 本机 peer 的对外 ID(`local:<uid>`,打码视图;真实实例 ID 只在服务端)。
  /// 播放器据此拉取服务端权威洗牌序列(SEE SPEC:洗牌序列唯一权威在服务端)。
  String? get localPeerId => _localPeerId;

  /// 连续轮询失败计数(离线判定)。
  int _failureCount = 0;

  /// 上次轮询读到的 position(用于「position 真实前进」播放态自愈判定)。
  double _lastPollPosition = -1;
  /// 最近一次本端发起 seek 的时刻(ms)。用于丢弃「seek 之前采样」的上报 ——
  /// 远端客户端要等下一个上报周期(~4s)才回新位置,期间轮询读到的仍是旧采样,
  /// 采纳它会把刚拖好的进度条拽回 seek 之前(与 HA 卡片 `_seekIssuedAt` 同款)。
  int _seekIssuedAtMs = 0;
  /// 最近一次本端下发**音量类命令**(volume / mute)的时刻(ms)。
  /// 与 seek 同因:远端客户端的音量也是周期上报的,连续拖动时(20→50→30)
  /// 上报回来的可能还是上一拍的 50,会把手上的 30 顶掉。
  int _volumeCommandAtMs = 0;
  /// 最近一次本端下发**传输类命令**(play / pause)的时刻(ms)。
  /// 远端上报滞后会让刚点的暂停被顶回「播放中」(详见 _applyTransportShadow)。
  int _transportCommandAtMs = 0;

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

  /// 登录后注册本机 peer(名称留给后端默认 username)并启动 30s 心跳,
  /// 同时开始把本机队列镜像到服务端。对齐前端 registerLocalPeer;best-effort。
  ///
  /// 服务端按请求头 `x-mf-client-id`(本安装的临时端 ID,见 LocalStorage.getClientId)
  /// 把本端与同账号的其它播放端(网页标签页 / 其它客户端)分开记账,对外返回的
  /// peerId 恒为 `local:<userId>`。
  Future<void> registerAndHeartbeat() async {
    await _registerSelf();
    startHeartbeat();
    _watchLocalQueue();
    _startLocalStatusReporting();
  }

  /// 注册本端(不碰心跳/监听),供 registerAndHeartbeat 与心跳补注册复用。
  ///
  /// [attempt] 为就近重试计数：冷启动时注册是由 auth 状态翻转**立刻**触发的，
  /// 而那一刻 API client 的 token 可能还没注入 → 必然 401。原先只能等 30s 后的
  /// 下一次心跳补注册，期间本端在服务端是个「离线端」（别的端看不到这台机器、
  /// 本机也不出现在播放器列表里）。故这里短延迟重试一次，把空窗从 30s 压到 ~1s。
  Future<void> _registerSelf({int attempt = 0}) async {
    final client = _ref.read(subsonicApiClientProvider);
    try {
      final resp = await client.postRaw(
        '/rest/api/v1/peers/register',
        data: <String, dynamic>{
          'name': '',
          // 设备名片:服务端据此把本实例分进侧边栏「播放器」页的「客户端」模块、
          // 并在切换器里显示机型名/电脑名(而不是笼统的「本机」或账号名)。
          ..._deviceCard(),
        },
      );
      if (resp is Map<String, dynamic> && resp['peer'] is Map<String, dynamic>) {
        final peer = resp['peer'] as Map<String, dynamic>;
        final pid = peer['peerId'];
        if (pid is String && pid.isNotEmpty) {
          _localPeerId = pid;
          // 同一个 peerId 也是 WS 广播里 peer_id 的形式(maskLocalPeerId 的输出),
          // 本端据此识别「这条队列变更广播是发给我的」,见 peer_remote_control_provider。
          _ref.read(peerRemoteControlProvider.notifier).noteSelfPeerId(pid);
        }
      }
    } catch (e) {
      // 冷启动的 token 竞态：就近重试一次，仍失败就交给 30s 心跳周期补注册。
      if (attempt < 1) {
        await Future<void>.delayed(const Duration(milliseconds: 900));
        if (mounted) return _registerSelf(attempt: attempt + 1);
        return;
      }
      // 注册失败不阻塞登录;下个心跳周期自动补注册(见 startHeartbeat)。
      Logger.debugWithTag('CAST-PEER', 'register self peer failed: $e');
    }
  }

  /// 本端设备名片:platform(平台)+ model(电脑名)。
  /// 桌面端取 `Platform.localHostname`(Windows 计算机名);移动端机型名需要额外
  /// 插件,暂只报 platform,名字由服务端退回上报名。
  Map<String, String> _deviceCard() {
    try {
      final platform = Platform.isWindows
          ? 'windows'
          : Platform.isAndroid
              ? 'android'
              : Platform.isIOS
                  ? 'ios'
                  : Platform.isMacOS
                      ? 'macos'
                      : Platform.isLinux
                          ? 'linux'
                          : '';
      final isMobile = Platform.isAndroid || Platform.isIOS;
      final host = isMobile ? '' : Platform.localHostname;
      return <String, String>{
        if (platform.isNotEmpty) 'platform': platform,
        if (host.isNotEmpty) 'model': host,
      };
    } catch (e) {
      Logger.debugWithTag('CAST-PEER', 'device card unavailable: $e');
      return const <String, String>{};
    }
  }

  /// 开始心跳保活(对齐前端 30s 间隔)。
  /// 心跳同时承担**自动注册**:服务端重启 / 网络恢复 / 首轮注册失败后,
  /// 只要还没拿到本端 peerId,就在心跳周期内补注册一次,直到成功。
  void startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_localPeerId == null || _localPeerId!.isEmpty) {
        unawaited(_registerSelf());
        return;
      }
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
    // 登出 / dispose:状态上报与心跳同生命周期(都是「本端还在线」的证据)。
    _stopLocalStatusReporting();
  }

  // ==================== 本机播放状态上报(供别的播放端遥控时镜像)====================
  //
  // 本机播放的传输状态(是否在播 / 播到第几秒 / 音量)权威在本地 just_audio,服务端
  // 只存队列元数据,光靠队列快照答不出传输状态。当**别的**播放端(网页 / HA / 另
  // 一台客户端)切成遥控本端时,它靠轮询 `GET /peers/:id/status` 镜像进度条与播放
  // 按钮 —— 没有这份上报,对端只能读到队列快照,进度条恒为 0、按钮恒显示「未播放」,
  // 遥控就变成了盲操。
  //
  // 上报节奏:播放/暂停/切歌**事件**立即上报(对端下个 2s 轮询周期就能看到变化),
  // 播放中再按 4s 周期补报刷新进度;服务端侧 TTL 30s(见 PeerManager.getLocalStatusReport)。
  // 投屏中(本端只是遥控器、本地不出声)如实上报 STOPPED。
  Timer? _statusTimer;
  bool _statusWatcherOn = false;

  /// 启动状态上报:事件监听 + 周期补报。停止由 [stopHeartbeat] 统一收尾。
  void _startLocalStatusReporting() {
    if (_statusWatcherOn) return;
    _statusWatcherOn = true;
    // 只关心「播/停切换」与「切歌」;position 变化由周期补报覆盖,
    // 避免每次进度 tick 都发一次请求(position polling 频率很高)。
    _ref.listen<PlayerState>(playerProvider, (prev, next) {
      if (prev?.isPlaying == next.isPlaying &&
          prev?.currentSong?.id == next.currentSong?.id) {
        return;
      }
      unawaited(_pushLocalStatus());
    });
    _statusTimer ??= Timer.periodic(const Duration(seconds: 4), (_) {
      unawaited(_pushLocalStatus());
    });
    unawaited(_pushLocalStatus());
  }

  void _stopLocalStatusReporting() {
    _statusTimer?.cancel();
    _statusTimer = null;
  }

  /// 上报一次本机播放状态。失败静默(下个周期再试)。
  Future<void> _pushLocalStatus() async {
    final pid = _localPeerId;
    if (pid == null || pid.isEmpty) return;
    final s = _ref.read(playerProvider);
    // 投屏中本端不出声(只是遥控器)→ 如实报 STOPPED,不冒充在播。
    final casting = state.activePeer != null;
    final songId = casting ? null : s.currentSong?.id;
    final String playState = (songId == null || songId.isEmpty)
        ? 'STOPPED'
        : (s.isPlaying ? 'PLAYING' : 'PAUSED_PLAYBACK');
    final client = _ref.read(subsonicApiClientProvider);
    try {
      await client.postRaw(
        '/rest/api/v1/peers/${Uri.encodeComponent(pid)}/local-status',
        data: <String, dynamic>{
          'state': playState,
          'position': casting ? 0.0 : s.position.inMilliseconds / 1000.0,
          'duration': s.duration.inMilliseconds / 1000.0,
          'volume': (s.volume * 100).clamp(0, 100),
          if (songId != null && songId.isNotEmpty) 'songId': songId,
        },
      );
    } catch (e) {
      Logger.debugWithTag('CAST-PEER', 'local status report failed: $e');
    }
  }

  // ==================== 本机队列上报(服务端隔离账本) ====================
  //
  // 本机播放(just_audio)的队列权威在客户端;这里把它镜像到服务端账号名下
  // **本播放端**那一行(对外 peerId 恒为 local:<userId>,服务端按请求头里的临时端
  // ID 落到本安装)。三个收益:
  //   1. 服务端预探测能替本机链路向前扫描坏源(与投屏链路共用同一颗大脑);
  //   2. 同账号多个播放端(多个标签页 / 网页 + 桌面客户端)互不覆盖 —— 历史实现
  //      里它们共用 local:<userId> 一个坑位,谁后连谁把队列顶掉;
  //   3. 队列不会被误清:服务端改成「6 小时未变动 且 该端离线 6 小时」才回收。
  //
  // 投屏中不上报 —— 此时本机只是遥控器,界面镜像的队列归设备,写成本机队列是错的。
  Timer? _localQueueTimer;
  bool _localQueueWatcherOn = false;

  /// 最近一次已上报的队列长度:用于「空队列不主动擦掉服务端」的判定
  /// (App 启动/切歌空窗期本机队列可能瞬时为空,不应把服务端队列清掉)。
  int _lastPushedLocalCount = 0;
  String? _lastPushedLocalMode;

  /// 订阅本机播放状态:队列 / 游标 / 播放模式变化 → 防抖上报。
  void _watchLocalQueue() {
    if (_localQueueWatcherOn) return;
    _localQueueWatcherOn = true;
    _ref.listen<PlayerState>(playerProvider, (prev, next) {
      if (state.activePeer != null) return; // 投屏中:队列归设备,不写本机
      final queue = next.queue;
      final index = next.currentIndex;
      final mode = mapLocalPlayMode(next.playbackMode);
      final queueChanged = !identical(prev?.queue, queue);
      final indexChanged = prev?.currentIndex != index;
      final modeChanged = prev == null || mapLocalPlayMode(prev.playbackMode) != mode;
      if (!queueChanged && !indexChanged && !modeChanged) return;
      // 空队列且此前从未上报过内容 → 跳过(避免启动空窗擦队列)。
      if (queue.isEmpty && _lastPushedLocalCount == 0) return;
      _localQueueTimer?.cancel();
      _localQueueTimer = Timer(const Duration(milliseconds: 600), () {
        unawaited(_syncLocalQueue(queue, index, mode, full: queueChanged));
      });
    });
  }

  /// 会话恢复后立刻把本机队列镜像到服务端 —— 即「告诉服务端这是本次需要
  /// 恢复的播放队列」。
  ///
  /// 日常队列/游标变化由 _watchLocalQueue 防抖上报,但**启动恢复这一下必须
  /// 单独补**:恢复路径直接调 playSong,不经过常规播放入口,且此时服务端
  /// 可能还留着上一次进程的旧队列。若本地落盘异常(曾出现会话文件停更,
  /// 每次都恢复成同一首旧歌),还能顺手把陈旧队列推给服务端,两端一起陈旧
  /// 但至少一致,不会再出现「界面一首、服务端另一首」。
  Future<void> syncLocalQueueNow() async {
    if (state.activePeer != null) return; // 投屏中:队列归设备,不写本机
    // 未注册时**不**顺带触发注册:_registerSelf 会拉起心跳 Timer,而本方法
    // 跑在会话恢复路径上(启动时),在 widget/单测环境里那颗 Timer 来不及被
    // 取消,会撞上 flutter_test 的「Timer 不变量」断言。注册由既有流程负责,
    // 注册成功后的下一次队列变化自然会补齐镜像(见 _watchLocalQueue)。
    final pid = _localPeerId;
    if (pid == null || pid.isEmpty) return;
    final s = _ref.read(playerProvider);
    if (s.queue.isEmpty) return;
    await _syncLocalQueue(
      s.queue,
      s.currentIndex,
      mapLocalPlayMode(s.playbackMode),
      full: true,
    );
  }

  /// 拉取服务端的本机队列快照(启动恢复「新鲜度竞速」用,见
  /// _restorePlaybackSession)。
  ///
  /// 返回原始快照(items/currentIndex/playMode/updatedAt),失败或空队列
  /// 返回 null,绝不抛出 —— 恢复流程不能被它卡死。未注册时短暂等待注册
  /// 完成(本方法跑在启动恢复路径上,注册通常同时在跑);测试环境直接
  /// 短路(避免 delay/timeout 的 Timer 撞 flutter_test 不变量)。
  Future<Map<String, dynamic>?> fetchLocalQueueForRestore() async {
    if (state.activePeer != null) return null; // 投屏中:队列归设备
    if (Platform.environment['FLUTTER_TEST'] != null) return null;
    final deadline = DateTime.now().add(const Duration(seconds: 4));
    var pid = _localPeerId;
    while ((pid == null || pid.isEmpty) && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      pid = _localPeerId;
    }
    if (pid == null || pid.isEmpty) return null;
    // 恢复窗口预算必须短:快照拉不到就回退本地会话,不能拖住启动。
    const budget = Duration(seconds: 5);
    try {
      final client = _ref.read(subsonicApiClientProvider);
      final data = await client
          .getRaw(
            '/rest/api/v1/peers/${Uri.encodeComponent(pid)}/queue',
            receiveTimeout: budget,
          )
          .timeout(budget) as Map<String, dynamic>;
      final items = data['items'];
      if (items is! List || items.isEmpty) return null;
      return data;
    } catch (e) {
      Logger.debugWithTag('CAST-PEER', 'restore snapshot fetch failed: $e');
      return null;
    }
  }

  /// 把本机队列/游标/模式镜像到服务端。失败静默(下个变化点再试)。
  Future<void> _syncLocalQueue(
    List<Song> queue,
    int index,
    String mode, {
    required bool full,
  }) async {
    // 还没注册成功(服务端重启 / 断线) → 先补注册拿到本端 peerId。
    if (_localPeerId == null || _localPeerId!.isEmpty) {
      await _registerSelf();
    }
    final pid = _localPeerId;
    if (pid == null || pid.isEmpty) return;
    final client = _ref.read(subsonicApiClientProvider);
    final items = queue.map(songToQueueItem).toList();
    try {
      if (full) {
        // 整队替换:超时预算随队列规模缩放(与投屏同一公式)。
        final budget = queueTransferBudget(items.length);
        await client
            .postRaw(
              '/rest/api/v1/peers/${Uri.encodeComponent(pid)}/queue/play',
              data: <String, dynamic>{
                'items': items,
                'startIndex': index < 0 ? 0 : index,
              },
              receiveTimeout: budget,
            )
            .timeout(budget);
        // queue/play 会把服务端模式重置为 order,必须随后补发当前模式
        // (与投屏 _pushQueueAndPlay 同款收尾)。
        await client.postRaw(
          '/rest/api/v1/peers/${Uri.encodeComponent(pid)}/play-mode',
          data: <String, dynamic>{'mode': mode},
        );
      } else {
        if (_lastPushedLocalMode != mode) {
          await client.postRaw(
            '/rest/api/v1/peers/${Uri.encodeComponent(pid)}/play-mode',
            data: <String, dynamic>{'mode': mode},
          );
        }
        await client.postRaw(
          '/rest/api/v1/peers/${Uri.encodeComponent(pid)}/queue/index',
          data: <String, dynamic>{'index': index},
        );
      }
      _lastPushedLocalCount = items.length;
      _lastPushedLocalMode = mode;
    } catch (e) {
      Logger.debugWithTag('CAST-PEER', 'local queue sync failed: $e');
    }
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

  // ==================== 流转播放 ====================

  /// 流转播放 = **纯 UI 控制目标切换**(对齐主项目前端 switchPeer):
  /// 只改控制目标,不推本地队列、不自动投屏;
  /// 选中远端 peer 时开始状态轮询,由轮询拉取其队列让 UI 镜像设备当前播放。
  /// 之后在客户端点歌/专辑/歌单会走 [playQueueOnPeer]/[playSongOnPeer]
  /// 命令**后端**在该设备播放,客户端此时仅是后端的远程遥控器。
  ///
  /// 离开本机时:保存本地状态快照并暂停本机(SPEC §3.1 本机播放与投屏互斥,
  /// 避免双实例抢音频设备);回本机时经 [backToLocal] 恢复快照。
  Future<bool> switchTo(PeerInfo peer) async {
    // 只有「本端自己那条」才算回本机。其它本机播放端(另一台客户端)与 DLNA 设备
    // 一样是**独立播放端**,走同一条遥控路径 —— 此前这里拿 kind=='local' 一刀切,
    // 会把非自身的本机播放端误判回本机、控制不到对方(Web 端现已由服务端从客户端视角过滤掉)。
    if (peer.isLocal && peer.self) {
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
  /// 供「流转播放」弹窗第二行展示与「接回本机」按钮可用性判断。
  /// 请求失败（设备掉线/网络抖）返回 null，调用方按「未知」处理。
  ///
  /// **分页拉当前项（2026-09-17）**：原先一次拉整队 `queue`（3000+ 首 ≈ **1MB**），
  /// 而 `peerNowPlayingProvider` 每 5s 对每台远端都轮询一次 —— 手机端这种高频
  /// 大 payload 极易超时/掉包，`fetchPeerNowPlaying` 抛异常返回 null，流转页/弹窗
  /// 就对端恒「未在播放」，而本机走本地 provider 反而正常（2026-09-17 实证：
  /// 全量 1,043,789B/634ms vs 分页 size=1 15,601B/55ms）。现改为先拉 meta 页拿
  /// `currentIndex`，再精确拉那一项（size=1）—— 30KB 内解决，极端缩小 ~35×。
  Future<PeerNowPlaying?> fetchPeerNowPlaying(String peerId) async {
    final client = _ref.read(subsonicApiClientProvider);
    Future<Map<String, dynamic>> fetchPage(int offset, int size) async {
      final raw = await client
          .getRaw(
            '/rest/api/v1/peers/${Uri.encodeComponent(peerId)}/queue',
            queryParameters: <String, dynamic>{'offset': offset, 'size': size},
            receiveTimeout: kQueueFetchBudget,
          )
          .timeout(kQueueFetchBudget);
      return raw as Map<String, dynamic>;
    }

    try {
      // 先拉元数据页(极小):服务端的 `isActive / currentIndex / total / currentMedia`
      // 恒在响应体里,不受分页影响。
      final meta = await fetchPage(0, 1);
      final isActive = meta['isActive'] == true;
      final currentIndex = (meta['currentIndex'] as num?)?.toInt() ?? -1;
      final total = (meta['total'] as num?)?.toInt() ?? 0;

      // 当前项:需求只展示「在播的那一首」,绝不再整队拉 1MB。
      Map<String, dynamic>? current;
      if (isActive && currentIndex >= 0 && currentIndex < total) {
        if (currentIndex == 0) {
          final items0 = meta['items'];
          if (items0 is List && items0.isNotEmpty) {
            current = items0.first as Map<String, dynamic>?;
          }
        } else {
          final page = await fetchPage(currentIndex, 1);
          final its = page['items'];
          if (its is List && its.isNotEmpty) {
            current = its.first as Map<String, dynamic>?;
          }
        }
      }

      // 曲目第一来源:设备侧实时值(`currentMedia`)。`local`(安卓 / Windows 客户端)
      // 恒为 undefined —— 这是「流转播放」里别的客户端行恒不显示的历史根因
      // (2026-09-15 反馈)；因此标题/封面独立回落到队列当前项,以 `currentMedia`
      // 优先、缺失再回落;唯一门控是「在播」,没在播不凑标题。
      final media = meta['currentMedia'];
      var title = media is Map ? '${media['title'] ?? ''}' : '';
      var artist = media is Map ? (media['artist'] as String?) : null;
      var coverArt = media is Map ? (media['coverArt'] as String?) : null;
      if (current != null) {
        if (title.isEmpty) title = '${current['title'] ?? ''}';
        artist ??= current['artist'] as String?;
        if (coverArt == null || coverArt.isEmpty) {
          coverArt = current['coverArt'] as String?;
        }
      }
      return PeerNowPlaying(
        isActive: isActive,
        currentIndex: currentIndex,
        total: total,
        title: title,
        artist: artist,
        coverArt: coverArt,
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
  /// 队列流转:把 [from] 的队列整体交给 [to] 播放 —— 快捷区拖拽的落地动作。
  ///
  /// 设计目标:**音乐可以随时在不同播放端之间流转**(任意两端,不限于本机)。
  /// 三条路由,前两条复用既有能力,只有「远端 → 远端」走新端点:
  ///   1. 本机 → 远端:[pushLocalToPeer](主通道 /v1/play,本机队列来源可解析);
  ///   2. 远端 → 本机:[pullPeerToLocal](搬回本机 just_audio 播);
  ///   3. 远端 → 远端:`POST /peers/:to/queue/transfer-from { from }` ——
  ///      服务端内部从源端取队列再写给目标端,**不收 items**(队列实体本就在服务端),
  ///      所以几千首的队列也是一次请求,不存在大队列 body 的体积闸门问题。
  ///
  /// 语义为**搬移**:源端在成功后停止(与 pullPeerToLocal 的「搬完原边停止」一致)。
  /// 本机做源端的收尾(流转推送/销毁共用)：**内存会话一并抛弃**。
  /// clearQueue(keepCurrent: false) 会停掉音频会话并清空内存队列；
  /// 服务端权威队列由 [_clearSourceQueue] 负责。两者配套 = 「本机的播放
  /// 上下文彻底清掉」，与远端源端的 stop+clear 同一口径。
  Future<void> _abandonLocalSession() async {
    try {
      await _ref.read(playerProvider.notifier).clearQueue(keepCurrent: false);
    } catch (e) {
      Logger.debugWithTag('CAST-PEER', 'abandonLocalSession failed: $e');
    }
  }

  /// 搬移语义收尾：清空源端的服务端权威队列（流转 = 搬走，不是复制）。
  ///
  /// best-effort：清空失败不影响流转结果（队列已搬到目标端并起播）。
  /// 本机做**源端**时配合 [_abandonLocalSession] 把内存会话也一并抛弃。
  Future<void> _clearSourceQueue(String peerId) async {
    if (peerId.isEmpty) return;
    final client = _ref.read(subsonicApiClientProvider);
    try {
      await client
          .deleteRaw(
            '/rest/api/v1/peers/${Uri.encodeComponent(peerId)}/queue',
          )
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      Logger.debugWithTag('CAST-PEER', 'clearSourceQueue($peerId) failed: $e');
    }
  }

  /// 销毁播放端（流转页底部「回收站」的落点动作）：
  /// 停止该端播放 + 清空其队列（本机 = 内存会话一并抛弃）。
  ///
  /// 切回本机的条件收窄：**只有被销毁的正是当前遥控对象**时才回本机
  /// （backToLocal 不续播）；销毁别的播放器不影响当前遥控目标。
  /// 失败尽力而为：stop 失败记为失败返回，清空队列永远 best-effort。
  Future<bool> destroyPeer(PeerInfo peer) async {
    final client = _ref.read(subsonicApiClientProvider);
    final isSelfLocal = peer.isLocal && peer.self;
    var ok = true;
    if (isSelfLocal) {
      await _abandonLocalSession();
    } else {
      try {
        await client
            .postRaw('/rest/api/v1/peers/${Uri.encodeComponent(peer.peerId)}/stop')
            .timeout(const Duration(seconds: 8));
      } catch (e) {
        ok = false;
        Logger.debugWithTag('CAST-PEER', 'destroyPeer: stop ${peer.peerId} failed: $e');
      }
    }
    await _clearSourceQueue(peer.peerId);
    if (ok && state.activePeer?.peerId == peer.peerId) {
      await backToLocal(resumeLocal: false);
    }
    unawaited(pollOnce(fullQueue: true));
    return ok;
  }

  Future<bool> transferQueue(PeerInfo from, PeerInfo to) async {    if (from.peerId == to.peerId) return false;
    final fromIsSelf = from.isLocal && from.self;
    final toIsSelf = to.isLocal && to.self;
    if (fromIsSelf) return pushLocalToPeer(to);
    if (toIsSelf) return pullPeerToLocal(from);

    final client = _ref.read(subsonicApiClientProvider);
    final base = '/rest/api/v1/peers/${Uri.encodeComponent(to.peerId)}';
    try {
      final res = await client
          .postRaw(
            '$base/queue/transfer-from',
            data: <String, dynamic>{'from': from.peerId},
            receiveTimeout: kQueueFetchBudget,
          )
          .timeout(kQueueFetchBudget);
      if (!(res is Map && res['success'] == true)) return false;

      // 源端收尾(搬移语义 = 停播 + 清空队列,不是复制):失败均不影响
      // 流转本身 —— 队列已经搬完并在目标端起播。
      try {
        await client
            .postRaw('/rest/api/v1/peers/${Uri.encodeComponent(from.peerId)}/stop')
            .timeout(const Duration(seconds: 8));
      } catch (e) {
        Logger.debugWithTag('CAST-PEER', 'transferQueue: stop source failed: $e');
      }
      await _clearSourceQueue(from.peerId);
      // 若目标端正是当前被遥控的那台,立即刷新镜像(队列/游标/模式都换了)。
      unawaited(pollOnce(fullQueue: true));
      return true;
    } catch (e) {
      Logger.debugWithTag('CAST-PEER', 'transferQueue failed: $e');
      return false;
    }
  }

  Future<bool> pushLocalToPeer(PeerInfo peer) async {
    // 只排除「本端自己那条」(推给自己没有意义,与 switchTo 同一判据)。
    //
    // 这里原先是 `if (peer.isLocal) return false;` —— 一刀切把**另一台客户端**
    // 也挡在门外,于是「流转播放」里给别的客户端按推流箭头必然失败
    // (用户 2026-09-15 反馈:推到别的客户端不能用,接回本机反而正常)。
    // 该守卫来自「本机端还不可被遥控」的年代;现在服务端对 local 目标的
    // `/v1/play` 与 `/queue/play` 都已实现(写入目标实例的权威队列 → 目标客户端
    // 按 peer_queue_changed 跟随起播),与 DLNA 走的是**同一条链路**,故不应再特判。
    if (peer.isLocal && peer.self) return false;
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
      if (ok) {
        await _clearSourceQueue(_localPeerId ?? '');
        await _abandonLocalSession();
        return true;
      }
      Logger.debugWithTag(
        'CAST-PEER',
        'pushLocalToPeer: main channel failed for '
        '${origin?.kind.name}:$contentId, fallback to full-queue push',
      );
    }
    // 兜底：整队推送（来源服务端无从解析时必须走这条）。
    final pushed = await _pushQueueAndPlay(peer.peerId, items, start);
    if (pushed) {
      await _clearSourceQueue(_localPeerId ?? '');
      await _abandonLocalSession();
    }
    return pushed;
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
      // 本机接续成功才算搬完：清空源设备的服务端队列(搬移语义)。
      await _clearSourceQueue(peer.peerId);
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
    _transportCommandAtMs = DateTime.now().millisecondsSinceEpoch;
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
    _transportCommandAtMs = DateTime.now().millisecondsSinceEpoch;
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
    _seekIssuedAtMs = DateTime.now().millisecondsSinceEpoch;
    state = state.copyWith(smoothPositionSeconds: position.inSeconds.toDouble());
    unawaited(pollOnce());
  }

  Future<void> setVolume(int volume) async {
    if (state.activePeer == null) return;
    // 先打点再下发:上报是周期性的(~4s),连续拖动时回传的可能是上一拍的值。
    _volumeCommandAtMs = DateTime.now().millisecondsSinceEpoch;
    await _post('volume', data: <String, dynamic>{'volume': volume});
    final nextStatus = state.status.copyWith(volume: volume);
    state = state.copyWith(status: nextStatus);
  }

  /// 静音开关(投屏设备;群组/端到端由后端分发)。
  Future<void> setMuted(bool muted) async {
    if (state.activePeer == null) return;
    // 与 setVolume 同理:静音态同样来自远端周期上报。
    _volumeCommandAtMs = DateTime.now().millisecondsSinceEpoch;
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
    _seekIssuedAtMs = 0;
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

  /// 把远端**客户端实例**上报的 position 采样外推到「此刻」。
  ///
  /// 客户端实例的 position 是**周期性上报**的采样(实测约 4s 一次),不是实时值;
  /// 采样时刻由 `/status` 的 `reportedAt`(服务端时钟,ms)给出。
  ///
  /// 直接把采样值当「此刻」写进平滑进度,会把本地已在推进的时钟(250/500ms tick)
  /// 每轮询**拽回**旧值 —— 表现为进度条 / 歌词「前进一段又回退」(回退幅度 = 一个
  /// 上报周期,约 2~4s,不是固定 2s;本端 2s 轮询、远端 ~4s 上报,故每两轮一次)。
  /// 与 HA 卡片 v2.4.1 修的是同一个 bug(`_projectStatusPosition`)。
  ///
  /// 修法:`采样值 + (现在 − reportedAt)` 外推到此刻 —— 两次上报之间连续推进,
  /// 新上报只重新对齐锚点,不再回退。暂停时保持上报值(不外推,避免暂停态漂移)。
  ///
  /// 边界:**只有客户端实例的 status 带 reportedAt** —— DLNA / AirPlay / Sendspin /
  /// 群组的 status 走各自实时查询,没有该字段 → 原样返回,设备型链路行为完全不变。
  double _projectPolledPosition(PeerStatus s) {
    if (!s.playing) return s.positionSeconds;
    final at = s.reportedAtMs;
    if (at == null || at <= 0) return s.positionSeconds;
    final ageSec = (DateTime.now().millisecondsSinceEpoch - at) / 1000.0;
    // 上报过旧(>30s,见服务端 local-status TTL)或时钟异常
    // (本端时钟落后/超前服务端 → age 为负或过大)→ 原样,不做外推。
    if (ageSec <= 0 || ageSec > 30) return s.positionSeconds;
    final projected = s.positionSeconds + ageSec;
    return s.durationSeconds > 0
        ? projected.clamp(0.0, s.durationSeconds)
        : projected;
  }

  /// 把「本端刚下发的**音量类**命令」叠加到滞后上报上。
  ///
  /// 远端客户端的音量与 position 一样是**周期上报**的(实测 ~4s 一次)。连续拖动
  /// (20 → 50 → 30)时,上报回来的可能还是上一拍的 50,直接采纳会把手上的 30
  /// **顶掉**,表现为「拖到 30 又跳回 50」。
  ///
  /// 判据:采样时刻(`reportedAt`)早于命令下发时刻 → 该采样不含本次命令结果,
  /// volume / muted 一律沿用本地值;采样时刻追上命令后自动恢复采纳。
  /// 无 `reportedAt`(设备型 peer 走实时查询)→ 原样返回,设备链路行为不变。
  /// 该上报是不是「命令下发**之前**采的样」—— 即尚未包含本次命令结果。
  ///
  /// 判据:采样时刻(`reportedAt`)早于命令下发时刻,且仍在保护窗口内。
  /// 无 `reportedAt`(设备型 peer 走实时查询)→ 恒 false,设备链路不受影响。
  bool _isStaleSample(PeerStatus s, int commandAtMs) {
    final at = s.reportedAtMs;
    if (at == null || commandAtMs <= 0) return false;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - commandAtMs > kCommandShadowWindowMs) return false;
    return at < commandAtMs;
  }

  PeerStatus _applyVolumeShadow(PeerStatus s) {
    if (!_isStaleSample(s, _volumeCommandAtMs)) return s;
    final cur = state.status;
    return PeerStatus(
      state: s.state,
      positionSeconds: s.positionSeconds,
      durationSeconds: s.durationSeconds,
      volume: cur.volume,
      muted: cur.muted,
      active: s.active,
      reportedAtMs: s.reportedAtMs,
    );
  }

  /// 播放/暂停(传输类)命令的影子,与音量同因。
  ///
  /// 点暂停后,陈旧上报仍是 `state=PLAYING` 且 position 还在前进 —— 不仅会覆盖
  /// 本地乐观置位,还会触发 `_tick` 里的 `advancing` 自愈(「position 在前进 → 判在播」)
  /// 把 PAUSED **强制改回 PLAYING**,表现为「点了暂停没反应 / 自己又播起来」。
  /// 故在窗口内:沿用在地状态,并停用 advancing 自愈(见 `_tick`)。
  PeerStatus _applyTransportShadow(PeerStatus s) {
    if (!_isStaleSample(s, _transportCommandAtMs)) return s;
    final cur = state.status;
    return PeerStatus(
      state: cur.state,
      positionSeconds: s.positionSeconds,
      durationSeconds: s.durationSeconds,
      volume: s.volume,
      muted: s.muted,
      active: cur.active,
      reportedAtMs: s.reportedAtMs,
    );
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
      // 传输类命令(play/pause)刚下发时,陈旧上报的 position 仍在前进,若照常做
      // 「position 前进 → 判在播」自愈,会把刚点的**暂停**改回 PLAYING
      // (表现为「点了暂停没反应,自己又播起来」)→ 窗口内先停用该自愈。
      final transportStale = _isStaleSample(next, _transportCommandAtMs);
      final advancing = !transportStale &&
          next.durationSeconds > 0 &&
          next.positionSeconds > _lastPollPosition &&
          next.positionSeconds < next.durationSeconds;
      _lastPollPosition = next.positionSeconds;
      final healedStatus = (advancing && next.state != 'PLAYING')
          ? next.copyWith(state: 'PLAYING', active: true)
          : next;
      // 沿用本端刚置位的播放/暂停态,不被滞后上报顶掉。
      final effectiveStatus = _applyTransportShadow(healedStatus);

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
      // 本端刚 seek 过时,跳过「seek 之前采样」的上报:远端客户端此刻回的仍是
      // **旧位置**(要等它下一个上报周期才更新),采纳它会把刚拖好的进度条拽回
      // seek 之前,过两秒再跳回去。窗口 6s。
      // 无 reportedAt 的设备型 peer 不参与(它们走实时查询,seek 后立刻能读到新值)。
      final staleAfterSeek = _seekIssuedAtMs > 0 &&
          DateTime.now().millisecondsSinceEpoch - _seekIssuedAtMs <= 6000 &&
          effectiveStatus.reportedAtMs != null &&
          effectiveStatus.reportedAtMs! < _seekIssuedAtMs;
      // 音量/静音同样来自远端周期上报,连续拖动会被上一拍的值顶掉(详见
      // _applyVolumeShadow)。设备型 peer 无 reportedAt → 原样,不受影响。
      final mergedStatus = _applyVolumeShadow(effectiveStatus);
      state = state.copyWith(
        status: mergedStatus,
        // 客户端实例的 position 是周期上报的采样,必须按 reportedAt 外推到此刻;
        // 直接写采样值会让进度条/歌词每两轮回退一次(详见 _projectPolledPosition)。
        smoothPositionSeconds: staleAfterSeek
            ? state.smoothPositionSeconds
            : _projectPolledPosition(mergedStatus),
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

/// 单个 peer 的实时队列摘要(FutureProvider.family):「流转播放」弹窗
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
