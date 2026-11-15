import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/network/address_pool.dart';
import 'package:musicflow_client/core/utils/logger.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';

const String _gateLogTag = 'CONN_GATE';

/// 连接就绪闸的等待预算。
///
/// 语义（唯一的语义，别的解释一律作废）：首屏的远程请求在「本次 app 运行内
/// 至少有一次真实往返成功」之前，**最多**等这么久。
///
/// - 等到 → 立刻放行：请求发在连接建立之后，这正是用户要的
///   「先把连接建立起来再刷新才对」；
/// - 等不到 → 照常尽力发出。**闸是加速器，不是门禁**：预算到期绝不抛错、
///   绝不置 `failed`、绝不弹「网络异常」。
const Duration kConnectionGateBudget = Duration(seconds: 6);

/// 冷启动档的重连间隔：还没真实连通过时，每秒探一次。
const Duration kColdStartReconnectInterval = Duration(seconds: 1);

/// 失联档的重连间隔：本会话连通过之后又断了，每 10 秒探一次（无总时限）。
const Duration kDisconnectReconnectInterval = Duration(seconds: 10);

/// 冷启动档的**硬窗口**：从 [Reconnector] 启动算起 30 秒，到点必停。
///
/// 注意语义是「最多试 30 秒」而**不是**「30 秒内必须成功」：服务器真的挂了
/// 就停在 30 秒，交给下拉刷新 / retry scope 兜，不许无限烧电池。
const Duration kColdStartReconnectWindow = Duration(seconds: 30);

/// 冷启动档的重连间隔（可注入，测试用）。
@visibleForTesting
Duration reconnectColdStartInterval = kColdStartReconnectInterval;

/// 失联档的重连间隔（可注入，测试用）。
@visibleForTesting
Duration reconnectDisconnectInterval = kDisconnectReconnectInterval;

/// 冷启动档的硬窗口（可注入，测试用）。
@visibleForTesting
Duration reconnectColdStartWindow = kColdStartReconnectWindow;

/// 本次会话当前是否已连通（供 UI / 日志读取）。
///
/// 唯一真值来源是 [activeAddressProvider] 的 `status`：
/// `ServerAddressStatus.ok` 是「服务器真的回了一个 200」的唯一信号 ——
/// 探测成功会经 `AddressPool._applyProbeResult → _setActiveAddress →
/// onActiveAddressChanged → activeAddressProvider.state` 传上来。
///
/// 刻意**不**复用 `ConnectivityMonitor`（那是系统网络的可用性，不是服务器
/// 连通性），也刻意**不**另起一次 ping：那会引入第二种真值来源，
/// 两条真值一旦不一致就没有人能判断谁对。
final sessionConnectedProvider = Provider<bool>((ref) {
  return ref.watch(activeAddressProvider)?.status == ServerAddressStatus.ok;
});

/// 本次 app 运行内**是否曾经**真实连通过（会话级 sticky，供 UI / 日志读取）。
///
/// 与 [sessionConnectedProvider] 的区别：后者是「此刻」，前者是「曾经」。
/// 前者由 `AddressPool.sessionEverConnected` 提供，写入点唯一（探测成功的
/// 分支），**不能**用「`activeAddressProvider.status == ok`」反推 ——
/// 持久化恢复的地址自带上次的 `ok`，那是 stale 的。
final sessionEverConnectedProvider = Provider<bool>((ref) {
  try {
    return ref.watch(addressPoolProvider).sessionEverConnected;
  } catch (e) {
    Logger.debugWithTag(_gateLogTag, 'sessionEverConnected unavailable', e);
    return false;
  }
});

/// 一个「失败区块」在 [Reconnector] 里的登记项。
///
/// 三个回调就是重连器需要的全部信息：怎么重拉、怎么探测、当前属于哪一档。
class _RetryTarget {
  _RetryTarget({
    required this.invalidate,
    required this.probe,
    required this.coldStart,
  });

  /// 让该 provider 重拉一次（`ref.invalidateSelf()`）。
  final void Function() invalidate;

  /// 单发 `/ping` 探测（走 probe dio，不占令牌桶）。
  final Future<bool> Function() probe;

  /// 是否处于冷启动档（`!sessionEverConnected`）。
  final bool Function() coldStart;
}

/// 全局单例重连器：两档周期重连。
///
/// ## 为什么要「全局单例」而不是每个 provider 自己重试
///
/// 首页 5~12 个区块，若每个区块每秒各重发一次业务请求，再叠加
/// `FallbackInterceptor` 内部的同址重试（0/1s/2s），就是每秒 10~30 个请求
/// —— **直接把 12 次/10s 的令牌桶打穿，然后永远恢复不了**（自我 DDoS）。
///
/// 唯一不自我打死的形态：**每秒只发 1 个廉价的 `/ping`**（单飞、2s 超时、
/// 不挂拦截器、不占令牌桶），一旦成功就一次性把**所有**失败区块 `invalidate`
/// 掉，让它们带着已就绪的连接重新取数。
///
/// ## 两档（档位由 `sessionEverConnected` 决定，每次 tick 重判）
///
/// | | 冷启动档 | 失联档 |
/// |---|---|---|
/// | 触发条件 | `sessionEverConnected == false` | `sessionEverConnected == true` |
/// | 间隔 | 1s | 10s |
/// | 总时限 | 30s 硬窗口（到点必停） | 无 |
/// | 探测失败后 | 只等下一 tick，**不**重拉区块 | 重拉至多 6 个区块，其余 deferred |
///
/// ## 护栏
///
/// - B1 探测成功即停，并一次性刷新全部失败区块；
/// - B2 无观众（注册过的 provider key 全部失去监听者）即暂停，恢复时立即重试一次；
/// - B3 全部区块被 dispose 即取消定时器，不留 pending timer；
/// - B4 单飞：任何时刻最多一个探测在飞；重复 `reportFailure` 只刷新集合，不重启 timer；
/// - B5 冷启动档 30s 硬窗口；
/// - B6 重连触发的重建不叠加 6s：见 [consumeFastPass]。
class Reconnector {
  Reconnector._();

  /// 进程内唯一实例（会话级状态就挂在这里）。
  static final Reconnector instance = Reconnector._();

  /// 失败区块登记表（key = `label|refreshKey`）。
  final Map<String, _RetryTarget> _targets = <String, _RetryTarget>{};

  /// 当前有监听者的 provider key（B2 的「观众集合」）。
  final Set<String> _audience = <String>{};

  /// 刚被重连器 `invalidate` 过的 key：它们重建时闸必须立即放行（B6）。
  final Set<String> _fastPass = <String>{};

  Timer? _timer;
  Timer? _windowTimer;
  bool _running = false;
  bool _paused = false;
  bool _probing = false;
  bool _flushing = false;
  bool _coldTier = true;
  int _ticks = 0;

  /// 是否有一轮重连正在跑（含「无观众暂停」期间）。
  bool get isRunning => _running;

  /// 已发出的重连探测次数（测试用）。
  @visibleForTesting
  int get tickCount => _ticks;

  /// 当前档位：`cold` / `disconnect`（测试与日志用）。
  @visibleForTesting
  String get tier => _coldTier ? 'cold' : 'disconnect';

  /// 是否处于「无观众暂停」态（测试用）。
  @visibleForTesting
  bool get isPaused => _paused;

  /// 还在等待重拉的区块数（测试用）。
  @visibleForTesting
  int get pendingTargetCount => _targets.length;

  /// provider 构建期登记「我有监听者」。
  void register(String key) {
    _audience.add(key);
  }

  /// 最后一个监听者走了（`ref.onCancel`）。
  void onCancel(String key) {
    _audience.remove(key);
    if (_audience.isEmpty) _pause();
  }

  /// 又有监听者了（`ref.onResume`）：若正处在暂停态，**立即**重试一次。
  void onResume(String key) {
    _audience.add(key);
    if (!_paused) return;
    _paused = false;
    if (!_running) return;
    Logger.infoWithTag(_gateLogTag, 'reconnector resumed: retry immediately');
    _schedule(Duration.zero);
  }

  /// provider 被 dispose（`ref.onDispose`）：取消登记。全部没了就停。
  ///
  /// **不清 `_fastPass`**：`invalidateSelf()` 是同步跑 onDispose、异步排重建的，
  /// 在这里清掉正好会把刚发出去的通行证收走，B6 就白做了。
  /// **flush 期间不判停**：一次 flush 会连环触发 onDispose，中途停掉会让后面
  /// 的区块永远收不到重拉。
  void unregister(String key) {
    _audience.remove(key);
    _targets.remove(key);
    if (_flushing) return;
    if (_audience.isEmpty && _targets.isEmpty) _stop('all targets disposed');
  }

  /// 一次「远程请求失败」上报。
  ///
  /// **不看 `status`**：隧道断掉时持久化恢复的地址仍然是 stale 的 `ok`，
  /// 按 status 判「已连通」会让重连永远不启动 —— 那正是用户报的现象。
  /// 档位由 `_RetryTarget.coldStart` 在每次 tick 时重判。
  ///
  /// B4：已经在跑就直接返回，只刷新登记集合 —— 重复上报不许重启 timer，
  /// 否则十几个区块同时失败会把「每 1s 一次」放大成「每 1s 十几次」。
  void reportFailure({
    required String key,
    required void Function() invalidate,
    required Future<bool> Function() probe,
    required bool Function() coldStart,
  }) {
    _targets[key] = _RetryTarget(
      invalidate: invalidate,
      probe: probe,
      coldStart: coldStart,
    );
    if (_running) return;
    _start();
  }

  /// 取出并消费一个「快速放行」标记（B6）。
  ///
  /// 重连成功后我们 `invalidate` 了区块；这些区块重建时如果还老老实实等
  /// 满 6s 的闸预算，「1 秒重连」就变成了「7 秒重连」。这里给它们一张一次性
  /// 通行证：闸看到就直接放行。
  bool consumeFastPass(String key) => _fastPass.remove(key);

  void _start() {
    _running = true;
    _paused = false;
    _ticks = 0;
    _probing = false;
    _fastPass.clear();
    _coldTier = _resolveColdTier();
    _windowTimer?.cancel();
    _windowTimer = null;
    if (_coldTier) {
      // 硬窗口用 Timer 而不是「累计间隔」：暂停（无观众）期间窗口照样流逝，
      // 这才是「从启动算起 30 秒」的字面语义。
      _windowTimer = Timer(reconnectColdStartWindow, _onWindowExpired);
    }
    Logger.infoWithTag(
      _gateLogTag,
      'reconnector start tier=$tier targets=${_targets.length} '
      'interval=${_interval().inMilliseconds}ms',
    );
    _schedule(_interval());
  }

  bool _resolveColdTier() {
    if (_targets.isEmpty) return true;
    return _targets.values.first.coldStart();
  }

  Duration _interval() {
    return _coldTier ? reconnectColdStartInterval : reconnectDisconnectInterval;
  }

  void _schedule(Duration delay) {
    _timer?.cancel();
    _timer = Timer(delay, () {
      unawaited(_tick());
    });
  }

  Future<void> _tick() async {
    _timer = null;
    if (!_running || _paused) return;
    if (_targets.isEmpty) {
      _stop('no target left');
      return;
    }
    if (_probing) {
      // B4 单飞：上一轮探测还没落定，跳过本 tick（绝不并发打 /ping）。
      _schedule(_interval());
      return;
    }
    // 档位每次 tick 重判：`sessionEverConnected` 一旦翻真就切到 10s 档。
    _coldTier = _resolveColdTier();
    final target = _targets.values.first;
    _probing = true;
    _ticks += 1;
    var ok = false;
    try {
      ok = await target.probe();
    } catch (e) {
      Logger.warnWithTag(_gateLogTag, 'reconnect probe threw', e);
      ok = false;
    } finally {
      _probing = false;
    }
    // 探测期间可能被 dispose / 无观众暂停 / 窗口到期停掉。
    if (!_running || _paused) return;
    if (ok) {
      // B1：成功即停，并把所有失败区块一次性刷掉。
      Logger.infoWithTag(
        _gateLogTag,
        'reconnected: tier=$tier ticks=$_ticks, '
        'refetch ${_targets.length} block(s)',
      );
      _flushAll();
      _stop('connected');
      return;
    }
    // 失败：**两档都只探测、不扇出**。
    //
    // 业务扇出只在成功那一刻做一次（`_flushAll`）。两个理由：
    //
    // 1. 失败扇出是纯浪费：`/ping` 都不通说明服务器不可达，此时把十几个区块
    //    invalidate 出去必然再失败一遍，只换来 UI 反复闪 loading→error→缓存。
    // 2. 更致命的是它会自我节流：`FallbackInterceptor` 的桶是 12 次/10s，而一次
    //    业务请求失败会重试到 3 次 —— 6 个区块 = 18 次请求挤进 ~3 秒，桶立刻见底。
    //    结果「10s 重连」被悄悄降级成单次尝试，且服务器真回来那一刻桶正好是空的，
    //    `_flushAll()` 反被限流 —— **在最该快的时候慢**。
    //
    // 「每 10 秒自动重连」的语义仍然满足：**重连动作就是这一次 `/ping` 探测**，
    // 不是「每 10 秒重拉 6 个区块」。这样两档的做法完全统一。
    Logger.debugWithTag(
      _gateLogTag,
      '$tier reconnect tick $_ticks not connected, '
      'next in ${_interval().inMilliseconds}ms',
    );
    if (_running && !_paused) _schedule(_interval());
  }

  void _flushAll() {
    // 先取快照：`invalidate()` 会同步触发 onDispose → unregister → 改表。
    final entries = _targets.entries
        .map((e) => MapEntry(e.key, e.value))
        .toList(growable: false);
    _targets.clear();
    _flushing = true;
    try {
      for (final entry in entries) {
        _fastPass.add(entry.key);
        _invoke(entry.key, entry.value);
      }
    } finally {
      _flushing = false;
    }
  }

  void _invoke(String key, _RetryTarget target) {
    try {
      target.invalidate();
    } catch (e) {
      Logger.debugWithTag(_gateLogTag, 'retry skipped for $key', e);
    }
  }

  void _pause() {
    if (!_running) return;
    _paused = true;
    _timer?.cancel();
    _timer = null;
    Logger.infoWithTag(_gateLogTag, 'reconnector paused: no audience');
  }

  void _stop(String reason) {
    if (!_running && _timer == null && _windowTimer == null) return;
    _timer?.cancel();
    _timer = null;
    _windowTimer?.cancel();
    _windowTimer = null;
    _running = false;
    _paused = false;
    _probing = false;
    _targets.clear();
    Logger.infoWithTag(_gateLogTag, 'reconnector stop: $reason');
  }

  void _onWindowExpired() {
    if (!_running || !_coldTier) return;
    Logger.warnWithTag(
      _gateLogTag,
      'cold-start reconnect window '
      '(${reconnectColdStartWindow.inSeconds}s) exhausted; '
      'giving up on ${_targets.length} block(s)',
    );
    _stop('cold-start window exhausted');
  }

  /// 测试隔离：清空全部会话级状态并复位可注入间隔。
  @visibleForTesting
  void resetForTest() {
    _timer?.cancel();
    _timer = null;
    _windowTimer?.cancel();
    _windowTimer = null;
    _targets.clear();
    _audience.clear();
    _fastPass.clear();
    _running = false;
    _paused = false;
    _probing = false;
    _flushing = false;
    _coldTier = true;
    _ticks = 0;
    reconnectColdStartInterval = kColdStartReconnectInterval;
    reconnectDisconnectInterval = kDisconnectReconnectInterval;
    reconnectColdStartWindow = kColdStartReconnectWindow;
  }
}

/// 测试隔离：清空重连器的全部会话级状态。
///
/// 同一文件的多条用例必须调用，否则第 2 条起会被第 1 条留下的「已经连通过」/
/// 「窗口已耗尽」/「区块还在登记表里」打成假绿或假红。
@visibleForTesting
void resetConnectionGateForTest() {
  Reconnector.instance.resetForTest();
}

/// 一次「provider 构建」的连接就绪闸。
///
/// 职责有两件（都围绕「请求时机早于连接建立」这条根因）：
/// 1. [wait]：连接尚未建立 / 有一轮探测正在给连接暖场时，最多等
///    [kConnectionGateBudget]，落定就放行；
/// 2. [reportFailure]：把「这个区块取数失败了」上报给全局 [Reconnector]，
///    由它按档位周期探测，连通后统一重拉（**不是**「一次为限」的自救）。
///
/// **安装时机唯一**：provider body 的同步段（`fetchWithCacheFallback` 的第一条
/// 语句）。内部要 `Ref.listen` / `Ref.onCancel` / `Ref.onResume`，而它们只能在
/// 构建期安全调用；放进 `await` 之后的异步回调里再装会踩 Riverpod 的生命周期坑
/// （订阅挂在已经重建/销毁的 element 上，回调永不触发）。Dart 的 async 函数体
/// 在第一个 `await` 之前是**同步**执行的，所以「函数顶部的第一条语句」确实落在
/// 构建期。
class ConnectionGate {
  ConnectionGate._(this._ref, this._label, this._key);

  /// 构建期同步安装（见类注释）。
  ///
  /// [label] / [refreshKey] 共同决定闸键：带上 `label` 是为了让两个首屏区块
  /// 传同一个 `libraryId` 时不互相抢占（刷新闸、快速放行通道都按这个键）。
  factory ConnectionGate.install({
    required Ref ref,
    required String label,
    String? refreshKey,
  }) {
    final gate = ConnectionGate._(ref, label, '$label|${refreshKey ?? ''}');
    gate._attach();
    return gate;
  }

  final Ref _ref;
  final String _label;
  final String _key;

  /// 正在等连接的等待方（同一构建周期内只有一个，见 [wait] 的幂等）。
  Completer<void>? _waiter;

  /// 幂等的 [wait] future。
  Future<void>? _waitFuture;

  /// 本 provider 构建周期是否已结束（`ref.onDispose` 标记）。
  ///
  /// 重建/销毁之后的回调一律早退：此刻 `ref` 已不可用，继续操作会抛
  /// 「Cannot use ref after dispose」把一次可恢复的竞态放大成红。
  bool _disposed = false;

  /// 当前是否已连通 —— 唯一判据见 [sessionConnectedProvider]。
  bool get isConnected =>
      _ref.read(activeAddressProvider)?.status == ServerAddressStatus.ok;

  void _attach() {
    Reconnector.instance.register(_key);
    // 订阅由 element 自己持有：`Ref.listen` 注册在 provider element 的
    // listener 表里，element 重建/销毁时由 Riverpod 自动关闭，这里不需要
    // （也不应该）自己保存/关闭，否则会和自动关闭抢时序。
    _ref.listen<ServerAddress?>(activeAddressProvider, (previous, next) {
      // 只认 `ok`：`failed` / `unknown` 一律不算连通。
      if (next?.status == ServerAddressStatus.ok) _onConnected();
    });
    // B2：无观众（该 provider 一个监听者都没有）时重连器暂停，省电省流量；
    // 观众回来时立即重试一次，避免「用户刚点回首页又要等一整个间隔」。
    _ref.onCancel(() => Reconnector.instance.onCancel(_key));
    _ref.onResume(() => Reconnector.instance.onResume(_key));
    _ref.onDispose(() {
      _dispose();
      Reconnector.instance.unregister(_key);
    });
  }

  void _dispose() {
    _disposed = true;
    final waiter = _waiter;
    _waiter = null;
    if (waiter != null && !waiter.isCompleted) {
      // 放行等待方，让 `wait()` 的续体继续跑（随后 `_disposed` 早退）；
      // 不放行会留下一个永不完成的 future 与未取消的 `timeout` 定时器。
      waiter.complete();
    }
  }

  /// 等「连接就绪」：落定就立刻返回，[budget] 到期也返回。
  ///
  /// 幂等：同一构建周期内被多条分支读到（cacheFirst 分支 + 远程分支 +
  /// 后台刷新分支）也只等一次 —— 返回同一个 future。
  Future<void> wait({Duration budget = kConnectionGateBudget}) {
    return _waitFuture ??= _waitInternal(budget);
  }

  Future<void> _waitInternal(Duration budget) async {
    if (_disposed) return;

    // B6：被重连器刷新的区块重建时，闸立即放行。
    // 否则每个区块白等 6s，「1 秒重连」就变成「7 秒重连」。
    if (Reconnector.instance.consumeFastPass(_key)) {
      Logger.infoWithTag(
        _gateLogTag,
        '$_label: gate fast-passed (reconnect retry)',
      );
      return;
    }

    final pool = _tryReadAddressPool();
    // 地址池为空 = 根本没有已配置的地址（首装 / 未配置服务器）：没有可等的
    // 连接，硬等 6s 只会把首屏白拖 6s。
    if (pool == null || pool.addresses.isEmpty) return;

    if (!pool.isProbing) {
      // 没有往返在飞。此时只有「连活跃地址都还没有」才值得踢一轮探测并等它：
      // 已经有活跃地址说明探测早已跑过、状态已经落定（非 ok 就是服务端真的
      // 不可用），再等不会改变任何东西 —— 那 6s 是纯延迟。
      // 这里也顺手挡掉了「已连通却去踢探测」：会话中后期的取数路径零等待。
      if (pool.activeAddress != null) return;
    }

    final waiter = Completer<void>();
    _waiter = waiter;

    // 「有一轮往返正在进行」本身就是等待的理由：
    //  - 冷启动 `setAddresses → probeAll` 正在给连接暖场；
    //  - 或者首屏某条请求自己踢出去的那一轮。
    // 放行信号有两个，任一落定即可：
    //  a) `activeAddressProvider` 观测到 `status == ok`（见 [_attach]）；
    //  b) 这一轮探测自己落定（已经在飞就复用它，没在飞就踢一轮）。
    // 必须有 b) 兜底：持久化恢复的地址自带上次的 `status = ok`，本轮探测成功
    // 时状态**没有变化** → `AddressPool._setActiveAddress` 判定
    // `changed == false` 直接 return（不回调），只等 a) 会让每次冷启动都白等
    // 满 6s，等于把「首屏加速」做成了「首屏减速」。
    // `probeAll` 内部有 in-flight 复用：首屏十几条请求拿到的是同一个 future，
    // 所以这里不会变成探测风暴。
    unawaited(() async {
      try {
        await pool.probeAll();
      } catch (e) {
        Logger.debugWithTag(_gateLogTag, '$_label: gate probe settle error', e);
      }
      if (!waiter.isCompleted) waiter.complete();
    }());

    try {
      await waiter.future.timeout(budget);
      Logger.infoWithTag(_gateLogTag, '$_label: gate released');
    } on TimeoutException {
      // 预算到期 → 照常尽力发出。绝不置 failed、绝不弹网络异常。
      Logger.infoWithTag(
        _gateLogTag,
        '$_label: gate budget exhausted, proceed best-effort',
      );
    } finally {
      if (identical(_waiter, waiter)) _waiter = null;
    }
  }

  /// 一次远程加载失败之后调用：把它交给全局重连器。
  ///
  /// 只在地址池非空（确实配置过服务器）时才上报 —— 首装未配置服务器是另一条
  /// 产品路径（引导页），给它起定时重连毫无意义。
  void reportFailure() {
    if (_disposed) return;
    final pool = _tryReadAddressPool();
    if (pool == null || pool.addresses.isEmpty) return;
    Reconnector.instance.reportFailure(
      key: _key,
      invalidate: _invalidateSelf,
      probe: () => pool.probeOnceForReconnect(),
      coldStart: () => !pool.sessionEverConnected,
    );
  }

  void _onConnected() {
    final waiter = _waiter;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  void _invalidateSelf() {
    if (_disposed) return;
    try {
      _ref.invalidateSelf();
      Logger.infoWithTag(_gateLogTag, '$_label: reconnect retry requested');
    } catch (e) {
      // element 已被销毁（页面切走 / 容器 dispose）：跳过即可，
      // 一次重连重拉失败不该冒泡成 uncaught。
      Logger.debugWithTag(_gateLogTag, '$_label reconnect retry skipped', e);
    }
  }

  AddressPool? _tryReadAddressPool() {
    try {
      return _ref.read(addressPoolProvider);
    } catch (e) {
      Logger.debugWithTag(_gateLogTag, 'address pool unavailable', e);
      return null;
    }
  }
}
