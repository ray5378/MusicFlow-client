import 'package:flutter/material.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/features/library/pages/album_list_page.dart';
import 'package:musicflow_client/features/settings/pages/offline_cached_songs_page.dart';
import 'package:musicflow_client/features/library/pages/artist_list_page.dart';
import 'package:musicflow_client/features/library/pages/playlist_search_page.dart';
import 'package:musicflow_client/features/library/pages/song_list_page.dart';
import 'package:musicflow_client/features/library/pages/starred_page.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/features/discover/pages/search_page.dart';


/// 顶部分类导航条(可左右滑动):探索/喜欢/歌单/歌曲/艺术家/专辑
class CategoryNavBar extends StatelessWidget {
  const CategoryNavBar({super.key});

  static List<(String, IconData, Widget)> _items(AppLocalizations loc) =>
      <(String, IconData, Widget)>[
    // 探索：原首页标题行右侧搜索按钮移入库导航第一位(v3.4.62)，
    // 样式与库按钮一致(accent 图标 + 下方文字标注)。
        (loc.discover_explore, AppIcons.search, const SearchPage()),
        (loc.discover_category_favorites, AppIcons.heart, const StarredPage()),
        (loc.discover_category_playlists, AppIcons.playlist, const PlaylistSearchPage()),
        (loc.discover_category_songs, AppIcons.music, const SongListPage()),
        (loc.discover_category_artists, AppIcons.profile, const ArtistListPage()),
        (loc.discover_category_albums, AppIcons.album, const AlbumListPage()),
        (loc.offline_cache_cached_songs_title, AppIcons.offline, const OfflineCachedSongsPage()),
      ];

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final items = _items(loc);
    return Semantics(
      label: loc.discover_category_nav,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(
          horizontal: context.musicFlowPageHorizontalPadding - 5,
          vertical: context.musicFlowSpacing.xs,
        ),
        child: Row(
          children: <Widget>[
            for (var i = 0; i < items.length; i++) ...<Widget>[
              if (i > 0)
                SizedBox(width: context.musicFlowSpacing.md),
              _CategoryNavItem(
                label: items[i].$1,
                icon: items[i].$2,
                onPressed: () {
                  Navigator.of(context).push<void>(
                    MusicFlowPageRoute<void>(
                      context: context,
                      builder: (context) => items[i].$3,
                    ),
                  );
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CategoryNavItem extends StatelessWidget {
  const _CategoryNavItem({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: MusicFlowPressable(
        onPressed: onPressed,
        minimumSize: const Size(64, 64),
        borderRadius: context.musicFlowRadii.surface,
        child: SizedBox(
          width: 64,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 26, color: context.musicFlowColors.accent),
              SizedBox(height: context.musicFlowSpacing.xxs),
              Text(
                label,
                style: context.musicFlowTypography.metadata,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
