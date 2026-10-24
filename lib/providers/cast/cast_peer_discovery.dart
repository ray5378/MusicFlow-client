part of 'cast_peer_provider.dart';

/// 「发现段」—— 播放端列表的获取/周期刷新、启动自动选中、远端实时播放状态取样。
///
/// 为什么从这里切开：这一段只依赖「服务端 peers 列表 + 各端 /status 实时读数」，
/// 与「本机 ⇄ 远端」的会话保活（注册/心跳/控制目标）和队列镜像/搬移互不重叠；
/// 唯一的跨段出口是自动选中时调用 [switchTo]（控制目标切换，属会话段）。
mixin CastPeerDiscovery on CastPeerControllerBase {
  // ==================== 播放器列表 ====================

  Future<List<PeerInfo>> loadPeers() async {
    final client = ref.read(subsonicApiClientProvider);
    state = state.copyWith(loadingPeers: true);
    try {
      final data = await client.getRaw('/rest/api/v1/peers') as Map<String, dynamic>;
      final list = (data['peers'] as List? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(PeerInfo.fromJson)
          .toList();
      // 成功路径才起周期刷新/做启动自动选中(失败路径的 [] 不算数)。
      _ensurePeersTimer();
      unawaited(_maybeAutoSelectPlayingTarget(list));
      return list;
    } catch (e) {
      Logger.debugWithTag('CAST-PEER', 'loadPeers failed: $e');
      return const <PeerInfo>[];
    } finally {
      if (_mounted) state = state.copyWith(loadingPeers: false);
    }
  }

  /// 播放端列表周期刷新(#2):块/切换器 watch 的是 remoteControlPeersProvider
  /// (一次性 Future),播放端上线/下线不会自动反映。这里每 10s 只递增
  /// peersRev,让该 provider rebuild 重新 loadPeers。Timer 生命周期归控制器,
  /// 仅在 dispose 取消(不进 _stopTimers —— 那是轮询周期的重置路径)。
  void _ensurePeersTimer() {
    _peersTimer ??= Timer.periodic(const Duration(seconds: 10), (_) {
      if (!_mounted) return;
      state = state.copyWith(peersRev: state.peersRev + 1);
    });
  }

  /// 启动自动选中(#5):首次成功拉到播放端列表时,若有「正在播放中」的目标,
  /// 自动把控制目标切过去。优先级(v5.1.7 用户定稿):
  ///   ① 本机正在播 → 保持本机(最高优先,不切);
  ///   ② 正在播放中的其它端 → 按类别序 本机类别 > 群组 > 独立播放器
  ///      (复用 peer_display_order.peerKindRank 唯一实现);
  ///   ③ 本机有队列但不在播 → 排在所有在播端**之后**(即不切,保持本机)。
  /// 「正在播放中」以各端实时 /status(state==PLAYING)为准 —— PeerInfo.queueActive
  /// 只是「队列激活」,暂停时也为 true,区分不了在播/暂停。
  /// 首次拿到非空列表即置位,之后不再自动切。
  Future<void> _maybeAutoSelectPlayingTarget(List<PeerInfo> peers) async {
    if (_autoTargetDone) return;
    // 「默认控制当前客户端」（设置项，默认关闭）：开启时**不做**启动自动切目标，
    // 保持控制本机；关闭时沿用历史行为（自动接管正在播放中的播放器）。
    // 读取失败按 false 处理 —— 设置读取异常不应改变用户的既有默认语义。
    if (await LocalStorage.getDefaultControlCurrentClient()) {
      _autoTargetDone = true; // 只影响启动这一次，之后不再评估
      Logger.debugWithTag(
        'CAST-PEER',
        'auto-select: default-control-current-client on, keep local',
      );
      return;
    }
    // await 之后控制器可能已被 dispose（页面销毁 / 测试 teardown 后异步
    // continuation 才恢复执行），必须提前退出 —— 否则下面访问 state 会抛
    // "Tried to use CastPeerController after `dispose` was called"。
    if (!_mounted) return;
    final visible = visiblePeers(peers);
    if (visible.isEmpty) return; // 服务端还没报上来任何端,等下一轮再评估
    _autoTargetDone = true;
    if (state.activePeer != null) return; // 用户已手动选过目标
    if (ref.read(playerProvider).isPlaying) return; // 本机在播 = 最高优先
    // 候选目标（有活跃队列、可用、非本机自身）按「类别序 → 名称」排序，
    // 见 [selectAutoSelectCandidates]。
    final candidates = selectAutoSelectCandidates(visible);
    if (candidates.isEmpty) return;
    unawaited(_autoSelectFirstPlaying(candidates));
  }

  /// 并行读候选端实时状态,取类别序第一个真正 PLAYING 的端切过去;
  /// 全都不在播(各端都只有暂停队列)则不动,保持本机。
  Future<void> _autoSelectFirstPlaying(List<PeerInfo> candidates) async {
    final playing = await Future.wait(
      candidates.map((p) => _readPeerRealtimePlaying(p.peerId)),
    );
    final idx = playing.indexWhere((v) => v);
    if (idx < 0) return;
    // 等本机会话恢复落定再切(v5.1.8):恢复中途切走,快照会拍到空队列,且队列
    // 镜像被抑制 → 服务端留陈旧队列,回环广播有误采纳风险。轮询最多等 10s
    // (恢复租约 20s,正常恢复远小于此),超时放弃,保守保持本机。
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (ref.read(playerProvider.notifier).isRestoringPlaybackSession) {
      if (!_mounted || state.activePeer != null) return;
      if (DateTime.now().isAfter(deadline)) {
        Logger.debugWithTag(
          'CAST-PEER',
          'auto-select: restore settle timeout, give up',
        );
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    if (!_mounted || state.activePeer != null) return;
    // 等待期间目标可能已停播,复验一次;不再在播则整轮放弃(保守)。
    if (!await _readPeerRealtimePlaying(candidates[idx].peerId)) return;
    await switchTo(candidates[idx]);
  }

  /// 读某播放端此刻是否正在播放(/status 的 state==PLAYING)。读不到 → false。
  Future<bool> _readPeerRealtimePlaying(String peerId) async {
    if (peerId.isEmpty) return false;
    final client = ref.read(subsonicApiClientProvider);
    try {
      final res = await client
          .getRaw(
            '/rest/api/v1/peers/${Uri.encodeComponent(peerId)}/status',
            receiveTimeout: const Duration(seconds: 4),
          )
          .timeout(const Duration(seconds: 4));
      if (res is! Map) return false;
      return (res['state'] ?? '').toString() == 'PLAYING';
    } catch (e) {
      Logger.debugWithTag('CAST-PEER', 'readPeerRealtimePlaying failed: $e');
      return false;
    }
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
    final client = ref.read(subsonicApiClientProvider);
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

  /// 拉取全部播放器群组(供流转页「点群组 → 加减成员」用)。
  /// 失败返回 null(调用方据此提示);成功返回原始 JSON 列表,
  /// 每项含 id / name / memberIds(成员为命名空间写法:sendspin:`clientId` /
  /// airplay:`deviceId`;DLNA 不入组,历史裸 id 只会出现在老数据里)。
  Future<List<dynamic>?> fetchGroups() async {
    final client = ref.read(subsonicApiClientProvider);
    try {
      final res = await client.getRaw('/rest/api/v1/groups');
      final groups = res is Map ? res['groups'] : null;
      return groups is List ? groups : null;
    } catch (e) {
      Logger.debugWithTag('CAST-PEER', 'fetchGroups failed: $e');
      return null;
    }
  }

  /// 把设备加入/移出群组。[memberKey] 必须用服务端成员命名空间写法:
  /// sendspin = `sendspin:<clientId>`;airplay = `airplay:<deviceId>`。
  /// DLNA 不入组(服务端 splitMemberId 拒收);历史裸 id 只用于移除老成员。
  /// 成功返回更新后的完整 memberIds;失败返回 null。
  Future<List<String>?> setGroupMembership(
    String groupId,
    String memberKey, {
    required bool join,
  }) async {
    final client = ref.read(subsonicApiClientProvider);
    final body = join
        ? <String, dynamic>{'add': <String>[memberKey]}
        : <String, dynamic>{'remove': <String>[memberKey]};
    try {
      final res = await client.postRaw(
        '/rest/api/v1/groups/${Uri.encodeComponent(groupId)}/members',
        data: body,
      );
      final group = res is Map ? res['group'] : null;
      final ids = group is Map ? group['memberIds'] : null;
      if (ids is List) return ids.map((e) => e.toString()).toList();
      return null;
    } catch (e) {
      Logger.debugWithTag('CAST-PEER', 'setGroupMembership failed: $e');
      return null;
    }
  }
}
