import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/utils/logger.dart';
import '../core/utils/network_error_notifier.dart';
import 'api_provider.dart';

const String _fallbackLogTag = 'FETCH';

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
Future<T> fetchWithCacheFallback<T>({
  required Ref ref,
  required String label,
  required Future<T> Function() fetch,
  required Future<void> Function(T data) cacheWrite,
  required Future<T?> Function() cacheRead,
  required StateProvider<bool> failedProvider,
  required String errorMessage,
  required T emptyValue,
}) async {
  try {
    await ref.read(ensureActiveAddressProvider.future);
    final data = await fetch();
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
    T? cached;
    try {
      cached = await cacheRead();
    } catch (e) {
      // 缓存读取本身异常（平台存储/单条坏数据）也不能冒泡成 uncaught，
      // 否则会把一组可恢复的失败放大成整页报错。
      Logger.warnWithTag(_fallbackLogTag, '$label cache read failed', e);
    }
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
