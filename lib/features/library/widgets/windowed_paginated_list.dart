import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// 全库统一的「窗口化分块加载 + 稀疏缓存 + 窗口外剪枝」,与 Web 前端
/// useInfiniteList / useCardGrid 同构,供客户端行式列表与卡片网格共用:
/// - 服务端按 page/pageSize 分页,一次只拉一块(pageSize 条),内存峰值恒定;
/// - 以「全长稀疏数组」为共享缓存(idx → item,未加载槽位为 null),渲染层只取
///   视口窗口渲染,占位槽等待块到达后填充;
/// - 随滚动按块预取;窗口移动超过 keepPages 后,把范围外的整块槽位置 null 释放,
///   保证缓存不随浏览过的条目数增长(对齐 Web 的内存优化)。
class WindowedPaginatedList<T> extends ChangeNotifier {
  final Future<({List<T> items, int total})> Function(
    int page,
    int pageSize,
    String query,
  ) fetcher;
  final int pageSize;
  final int keepPages;
  final int concurrency;

  WindowedPaginatedList({
    required this.fetcher,
    this.pageSize = 200,
    this.keepPages = 2,
    this.concurrency = 3,
    String query = '',
  }) : _query = query;

  String _query;
  List<T?> _slots = <T?>[];
  int _total = 0;
  bool _loading = false;
  Object? _error;

  final Set<int> _loaded = <int>{};
  final Set<int> _inflight = <int>{};
  int _seq = 0;

  List<T?> get slots => _slots;
  int get total => _total;
  bool get loading => _loading;
  Object? get error => _error;
  bool get hasError => _error != null;

  T? operator [](int index) =>
      (index >= 0 && index < _slots.length) ? _slots[index] : null;

  /// 重置并以新 query 重新加载(排序变化也走此,调用方在 fetcher 闭包中携带 sort)。
  void load(String query) {
    _query = query;
    _seq++;
    _loaded.clear();
    _inflight.clear();
    _slots = <T?>[];
    _total = 0;
    _loading = true;
    _error = null;
    notifyListeners();
    _ensurePage(0);
  }

  void retry() => load(_query);

  /// 渲染层滚动通知进入[可见全局行区间];同时负责预取与剪枝。
  void ensureRange(int start, int end) {
    if (_total <= 0) return;
    final first = math.max(0, start) ~/ pageSize;
    final last = math.min(_total - 1, end) ~/ pageSize;
    // 剪枝:窗口 ± keepPages 外的旧块置 null 并移除「已加载」标记。
    if (_loaded.isNotEmpty) {
      final pruneFirst = first - keepPages;
      final pruneLast = last + keepPages;
      for (final p in <int>{..._loaded}) {
        if (p < pruneFirst || p > pruneLast) {
          _nullPage(p);
          _loaded.remove(p);
        }
      }
    }
    for (int p = first; p <= last; p++) {
      _ensurePage(p);
    }
  }

  void _ensurePage(int page) {
    if (page < 0) return;
    if (_inflight.contains(page) || _loaded.contains(page)) return;
    if (_inflight.length >= concurrency) return; // 被并发限流,等块到达后续拉
    _inflight.add(page);
    final mySeq = _seq;
    _fetchPage(page, mySeq);
  }

  Future<void> _fetchPage(int page, int mySeq) async {
    try {
      final res = await fetcher(page + 1, pageSize, _query);
      if (mySeq != _seq) return; // 已被 load/retry 作废
      _inflight.remove(page);
      _total = res.total;
      _growTo(_total);
      final base = page * pageSize;
      for (int j = 0; j < res.items.length; j++) {
        final idx = base + j;
        if (idx < _slots.length) _slots[idx] = res.items[j];
      }
      _loaded.add(page);
      _loading = false;
      _error = null;
      // 首块到达后预取初始可见窗口(列表此时才拿到 total 开始布局)。
      if (page == 0) ensureRange(0, math.min(_total - 1, 40));
      notifyListeners();
    } catch (e) {
      if (mySeq != _seq) return;
      _inflight.remove(page);
      _error = e;
      _loading = false;
      notifyListeners();
    }
  }

  void _growTo(int n) {
    if (_slots.length >= n) return;
    final next = List<T?>.filled(n, null);
    for (int i = 0; i < _slots.length; i++) {
      next[i] = _slots[i];
    }
    _slots = next;
  }

  void _nullPage(int page) {
    final base = page * pageSize;
    for (int j = 0; j < pageSize; j++) {
      final idx = base + j;
      if (idx < _slots.length) _slots[idx] = null;
    }
  }
}
