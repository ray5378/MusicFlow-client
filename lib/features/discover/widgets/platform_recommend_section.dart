import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/l10n/localizations.dart';
import 'package:musicflow_client/core/utils/network_error_notifier.dart';
import 'package:musicflow_client/data/models/recommend.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/library/recommend_provider.dart';
import 'package:musicflow_client/providers/ui/locale_provider.dart';
import 'package:musicflow_client/features/discover/discover_page_support.dart';
import 'package:musicflow_client/features/discover/widgets/discover_playlist_widgets.dart';
import 'package:musicflow_client/features/discover/widgets/discover_section_message.dart';
import 'package:musicflow_client/features/discover/widgets/hoverable_horizontal_scroll.dart';
import 'package:musicflow_client/features/library/pages/playlist_detail_page.dart';

/// 打开插件推荐歌单。
/// - **已入库**的歌单（recommend 数据带 imported 标记）：直接经
///   /recommend/local 反查本地 playlistId 打开，**不再重新导入刷新**；
/// - **未入库**的歌单：与主项目一致，先经 /v1/online/:providerId/recommend/import
///   导入（幂等 upsert）拿到真实 library playlistId，再以本地歌单打开播放。
Future<void> openRecommendPlaylist(
  BuildContext context,
  WidgetRef ref,
  String? providerId,
  RecommendPlaylist pl,
) async {
  final loc = AppLocalizations.of(context);
  if (providerId == null || providerId.isEmpty) {
    showMusicFlowToast(context, loc.discover_recommend_service_unavailable);
    return;
  }
  final repo = ref.read(recommendRepositoryProvider);
  if (repo == null) {
    showMusicFlowToast(context, loc.discover_not_connected_library);
    return;
  }

  // 已入库：直接打开本地歌单，跳过导入刷新。
  if (pl.imported) {
    try {
      final localId = await repo.findImportedPlaylistId(providerId, pl.id);
      if (localId != null && localId.isNotEmpty) {
        if (!context.mounted) return;
        Navigator.of(context).push<void>(
          MusicFlowPageRoute<void>(
            context: context,
            builder: (context) => PlaylistDetailPage(playlistId: localId),
          ),
        );
        return;
      }
    } catch (_) {
      // 反查失败则回退到导入流程（幂等，无副作用）。
    }
  }

  ref.read(recommendImportingProvider.notifier).state = pl.id;
  try {
    final playlistId = await repo.importRecommendPlaylist(providerId, <String, dynamic>{
      'source': pl.source,
      'id': pl.id,
      'name': pl.name,
      'cover': pl.cover ?? '',
      'creator': pl.creator,
      'trackCount': pl.trackCount,
      'link': pl.link,
    });
    if (!context.mounted) return;
    Navigator.of(context).push<void>(
      MusicFlowPageRoute<void>(
        context: context,
        builder: (context) => PlaylistDetailPage(playlistId: playlistId),
      ),
    );
  } catch (e) {
    if (context.mounted) {
      final msg = e is Exception ? e.toString().replaceFirst('Exception: ', '') : '$e';
      showMusicFlowToast(context, loc.discover_import_playlist_failed(msg));
    }
  } finally {
    ref.read(recommendImportingProvider.notifier).state = null;
  }
}

/// 播放插件推荐歌单（封面播放按钮）。
/// - **已入库**：直接反查本地 playlistId 后整单播放，不再导入刷新；
/// - **未入库**：先经 /v1/online/:providerId/recommend/import 幂等导入，
///   拿到真实 library playlistId 再整单播放（与 [openRecommendPlaylist] 同链路）。
Future<void> playRecommendPlaylist(
  WidgetRef ref,
  String? providerId,
  RecommendPlaylist pl,
) async {
  final loc = l10nNow(ref.read(appLanguageProvider).preference);
  if (providerId == null || providerId.isEmpty) {
    NetworkErrorNotifier.show(loc.discover_recommend_service_unavailable);
    return;
  }
  final repo = ref.read(recommendRepositoryProvider);
  if (repo == null) {
    NetworkErrorNotifier.show(loc.discover_not_connected_library);
    return;
  }
  try {
    String? localId;
    if (pl.imported) {
      try {
        localId = await repo.findImportedPlaylistId(providerId, pl.id);
      } catch (_) {
        // 反查失败则回退到导入流程（幂等，无副作用）。
      }
    }
    localId ??= await repo.importRecommendPlaylist(providerId, <String, dynamic>{
      'source': pl.source,
      'id': pl.id,
      'name': pl.name,
      'cover': pl.cover ?? '',
      'creator': pl.creator,
      'trackCount': pl.trackCount,
      'link': pl.link,
    });
    if (localId.isEmpty) {
      NetworkErrorNotifier.show(loc.discover_import_no_valid_id);
      return;
    }
    await playLocalPlaylistById(ref, localId);
  } catch (e) {
    final msg =
        e is Exception ? e.toString().replaceFirst('Exception: ', '') : '$e';
    NetworkErrorNotifier.show(loc.discover_play_playlist_failed(msg));
  }
}

/// 插件推荐(原「平台推荐」):不同插件提供方(网易云/QQ 等)的推荐歌单,
/// 整体上下滚动不同平台,同一平台内歌单横向滑动(与网页一致)。
///
/// 从 `discover_page.dart` 抽出（v5.8.4 大页面拆分子组件，行为零变更）。
class PlatformRecommendSection extends ConsumerWidget {
  const PlatformRecommendSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = AppLocalizations.of(context);
    final channelsAsync = ref.watch(recommendChannelsProvider);
    final loadFailed = ref.watch(recommendChannelsLoadFailedProvider);
    final providerId = ref.watch(recommendProviderIdProvider).valueOrNull;
    final importingId = ref.watch(recommendImportingProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        MusicFlowSectionHeader.compact(
          title: loc.discover_platform_recommend,
        ),
        SizedBox(height: context.musicFlowSpacing.xxs),
        channelsAsync.when(
          skipLoadingOnRefresh: false,
          skipLoadingOnReload: false,
          data: (result) {
            final channels = result.channels;
            final allPlaylists =
                channels.expand((c) => c.playlists).toList();
            if (allPlaylists.isEmpty) {
              // 数据驱动解耦:服务端暂无插件推荐数据时整块隐藏;仅加载失败才保留
              // 错误提示(可重试),避免空数据/失败占位堆满首屏。
              if (!loadFailed) return const SizedBox.shrink();
              return DiscoverSectionMessage(
                title: loc.discover_unavailable_platform,
                description: loc.discover_error_desc_check_route,
                icon: AppIcons.cloudOff,
                onRetry: () => ref.invalidate(recommendChannelsProvider),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (final channel in channels) ...<Widget>[
                  if (channels.length > 1) ...<Widget>[
                    SizedBox(height: context.musicFlowSpacing.sm),
                    Text(
                      channel.name,
                      style: context.musicFlowTypography.label.copyWith(
                        color: context.musicFlowColors.accent,
                      ),
                    ),
                    SizedBox(height: context.musicFlowSpacing.xxs),
                  ],
                  if (channel.playlists.isNotEmpty)
                    HoverableHorizontalScroll(
                      builder: (context, controller) => SizedBox(
                        height: playlistRailHeight(context),
                        child: ListView.separated(
                          controller: controller,
                          scrollDirection: Axis.horizontal,
                          // 严格视口渲染：只为视口内的封面构建/加载，不为视口外预热。
                          cacheExtent: 0,
                          padding: EdgeInsets.zero,
                          itemCount: channel.playlists.length,
                          separatorBuilder: (context, index) =>
                              SizedBox(width: context.musicFlowSpacing.sm),
                          itemBuilder: (context, index) {
                            final pl = channel.playlists[index];
                            final isImporting = importingId == pl.id;
                            return DiscoverPlaylistCard(
                              width: kPlaylistCardWidth,
                              title: pl.name,
                              subtitle: pl.trackCount.isNotEmpty
                                  ? loc.discover_track_count(pl.trackCount)
                                  : null,
                              coverUrl: pl.cover,
                              loading: isImporting,
                              onPressed: isImporting
                                  ? () {}
                                  : () => openRecommendPlaylist(
                                        context,
                                        ref,
                                        providerId,
                                        pl,
                                      ),
                              // 封面右下角播放按钮：未入库先幂等导入再整单播放。
                              onPlay: isImporting
                                  ? null
                                  : () => playRecommendPlaylist(
                                        ref,
                                        providerId,
                                        pl,
                                      ),
                            );
                          },
                        ),
                      ),
                    ),
                ],
              ],
            );
          },
          loading: () => SizedBox(
            height: playlistRailHeight(context),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.zero,
              itemCount: 4,
              separatorBuilder: (context, index) =>
                  SizedBox(width: context.musicFlowSpacing.sm),
              itemBuilder: (context, index) =>
                  DiscoverPlaylistCardLoading(width: kPlaylistCardWidth),
            ),
          ),
          error: (error, stackTrace) => DiscoverSectionMessage(
            title: loc.discover_platform_load_failed,
            description: loc.discover_error_desc_switch_route,
            icon: AppIcons.cloudOff,
            onRetry: () => ref.invalidate(recommendChannelsProvider),
          ),
        ),
      ],
    );
  }
}
