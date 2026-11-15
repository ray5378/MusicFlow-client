import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/utils/logger.dart';
import 'package:musicflow_client/core/utils/network_error_notifier.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/api/connection_gate.dart';

const String _fallbackLogTag = 'FETCH';

/// 单次「远程加载」的总预算上限（覆盖 connect + send + receive + TLS）。
///
/// 批 A 的同地址重试把黑洞 / 隧道断场景的单请求最坏耗时从 ~10s 拉到 ~33s
/// （connectTimeout 10s × 3 + 1s + 2s 退避），首屏区块会白等到 33s 才有结果。
/// 这里在 provider 层截断：用户最多等 5s，之后走缓存 / 失败态。
///
/// **为什么不在拦截器里**：批 A 的 `_dio.fetch` 递归会让同一个逻辑请求穿过
/// 多帧 `onRequest` / `onError`，「哪一帧是最后一帧」不可判定 —— 武装/取消
/// `Timer` 的时机一旦错，要么预算失效，要么残留 `Timer` 让 widget 测试直接红。
/// `Future.timeout` 自己管计时器（完成即取消），且只作用在用户真正在看的那一层。
///
/// 已知残留（批 C）：超时后底层 dio 请求仍在跑（11s/13s 还会再试两波），受
/// 令牌桶约束但不会真 abort。要真 abort 得给 20+ 调用点传 `CancelToken`。
const Duration kDefaultRequestBudget = Duration(seconds: 5);

/// 每个刷新闸键最近一次放行后台刷新的时刻。
///
/// 键是 `'$label|$refreshKey'` 的复合值（见 [_scheduleBackgroundRefresh]）：
/// `label` 给出区块命名空间，避免两个首屏区块传同一个 `libraryId` 时互相
/// 吃掉刷新机会；`refreshKey` 保持纯业务维度（如切库后重新获得一次刷新）。
///
/// 用**带 TTL 的时刻表**而不是一次性 Set：Set 一旦 `add` 就永不释放，用户
/// 手动刷新 / 下拉 / 切库 / 入库回调这些 `ref.invalidate` 路径会退化成
/// 「返回缓存、零远程请求」；TTL 让 10s 窗口内 `invalidateSelf` 触发的
/// provider 重跑被挡住（防自我刷新死循环），窗口过后的显式刷新重新放行。
final Map<String, DateTime> _lastRefreshAt = <String, DateTime>{};

/// 闸的时间窗：同一个复合键在此窗口内最多放行一次后台刷新。
const Duration _kRefreshGateTtl = Duration(seconds: 10);

/// 测试可注入的时钟 —— 让「窗口内 / 窗口外」可被确定性钉住，不用 Timer，
/// 避免 fake-async 里残留 pending timer 让 widget 测试假绿。
@visibleForTesting
DateTime Function() refreshClockForTest = DateTime.now;

/// 测试专用：清空后台刷新闸。
///
/// 同一文件的多条用例必须调用 —— 否则第 2 条起 `_scheduleBackgroundRefresh`
/// 会因为「这个 key 刚刷过」直接 return，`fetchCallCount` 永远是 0，
/// 「后台刷新真的跑了一次」这类断言全变假绿。
@visibleForTesting
void resetRefreshGateForTest() => _lastRefreshAt.clear();

/// 首页各区块统一的「远程优先 + 缓存兜底」加载封装。
///
/// 随机歌曲 / 最近更新歌单 / 所有歌单 等区块**必须共用这一套语义**，
/// 否则会出现「同一份数据、不同区块表现不一致」的首屏顽疾：
///
/// - 远程成功：写缓存；**写缓存失败绝不反噬本次结果**
///   （Windows 上个别元数据含 shared_prefs 无法落盘的字符，
///   jsonEncode 会抛 FormatException，若让它冒出去会把整次 200 请求判成失败，
///   正是「有网却不显示」的历史根因）。
/// - 远程失败：静默回落缓存并正常展示，**不弹网络异常**；
///   只有「远程失败 + 缓存也没命中」才标记失败并向用户提示。
///
/// 冷启动时活跃库/地址可能尚未就绪，调用方应先自行尝试用
/// `getLastLibraryId()` 回退读缓存秒出（见 [recentPlaylistsProvider]），
/// 本函数只负责「已具备远程条件」后的加载与兜底。
///
/// [cacheFirst]（SWR）：有缓存就**立刻**把缓存交出去，再在后台拉新值
/// （同一 `label + refreshKey` 在 [_kRefreshGateTtl] 窗口内只拉一次）。
/// 没有缓存时行为与不开启完全一致。
///
/// 批 D（连接就绪闸 + 两档周期重连）：
/// - 远程请求前先过 [ConnectionGate.wait]：本次会话尚未观察到「真实往返成功」
///   （`ServerAddress.status == ok`）时最多等 [kConnectionGateBudget]，等到就
///   放行，等不到也放行 —— 请求不再抢先发在连接建立之前；
/// - **任何**一次远程失败都 [ConnectionGate.reportFailure]：全局单例
///   `Reconnector` 接手，冷启动档 1s 一次、失联档 10s 一次探测 `/ping`，
///   连通后把所有失败区块一次性重拉（不是「一次为限」的自救）。
///
/// [addressFailureIsLoadFailure] = false 时，「地址/连接还没就绪」这一类失败
/// 既不置 [failedProvider] 也不弹网络异常（首页固定卡区块的老口径：地址失败
/// 不算「固定卡加载失败」，UI 不该因此显示错误态）。
///
/// [notifyOnFailure] = false 时，失败仍会置 [failedProvider]（供 UI 走错误
/// 分支），但不弹全局「网络异常」—— 用于「失败本来就有静默降级语义」的区块
/// （分区清单回落默认顺序、歌单数回落默认值），避免首屏叠出一片 toast。
Future<T> fetchWithCacheFallback<T>({
  required Ref ref,
  required String label,
  required Future<T> Function() fetch,
  required Future<void> Function(T data) cacheWrite,
  required Future<T?> Function() cacheRead,
  required StateProvider<bool> failedProvider,
  required String errorMessage,
  required T emptyValue,
  bool cacheFirst = false,
  Duration budget = kDefaultRequestBudget,
  String? refreshKey,
  bool addressFailureIsLoadFailure = true,
  bool notifyOnFailure = true,
}) async {
  // ⚠️ 连接就绪闸的安装**必须**是本函数（即 provider body 同步段）的
  // 第一条语句：内部要 `Ref.listen`，而它只能在构建期安全调用。Dart 的
  // async 函数体在第一个 `await` 之前是**同步**执行的，所以这行确实落在
  // provider 的构建期；放进 `await` 之后的异步回调再装会踩 Riverpod 的
  // 生命周期坑（订阅挂在已重建/已销毁的 element 上，回调永不触发）。
  final gate = ConnectionGate.install(
    ref: ref,
    label: label,
    refreshKey: refreshKey,
  );

  if (cacheFirst) {
    final cached = await _readCacheQuietly(label, cacheRead);
    if (cached != null && !_isEmptyPayload(cached)) {
      // 首屏秒出：先把旧值交出去，新鲜值由后台刷新补上。
      // 刻意**不**在这里 `await fetch()` —— 那等于把「缓存优先」又变回远程优先。
      ref.read(failedProvider.notifier).state = false;
      // 闸键必须带 label 命名空间：recentPlaylists / randomSongs 传的是同一个
      // libraryId，只按业务 key 去重会让先 build 的区块吃掉另一个的刷新机会。
      final gateKey = '$label|${refreshKey ?? ''}';
      _scheduleBackgroundRefresh<T>(
        ref: ref,
        label: label,
        fetch: fetch,
        cacheWrite: cacheWrite,
        budget: budget,
        gateKey: gateKey,
        gate: gate,
        previous: cached,
      );
      Logger.infoWithTag(_fallbackLogTag, '$label served from cache (SWR)');
      return cached;
    }
  }

  // 活跃地址是否已就绪。用来区分「连接还没起来」与「服务器真的回了错」。
  var addressReady = false;
  try {
    // 闸在前：先等连接建立（有界预算），再取活跃地址（自身也有 300ms 预算）。
    await gate.wait();
    await ref.read(ensureActiveAddressProvider.future);
    addressReady = true;
    final data = await fetch().timeout(
      budget,
      onTimeout: () => throw TimeoutException(
        '$label request budget exceeded ($budget)',
        budget,
      ),
    );
    try {
      await cacheWrite(data);
    } catch (e) {
      Logger.warnWithTag(_fallbackLogTag, '$label cache write failed', e);
    }
    ref.read(failedProvider.notifier).state = false;
    Logger.infoWithTag(_fallbackLogTag, '$label loaded from remote');
    return data;
  } catch (e, stackTrace) {
    Logger.warnWithTag(_fallbackLogTag, '$label remote load failed', e);
    Logger.debugWithTag(
      _fallbackLogTag,
      '$label fallback stackTrace',
      null,
      stackTrace,
    );
    // 前台失败 → 触发一次**限速的点探测**，把「判死」延迟从 30~70s 压到 ~10s。
    // 只探一条、全池 5s 内最多一次、上一次未结束直接跳过（见
    // `AddressPool.probeActiveThrottled`）：绝不能在这里 probeAll()。
    // 后台刷新失败走的是 _scheduleBackgroundRefresh 的 catch，**不**触发
    // 探测 —— 那是可接受的后台失败，不该为它去打扰整池状态。
    // 远程失败 → 交给全局重连器（两档周期重连）。
    // **不看 `status`**：隧道断掉时持久化恢复的地址仍然是 stale 的 `ok`，
    // 按 status 判「已连通」会让重连永远不启动 —— 这正是用户报的那个现象。
    // 缓存兜底成功的路径也要上报：用户看到的是旧数据，连接恢复后必须换成新
    // 的，否则首页会一直停在过期缓存上。
    gate.reportFailure();
    unawaited(_probeActiveQuietly(ref));
    final cached = await _readCacheQuietly(label, cacheRead);
    if (cached != null) {
      ref.read(failedProvider.notifier).state = false;
      Logger.infoWithTag(_fallbackLogTag, '$label fallback to cache');
      return cached;
    }
    // 「地址还没就绪」被调用方声明为「不算加载失败」：既不置 failed 也不弹窗，
    // 探测完成 / 地址变化会让 provider 自重算（老口径见首页固定卡区块）。
    if (!addressReady && !addressFailureIsLoadFailure) {
      ref.read(failedProvider.notifier).state = false;
      Logger.warnWithTag(
        _fallbackLogTag,
        '$label skipped: address not ready (not a load failure)',
      );
      return emptyValue;
    }
    // 远程失败且无缓存兜底，才向用户提示网络异常。
    if (notifyOnFailure) NetworkErrorNotifier.show(errorMessage);
    ref.read(failedProvider.notifier).state = true;
    Logger.warnWithTag(_fallbackLogTag, '$label cache miss');
    return emptyValue;
  }
}

/// 静默读缓存：缓存读取本身异常（平台存储 / 单条坏数据）也不能冒泡成
/// uncaught，否则会把一组可恢复的失败放大成整页报错。
Future<T?> _readCacheQuietly<T>(
  String label,
  Future<T?> Function() cacheRead,
) async {
  try {
    return await cacheRead();
  } catch (e) {
    Logger.warnWithTag(_fallbackLogTag, '$label cache read failed', e);
    return null;
  }
}

/// 后台刷新失败只降级为一条 debug 日志：用户**已经看到内容了**，
/// 这时候弹「网络异常」正是批 A 要消灭的症状。
void _scheduleBackgroundRefresh<T>({
  required Ref ref,
  required String label,
  required Future<T> Function() fetch,
  required Future<void> Function(T data) cacheWrite,
  required Duration budget,
  required String gateKey,
  required ConnectionGate gate,
  required T? previous,
}) {
  // 10s 窗口内同一 gateKey 只放行一次：既挡住 `invalidateSelf` 触发的
  // provider 重跑（防自我刷新死循环），也保证窗口过后用户显式刷新能重新
  // 发出远程请求 —— 一次性 Set 会把这些 invalidate 路径永久挡死（P0-2）。
  final now = refreshClockForTest();
  final last = _lastRefreshAt[gateKey];
  if (last != null && now.difference(last) < _kRefreshGateTtl) return;
  _lastRefreshAt[gateKey] = now;
  // 必须推到**事件队列**（`Future(() {...})`）而不是就地执行：
  // 就地调用一个 async 函数会同步执行到第一个 await 之前，也就是 `fetch()`
  // 当场就被调用了 —— 那等于「首帧就发了远程请求」，既有缓存优先的语义
  // （首屏不再等网络）会被破坏，也让「首帧 fetchCallCount == 0」不可测。
  unawaited(Future<void>(() async {
    try {
      // 后台刷新同样要过闸：隧道/连接还没暖时它必然失败，等于白烧一次
      // 重试预算，还要吃 `FallbackInterceptor` 的令牌桶。
      await gate.wait();
      final fresh = await fetch().timeout(budget);
      try {
        await cacheWrite(fresh);
      } catch (e) {
        Logger.warnWithTag(
          _fallbackLogTag,
          '$label background cache write failed',
          e,
        );
      }
      // 内容和顺序都一模一样：只静默刷新了缓存，**不**重建 provider。
      // `invalidateSelf` 会让整块走过一帧 AsyncLoading，即便数据没变，
      // 观感也是闪一下 —— 用户报的就是这个。
      final freshPrint = _payloadFingerprintOf(fresh);
      final previousPrint = _payloadFingerprintOf(previous);
      if (freshPrint != null &&
          previousPrint != null &&
          freshPrint == previousPrint) {
        Logger.debugWithTag(
          _fallbackLogTag,
          '$label background refresh: unchanged, skip rebuild',
        );
        return;
      }
      // 让 provider 重新 emit 新值。启用 cacheFirst 的区块必须同时把
      // `skipLoadingOnRefresh/skipLoadingOnReload` 保持默认（true），否则
      // AsyncLoading(previous) 会让区块闪回一帧骨架。
      ref.invalidateSelf();
      Logger.infoWithTag(_fallbackLogTag, '$label background refresh applied');
    } catch (e) {
      Logger.debugWithTag(
        _fallbackLogTag,
        '$label background refresh failed (silent)',
      );
    }
  }));
}

/// 失败请求触发的加速探测：把它关在 try/catch 里，任何意外都不能从
/// 后台路径裸抛进 zone。
Future<void> _probeActiveQuietly(Ref ref) async {
  try {
    await ref.read(addressPoolProvider).probeActiveThrottled();
  } catch (e) {
    Logger.debugWithTag(_fallbackLogTag, 'on-demand probe skipped', e);
  }
}

/// 「空载荷」判定：空列表 / 空 Map / 空串都视为「缓存里没有可用数据」，
/// 否则首次启动缓存写了个空列表之后，SWR 会一直把空列表当成"有缓存"秒出。
bool _isEmptyPayload(Object? value) {
  if (value == null) return true;
  if (value is Iterable) return value.isEmpty;
  if (value is Map) return value.isEmpty;
  if (value is String) return value.isEmpty;
  return false;
}

/// 载荷指纹：这些模型都没实现 `operator ==`（`==` 比的是对象地址，永远不等），
/// `toString()` 又是 `Instance of 'X'`（永远相等，会把真实变化全部吞掉）。
/// 唯一可信的等值判据是 `toJson()` 序列化后的字符串 —— 数组序列化保留顺序，
/// 所以「顺序变了」天然被判成不相等，正好符合「内容和位置都不变才跳过」。
///
/// 返回 null 表示「无法判断」：调用方必须把 null 当成**不相等**，
/// 否则任何不可序列化的载荷都会永远不再上屏。
String? _payloadFingerprintOf(Object? value) {
  if (value == null) return null;
  try {
    return jsonEncode(value);
  } catch (e) {
    Logger.debugWithTag(_fallbackLogTag, 'payload fingerprint failed', e);
    return null;
  }
}
