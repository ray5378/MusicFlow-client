part of 'cast_peer_provider.dart';

/// 「队列段」—— 本机队列镜像与上报、远端队列快照拉取/恢复、队列搬移
/// （本机 ⇄ 远端）、投屏入队/跳转/重排/清空。
///
/// 为什么从这里切开：这一段处理的是**队列内容**（items/游标/模式）与它在
/// 服务端权威侧的落盘/取回，与保活、控制目标切换正交；跨段出口是对远端
/// 下发整队（[playContentOnPeer]/[_pushQueueAndPlay]）与接回本机前停设备。
mixin CastPeerQueue on CastPeerControllerBase {
  /// 订阅本机播放状态:队列 / 游标 / 播放模式变化 → 防抖上报。
  @override
  void _watchLocalQueue() {
    if (_localQueueWatcherOn) return;
    _localQueueWatcherOn = true;
    ref.listen<PlayerState>(playerProvider, (prev, next) {
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
    final s = ref.read(playerProvider);
    if (s.queue.isEmpty) return;
    await _syncLocalQueue(
      s.queue,
      s.currentIndex,
      mapLocalPlayMode(s.playbackMode),
      full: true,
    );
  }

  /// 仅供测试的行为锁入口:纯转发 [_waitForLocalPeerId],**不改任何行为**。
  ///
  /// 为什么需要它:该等待路径在 `flutter test` 下无法从公开 API 驱动 ——
  /// 唯一调用方 [fetchLocalQueueForRestore] 在 `FLUTTER_TEST` 存在时直接短路,
  /// 而该变量由 flutter 工具注入、`Platform.environment` 只读;私有方法又不能
  /// 跨库访问(dynamic 调用抛 NoSuchMethodError)。为了让「注册落地即刻唤醒 /
  /// 1.5s 预算后放弃」这两条不变量有**运行时**回归保护(而不是只靠源码文本
  /// 守卫),这里开一个零逻辑转发入口给 test/ 使用。生产代码请勿调用。
  @visibleForTesting
  Future<String?> waitForLocalPeerIdForTest() => _waitForLocalPeerId();

  /// 把本机队列/游标/模式镜像到服务端。失败静默(下个变化点再试)。
  Future<void> _syncLocalQueue(
    List<Song> queue,
    int index,
    String mode, {
    required bool full,
  }) async {
    // 遥控远端期间不写本机队列(与 _watchLocalQueue / syncLocalQueueNow 同口径)。
    // 防抖定时器可能在 switchTo 落地后才触发,此处兜底拦截 —— 否则会把恢复中的
    // 中间态推给服务端,回环广播被本端误采纳后在本机强制起播(见
    // peer_remote_control_provider._handleQueueChanged,v5.1.8 启动竞态实测)。
    if (state.activePeer != null) return;
    // 还没注册成功(服务端重启 / 断线) → 先补注册拿到本端 peerId。
    if (_localPeerId == null || _localPeerId!.isEmpty) {
      await _registerSelf();
    }
    final pid = _localPeerId;
    if (pid == null || pid.isEmpty) return;
    final client = ref.read(subsonicApiClientProvider);
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

  Future<bool> transferQueue(PeerInfo from, PeerInfo to) async {    if (from.peerId == to.peerId) return false;
    final fromIsSelf = from.isLocal && from.self;
    final toIsSelf = to.isLocal && to.self;
    if (fromIsSelf) return pushLocalToPeer(to);
    if (toIsSelf) return pullPeerToLocal(from);

    final client = ref.read(subsonicApiClientProvider);
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

      // 源端收尾(搬移语义 = 搬走了,不是复制):**彻底重置** —— 停止 + 清队列 +
      // 清服务端运行态(设备端媒体缓存 / 定时暂停 / 预探测 / 本机状态上报)。
      // 原先只做 stop + DELETE /queue,运行态各留各的,源端虽空仍被报成「在播」。
      // 失败均不影响流转本身 —— 队列已经搬完并在目标端起播。
      await _resetPeer(from.peerId);
      // 若目标端正是当前被遥控的那台,立即刷新镜像(队列/游标/模式都换了)。
      unawaited(pollOnce(fullQueue: true));
      return true;
    } catch (e) {
      Logger.debugWithTag('CAST-PEER', 'transferQueue failed: $e');
      return false;
    }
  }

  /// 读某个播放端**此刻**的实时进度(秒)。读不到(离线 / 旧服务端无该读数)→ null。
  ///
  /// 服务端 `/status` 是唯一统一口径:dlna 走 SOAP 实时值、group / airplay / sendspin
  /// 由各自引擎给、local 取对端客户端的上报。流转必须在**停源端之前**取值(停完读数
  /// 就归零/掉线),所以独立成方法,而不是复用轮询里的镜像值(那是上次轮询的旧值)。
  Future<double?> _readPeerPositionSeconds(String peerId) async {
    if (peerId.isEmpty) return null;
    final client = ref.read(subsonicApiClientProvider);
    try {
      final res = await client
          .getRaw(
            '/rest/api/v1/peers/${Uri.encodeComponent(peerId)}/status',
            receiveTimeout: const Duration(seconds: 8),
          )
          .timeout(const Duration(seconds: 8));
      if (res is! Map) return null;
      final pos = (res['position'] as num?)?.toDouble();
      if (pos == null || !pos.isFinite || pos < 0) return null;
      return pos;
    } catch (e) {
      Logger.debugWithTag('CAST-PEER', 'readPeerPositionSeconds failed: $e');
      return null;
    }
  }

  /// 接回本机：把 [peer] 的播放队列搬回本机，并**落到源端此刻的进度**上，
  /// 设备停止（接续搬移语义：搬完原边停止）。
  ///
  /// 链路：GET queue(队列+游标) → 停设备 → 本机 playSong(同队同曲自动播)。
  Future<bool> pullPeerToLocal(PeerInfo peer) async {
    final client = ref.read(subsonicApiClientProvider);
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

    // 源端此刻的进度:必须在下面停设备**之前**读(停完就归零/掉线)。
    // 读不到 → null,退化为「从这首开头接续」(与改动前的行为一致,不会更差)。
    final srcPos = await _readPeerPositionSeconds(peer.peerId);

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

    // 本机从当前曲**同一进度**接续:initialPosition 走 playSong 既有的
    // pendingSeek 管线,音源就绪后自动落位(不用等加载再补一次 seek)。
    try {
      await ref.read(playerProvider.notifier).playSong(
            songs[index],
            queue: songs,
            index: index,
            autoPlay: true,
            initialPosition: srcPos == null
                ? null
                : Duration(milliseconds: (srcPos * 1000).round()),
          );
      // 本机接续成功才算搬完:彻底重置源端 —— 停止 + 清队列 + 清服务端运行态
      // (设备端媒体缓存 / 定时暂停 / 预探测 / 本机状态上报)。
      await _resetPeer(peer.peerId);
      return true;
    } catch (e) {
      Logger.debugWithTag('CAST-PEER', 'pullPeerToLocal: local resume failed: $e');
      return false;
    }
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
  @override
  Future<bool> playContentOnPeer({
    required String type,
    required String id,
    String? songId,
    int? startIndex,
    List<Map<String, dynamic>>? localItems,
    int? localStartIndex,
    /// 流转场景:目标端应落的**起始位置**(秒)。服务端起播后自行 seek,回执里
    /// 用 `position` 回报实际落点。0 / null = 从头播(既有行为)。
    double? positionSeconds,
  }) async {
    final peerId = state.activePeer?.peerId;
    if (peerId == null || type.isEmpty || id.isEmpty) return false;
    final client = ref.read(subsonicApiClientProvider);
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
              if (positionSeconds != null && positionSeconds > 0)
                'position': positionSeconds,
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
        ref.read(playerProvider.notifier).syncQueueForCast(items, start);
        _lastPollPosition = -1;
        // 乐观进度也要落在带过来的起点上:否则按钮已显示播放、进度条却从 0
        // 爬起来,直到下一次轮询才被拉回(观感就是「跳了一下」)。
        state = state.copyWith(
          castQueue: items,
          castIndex: start,
          smoothPositionSeconds: positionSeconds ?? 0,
          offline: false,
          status: state.status.copyWith(
            state: 'PLAYING',
            active: true,
            positionSeconds: positionSeconds ?? 0,
          ),
        );
      } else {
        _lastPollPosition = -1;
        state = state.copyWith(
          smoothPositionSeconds: positionSeconds ?? 0,
          offline: false,
          status: state.status.copyWith(
            state: 'PLAYING',
            active: true,
            positionSeconds: positionSeconds ?? 0,
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
  @override
  Future<bool> _pushQueueAndPlay(
    String peerId,
    List<Map<String, dynamic>> items,
    int startIndex, {
    /// 流转场景:目标端应落的起始位置(秒)。cast 目标由服务端起播后 seek;
    /// local 目标由服务端把起点塞进当次队列快照(startPosition),客户端自行落位。
    double? positionSeconds,
  }) async {
    final client = ref.read(subsonicApiClientProvider);
    _markUserCommand();
    // 超时随队列规模缩放(见 queueTransferBudget):800 首 ≈ 39s、5000 首 ≈ 165s。
    // 必须同时下发给 Dio——全局 receiveTimeout 30s 会先于外层 Future 触发。
    final budget = queueTransferBudget(items.length);
    final sw = Stopwatch()..start();
    try {
      final resp = await client
          .postRaw(
            '/rest/api/v1/peers/${Uri.encodeComponent(peerId)}/queue/play',
            data: <String, dynamic>{
              'items': items,
              'startIndex': startIndex,
              if (positionSeconds != null && positionSeconds > 0)
                'position': positionSeconds,
            },
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
      ref.read(playerProvider.notifier).syncQueueForCast(items, startIndex);
      _lastPollPosition = -1;
      state = state.copyWith(
        castQueue: items,
        castIndex: startIndex,
        smoothPositionSeconds: positionSeconds ?? 0,
        offline: false,
        status: state.status.copyWith(
          state: 'PLAYING',
          active: true,
          positionSeconds: positionSeconds ?? 0,
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
    // [D-016 失败外显(2026-10-07)] 加歌未送达时 warn 外显并跳过补拉。
    final res = await _post(
      'queue/enqueue',
      data: <String, dynamic>{'items': items},
      budget: queueTransferBudget(items.length),
    );
    if (res == null) {
      Logger.warnWithTag(
        'CAST-PEER',
        '[enqueueSongs] peer=${state.activePeer?.peerId} '
            'items=${items.length} send failed (post returned null)',
      );
      return;
    }
    unawaited(pollOnce(fullQueue: true));
  }

  /// 点歌:跳播到指定索引(即使随机模式也尊重 index,对齐后端 queue/jump)。
  Future<void> jumpTo(int index) async {
    final peerId = state.activePeer?.peerId;
    if (peerId == null) return;
    // [D-016 失败外显(2026-10-07)] 点歌未送达时 warn 外显并跳过补拉。
    final res = await _post('queue/jump', data: <String, dynamic>{'index': index});
    if (res == null) {
      Logger.warnWithTag(
        'CAST-PEER',
        '[jumpTo] peer=${state.activePeer?.peerId} index=$index '
            'send failed (post returned null)',
      );
      return;
    }
    unawaited(pollOnce(fullQueue: true));
  }

  /// 从投屏队列移除指定索引(播放保持连贯,对齐前端 castRemoveFromQueue)。
  Future<void> removeQueueItem(int index) async {
    final peerId = state.activePeer?.peerId;
    final client = ref.read(subsonicApiClientProvider);
    if (peerId == null) return;
    try {
      await client
          .deleteRaw(
            '/rest/api/v1/peers/${Uri.encodeComponent(peerId)}/queue/$index',
          )
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      // [D-016 失败外显(2026-10-07)] 删歌失败从 debug 升级为 warn。
      Logger.warnWithTag('CAST-PEER', 'removeQueueItem failed: $e');
    }
    unawaited(pollOnce(fullQueue: true));
  }

  /// 队列拖拽排序(from → to,对齐前端 castReorderQueue)。
  Future<void> reorderQueue(int from, int to) async {
    final peerId = state.activePeer?.peerId;
    if (peerId == null) return;
    // [D-016 失败外显(2026-10-07)] 重排未送达时 warn 外显并跳过补拉。
    final res = await _post('queue/reorder', data: <String, dynamic>{'from': from, 'to': to});
    if (res == null) {
      Logger.warnWithTag(
        'CAST-PEER',
        '[reorderQueue] peer=${state.activePeer?.peerId} from=$from to=$to '
            'send failed (post returned null)',
      );
      return;
    }
    unawaited(pollOnce(fullQueue: true));
  }

  /// 清空投屏队列并停止轮询、切回本机(对齐前端 castClearQueue)。
  Future<void> clearCastQueue() async {
    final peerId = state.activePeer?.peerId;
    final client = ref.read(subsonicApiClientProvider);
    if (peerId != null) {
      _markUserCommand();
      try {
        await client
            .deleteRaw('/rest/api/v1/peers/${Uri.encodeComponent(peerId)}/queue')
            .timeout(const Duration(seconds: 8));
      } catch (e) {
        // [D-016 失败外显(2026-10-07)] 清队失败从 debug 升级为 warn。
        Logger.warnWithTag('CAST-PEER', 'clearCastQueue failed: $e');
      }
    }
    await backToLocal();
  }
}
