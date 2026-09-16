import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/utils/cover_ref_security.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/offline/offline_provider.dart';

/// 全局封面并发闸门：把同时进行的网络封面请求数封顶在一个小值。
///
/// 背景：每个网络封面都走 Flutter 的 [Image.network]，而其 `NetworkImage` 在
/// **每次请求时都会 `new HttpClient()` 并在加载完成后 `close()`**——不同封面之间
/// 没有任何 keep-alive 连接复用。于是「播放大歌单」时，队列/歌单里一屏所能构建的
/// ~50 个封面会一次性打出 ~50 条独立 HTTPS 连接（并各自缓冲解码头 → 内存暴涨）。
///
/// 该闸门在 `CoverArtImage`（所有封面都必经的单一漏斗）把「同时真正发起网络请求的
/// 封面」限为 [maxConcurrent]（默认 6）：未获得槽位的封面先渲染同尺寸骨架占位，
/// 等前一批封面出帧（或滑出视口销毁）释放槽位后再补齐真封面。这样即便列表一屏构建
/// 了 50 个封面，同时在途连接也被封顶，杜绝 ~50 条并发。
class _CoverRequestGate {
  _CoverRequestGate(this.maxConcurrent);

  final int maxConcurrent;
  final Set<_CoverArtImageState> _active = <_CoverArtImageState>{};
  final List<_CoverArtImageState> _queued = <_CoverArtImageState>[];

  /// 尝试为 [state] 获取并发槽位。成功返回 true（进入加载），否则排队等待。
  bool acquire(_CoverArtImageState state) {
    if (_active.length < maxConcurrent) {
      _active.add(state);
      return true;
    }
    _queued.add(state);
    return false;
  }

  /// 释放 [state] 持有的槽位（或从等待队列移除），并顺带派发下一个排队者。
  void release(_CoverArtImageState state) {
    _queued.remove(state);
    if (_active.remove(state)) _drain();
  }

  void _drain() {
    while (_active.length < maxConcurrent && _queued.isNotEmpty) {
      final next = _queued.removeAt(0);
      _active.add(next);
      // 延迟到帧回调放行：release 可能发生在任意阶段（含构建/布局），
      // 直接 setState 会触发「setState during build」。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        next.grantCoverSlot();
      });
    }
  }
}

/// 全应用共享的封面并发闸门。上限 6：既压住 ~50 条并发连接，又保证滚动时封面能
/// 稳定补齐（比 4 更宽松，接近主流连接池每主机上限）。
final _coverRequestGate = _CoverRequestGate(6);

/// 网络封面图。
///
/// 冷启动兜底刷新策略（三层）：
/// 1. **就绪兜底**：地址探测未完成（status != ok）不发起请求，等后台连接
///    服务器成功后组件随 `activeAddressProvider` 重建再请求，避免冷启动
///    一堆失败请求与占位闪变（SPEC §8.3 时机控制配套）。
/// 2. **失败自动重试**：单次加载失败后指数退避重试（1s / 2s，共 3 次尝试），
///    用带尝试次数的 key 强制重新请求，覆盖服务器刚就绪 / 线路切换 /
///    偶发网络抖动导致的封面不稳定。
/// 3. **地址/封面变化重置**：URL 变化（切线路导致 baseUrl 变化、封面 id
///    变化）时重置重试计数，保证新地址的封面不被旧失败状态锁死。
///
/// 离线回退：`alwaysFresh == false`（默认）时，离线状态下先查本地缓存
/// （歌曲封面 `cover` / 歌单封面 `playlistCover`），命中则 `Image.file` 渲染；
/// 未命中走占位图。`alwaysFresh == true`（动态歌单封面）时**绝不读写缓存**，
/// 保证冷启动每次重拉。
class CoverArtImage extends ConsumerStatefulWidget {
  final String? coverArtId;
  final double? size;
  final int? requestSize;
  final BoxFit fit;
  final String? semanticLabel;
  /// 动态封面（今日漫游/每日推荐/随机歌曲等）传 true：不读不写离线缓存，每次冷启动重拉。
  final bool alwaysFresh;

  const CoverArtImage({
    super.key,
    required this.coverArtId,
    this.size,
    this.requestSize,
    this.fit = BoxFit.cover,
    this.semanticLabel,
    this.alwaysFresh = false,
  });

  @override
  ConsumerState<CoverArtImage> createState() => _CoverArtImageState();
}

class _CoverArtImageState extends ConsumerState<CoverArtImage> {
  /// 最大尝试次数：首次 + 2 次重试。
  static const int _maxAttempts = 3;
  int _attempt = 0;
  Timer? _retryTimer;
  String? _lastUrl;

  /// 并发闸门相关状态（见 [_CoverRequestGate]）。
  bool _slotGranted = false; // 当前是否已持有并发槽位（正在/即将真正发网络请求）
  bool _slotQueued = false; // 是否已在闸门等待队列（防重复入队）
  bool _everShownNetwork = false; // 是否已经渲染过一次真封面（之后走缓存，无需再占槽）
  bool _slotReleaseScheduled = false; // 首帧后的槽位释放是否已安排（防重复释放）

  @override
  void dispose() {
    _retryTimer?.cancel();
    _coverRequestGate.release(this);
    super.dispose();
  }

  /// 由并发闸门派发：成功拿到槽位，放行真封面（下一帧起渲染网络图）。
  void grantCoverSlot() {
    if (!mounted) {
      _coverRequestGate.release(this);
      return;
    }
    setState(() {
      _slotGranted = true;
      _slotQueued = false;
    });
  }

  /// 请求一个并发槽位；成功则同步置位，失败则加入闸门等待队列。
  void _requestCoverSlot() {
    if (!mounted || _slotGranted || _everShownNetwork || _slotQueued) return;
    if (_coverRequestGate.acquire(this)) {
      _slotGranted = true;
    } else {
      _slotQueued = true;
    }
  }

  /// 释放当前持有的槽位（或从闸门等待队列移除）。渲染中的缓存封面不占槽位。
  void _releaseCoverSlot() {
    _coverRequestGate.release(this);
    _slotGranted = false;
    _slotQueued = false;
  }

  /// 首个完整帧渲染后（或首次加载失败后）安排放行槽位，把并发额度让给下一批封面。
  /// [markShown] 仅成功出帧时置 `_everShownNetwork`，之后本封面走缓存不再占槽。
  void _scheduleSlotRelease({required bool markShown}) {
    if (_slotReleaseScheduled) return;
    _slotReleaseScheduled = true;
    final expectedUrl = _lastUrl;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _slotReleaseScheduled = false;
      // URL 已切换：这个回调属于旧封面，交给新 URL 的构建流程重新走闸门。
      if (!mounted || _lastUrl != expectedUrl) {
        _releaseCoverSlot();
        return;
      }
      if (markShown) _everShownNetwork = true;
      _releaseCoverSlot();
    });
  }

  /// 加载失败：未到上限则指数退避（1s / 2s）后重试一次。
  void _scheduleRetry() {
    if (!mounted || _attempt >= _maxAttempts - 1) return;
    final delay = Duration(seconds: 1 << _attempt);
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      if (!mounted) return;
      setState(() => _attempt += 1);
    });
  }

  @override
  Widget build(BuildContext context) {
    // 监听活跃地址变化：地址池探测/切线路完成后 baseUrl 就绪，封面 URL 依赖
    // dio.options.baseUrl，必须随地址重建，否则首屏占位后永不刷新（30da0e7 回归）。
    final address = ref.watch(activeAddressProvider);
    // 缓存就绪时重建，避免冷启动离线时首帧未命中缓存。
    ref.watch(offlineCacheReadyProvider);
    // 冷启动地址探测未完成前不发起封面请求：等后台连接服务器成功
    // （status=ok）后本组件随 provider 重建，再真正请求封面。
    final serverReady = address?.status == ServerAddressStatus.ok;

    final raw = widget.coverArtId?.trim() ?? '';
    if (raw.isEmpty) {
      return _buildPlaceholder(context);
    }

    final apiClient = ref.watch(subsonicApiClientProvider);
    final resolvedCoverSize = _resolveCoverSize(context);
    String? coverUrl;

    final trustedCoverUrl = extractTrustedCoverUrl(raw);
    if (trustedCoverUrl != null) {
      coverUrl = apiClient.getCoverArtUrl(
        trustedCoverUrl,
        size: resolvedCoverSize,
      );
    } else {
      final safeCoverArtId = sanitizeServerCoverArtId(raw);
      if (safeCoverArtId == null) {
        return _buildPlaceholder(context);
      }
      coverUrl = apiClient.getCoverArtUrl(
        safeCoverArtId,
        size: resolvedCoverSize,
      );
    }

    if (coverUrl.isEmpty) {
      return _buildPlaceholder(context);
    }

    // 离线回退：非动态封面且离线时，优先读本地缓存（歌曲封面 / 歌单封面）。
    if (!widget.alwaysFresh && ref.read(isOfflineProvider)) {
      final cache = ref.read(offlineCacheManagerProvider);
      final cached = cache.coverFile(raw) ?? cache.playlistCoverFile(raw);
      if (cached != null && cached.existsSync()) {
        return _buildCachedImage(context, cached, resolvedCoverSize);
      }
    }

    // URL 变化（切线路 / 换封面）：重置重试计数，让新地址的封面立即重试，
    // 不被旧地址的失败状态锁死。同时释放旧封面占用的并发槽位并重置闸门状态。
    if (_lastUrl != coverUrl) {
      _lastUrl = coverUrl;
      _attempt = 0;
      _retryTimer?.cancel();
      _coverRequestGate.release(this);
      _slotGranted = false;
      _slotQueued = false;
      _everShownNetwork = false;
      _slotReleaseScheduled = false;
    }

    if (!serverReady) {
      return _buildPlaceholder(context, isLoading: true);
    }

    return _buildGatedNetworkImage(context, coverUrl, resolvedCoverSize);
  }

  /// 经由全局并发闸门渲染网络封面：未拿到槽位前渲染骨架占位，不发起网络请求。
  Widget _buildGatedNetworkImage(
    BuildContext context,
    String imageUrl,
    int cacheSize,
  ) {
    // 已展示过真封面（走 ImageCache 命中，瞬时完成）不再占任何槽位。
    if (!_everShownNetwork) {
      _requestCoverSlot(); // 可能同步拿到槽位（_slotGranted=true），也可能入队等待
      if (!_slotGranted) {
        // 并发额度已满：先渲染同尺寸骨架，等闸门释放后由 grantCoverSlot 放行。
        return _buildPlaceholder(context, isLoading: true);
      }
    }
    return _buildNetworkImage(context, imageUrl, cacheSize);
  }

  int _resolveCoverSize(BuildContext context) {
    if (widget.requestSize != null && widget.requestSize! > 0) {
      return widget.requestSize!;
    }

    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    if (widget.size != null && !widget.size!.isInfinite) {
      return (widget.size! * devicePixelRatio).ceil();
    }
    return 500;
  }

  Widget _buildNetworkImage(
    BuildContext context,
    String imageUrl,
    int cacheSize,
  ) {
    final loc = AppLocalizations.of(context);
    final loadedLabel = widget.semanticLabel ?? loc.widgets_cover_art_album;
    return RepaintBoundary(
      child: Image.network(
        imageUrl,
        // 带尝试次数的 key：重试时强制重建并重新发起网络请求
        // （ImageCache 失败不缓存，同 key 不会自动重发）。
        key: ValueKey<String>('$imageUrl#$_attempt'),
        width: widget.size,
        height: widget.size,
        fit: widget.fit,
        // 限制解码尺寸（物理像素）：避免按远超显示需求的原图尺寸解码/缓存，
        // 降低内存占用与解码耗时；ResizeImage 等比缩放，不影响显示效果。
        cacheWidth: cacheSize,
        cacheHeight: cacheSize,
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          if (frame == null) {
            return _buildPlaceholder(
              context,
              isLoading: true,
              accessibilityLabel: loadedLabel,
            );
          }
          // 首个完整帧出帧：释放并发槽位，让额度给下一批封面继续加载。
          _scheduleSlotRelease(markShown: true);
          return Semantics(
            image: true,
            label: loadedLabel,
            child: ExcludeSemantics(child: child),
          );
        },
        errorBuilder: (context, error, stackTrace) {
          // 失败自动重试兜底：指数退避后重发，覆盖服务器刚就绪/线路
          // 切换/偶发网络抖动导致的封面不稳定。失败也放行槽位，避免
          // 失败封面霸占额度、阻塞队列里其它封面。
          _scheduleRetry();
          _scheduleSlotRelease(markShown: false);
          final label = widget.semanticLabel;
          return _buildPlaceholder(
            context,
            accessibilityLabel: label == null
                ? loc.widgets_cover_art_load_failed
                : loc.widgets_cover_art_load_failed_with_label(label),
          );
        },
      ),
    );
  }

  Widget _buildCachedImage(
    BuildContext context,
    File file,
    int cacheSize,
  ) {
    final loc = AppLocalizations.of(context);
    final loadedLabel = widget.semanticLabel ?? loc.widgets_cover_art_album;
    return RepaintBoundary(
      child: Image.file(
        file,
        width: widget.size,
        height: widget.size,
        fit: widget.fit,
        cacheWidth: cacheSize,
        cacheHeight: cacheSize,
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          if (frame == null) {
            return _buildPlaceholder(
              context,
              isLoading: true,
              accessibilityLabel: loadedLabel,
            );
          }
          return Semantics(
            image: true,
            label: loadedLabel,
            child: ExcludeSemantics(child: child),
          );
        },
        errorBuilder: (context, error, stackTrace) {
          return _buildPlaceholder(
            context,
            accessibilityLabel: loc.widgets_cover_art_load_failed,
          );
        },
      ),
    );
  }

  Widget _buildPlaceholder(
    BuildContext context, {
    bool isLoading = false,
    bool semantic = true,
    String? accessibilityLabel,
  }) {
    final loc = AppLocalizations.of(context);
    final bgColor = context.musicFlowColors.raised;
    final placeholder = SizedBox(
      width: widget.size,
      height: widget.size,
      child: isLoading
          ? _buildLoadingSkeleton()
          : ColoredBox(
              color: bgColor,
              child: Center(
                child: Icon(
                  AppIcons.music,
                  size: _getIconSize(),
                  color: context.musicFlowColors.muted,
                ),
              ),
            ),
    );

    if (!semantic) return placeholder;

    return Semantics(
      image: true,
      label:
          accessibilityLabel ??
          (isLoading
              ? loc.widgets_cover_art_loading
              : widget.semanticLabel ?? loc.widgets_cover_art_none),
      child: ExcludeSemantics(child: placeholder),
    );
  }

  Widget _buildLoadingSkeleton() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final boundedWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : null;
        final boundedHeight = constraints.hasBoundedHeight
            ? constraints.maxHeight
            : null;
        final fallbackExtent = boundedWidth ?? boundedHeight ?? 48.0;

        return MusicFlowSkeleton(
          width: widget.size ?? boundedWidth ?? fallbackExtent,
          height: widget.size ?? boundedHeight ?? fallbackExtent,
          borderRadius: BorderRadius.zero,
        );
      },
    );
  }

  double? _getIconSize() {
    if (widget.size == null || widget.size!.isInfinite) {
      return 48;
    }
    return widget.size! * 0.5;
  }
}