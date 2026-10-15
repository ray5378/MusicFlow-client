// ADR-2 阶段 2b（[l17]）：播放会话「落盘 / 恢复」从 `PlayerNotifier` 家族的
// `PlayerPlaybackSessionInternals` mixin 抽成**真正的协作者对象**。
//
// 与 mixin（part 体系、共享整个 PlayerNotifier 库私有命名空间）不同，本协作者：
//   * 独立 Dart 库，只通过窄接口 [PlaybackSessionPersisterHost] 触达宿主；
//   * 全部落盘/恢复状态（防抖 Timer、写租约、脏标记、在途写、会话代际、
//     恢复租约、测试钩子）收拢在本类，宿主只在生命周期点调用（dispose /
//     persistPlaybackStateNow / _finishSessionTeardown / state setter）；
//   * 可脱离 Riverpod / 播放器独立构造单测（见
//     test/providers/player/b51a_session_persister_test.dart）。
//
// ⚠️ 逻辑零改动：方法体从 mixin 逐字搬运，只改成员访问方式
// （state→host.state、_ref.read→host.xxx 转发、库私有成员→本类成员）。
// 行为契约（防抖 5s、写租约 15s、恢复租约 20s、脏标记补写、代际守卫）
// 全部保持原样，回归网是既有持久化测试族 + 新增协作者独立测试。
import 'dart:async';
import 'dart:math';

import 'package:musicflow_client/core/player/playback_payload.dart';
import 'package:musicflow_client/core/utils/logger.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/sources/local_storage.dart';
import 'package:musicflow_client/providers/player/player_queue_policy.dart';
import 'package:musicflow_client/providers/player/player_state.dart';
import 'package:musicflow_client/providers/player/queue_origin_provider.dart';

/// 会话落盘防抖间隔：由 2s 放宽到 5s（降频 2.5 倍，崩溃续播最多损失 ~5s
/// 进度，与主流播放器一致）。
const Duration _playbackSessionPersistInterval = Duration(seconds: 5);

/// 租约时长：一次落盘占用「正在写」标记的最长时间。超过即视为上次落盘已死
/// （await 永久挂起），强制放行下一次写入。
///
/// 为什么**不用** `Future.timeout()` 兜底：`.timeout()` 会创建一颗 Timer，而
/// flutter_test 的 fakeAsync 环境下它是 FakeTimer —— 写入走真实 IO、不会在
/// fakeAsync 时钟内完成，那颗 Timer 就永远 pending，撞上框架的不变量断言
/// 「A Timer is still pending even after the widget tree was disposed」。
/// 租约是纯时间戳比较，不创建任何 Timer，测试与生产行为一致。
const Duration _persistLease = Duration(seconds: 15);

/// 恢复租约时长:正常恢复(含一次源加载尝试)远小于此值;超时只可能是
/// 某个 await 挂死了。
const int _restoreLeaseMs = 20000;

const String _logTag = 'PLAYER';

/// 宿主窄接口：协作者触达播放器宿主的**最小面**。
///
/// 刻意不含 `Ref` 与任何 provider 直接依赖（castPeerController /
/// queueOriginProvider 经宿主转发），既断开库间耦合，也让本协作者可以
/// 用一个几十行的 fake host 独立构造单测。
abstract class PlaybackSessionPersisterHost {
  /// 播放状态快照（只读：落盘序列化与音量写盘的取值来源）。
  PlayerState get state;

  /// 宿主逐 run 存活标记（`Notifier` 迁移后用宿主自持的 `mounted` 等价物提供）：
  /// 拆卸后停止调度新的落盘。
  bool get mounted;

  /// 队列序列化编码器（内部带「队列未变化复用上次序列化」缓存，必须与
  /// 宿主共用同一实例）。
  PlaybackPayloadEncoder get payloadEncoder;

  /// 队列来源（落盘时写进 payload；恢复后写回）。
  QueueOrigin? get queueOrigin;
  set queueOrigin(QueueOrigin? origin);

  /// 服务端队列快照（恢复时与本地文件做新鲜度竞速；失败/测试环境返回 null）。
  Future<Map<String, dynamic>?> fetchLocalQueueForRestore();

  /// 恢复后把本地队列镜像给服务端。
  Future<void> syncLocalQueueNow();

  /// 恢复流程的起播出口（fire-and-forget，不 await 源加载）。
  Future<void> playSong(
    Song song, {
    List<Song>? queue,
    int? index,
    bool autoPlay = true,
    Duration? initialPosition,
  });

  /// 恢复服务端快照时同步播放模式（persist: false，不回写配置）。
  Future<void> setPlaybackMode(PlaybackMode mode, {bool persist = true});
}

/// 播放会话「落盘 / 恢复」协作者。
///
/// 对外入口（宿主调用）：
///   * [schedulePersist] —— 状态变化后的防抖落盘（state setter、teardown）；
///   * [persistPlaybackSession] —— 立即落盘（dispose / persistPlaybackStateNow）；
///   * [restorePlaybackSession] —— 启动恢复（_init 尾部）；
///   * [bumpSessionGeneration] —— 整份会话归零时自增代际（作废在途恢复）；
///   * [cancelPersistTimer] / [awaitInFlightPersist] —— 退出路径（dispose /
///     persistPlaybackStateNow）配套；
///   * [isRestoringPlaybackSession] —— 恢复租约（生产消费方：启动自动选中）。
class PlaybackSessionPersister {
  PlaybackSessionPersister(this.host);

  final PlaybackSessionPersisterHost host;

  /// 落盘防抖 Timer（5s，见 [_playbackSessionPersistInterval]）。
  Timer? _persistTimer;

  /// 落盘进行中标记 —— 用「租约起点时间戳」而非布尔量实现。
  ///
  /// 布尔量的致命缺陷：它靠 `persistPlaybackSession` 的 finally 复位，一旦
  /// 某个 await 永久挂起（Windows 上 tmp.rename 覆盖已存在文件时若被杀软/
  /// 索引服务占用会**阻塞等待**而非抛错），finally 永不执行 → 标记永久 true
  /// → **此后所有播放会话落盘被静默跳过**。
  /// 实测症状：playback_session_v1.json 停在某个时刻再不更新，而同目录其它
  /// key 正常写入，于是每次重启都恢复成同一首旧歌。
  /// 改用时间戳租约后，即使超时兜底也失效，过期即强制放行：宁可并发写一次，
  /// 也不能再也不写。
  int? _persistingSinceMs;

  /// 上一轮落盘**进行中**时又有新的落盘请求 → 标记为脏，等这轮写完自动补一次。
  ///
  /// 旧实现是直接 `return` 丢弃：丢掉的那次若是「清空/销毁后的空会话」，
  /// 磁盘上就留着清空前的旧会话 —— 重启后已销毁的歌原地复活。
  bool _persistDirty = false;

  /// 正在落地的那一轮写。退出（persistPlaybackStateNow）前要等它，
  /// 否则本次写会被当作「进行中」跳过，磁盘留旧会话。
  Future<void>? _persistInFlight;

  /// 会话代际：每次「整份会话归零」（清空队列 / 移除当前曲）自增。
  ///
  /// 用来让**进行中的恢复**作废：恢复是异步长流程（读盘 → 探服务端 →
  /// getAutoPlayOnLaunch → playSong），期间用户完全可能已经把本机销毁。
  /// 若不自增比对，恢复流程照旧 playSong，就把刚销毁的会话又挂回当前曲 ——
  /// 用户视角就是「销毁没生效，Mini 播放器一会儿又冒出歌名」。
  int _sessionGeneration = 0;

  /// 测试注入点：每轮落盘**真正写盘之前**的挂起点。单测用它把一轮写人为拉长，
  /// 稳定复现「写完前状态又变了 → 旧实现静默丢弃这次写入」的竞态。
  Future<void> Function()? debugBeforePersistWrite;

  /// 测试注入点：恢复流程「即将起播」之前的挂起点（见
  /// [restorePlaybackSession]）。单测用它把恢复卡在竞态窗口内，稳定复现
  /// 「恢复到一半，本机被销毁」。
  Future<void> Function()? debugBeforeRestoreResume;

  /// 测试观察点：代际守卫拦下恢复的次数（正常恢复恒为 0）。
  ///
  /// 为什么需要它：守卫放行之后那一步是 `playSong(...)`，它要碰离线缓存、音源
  /// 加载、网络——在单测里既不收敛也不稳。而「守卫有没有误杀正常恢复」这件事
  /// 只需要看这个计数，不必等 playSong 跑完（见 session_teardown_test 的 C2）。
  int debugRestoreAbortCount = 0;

  /// 会话恢复租约起点（替代布尔量 `_isRestoringPlaybackSession`）。
  ///
  /// 与落盘租约同理:恢复流程里有 `await playSong(...)`,而 playSong 会对
  /// 当前曲做 setUrl 加载 —— 死链/慢源下该 await 可能**永久不返回**,恢复
  /// 标志就永远为 true,此后所有会话落盘在入口被静默跳过,本地会话
  /// 文件整体陈旧,每次重启都恢复同一首旧歌(v4.3.49 实测症状)。改成时间
  /// 戳租约:超时即视为恢复已结束,强制放行落盘 —— 宁可恢复窗口被提前
  /// 关闭,也不能让本地留存再也不写。
  int? _restoreStartedAtMs;

  /// 恢复是否进行中。带租约上限:超时强制视为已结束。
  bool get isRestoringPlaybackSession {
    final since = _restoreStartedAtMs;
    if (since == null) return false;
    final heldMs = DateTime.now().millisecondsSinceEpoch - since;
    if (heldMs <= _restoreLeaseMs) return true;
    Logger.warnWithTag(
      _logTag,
      'playback session restore lease expired, forcing persist path open '
      '(heldMs=$heldMs)',
    );
    _restoreStartedAtMs = null;
    return false;
  }

  /// 落盘是否正在进行中（租约制，见 [_persistingSinceMs]）。
  bool get _isPersisting {
    final since = _persistingSinceMs;
    if (since == null) return false;
    final stuckMs = DateTime.now().millisecondsSinceEpoch - since;
    if (stuckMs <= _persistLease.inMilliseconds) return true;
    // 租约过期：上次落盘的 await 永久挂起，finally 没机会复位标记。强制
    // 放行并留证，否则会话落盘永久停摆（每次重启都恢复成同一首旧歌）。
    Logger.warnWithTag(
      _logTag,
      'playback session persist lease expired, forcing next write '
      '(stuckForMs=$stuckMs)',
    );
    _persistingSinceMs = null;
    return false;
  }

  void _beginPersistLease() =>
      _persistingSinceMs = DateTime.now().millisecondsSinceEpoch;

  void _endPersistLease() => _persistingSinceMs = null;

  /// 状态变化后的防抖落盘入口（宿主 state setter 每次赋值都会调）。
  void schedulePersist({bool immediate = false}) {
    if (!host.mounted || isRestoringPlaybackSession) return;

    if (immediate) {
      _persistTimer?.cancel();
      _persistTimer = null;
      unawaited(persistPlaybackSession());
      return;
    }

    if (_persistTimer != null) return;
    _persistTimer = Timer(_playbackSessionPersistInterval, () {
      _persistTimer = null;
      unawaited(persistPlaybackSession());
    });
  }

  /// 退出路径配套：取消挂起的防抖 Timer（dispose / persistPlaybackStateNow）。
  void cancelPersistTimer() {
    _persistTimer?.cancel();
    _persistTimer = null;
  }

  /// 本协作者是否已被宿主逐 run 拆卸（见 [dispose]）。
  ///
  /// 为什么需要它：`NotifierProvider` 复用 notifier 实例重跑 `build()`，宿主每轮
  /// 都会换一个新的 persister；旧 persister 的 `restorePlaybackSession` 可能还挂
  /// 在某个 await 上。若不加这个标记，旧流程醒来后会照旧 `playSong` 把「上一轮
  /// 已拆掉的会话」重挂到新 run 上（旧 `同步通知基类` 模型靠整体换实例天然避免）。
  bool _disposed = false;

  /// 逐 run 拆卸（宿主 `_teardownRun` 调用）：标死本协作者。
  ///
  /// 只标死、不取消 Timer —— 调用方（宿主）已在同一拆卸流程里先调
  /// [cancelPersistTimer]；此处专注一件事：让在途恢复优先于后续任何写动作早退。
  void dispose() => _disposed = true;

  /// 测试观察点：本协作者是否已被宿主逐 run 拆卸。
  ///
  /// 「invalidate 有没有真的释放旧 run 资源」靠它取证（旧同步通知模型
  /// 换实例即等价于这里置真）。
  bool get debugDisposed => _disposed;

  /// 序列化队列，队列未变化时复用上次结果（避免每次落盘都全量 toJson 整队，
  /// 那是大屏旋转封面"定时卡顿"的周期性主线程分配源）。
  Map<String, dynamic>? _buildPayload() {
    // 来源一并落盘：重启后队列由此会话恢复，若来源丢失则「本机→设备」接续
    // 搬移拿不到 serverContentType，只能整队推送（大歌单上行 MB 级、耗时
    // 随规模线性劣化）。
    final origin = host.queueOrigin;
    return host.payloadEncoder.buildSession(
      queue: host.state.queue,
      currentIndex: host.state.currentIndex,
      currentSongId: host.state.currentSong?.id,
      position: host.state.position,
      duration: host.state.duration,
      isPlaying: host.state.isPlaying,
      nowMs: DateTime.now().millisecondsSinceEpoch,
      queueOrigin: origin?.toJson(),
    );
  }

  /// 落盘入口。**保证「最后一次状态一定写得进去」** —— 无论期间有多少轮并发。
  ///
  /// 旧实现在「上一轮还在写」时直接 `return` 丢弃本次请求。丢弃本身在当时看是
  /// 无害的（下个 5s 防抖会补），但有两个致命窗口：
  ///   1. 被丢弃的那次恰恰是「清空 / 销毁后的空会话」→ 磁盘上留着清空**前**的
  ///      旧会话，重启即复活；
  ///   2. 紧接着退出（进程结束）→ 再没有下一轮，旧会话永久留在盘上。
  /// 现在改为：标记脏 + 本轮写完后自动补一轮（补的永远是最新 state）。
  Future<void> persistPlaybackSession() async {
    // 关闭(dispose)时 mounted 已为 false,但不能因此跳过落盘 —— 否则退出瞬间
    // 刚更新的进度/歌曲就会丢,重开无法续播。只在「恢复会话进行中」与「正在写」
    // 时跳过,其余情况(含关闭)都照常保存。
    if (isRestoringPlaybackSession) return;
    if (_isPersisting) {
      _persistDirty = true;
      Logger.debugWithTag(
        _logTag,
        'persist deferred: previous write still in flight '
        '(will re-run with latest state)',
      );
      return;
    }

    _persistDirty = false;
    final write = _persistOnce();
    _persistInFlight = write;
    try {
      await write;
    } finally {
      if (identical(_persistInFlight, write)) _persistInFlight = null;
    }

    if (_persistDirty) {
      _persistDirty = false;
      // 期间状态又变了：立刻补写最新状态。不 await —— 调用方（含 dispose）
      // 不该被这次补偿拖住，写盘自己有租约兜底。
      unawaited(persistPlaybackSession());
    }
  }

  Future<void> _persistOnce() async {
    _beginPersistLease();
    try {
      final payload = _buildPayload();
      if (payload == null) {
        await LocalStorage.clearPlaybackSession();
        return;
      }
      // 测试注入点：payload **已按此刻状态算好**、但还没落盘之前的挂起点。
      // 单测用它把这一轮写人为拉长，稳定复现「这轮写带着清空前的旧状态飞在半空，
      // 期间用户把本机销毁 → 清空那次落盘请求被静默丢弃 → 磁盘上永远停着旧会话」。
      //
      // 位置很关键：必须在 payload 构造**之后**。挂在构造之前的话，被测轮次会等
      // 到放行后才去读 state，读到的已是清空后的新状态，等于根本没复现那个竞态
      // （实测：挂错位置时旧实现照样能过 B2，等于把这条契约放空）。
      await debugBeforePersistWrite?.call();
      Logger.debugWithTag(
        _logTag,
        'persist session currentSongId=${payload['currentSongId']} '
        'index=${payload['currentIndex']} '
        'posMs=${payload['positionMs']} isPlaying=${payload['isPlaying']} '
        'queueLen=${(payload['queue'] as List).length} '
        'updatedAt=${payload['updatedAt']}',
      );
      // 挂起风险:Windows 上 tmp.rename 覆盖已存在文件时若被杀软/索引服务
      // 占用会阻塞等待而非抛错,await 永不返回 → finally 不执行。此时靠
      // _persistingSinceMs 租约兜底(见 _persistLease),不再用 .timeout()。
      await LocalStorage.savePlaybackSession(payload);
    } catch (e) {
      Logger.warnWithTag(
        _logTag,
        'failed to persist playback session',
        e,
      );
    } finally {
      _endPersistLease();
    }

    // 音量单独成块:即使会话写入失败/超时也要保住音量,避免「直接退出客户端
    // 后音量回到 100%」。原实现与会话同一个 try,会话一失败音量就跟着不落盘。
    try {
      await LocalStorage.setPlayerVolume(host.state.volume);
    } catch (e) {
      Logger.warnWithTag(_logTag, 'failed to persist player volume', e);
    }
  }

  /// 启动恢复（_init 尾部调用）。
  Future<void> restorePlaybackSession() async {
    if (!host.mounted) return;
    var restored = false;
    var fromServer = false;
    // 代际基线：恢复是异步长流程，中途随时可能被「清空 / 销毁」打断 ——
    // 那时 _sessionGeneration 会自增，本次恢复必须整段作废（见下方守卫）。
    final generation = _sessionGeneration;
    var aborted = false;
    _restoreStartedAtMs = DateTime.now().millisecondsSinceEpoch;

    try {
      final session = await LocalStorage.getPlaybackSession();
      final localQueue = session == null
          ? const <Song>[]
          : _parsePlaybackSessionQueue(session['queue']);
      if (session != null && localQueue.isEmpty) {
        await LocalStorage.clearPlaybackSession();
      }
      final localUpdatedAt =
          session == null ? 0 : (_parseStoredInt(session['updatedAt']) ?? 0);

      // ── 新鲜度竞速:服务端快照比本地文件新则采用服务端队列 ──
      // 本地文件可能因历史 bug(恢复卡死压制落盘 / 写卡死)整体陈旧;若
      // 无条件信任本地,会把旧队列恢复上屏,还会经 syncLocalQueueNow 把
      // 服务端较新的队列覆盖掉(实测:本地 412 首旧会话反杀服务端 3215
      // 首歌单队列)。比较基准是 updatedAt:后端未带该字段(旧版本)按 0
      // 处理 → 本地优先,行为与旧版一致。拉取失败/测试环境返回 null。
      Map<String, dynamic>? snap;
      try {
        snap = await host.fetchLocalQueueForRestore();
      } catch (e) {
        Logger.debugWithTag(
          _logTag,
          'restore: server queue snapshot unavailable: $e',
        );
      }
      final serverQueue = snap == null
          ? const <Song>[]
          : [
              for (final it in (snap['items'] as List))
                if (it is Map) queueItemToSong(it.map((k, v) => MapEntry(k.toString(), v))),
            ];
      final serverUpdatedAt =
          snap == null ? 0 : ((snap['updatedAt'] as num?)?.toInt() ?? 0);
      final useServer = serverQueue.isNotEmpty && serverUpdatedAt > localUpdatedAt;

      if (session == null && !useServer) return;

      List<Song> queue;
      int restoredIndex;
      var restoredPosition = Duration.zero;
      if (useServer) {
        fromServer = true;
        queue = serverQueue;
        final idx = (snap!['currentIndex'] as num?)?.toInt() ?? 0;
        restoredIndex = (idx < 0 || idx >= queue.length) ? 0 : idx;
        // 恢复服务端播放模式(客户端本地洗牌序自建,服务端序列只喂预探测)。
        final modeStr = snap['playMode'] as String?;
        final mode = switch (modeStr) {
          'shuffle' => PlaybackMode.shuffle,
          'one' => PlaybackMode.one,
          'all' => PlaybackMode.all,
          _ => PlaybackMode.order,
        };
        unawaited(host.setPlaybackMode(mode, persist: false));
        Logger.infoWithTag(
          _logTag,
          'restoring FROM SERVER queue=${queue.length} '
          'index=$restoredIndex serverUpdatedAt=$serverUpdatedAt '
          'localUpdatedAt=$localUpdatedAt mode=$modeStr',
        );
      } else {
        queue = localQueue;
        final preferredIndex = _parseStoredInt(session!['currentIndex']) ?? 0;
        final currentSongId = session['currentSongId']?.toString();
        restoredIndex = resolveRestoredQueueIndex(
          queue: queue,
          preferredIndex: preferredIndex,
          currentSongId: currentSongId,
        );
        final storedPositionMs = _parseStoredInt(session['positionMs']) ?? 0;
        restoredPosition = Duration(milliseconds: max(0, storedPositionMs));
        Logger.infoWithTag(
          _logTag,
          'restoring playback session queue=${queue.length} '
          'index=$restoredIndex posMs=${restoredPosition.inMilliseconds} '
          'wasPlaying=${session['isPlaying'] == true}',
        );
      }
      final song = queue[restoredIndex];

      // ── 代际守卫：恢复途中本机被销毁 → 整段作废 ──
      // 上一步到这一步之间隔着读盘 / 探服务端 / 读配置等多个 await，用户完全
      // 可能在流转页把本机拖进回收站。若照旧往下走 playSong，就把刚刚清空的
      // 会话又挂回当前曲 —— 用户看到的正是「销毁了，Mini 播放器一会儿又冒出
      // 歌名、进度还接着走」。销毁是**终结语义**，恢复没有资格把它复活。
      await debugBeforeRestoreResume?.call();
      // 两个作废条件，任一命中就整段丢弃：
      //   * 宿主已逐 run 拆卸（`_disposed`，Notifier 迁移新增：宿主换的是实例里
      //     的对象而非 notifier 本身，光靠代际比对拦不住「同一实例重跑 build」）；
      //   * 会话代际已变（用户清空 / 销毁本机）。
      // 不拦的话，旧流程会 playSong 把已结束的会话重挂到新 run 上。
      if (_disposed || generation != _sessionGeneration) {
        Logger.infoWithTag(
          _logTag,
          'restore aborted: session torn down while restoring '
          '(gen=$generation now=$_sessionGeneration disposed=$_disposed)',
        );
        aborted = true;
        debugRestoreAbortCount++;
        return;
      }

      // ── 恢复不再 await 音源加载 ──
      // playSong 会对当前曲 setUrl;死链/慢源下该 await 可能永久不返回,
      // 把整个恢复流程卡死 → 恢复标志(旧布尔量/现租约)长期为 true →
      // 之后所有会话落盘被跳过 → 本地文件整体陈旧 → 每次重启都恢复成
      // 同一首旧歌(v4.3.49 真机实测)。这里 fire-and-forget:恢复只负责
      // 恢复状态,加载与重试交给播放器既有看门狗;进度经 initialPosition
      // 走 pendingSeek 管线,源就绪后自动 seek 落位。
      final autoResume = await LocalStorage.getAutoPlayOnLaunch();
      unawaited(
        host.playSong(
          song,
          queue: queue,
          index: restoredIndex,
          autoPlay: autoResume,
          initialPosition: fromServer ? null : restoredPosition,
        ).catchError((Object e) {
          Logger.warnWithTag(_logTag, 'post-restore load failed', e);
        }),
      );

      // 恢复队列来源(与队列同源,必须成对):服务端快照无来源 → null,
      // 按「其它来源」降级为整队推送,不误走主通道。
      host.queueOrigin = fromServer
          ? null
          : QueueOrigin.fromJson(readSessionQueueOrigin(session!));

      Logger.infoWithTag(
        _logTag,
        'playback session restored (fromServer=$fromServer)',
      );
      restored = true;

      // 本地为准:把队列镜像给服务端(告诉服务端这是本次要恢复的队列)。
      // 服务端为准:内容一致,无需回推,避免 MB 级冗余上行。
      if (!fromServer) {
        try {
          await host.syncLocalQueueNow();
        } catch (e) {
          Logger.debugWithTag(
            _logTag,
            'post-restore queue mirror skipped: $e',
          );
        }
      }
    } catch (e) {
      Logger.warnWithTag(
        _logTag,
        'failed to restore playback session',
        e,
      );
    } finally {
      _restoreStartedAtMs = null;
      if (aborted) {
        // 恢复在最后一步被作废（见代际守卫）：销毁那次的「立即落盘」曾被
        // 「恢复中」闸门挡下（schedulePersist 在恢复期间直接
        // 返回），这里补写一次「会话已结束」—— 否则磁盘上那份旧会话会在下次
        // 启动把这局已经结束的播放再搬回来。此刻闸门已放开，写的是最新 state。
        schedulePersist(immediate: true);
      }
    }

    if (restored) {
      // 两种来源都立即回写本地文件:服务端胜出时,这次回写把服务端内容
      // 落成新的本地会话,下次启动两侧一致。
      schedulePersist(immediate: true);
    }
  }

  List<Song> _parsePlaybackSessionQueue(Object? rawQueue) {
    if (rawQueue is! List) return const [];

    final queue = <Song>[];
    for (final item in rawQueue) {
      try {
        // jsonDecode 产物恒为 Map<String, dynamic>（原 `item is Map` 非 String 键
        // 防御分支从磁盘路径永远进不去 —— 2026-10-07 按死代码删除）。
        if (item is Map<String, dynamic>) {
          queue.add(Song.fromJson(item));
        }
      } catch (e) {
        Logger.warnWithTag(
          _logTag,
          'skip invalid song in playback session',
          e,
        );
      }
    }
    return queue;
  }

  int? _parseStoredInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  /// 整份会话归零（清空队列 / 移除当前曲）时自增代际，作废在途恢复。
  void bumpSessionGeneration() => _sessionGeneration++;

  /// 等掉正在落地的那一轮写，**以落盘租约为上限**。
  ///
  /// 上限不能省：Windows 上 tmp.rename 可能被杀软/索引服务占用而永久阻塞
  /// （见 [_persistingSinceMs] 的注释），无上限就是「退出时卡死」——
  /// 那比丢一次落盘更糟。超时后照常往下走，由租约强制放行下一次写。
  Future<void> awaitInFlightPersist() async {
    final inflight = _persistInFlight;
    if (inflight == null) return;

    final deadline = Completer<void>();
    final timer = Timer(_persistLease, () {
      if (!deadline.isCompleted) deadline.complete();
    });
    try {
      await Future.any<void>(<Future<void>>[
        inflight.catchError((Object _) {}),
        deadline.future,
      ]);
    } finally {
      // 必须显式 cancel：否则这颗 15s 定时器会在测试里悬着（fakeAsync 的
      // 「A Timer is still pending」断言），生产里也无谓占一颗 Timer。
      timer.cancel();
    }
  }
}
