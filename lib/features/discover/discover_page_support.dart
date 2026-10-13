import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/l10n/localizations.dart';
import 'package:musicflow_client/core/utils/network_error_notifier.dart';
import 'package:musicflow_client/providers/library/playlist_provider.dart';
import 'package:musicflow_client/providers/offline/offline_cache_daemon.dart';
import 'package:musicflow_client/providers/player/effective_playback_provider.dart';
import 'package:musicflow_client/providers/player/queue_origin_provider.dart';
import 'package:musicflow_client/providers/ui/locale_provider.dart';
import 'package:musicflow_client/features/discover/pages/search_page.dart';

/// 首页分区共用的卡片布局与播放辅助（从 `discover_page.dart` 抽出，
/// v5.8.4 大页面拆分子组件，行为零变更）。
///
/// 四个分区 widget（最近歌单 / 为你推荐 / 插件推荐 / 平台推荐）与页面本身
/// 共用这些符号；集中于此避免「页面 ↔ 分区」循环 import。

/// 歌单卡片行宽度。
const double kPlaylistCardWidth = 128;

/// 歌单卡片行高度:随文本缩放自适应,避免大字号下溢出。
/// 需容纳:封面(128) + 标题最多 2 行 + 「N 首」副标题。
double playlistRailHeight(BuildContext context) {
  final scale = MediaQuery.textScalerOf(context).scale(1);
  return kPlaylistCardWidth + 56 + ((scale - 1) * 40).clamp(0.0, 56.0);
}

/// 打开全屏搜索页。首页标题行搜索按钮与搜索条共用同一入口，
/// 保证各端搜索功能/逻辑一致（所有输入都在搜索页完成）。
void openSearchPage(BuildContext context) {
  Navigator.of(context).push<void>(
    MusicFlowPageRoute<void>(
      context: context,
      builder: (context) => const SearchPage(),
    ),
  );
}

/// 播放本地歌单（供首页歌单卡封面播放按钮与长按菜单使用）。
/// 加载歌单全部歌曲后整单播放，并记录队列来源为歌单（封面叠加跳动竖条）。
///
/// [coverArtId]/[playlistName] 非空时，顺带把该歌单封面（非动态）写入离线缓存，
/// 供首页断网时离线展示。
Future<void> playLocalPlaylistById(
  WidgetRef ref,
  String playlistId, {
  String? coverArtId,
  String? playlistName,
}) async {
  final loc = l10nNow(ref.read(appLanguageProvider).preference);
  final repository = ref.read(playlistRepositoryProvider);
  if (repository == null) {
    NetworkErrorNotifier.show(loc.discover_no_library_selected);
    return;
  }
  try {
    final songs = await repository.getAllPlaylistSongs(playlistId);
    if (songs.isEmpty) {
      NetworkErrorNotifier.show(loc.discover_playlist_empty);
      return;
    }
    // 缓存歌单封面（非动态）供首页离线展示；动态歌单由 cachePlaylistCover 判定跳过。
    final effectiveCover = (coverArtId != null && coverArtId.isNotEmpty)
        ? coverArtId
        : songs.first.coverArt;
    if (effectiveCover != null && effectiveCover.isNotEmpty) {
      unawaited(
        ref
            .read(offlineCacheDaemonProvider)
            .cachePlaylistCover(effectiveCover, playlistName: playlistName),
      );
    }
    await playEffectiveQueue(
      ref,
      songs,
      startIndex: 0,
      shuffleRandomStart: true,
      origin: QueueOrigin(QueueOriginKind.playlist, playlistId),
    );
  } catch (_) {
    NetworkErrorNotifier.show(loc.discover_network_failed_play_playlist);
  }
}
