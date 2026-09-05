import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/design/music_flow_design.dart';
import '../core/utils/cover_ref_security.dart';
import '../data/models/server_address.dart';
import '../l10n/generated/app_localizations.dart';
import '../providers/api_provider.dart';
import '../providers/offline_provider.dart';

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

  @override
  void dispose() {
    _retryTimer?.cancel();
    super.dispose();
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
    // 不被旧地址的失败状态锁死。
    if (_lastUrl != coverUrl) {
      _lastUrl = coverUrl;
      _attempt = 0;
      _retryTimer?.cancel();
    }

    if (!serverReady) {
      return _buildPlaceholder(context, isLoading: true);
    }

    return _buildNetworkImage(context, coverUrl, resolvedCoverSize);
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
          return Semantics(
            image: true,
            label: loadedLabel,
            child: ExcludeSemantics(child: child),
          );
        },
        errorBuilder: (context, error, stackTrace) {
          // 失败自动重试兜底：指数退避后重发，覆盖服务器刚就绪/线路
          // 切换/偶发网络抖动导致的封面不稳定。
          _scheduleRetry();
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