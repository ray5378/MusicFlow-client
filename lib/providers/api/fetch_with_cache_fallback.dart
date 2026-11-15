import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/utils/logger.dart';
import 'package:musicflow_client/core/utils/network_error_notifier.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';

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
/// [budget] 是这一次远程加载的**总**预算：与拦截器里按帧计算的
/// `connectTimeout` / `receiveTimeout` 无关，它兜的是「重试叠加后的长尾」。
/// 各区块可按数据体量单独放宽（全量歌单 317KB 级给 8s）。
Future<T> fetchWithCacheFallback<T>({
  required Ref ref,
  required String label,
  required Future<T> Function() fetch,
  required Future<void> Function(T data) cacheWrite,
  required Future<T?> Function() cacheRead,
  required StateProvider<bool> failedProvider,
  required String errorMessage,
  required T emptyValue,
  Duration budget = kDefaultRequestBudget,
}) async {
  try {
    await ref.read(ensureActiveAddressProvider.future);
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
    unawaited(_probeActiveQuietly(ref));
    final cached = await _readCacheQuietly(label, cacheRead);
    if (cached != null) {
      ref.read(failedProvider.notifier).state = false;
      Logger.infoWithTag(_fallbackLogTag, '$label fallback to cache');
      return cached;
    }
    // 远程失败且无缓存兜底，才向用户提示网络异常。
    NetworkErrorNotifier.show(errorMessage);
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

/// 失败请求触发的加速探测：把它关在 try/catch 里，任何意外都不能从
/// 后台路径裸抛进 zone。
Future<void> _probeActiveQuietly(Ref ref) async {
  try {
    await ref.read(addressPoolProvider).probeActiveThrottled();
  } catch (e) {
    Logger.debugWithTag(_fallbackLogTag, 'on-demand probe skipped', e);
  }
}
