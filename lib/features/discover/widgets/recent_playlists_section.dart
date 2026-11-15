import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/library/playlist_provider.dart';
import 'package:musicflow_client/providers/offline/offline_cache_daemon.dart';
import 'package:musicflow_client/providers/player/queue_origin_provider.dart';
import 'package:musicflow_client/features/discover/discover_page_support.dart';
import 'package:musicflow_client/features/discover/widgets/discover_playlist_widgets.dart';
import 'package:musicflow_client/features/discover/widgets/discover_section_message.dart';
import 'package:musicflow_client/features/discover/widgets/hoverable_horizontal_scroll.dart';
import 'package:musicflow_client/features/library/pages/playlist_detail_page.dart';
import 'package:musicflow_client/features/library/widgets/playlist_options_sheet.dart';

/// 最近更新的歌单(横滑卡片行)
///
/// 从 `discover_page.dart` 抽出（v5.8.4 大页面拆分子组件，行为零变更）。
class RecentPlaylistsSection extends ConsumerWidget {
  const RecentPlaylistsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = AppLocalizations.of(context);
    final playlistsAsync = ref.watch(recentPlaylistsProvider);
    final loadFailed = ref.watch(recentPlaylistsLoadFailedProvider);
    // 当前播放来源：识别正在播放的歌单（封面叠加跳动竖条）。
    final queueOrigin = ref.watch(queueOriginProvider);

    // 歌单封面在「展示」时即写离线缓存（非动态歌单），供首页断网离线展示；
    // 动态歌单（今日漫游/每日推荐等）由 cachePlaylistCover 内部判定跳过。
    ref.listen(recentPlaylistsProvider, (_, next) {
      final data = next.valueOrNull;
      if (data == null || data.isEmpty) return;
      final daemon = ref.read(offlineCacheDaemonProvider);
      for (final pl in data) {
        final cover = pl.coverArt?.trim() ?? '';
        if (cover.isEmpty) continue;
        unawaited(daemon.cachePlaylistCover(cover, playlistName: pl.name));
      }
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        MusicFlowSectionHeader.compact(
          title: loc.discover_recent_playlists,
          // 刷新按钮挨着模块标题。
          trailingFollowsTitle: true,
          trailing: MusicFlowIconButton(
            icon: AppIcons.refresh,
            label: loc.discover_refresh_recent_playlists,
            // 刷新途中禁用按钮：区块本身不再因 `invalidateSelf` 闪回骨架
            // （见下方 when 的 skip 参数），点击反馈改由按钮的禁用态承担。
            onPressed: playlistsAsync.isRefreshing
                ? null
                : () => ref.invalidate(recentPlaylistsProvider),
          ),
        ),
        SizedBox(height: context.musicFlowSpacing.xxs),
        // 这两个参数**必须是 true**（原为显式 false）。
        // 批 B 的 cache-first SWR 在后台刷新成功后调 `ref.invalidateSelf()`，
        // 那会产生 `AsyncLoading(previous)`；显式 false 会让整块闪回一帧骨架，
        // 正是历史上「闪一下就空了」的观感。
        //
        // `skipLoadingOnRefresh` 保持**不写**（走默认 true），覆盖上面这种
        // 「自己 invalidate」的场景。
        // `skipLoadingOnReload` 的默认值是 **false**，必须显式置 true：
        // `recentPlaylistsProvider` 内部 `ref.watch(activeAddressProvider)`，
        // 冷启动时地址从「探测中」翻成「ok」会把它推着重建；Riverpod 的默认值
        // 只跳过「自己 invalidate」引起的 loading，**不**跳过「上游依赖变化」
        // 引起的 loading —— 那正是用户报的「连上服务端后闪一下」。
        playlistsAsync.when(
          skipLoadingOnReload: true,
          data: (playlists) {
            if (playlists.isEmpty) {
              // 数据驱动解耦:服务端暂无歌单数据时整块隐藏;仅加载失败才保留
              // 错误提示(可重试),避免空数据/失败占位堆满首屏。
              if (!loadFailed) return const SizedBox.shrink();
              return DiscoverSectionMessage(
                title: loc.discover_section_unavailable_playlist,
                description: loc.discover_error_desc_check_route,
                icon: AppIcons.cloudOff,
                onRetry: () => ref.invalidate(recentPlaylistsProvider),
              );
            }
            return HoverableHorizontalScroll(
              builder: (context, controller) => SizedBox(
                height: playlistRailHeight(context),
                child: ListView.separated(
                  controller: controller,
                  scrollDirection: Axis.horizontal,
                  // 严格视口渲染：只为视口内的封面构建/加载，不为视口外预热。
                  cacheExtent: 0,
                  padding: EdgeInsets.zero,
                  itemCount: playlists.length,
                  separatorBuilder: (context, index) =>
                      SizedBox(width: context.musicFlowSpacing.sm),
                  itemBuilder: (context, index) {
                    final pl = playlists[index];
                    return DiscoverPlaylistCard(
                      // 稳定 key：歌单更新导致排序变化时，Flutter 复用/移动
                      // 未变的卡片，只新建真正新增的，避免整条轨道逐格改写。
                      key: ValueKey<String>('recent-playlist-${pl.id}'),
                      width: kPlaylistCardWidth,
                      title: pl.name,
                      subtitle: loc.discover_track_count('${pl.songCount}'),
                      coverArtId: pl.coverArt,
                      isNowPlaying: queueOrigin?.matchesPlaylist(pl.id) ??
                          false,
                      onLongPress: () => showPlaylistOptionsSheet(
                        context: context,
                        playlist: pl,
                      ),
                      onPlay: () => playLocalPlaylistById(
                            ref,
                            pl.id,
                            coverArtId: pl.coverArt,
                            playlistName: pl.name,
                          ),
                      onPressed: () {
                        Navigator.of(context).push<void>(
                          MusicFlowPageRoute<void>(
                            context: context,
                            builder: (context) => PlaylistDetailPage(
                              playlistId: pl.id,
                              initialName: pl.name,
                              initialSongCount: pl.songCount,
                              initialCoverArt: pl.coverArt,
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
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
            title: loc.discover_recent_playlists_load_failed,
            description: loc.discover_error_desc_switch_route,
            icon: AppIcons.cloudOff,
            onRetry: () => ref.invalidate(recentPlaylistsProvider),
          ),
        ),
      ],
    );
  }
}
