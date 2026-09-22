import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/utils/logger.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/providers/cast/cast_peer_state.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

/// 拉全队的预算:与 cast_peer_provider 的 kQueueFetchBudget 同量级(3000+ 首的
/// items 是 MB 级 body,全局 30s 不够)。此处独立定义,避免与 cast_peer_provider
/// 形成循环 import(那边会反向引用本文件)。
const Duration _queueFetchBudget = Duration(seconds: 60);

/// 本端实例最近一次「被遥控」的记录(仅供 UI/日志观察,不参与仲裁)。
class PeerRemoteControlState {
  const PeerRemoteControlState({this.lastAction, this.lastAt});

  /// 最近一次应用的远端动作:play / pause / next / prev / seek / volume / queue。
  final String? lastAction;
  final DateTime? lastAt;
}

/// 本机实例的「被遥控」接收端 —— 服务端(Web / HA / 另一台客户端) → 本端。
///
/// 服务端遥控另一台本机播放端时,通过 WS **定向**投递(按 userId + clientId 精确
/// 匹配连接,见后端 `services/ws` 的 `sendToLocalPeer`),所以本端只需处理两类消息:
///
/// - `peer_command`      : 传输指令 play/pause/stop/next/prev/seek/volume → 立即执行。
///   这类动作**不写队列**,因此必须靠定向下发,不能靠队列广播。
/// - `peer_queue_changed` : 服务端**权威队列**变更(Web 端点了歌 / 清空 / 换模式)→ 跟随。
///   队列类操作由服务端直接写权威队列(服务端是本机队列的唯一真源),本端只负责
///   「发现不一致就跟上」。
///
/// ## 为什么用「内容比对」而不是时间戳/抑制窗口
///
/// 本端自己上报也会触发同一条广播(服务端向所有可见连接推)。用内容比对:
/// 自己造成的变更 → 服务端内容与本地逐项一致 → 什么都不做;只有真的不一致
/// (外部改的)才跟随。跟随本身会再次触发上报,但那时两端已一致,不会形成回环。
///
/// 注意:本仓库已有「本端作为遥控器去遥控别人」(cast_peer_provider 的
/// playQueueOnPeer 等);本类是其**反向** —— 本端作为**被遥控方**。
class PeerRemoteControlNotifier extends StateNotifier<PeerRemoteControlState> {
  PeerRemoteControlNotifier(this._ref) : super(const PeerRemoteControlState());

  final Ref _ref;
  static const _tag = 'PEER-REMOTE';

  /// 本端实例的对外 peerId(打码形式,注册成功时由 cast_peer_provider 注入)。
  /// 与服务端广播里 `peer_id` 同形 —— 用它筛出「发给本端实例」的队列广播。
  String? _selfPeerId;

  /// 「摘要态下按需拉全队」的在途标记:同一条广播会被投递两次(2026-09-15 实测
  /// 客户端日志成对出现),不做在途去重就会拉两趟 MB 级队列并起播两次。
  bool _adoptingQueue = false;

  /// 注册成功 / 拿到本端 peerId 时注入(见 CastPeerController._registerSelf)。
  void noteSelfPeerId(String peerId) {
    if (peerId.isEmpty || peerId == _selfPeerId) return;
    _selfPeerId = peerId;
    Logger.debugWithTag(_tag, 'bound to self peer: $peerId');
  }

  /// 服务端推送消息入口(由 WS 客户端转发,见 random_songs_push_provider)。
  Future<void> handleServerMessage(Map<String, dynamic> msg) async {
    switch (msg['type']) {
      case 'peer_command':
        await _handleCommand(msg);
      case 'peer_queue_changed':
        await _handleQueueChanged(msg);
      default:
        return;
    }
  }

  // ==================== 传输指令 ====================

  Future<void> _handleCommand(Map<String, dynamic> msg) async {
    final action = (msg['action'] as String?) ?? '';
    final raw = msg['payload'];
    final payload = raw is Map
        ? raw.cast<String, dynamic>()
        : const <String, dynamic>{};
    final player = _ref.read(playerProvider.notifier);
    try {
      switch (action) {
        case 'play':
          await player.play();
        case 'pause':
        case 'stop':
          await player.pause();
        case 'next':
          await player.next();
        case 'prev':
          await player.previous();
        case 'seek':
          final seconds = (payload['seconds'] as num?)?.toDouble();
          if (seconds == null) return;
          await player.seek(
            Duration(milliseconds: (seconds * 1000).round()),
          );
        case 'volume':
          final volume = (payload['volume'] as num?)?.toDouble();
          if (volume == null) return;
          // 服务端音量是 0-100,本机 just_audio 是 0..1。
          await player.setVolume((volume / 100).clamp(0.0, 1.0));
        default:
          Logger.debugWithTag(_tag, 'unknown remote command: $action');
          return;
      }
      if (mounted) {
        state = PeerRemoteControlState(
          lastAction: action,
          lastAt: DateTime.now(),
        );
      }
      Logger.infoWithTag(_tag, 'applied remote command: $action');
    } catch (e) {
      Logger.warnWithTag(_tag, 'apply remote command failed: $action', e);
    }
  }

  // ==================== 权威队列跟随 ====================

  Future<void> _handleQueueChanged(Map<String, dynamic> msg) async {
    // 广播是发给所有可见连接的,先确认这条是不是本端实例的(peer_id 用对外
    // 打码形式,与注册时拿到的 peerId 同形 —— register 返回的就是打码值)。
    final peerId = (msg['peer_id'] as String?) ?? '';
    final mine = _selfPeerId;
    if (peerId.isEmpty || mine == null || mine.isEmpty || peerId != mine) return;

    final raw = msg['queue'];
    if (raw is! Map) {
      Logger.debugWithTag(_tag, 'queue broadcast without queue map, ignore');
      return;
    }
    final queue = raw.cast<String, dynamic>();
    // 判定留痕:跟随一旦触发就会在本机 playQueue/playSong(出声!),必须能回答
    // "这次跟随是谁触发的". items/total/index/mode 四件套全打出来。
    final local = _ref.read(playerProvider);
    final total = (queue['total'] as num?)?.toInt();
    final index = (queue['currentIndex'] as num?)?.toInt();
    final mode = queue['playMode']?.toString();
    if (_sameAsLocal(local, queue)) {
      Logger.debugWithTag(
        _tag,
        'queue broadcast matches local, skip (self-echo) '
        'total=$total index=$index mode=$mode localLen=${local.queue.length} '
        'localIndex=${local.currentIndex}',
      );
      return; // 自己上报造成的
    }
    Logger.infoWithTag(
      _tag,
      'queue broadcast DIFFERS from local, follow '
      'total=$total index=$index mode=$mode localLen=${local.queue.length} '
      'localIndex=${local.currentIndex} localMode=${local.playbackMode}',
    );
    await _follow(queue);
  }

  /// 与服务端权威快照逐项比对:歌曲 id 序列 + 当前游标 + 播放模式。
  bool _sameAsLocal(PlayerState local, Map<String, dynamic> queue) {
    final items = queue['items'];
    if (items is! List) return true; // 拿不到内容 → 保守不动作
    if (items.isEmpty) {
      // 大队列摘要:服务端 summarizeQueue 把 items 清空了,只剩外层元数据,
      // 无法逐项比对 → 退化为「外层三件套是否已一致」。一致即认定这条广播就是
      // 本端上报触发的(无需动作);不一致才当作外部改动去套用。
      final total = (queue['total'] as num?)?.toInt() ?? -1;
      if (total != local.queue.length) return false;
      final idx = (queue['currentIndex'] as num?)?.toInt() ?? -1;
      if (idx != local.currentIndex) return false;
      final mode = queue['playMode']?.toString();
      return mode == null || mode == mapLocalPlayMode(local.playbackMode);
    }
    if (!_sameSongIds(items, local.queue)) return false;
    final index = (queue['currentIndex'] as num?)?.toInt() ?? -1;
    if (index != local.currentIndex) return false;
    final mode = queue['playMode']?.toString();
    if (mode != null && mode != mapLocalPlayMode(local.playbackMode)) return false;
    return true;
  }

  /// 只比 songId 序列(不比其他字段):判断服务端的 items 与本机镜像队列是不是
  /// 同一份歌单。是同一份时,任何差异都只可能是外层(模式 / 游标),不该整队重建。
  bool _sameSongIds(List<dynamic> items, List<Song> songs) {
    if (items.length != songs.length) return false;
    for (var i = 0; i < items.length; i++) {
      final it = items[i];
      if (it is! Map) return false;
      if ('${it['songId'] ?? ''}' != songs[i].id) return false;
    }
    return true;
  }

  Future<void> _follow(Map<String, dynamic> queue) async {
    final items = queue['items'];
    if (items is! List) return;
    final total = (queue['total'] as num?)?.toInt() ?? items.length;
    if (items.isEmpty && total > 0) {
      // 大队列:WS 摘要只带外层元数据(items 被服务端 summarizeQueue 清空)。
      // 外层字段一个都不能丢 —— 服务端 summarizeQueue 是 `{...q, items: []}`,
      // playMode / currentIndex 照常在。此前这里整条 return,连带把权威播放模式
      // 一起丢掉,于是「Web 端切了随机/顺序,客户端毫无反应」(用户 2026-09-15 实测)。
      Logger.debugWithTag(_tag, 'queue truncated (total=$total), apply outer fields only');
      final localLength = _ref.read(playerProvider).queue.length;
      await _applyOuterFields(queue, localLength: localLength);
      // 长度对不上 → 服务端换的是**另一份队列**(Web 端点了别的歌单/整列表)。
      // 摘要里没有 items,不主动拉全队的话客户端会一直播着旧队列,表现为
      // 「Web 让客户端播这个歌单,客户端没反应」。故按需拉一次全队再整队播放。
      if (total != localLength) await _adoptRemoteQueue(total);
      return;
    }
    final local = _ref.read(playerProvider);
    if (items.isNotEmpty && _sameSongIds(items, local.queue)) {
      // 同一份歌单:差异只可能在外层(播放模式 / 游标)。绝不能走下面的整队重建 ——
      // 那会把正在播的这首歌从头重启(「切一下随机就重头放」)。只套外层。
      Logger.debugWithTag(_tag, 'same song sequence (${items.length} items), apply outer fields only');
      await _applyOuterFields(queue, localLength: local.queue.length);
      return;
    }
    final songs = <Song>[];
    for (final it in items) {
      if (it is Map) songs.add(queueItemToSong(it.cast<String, dynamic>()));
    }
    final player = _ref.read(playerProvider.notifier);
    if (songs.isEmpty) {
      Logger.infoWithTag(_tag, 'remote cleared the queue');
      if (mounted) {
        state = PeerRemoteControlState(lastAction: 'queue', lastAt: DateTime.now());
      }
      // 远端清空 = 全清 + 停止(与 DLNA 清队列语义一致)。不能用默认的
      // keepCurrent:true —— 那是本地清空按钮的语义,会把当前歌留下并镜像回
      // 服务端,表现为「Web 清空后客户端还剩一首」(用户 2026-09-15 实测)。
      await player.clearQueue(keepCurrent: false);
      // 清空也带权威模式(清队后服务端会回落 order),照常套用。
      await _applyPlayMode(queue);
      return;
    }
    final index =
        ((queue['currentIndex'] as num?)?.toInt() ?? 0).clamp(0, songs.length - 1);
    // 可听变更留痕:这一步会在本机出声(autoPlay 默认 true)。跟随误触发时,
    // 靠这行 + _handleQueueChanged 的 DIFF 行反推"谁让手机响的"。
    Logger.infoWithTag(
      _tag,
      'following authoritative queue (${songs.length} items, index=$index) '
      '→ playQueue audible, first=${songs.first.id} target=${songs[index].id}',
    );
    await player.playQueue(songs, startIndex: index);
    await _applyPlayMode(queue);
    if (mounted) {
      state = PeerRemoteControlState(lastAction: 'queue', lastAt: DateTime.now());
    }
  }

  /// 摘要态(WS 只带外层字段)下把服务端权威队列**拉全**并整队接管。
  ///
  /// 触发条件:广播的 `total` 与本机镜像队列长度不一致 —— 说明服务端换的是另一份
  /// 队列(典型:Web 端在迷你播放器里点了某个歌单/整张专辑让本端播),此时光是套外层
  /// 字段不够,必须把 items 拿回来才能播。
  ///
  /// 只对**自己的**实例队列发一次:同一条广播会被投递两次,用 [_adoptingQueue]
  /// 做在途去重,避免两趟 MB 级拉取 + 两次起播。
  Future<void> _adoptRemoteQueue(int expectedTotal) async {
    final peerId = _selfPeerId;
    if (peerId == null || peerId.isEmpty) return;
    if (_adoptingQueue) return;
    _adoptingQueue = true;
    try {
      final client = _ref.read(subsonicApiClientProvider);
      final data = await client
          .getRaw(
            '/rest/api/v1/peers/${Uri.encodeComponent(peerId)}/queue',
            receiveTimeout: _queueFetchBudget,
          )
          .timeout(_queueFetchBudget);
      if (data is! Map) return;
      final snap = data.cast<String, dynamic>();
      final rawItems = snap['items'];
      if (rawItems is! List || rawItems.isEmpty) return;
      // 拉回来的这一路可能已经过期(又换队列了):以服务端快照自身为准。
      final songs = <Song>[];
      for (final it in rawItems) {
        if (it is Map) songs.add(queueItemToSong(it.cast<String, dynamic>()));
      }
      if (songs.isEmpty) return;
      final index =
          ((snap['currentIndex'] as num?)?.toInt() ?? 0).clamp(0, songs.length - 1);
      // 可听变更留痕(同 _follow):整队接管会在本机出声。
      Logger.infoWithTag(
        _tag,
        'adopting remote queue (${songs.length} items, index=$index, expected=$expectedTotal) '
        '→ playQueue audible, target=${songs[index].id}',
      );
      await _ref.read(playerProvider.notifier).playQueue(songs, startIndex: index);
      await _applyPlayMode(snap);
      if (mounted) {
        state = PeerRemoteControlState(lastAction: 'queue', lastAt: DateTime.now());
      }
    } catch (e) {
      Logger.debugWithTag(_tag, 'adopt remote queue failed: $e');
    } finally {
      _adoptingQueue = false;
    }
  }

  /// 只套用队列快照的**外层权威字段**(不碰 items):播放模式,以及「同一份队列内
  /// 的游标跳转」。
  ///
  /// 游标跳转仅在 `total == 本机镜像队列长度` 时套用 —— 长度一致说明两端是同一份
  /// 队列(本端曾把它镜像上去),此时能直接用本机镜像里的那首歌定位,无需拉全队;
  /// 长度不一致说明服务端换了整份队列(如 Web 点了别的歌单),那必须走分页拉取
  /// (留待后续),此处不猜。
  Future<void> _applyOuterFields(
    Map<String, dynamic> queue, {
    required int localLength,
  }) async {
    await _applyPlayMode(queue);
    final total = (queue['total'] as num?)?.toInt() ?? -1;
    final index = (queue['currentIndex'] as num?)?.toInt() ?? -1;
    final player = _ref.read(playerProvider);
    if (total != localLength || index < 0 || index >= player.queue.length) return;
    if (index == player.currentIndex) return;
    // 可听变更留痕:游标跟随会 playSong(autoPlay 默认 true)在本机出声。
    // 13:34:50 实锤就是这行在回声/过期快照下播了鼓楼。若只想静默对齐游标,
    // 不要调这里 —— 调 playSong 时显式 autoPlay:false。
    Logger.infoWithTag(
      _tag,
      'remote moved cursor to index=$index '
      '→ playSong audible, from=${player.currentSong?.id} to=${player.queue[index].id}',
    );
    // 必须把**整份队列**一起传回去:playSong 的签名是 `queue ?? [song]`,不传 queue
    // 会把这 3000+ 首的队列就地清成一首 —— 而且 `_watchLocalQueue` 会以 full:true 把
    // 这个「一首歌的队列」镜像回服务端,权威队列随之塌成 1 首,连带把别端也带崩。
    // (2026-09-15 真机实测到该坍缩:queueLen 3217 → 1。)
    await _ref.read(playerProvider.notifier).playSong(
          player.queue[index],
          queue: player.queue,
          index: index,
        );
    if (mounted) {
      state = PeerRemoteControlState(lastAction: 'queue', lastAt: DateTime.now());
    }
  }

  /// 套用服务端权威播放模式(order / all / one / shuffle)。
  /// 这是「Web 端点了模式按钮 → 被遥控的客户端跟着切」的落点。
  Future<void> _applyPlayMode(Map<String, dynamic> queue) async {
    final mode = _parsePlayMode(queue['playMode']?.toString());
    if (mode == null) return;
    if (_ref.read(playerProvider).playbackMode == mode) return;
    Logger.infoWithTag(_tag, 'apply authoritative play mode: ${queue['playMode']}');
    await _ref.read(playerProvider.notifier).setPlaybackMode(mode);
  }

  static PlaybackMode? _parsePlayMode(String? raw) => switch (raw) {
        'shuffle' => PlaybackMode.shuffle,
        'one' => PlaybackMode.one,
        'all' => PlaybackMode.all,
        'order' => PlaybackMode.order,
        _ => null,
      };
}

final peerRemoteControlProvider = StateNotifierProvider<
    PeerRemoteControlNotifier, PeerRemoteControlState>(
  (ref) => PeerRemoteControlNotifier(ref),
);
