import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/search.dart';
import '../../data/repositories/search_repository.dart';
import '../../providers/effective_playback_provider.dart';
import '../../providers/player_provider.dart';
import '../../providers/playlist_provider.dart';
import '../../providers/search_provider.dart';
import '../../core/design/components/music_flow_message.dart';
import '../../core/utils/toast_notifier.dart';
import '../../l10n/generated/app_localizations.dart';

void _toast(BuildContext context, String message, {bool error = false}) {
  if (!context.mounted) return;
  showMusicFlowToast(
    context,
    message,
    kind: error ? MusicFlowMessageKind.error : MusicFlowMessageKind.info,
  );
}

/// 后台监听入库任务:不阻塞任何 UI,完成后经全局 ToastNotifier 通知。
///
/// 提交成功后 fire-and-forget 调用;页面此时可能已被关闭/切换,
/// 因此完成通知走根导航器 Overlay(ToastNotifier)而不是页面 context。
///
/// 成功完成时可由 [onSuccess] 回调执行后续动作(例如刷新「最近更新的歌单」),
/// 回调通过参数传入以避免本页直接持有具体 WidgetRef。
void _watchImportTask(
  SearchRepository repo,
  String taskId,
  String label,
  AppLocalizations loc, {
  void Function(Map<String, dynamic> result)? onSuccess,
}) {
  unawaited(
    repo.waitTask(taskId).then((result) {
      ToastNotifier.show(loc.search_import_done(label));
      onSuccess?.call(result);
    }).catchError((Object e) {
      ToastNotifier.show(loc.search_import_entry_failed(label, '$e'), kind: MusicFlowMessageKind.error);
    }),
  );
}

/// 直接播放一首远程搜索歌曲(走 /rest/stream-remote)
Future<void> playRemoteSearchSong(
  BuildContext context,
  WidgetRef ref,
  SearchSong song,
) async {
  final loc = AppLocalizations.of(context);
  final repo = ref.read(searchRepositoryProvider);
  if (repo == null) return;
  try {
    final playSong = repo.buildRemoteSong(song);
    await ref.read(playerProvider.notifier).playPreviewSong(playSong);
  } catch (e) {
    _toast(context, loc.search_play_failed('$e'), error: true);
  }
}

/// 拉取远程专辑/艺术家/歌单内部歌曲并直接播放
Future<void> playRemoteSearchCollection(
  BuildContext context,
  WidgetRef ref,
  SearchEntityKind kind,
  String providerId,
  SearchSongLike item, {
  SearchPlaylist? playlist,
}) async {
  final loc = AppLocalizations.of(context);
  final repo = ref.read(searchRepositoryProvider);
  if (repo == null) return;
  if (providerId.isEmpty) {
    _toast(context, loc.search_source_not_specified, error: true);
    return;
  }
  try {
    final songs = kind == SearchEntityKind.playlist
        ? await repo.getPlaylistSongs(
            providerId,
            playlist ?? (item as SearchPlaylist),
          )
        : await repo.getCollectionSongs(kind, providerId, item);
    if (songs.isEmpty) {
      _toast(context, loc.search_entity_no_playable(_kindLabel(kind, loc)));
      return;
    }
    await playEffectiveQueue(ref, songs, startIndex: 0);
  } catch (e) {
    _toast(context, loc.search_play_failed('$e'), error: true);
  }
}

/// 把远程歌曲加入本地库(触发即返回,后台监听完成)
Future<void> importSearchSong(
  BuildContext context,
  WidgetRef ref,
  SearchSong song,
) async {
  final loc = AppLocalizations.of(context);
  final repo = ref.read(searchRepositoryProvider);
  if (repo == null) return;
  try {
    final taskId = await repo.importSong(song.providerId, [song]);
    _toast(context, loc.search_import_submitted);
    _watchImportTask(repo, taskId, song.name, loc);
  } catch (e) {
    _toast(context, loc.search_import_failed('$e'), error: true);
  }
}

/// 把远程专辑加入本地库(以专辑歌单形式;触发即返回,后台监听完成)
Future<void> importSearchAlbum(
  BuildContext context,
  WidgetRef ref,
  SearchAlbum album,
) async {
  final loc = AppLocalizations.of(context);
  final repo = ref.read(searchRepositoryProvider);
  if (repo == null) return;
  try {
    final taskId = await repo.importAlbum(album.providerId, album);
    _toast(context, loc.search_import_submitted);
    _watchImportTask(repo, taskId, album.name, loc);
  } catch (e) {
    _toast(context, loc.search_import_failed('$e'), error: true);
  }
}

/// 把远程歌单加入本地库(**触发即返回,全程不阻塞 UI**)。
///
/// 只做一次 POST 提交(秒回),不弹任何等待遮罩;拉歌+入库由后端异步完成,
/// 期间用户可继续任何操作,完成后经全局 Toast 通知成功/失败。
///
/// 成功后**自动刷新「最近更新的歌单」**——入库完成的歌单在本地音乐库可用了,
/// 应当立即出现在首页最近更新列表,避免用户切回首页还看不到自己刚入库的内容。
Future<void> importSearchPlaylist(
  BuildContext context,
  WidgetRef ref,
  SearchPlaylist pl,
) async {
  final loc = AppLocalizations.of(context);
  final repo = ref.read(searchRepositoryProvider);
  if (repo == null) return;
  if (pl.providerId.isEmpty) {
    _toast(context, loc.search_source_not_specified, error: true);
    return;
  }
  try {
    final taskId = await repo.startPlaylistImport(pl.providerId, pl);
    _toast(context, loc.search_playlist_import_submitted(pl.name));
    _watchImportTask(
      repo,
      taskId,
      pl.name,
      loc,
      // 后台回调:拿到一个独立 ref(ProviderContainer 不会随页面销毁而失效),
      // 让最近更新歌单下一次被读时重新加载,把刚入库的歌单带回来。
      onSuccess: (_) {
        try {
          // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
          ref.invalidate(recentPlaylistsProvider);
        } catch (_) {
          // ref 在极端情况下(如整个 app 退出)已失效,吞掉避免破坏后台流程
        }
      },
    );
  } catch (e) {
    _toast(context, loc.search_import_failed('$e'), error: true);
  }
}

String _kindLabel(SearchEntityKind kind, AppLocalizations loc) {
  switch (kind) {
    case SearchEntityKind.song:
      return loc.widgets_songs;
    case SearchEntityKind.album:
      return loc.widgets_albums;
    case SearchEntityKind.artist:
      return loc.widgets_artists;
    case SearchEntityKind.playlist:
      return loc.widgets_playlists;
  }
}
