part of 'cast_peer_provider.dart';

/// 「会话段」—— 自注册与心跳保活、控制目标切换（switchTo/backToLocal/stopCasting）、
/// 传输类命令（play/pause/next/prev/seek/音量/静音/播放模式）、轮询与平滑进度、
/// 播放端销毁。
///
/// 为什么从这里切开：这些都是「客户端作为后端远程遥控器」的运行态 ——
/// 保活信号、控制目标、本机快照，与队列内容无关；跨段出口只有两处：
/// 注册落地时要挂本机队列上报（[_watchLocalQueue]，属队列段）、
/// 接回本机时要停设备（[stopCasting]，本段内），均已在基类声明保证可见。
mixin CastPeerSession on CastPeerControllerBase {
  // ==================== 注册与保活 ====================

  /// 登录后注册本机 peer(名称留给后端默认 username)并启动 30s 心跳,
  /// 同时开始把本机队列镜像到服务端。对齐前端 registerLocalPeer;best-effort。
  ///
  /// 服务端按请求头 `x-mf-client-id`(本安装的临时端 ID,见 LocalStorage.getClientId)
  /// 把本端与同账号的其它播放端(网页标签页 / 其它客户端)分开记账,对外返回的
  /// peerId 恒为 `local:<userId>`。
  Future<void> registerAndHeartbeat() async {
    // 每次(重新)登录都清掉上一次的「鉴权被拒」抑制:新 token 值得再试一次。
    _authRejectedAt = null;
    await _registerSelf();
    startHeartbeat();
    _watchLocalQueue();
    _startLocalStatusReporting();
  }

  /// 开始心跳保活(对齐前端 30s 间隔)。
  /// 心跳同时承担**自动注册**:服务端重启 / 网络恢复 / 首轮注册失败后,
  /// 只要还没拿到本端 peerId,就在心跳周期内补注册一次,直到成功。
  void startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      // 已知鉴权被拒(真 401,冷却窗口内):补注册与心跳都会被同样拒掉,
      // 静默跳过,避免每 30s 往服务端刷一条「认证失败」。
      if (_authRejectedActive) return;
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
    final client = ref.read(subsonicApiClientProvider);
    try {
      await client.postRaw(
        '/rest/api/v1/peers/${Uri.encodeComponent(pid)}/heartbeat',
      );
    } catch (e) {
      // 心跳失败忽略,下个周期再试。
      Logger.debugWithTag('CAST-PEER', 'heartbeat failed: $e');
    }
  }

  @override
  void stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    // 登出 / dispose:状态上报与心跳同生命周期(都是「本端还在线」的证据)。
    _stopLocalStatusReporting();
  }

  /// 启动状态上报:事件监听 + 周期补报。停止由 [stopHeartbeat] 统一收尾。
  void _startLocalStatusReporting() {
    if (_statusWatcherOn) return;
    _statusWatcherOn = true;
    // 只关心「播/停切换」与「切歌」;position 变化由周期补报覆盖,
    // 避免每次进度 tick 都发一次请求(position polling 频率很高)。
    ref.listen<PlayerState>(playerProvider, (prev, next) {
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
    final s = ref.read(playerProvider);
    // 投屏中本端不出声(只是遥控器)→ 如实报 STOPPED,不冒充在播。
    final casting = state.activePeer != null;
    final songId = casting ? null : s.currentSong?.id;
    final String playState = (songId == null || songId.isEmpty)
        ? 'STOPPED'
        : (s.isPlaying ? 'PLAYING' : 'PAUSED_PLAYBACK');
    final client = ref.read(subsonicApiClientProvider);
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

  // ==================== 流转播放 ====================

  /// 流转播放 = **纯 UI 控制目标切换**(对齐主项目前端 switchPeer):
  /// 只改控制目标,不推本地队列、不自动投屏;
  /// 选中远端 peer 时开始状态轮询,由轮询拉取其队列让 UI 镜像设备当前播放。
  /// 之后在客户端点歌/专辑/歌单会走 [playQueueOnPeer]/[playSongOnPeer]
  /// 命令**后端**在该设备播放,客户端此时仅是后端的远程遥控器。
  ///
  /// 离开本机时:保存本地状态快照并暂停本机(SPEC §3.1 本机播放与投屏互斥,
  /// 避免双实例抢音频设备);回本机时经 [backToLocal] 恢复快照。
  @override
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
      await ref.read(playerProvider.notifier).pause();
    }
    state = state.copyWith(
      activePeer: peer,
      status: const PeerStatus(state: 'BUFFERING'),
      playMode: state.playMode,
      smoothPositionSeconds: 0,
      // 清掉上一目标的队列镜像:控制目标已切换,残留会让 Now 区在第一拍
      // 轮询落地前显示上一目标的歌(targetIdle 派生为 true → 显示「未在播放」)。
      castQueue: const <Map<String, dynamic>>[],
      castIndex: -1,
      offline: false,
    );
    // 通知被遥控方(WS 广播采纳仲裁用):本端进入遥控模式,期间本机队列镜像
    // 已停写,服务端那份本机队列必然陈旧,不带起播起点的广播一律不采纳。
    ref.read(peerRemoteControlProvider.notifier).noteSelfRemoteControlling(true);
    _startPolling(peer.peerId);
    // 不等周期 tick:_startPolling 首拍立即 _tick,且此时 castQueue 已被
    // 上面清空 → 首拍必然走 needFull 全量拉取,新目标的真实状态即刻上屏
    // (不要再显式 pollOnce,会重复拉状态破坏「status called(1)」契约)。
    return true;
  }

  /// 回本机:仅切换控制目标(远端继续播放,对齐前端 switchPeer 纯 UI 切换),
  /// 并恢复离开本机时保存的本地状态快照。
  /// 不主动 stop 设备、不清空远端队列。
  ///
  /// [resumeLocal] 为 true 且快照当时在播放时,恢复后自动续播本机
  /// (即用户主动选「本机播放」);false(如 stopCasting)则保持暂停。
  @override
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
    ref.read(peerRemoteControlProvider.notifier).noteSelfRemoteControlling(false);
  }

  /// 保存当前本机播放状态为快照(供回本机恢复)。
  void _saveLocalSnapshot() {
    final ps = ref.read(playerProvider);
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
    final notifier = ref.read(playerProvider.notifier);
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
  @override
  Future<void> stopCasting() async {
    final peerId = state.activePeer?.peerId;
    final client = ref.read(subsonicApiClientProvider);
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

  /// 销毁播放端（流转页底部「回收站」的落点动作）：
  /// **彻底重置**该端 —— 停止播放 + 清空队列 + 清服务端运行态
  /// （设备端媒体缓存 / 洗牌序列 / 定时暂停 / 预探测 / 本机状态上报）。
  /// 本机额外抛弃内存会话。peer 本身**保留**在列表里，playMode 也保留。
  ///
  /// 切回本机的条件收窄：**只有被销毁的正是当前遥控对象**时才回本机
  /// （backToLocal 不续播）；销毁别的播放器不影响当前遥控目标。
  /// 失败尽力而为：stop 失败记为失败返回，清空队列永远 best-effort。
  Future<bool> destroyPeer(PeerInfo peer) async {
    final isSelfLocal = peer.isLocal && peer.self;
    if (isSelfLocal) {
      // 本机:先停音频 + 清内存队列;服务端那份权威队列与状态上报交给 _resetPeer。
      await _abandonLocalSession();
    }
    // 彻底重置:停止 + 清队列 + 清服务端运行态(非本机的 stop 失败记为失败)。
    final ok = await _resetPeer(peer.peerId);
    if (ok && state.activePeer?.peerId == peer.peerId) {
      await backToLocal(resumeLocal: false);
    }
    unawaited(pollOnce(fullQueue: true));
    return ok;
  }

  // ==================== 传输控制 ====================

  Future<void> toggle() async {
    if (state.activePeer == null) {
      await ref.read(playerProvider.notifier).togglePlayPause();
      return;
    }
    final target = !state.status.playing;
    _transportCommandAtMs = DateTime.now().millisecondsSinceEpoch;
    // [D-016 失败外显(2026-10-07)] _post 返回 null = 命令未送达服务端 →
    // 清判定标记、不做乐观翻转（轮询以后端权威状态为准），warn 外显失败。
    final res = await _post(target ? 'play' : 'pause');
    if (res == null) {
      _transportCommandAtMs = 0;
      Logger.warnWithTag(
        'CAST-PEER',
        '[toggle] peer=${state.activePeer?.peerId} '
            'action=${target ? 'play' : 'pause'} send failed '
            '(post returned null), optimistic flip skipped',
      );
      return;
    }
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
      await ref.read(playerProvider.notifier).pause();
      return;
    }
    if (!state.status.playing) return;
    _transportCommandAtMs = DateTime.now().millisecondsSinceEpoch;
    // [D-016 失败外显(2026-10-07)] 同 toggle：null = 未送达，清标记不乐观翻转。
    final res = await _post('pause');
    if (res == null) {
      _transportCommandAtMs = 0;
      Logger.warnWithTag(
        'CAST-PEER',
        '[pause] peer=${state.activePeer?.peerId} send failed '
            '(post returned null), optimistic flip skipped',
      );
      return;
    }
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
    final client = ref.read(subsonicApiClientProvider);
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
    final client = ref.read(subsonicApiClientProvider);
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
      await ref.read(playerProvider.notifier).next();
      return;
    }
    // [D-016 失败外显(2026-10-07)] 下发失败（null）时 warn 外显并跳过本次补拉。
    final res = await _post('next');
    if (res == null) {
      Logger.warnWithTag(
        'CAST-PEER',
        '[next] peer=${state.activePeer?.peerId} send failed (post returned null)',
      );
      return;
    }
    unawaited(pollOnce(fullQueue: true));
  }

  Future<void> previous() async {
    if (state.activePeer == null) {
      await ref.read(playerProvider.notifier).previous();
      return;
    }
    // [D-016 失败外显(2026-10-07)] 同 next。
    final res = await _post('prev');
    if (res == null) {
      Logger.warnWithTag(
        'CAST-PEER',
        '[previous] peer=${state.activePeer?.peerId} send failed (post returned null)',
      );
      return;
    }
    unawaited(pollOnce(fullQueue: true));
  }

  Future<void> seek(Duration position) async {
    if (state.activePeer == null) {
      // 无活跃投屏 peer → 本机播放器自己 seek。
      Logger.debugWithTag(
        'CAST-PEER',
        '[seek] local player (no cast) -> ${position.inMilliseconds}ms',
      );
      await ref.read(playerProvider.notifier).seek(position);
      return;
    }
    // 有投屏 peer → 命令下发到服务端,由服务端转给目标设备/客户端。
    // 「拖了没反应」时先看这一行:有没有打出来(打到说明命令真的发出去了)、
    // peerId 是不是你以为的那台设备。
    final peerId = state.activePeer!.peerId;
    final t0 = DateTime.now().millisecondsSinceEpoch;
    Logger.debugWithTag(
      'CAST-PEER',
      '[seek] peer=$peerId target=${position.inSeconds}s '
          '(${position.inMilliseconds}ms, truncation drops ${position.inMilliseconds - position.inSeconds * 1000}ms)',
    );
    // 先打点再下发:_seekIssuedAtMs = seek **下发**时刻(对齐 HA 卡片,响应后才置
    // 会漏掉「下发与响应之间」的采样),供 sampleStale 判「采样早于 seek」。
    _seekIssuedAtMs = DateTime.now().millisecondsSinceEpoch;
    // [D-060 已修复] _post 对所有异常 catch 后返回 null（不抛），故用返回值区分成败：
    // null = 命令未送达服务端 → 视为 seek 失败：清因果屏障标记、不做乐观对齐
    // （旧位置上报依然有效，交周期轮询确认真实进度），并经日志通道上报失败。
    final res = await _post('seek', data: <String, dynamic>{'seconds': position.inSeconds});
    if (res == null) {
      _seekIssuedAtMs = 0;
      _seekAckAtMs = 0;
      _seekTargetSeconds = null;
      Logger.warnWithTag(
        'CAST-PEER',
        '[seek] peer=$peerId target=${position.inSeconds}s send failed '
            '(post returned null) ${DateTime.now().millisecondsSinceEpoch - t0}ms, '
            'guard cleared and optimistic alignment skipped',
      );
      return;
    }
    // 因果屏障:seek 响应返回 = 服务端锚点已落位,此后发起的轮询必含 seek 结果。
    _seekAckAtMs = DateTime.now().millisecondsSinceEpoch;
    _seekTargetSeconds = position.inSeconds.toDouble();
    // 立即用目标位置对齐平滑进度,减少插值滞后。
    state = state.copyWith(smoothPositionSeconds: position.inSeconds.toDouble());
    Logger.debugWithTag(
      'CAST-PEER',
      '[seek] peer=$peerId target=${position.inSeconds}s send returned '
          '${DateTime.now().millisecondsSinceEpoch - t0}ms, guard set and progress optimistically aligned',
    );
    // seek 后**不**立刻拉状态(对齐 HA 卡片):这次拉取在 ack 之后发起,fetchStale
    // 挡不住;而设备型 peer 此刻仍在重锚,立即查询可能读到瞬态 0,把刚拖好的
    // 进度条拽回开头 —— v5.0.23 真机仍偶发回退的元凶。交给周期轮询确认,
    // 确认前平滑进度按乐观值自然推进。
  }

  Future<void> setVolume(int volume) async {
    if (state.activePeer == null) return;
    // 先打点再下发:上报是周期性的(~4s),连续拖动时回传的可能是上一拍的值。
    _volumeCommandAtMs = DateTime.now().millisecondsSinceEpoch;
    // [D-016 失败外显(2026-10-07)] null = 未送达：清标记（不抑制旧值回传）、
    // 不做乐观回写，warn 外显。
    final res = await _post('volume', data: <String, dynamic>{'volume': volume});
    if (res == null) {
      _volumeCommandAtMs = 0;
      Logger.warnWithTag(
        'CAST-PEER',
        '[setVolume] peer=${state.activePeer?.peerId} volume=$volume '
            'send failed (post returned null), optimistic writeback skipped',
      );
      return;
    }
    final nextStatus = state.status.copyWith(volume: volume);
    state = state.copyWith(status: nextStatus);
  }

  /// 静音开关(投屏设备;群组/端到端由后端分发)。
  Future<void> setMuted(bool muted) async {
    if (state.activePeer == null) return;
    // 与 setVolume 同理:静音态同样来自远端周期上报。
    _volumeCommandAtMs = DateTime.now().millisecondsSinceEpoch;
    // [D-016 失败外显(2026-10-07)] 同 setVolume。
    final res = await _post('mute', data: <String, dynamic>{'muted': muted});
    if (res == null) {
      _volumeCommandAtMs = 0;
      Logger.warnWithTag(
        'CAST-PEER',
        '[setMuted] peer=${state.activePeer?.peerId} muted=$muted '
            'send failed (post returned null), optimistic writeback skipped',
      );
      return;
    }
    final nextStatus = state.status.copyWith(muted: muted);
    state = state.copyWith(status: nextStatus);
  }

  // ==================== 播放模式同步 ====================

  /// 下发投屏播放模式(order|one|all|shuffle)。
  Future<void> setPlayMode(String mode) async {
    if (state.activePeer == null) return;
    // [D-016 失败外显(2026-10-07)] null = 未送达：不乐观写回播放模式。
    final res = await _post('play-mode', data: <String, dynamic>{'mode': mode});
    if (res == null) {
      Logger.warnWithTag(
        'CAST-PEER',
        '[setPlayMode] peer=${state.activePeer?.peerId} mode=$mode '
            'send failed (post returned null), optimistic writeback skipped',
      );
      return;
    }
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
      if (!_mounted) return;
      // 控制目标已切换/回本机:停止该轮询链,避免孤儿定时器持续空转。
      if (state.activePeer?.peerId != peerId) return;
      _schedulePoll(peerId);
    });
  }

  /// 平滑进度插值:播放中按 tick 递增,轮询结果回写修正。
  void _advanceSmooth() {
    final st = state;
    final next = nextSmoothPosition(
      smoothPositionSeconds: st.smoothPositionSeconds,
      status: st.status,
      tickMs: _progressTickMs,
    );
    if (next == st.smoothPositionSeconds) return;
    state = st.copyWith(smoothPositionSeconds: next);
  }
}
