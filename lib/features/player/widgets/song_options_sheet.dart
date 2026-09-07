import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/utils/network_error_notifier.dart';
import 'package:musicflow_client/core/utils/toast_notifier.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/widgets/music_flow_artwork.dart';
import 'package:musicflow_client/features/library/pages/album_detail_page.dart';
import 'package:musicflow_client/features/library/pages/artist_detail_page.dart';
import 'package:musicflow_client/features/player/widgets/add_to_playlist_sheet.dart' show AddToPlaylistSheet;
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

class SongOptionsExtraAction {
  const SongOptionsExtraAction({
    required this.icon,
    required this.title,
    required this.onPressed,
    this.isDestructive = false,
  });

  final IconData icon;
  final String title;
  final bool isDestructive;
  final FutureOr<void> Function() onPressed;
}

Future<void> showSongOptionsSheet({
  required BuildContext context,
  required Song song,
  bool useRootNavigator = true,
  List<SongOptionsExtraAction> extraActions = const <SongOptionsExtraAction>[],
  MusicFlowMediaVisuals? mediaVisuals,
}) async {
  // 桌面端:在触发点附近渲染「菜单」型小弹窗;移动端保留底部抽屉样式。
  final compactSheet =
      context.musicFlowWindowClass == MusicFlowWindowClass.compact;
  await showMusicFlowBottomSheet<void>(
    context: context,
    useRootNavigator: useRootNavigator,
    isScrollControlled: true,
    desktopAnchored: !compactSheet,
    builder: (_) {
      final sheet = _SongOptionsSheet(
        hostContext: context,
        song: song,
        extraActions: extraActions,
        compactSheet: compactSheet,
      );
      if (mediaVisuals == null) return sheet;
      return MusicFlowMediaColorScope(
        visuals: mediaVisuals,
        role: MusicFlowMediaSurfaceRole.panel,
        child: sheet,
      );
    },
  );
}

class _SongOptionsSheet extends ConsumerWidget {
  const _SongOptionsSheet({
    required this.hostContext,
    required this.song,
    required this.extraActions,
    required this.compactSheet,
  });

  final BuildContext hostContext;
  final Song song;
  final List<SongOptionsExtraAction> extraActions;

  /// 是否为移动端(compact)底部抽屉;false 时表现为桌面端锚点弹窗。
  final bool compactSheet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = AppLocalizations.of(context);
    final currentSongId = ref.watch(
      playerProvider.select((state) => state.currentSong?.id),
    );
    final isCurrentSong = currentSongId != null && currentSongId == song.id;
    final isCasting = ref.watch(
      castPeerControllerProvider.select((s) => s.activePeer != null),
    );
    // 链路 B（局域网 DLNA 直投）投屏态：同样把「加入投屏队列」路由到直投队列。
    final isDlnaCasting = ref.watch(
      dlnaCastProvider.select((s) => s.isCasting),
    );
    // 「加入投屏队列」的目标：链路 A > 链路 B > 本机下一曲。
    final enqueued = isCasting || isDlnaCasting;
    final artistName = song.artist?.trim().isNotEmpty == true
        ? song.artist!.trim()
        : loc.song_option_unknown_artist;
    final albumName = song.album?.trim().isNotEmpty == true
        ? song.album!.trim()
        : loc.song_option_unknown_album;
    final canOpenArtist = song.artistId?.trim().isNotEmpty == true;
    final canOpenAlbum = song.albumId?.trim().isNotEmpty == true;

    final actions = <Widget>[];
    if (song.isPreview) {
      actions.addAll(<Widget>[
        if (!isCurrentSong)
          _SongOptionRow(
            icon: AppIcons.queueAdd,
            title: enqueued ? loc.song_option_enqueue : loc.song_option_play_next,
            onPressed: () => unawaited(
              _closeAndRun(context, () async {
                if (isCasting) {
                  await ref
                      .read(castPeerControllerProvider.notifier)
                      .enqueueSongs(<Song>[song]);
                } else if (isDlnaCasting) {
                  await ref
                      .read(dlnaCastProvider.notifier)
                      .enqueueSongs(<Song>[song]);
                  _showMessage(loc.song_option_enqueued);
                } else {
                  await ref.read(playerProvider.notifier).playNext(song);
                }
              }),
            ),
          ),
      ]);
    } else {
      actions.addAll(<Widget>[
        _SongOptionRow(
          icon: song.starred ? AppIcons.heart : AppIcons.heartOutline,
          title: song.starred ? loc.player_unfavorite : loc.player_favorite,
          selected: song.starred,
          onPressed: () => unawaited(
            _closeAndRun(context, () async {
              final newStarred = await ref
                  .read(playerProvider.notifier)
                  .toggleSongFavorite(song);
              if (newStarred == null) {
                NetworkErrorNotifier.show(loc.song_option_operation_failed);
                return;
              }
              _showMessage(newStarred ? loc.song_option_favorite_added : loc.song_option_favorite_removed);
            }),
          ),
        ),
        _SongOptionRow(
          icon: AppIcons.playlistAdd,
          title: loc.library_add_to_playlist,
          onPressed: () => unawaited(
            _closeAndRun(context, () async {
              if (!hostContext.mounted) return;
              await showMusicFlowBottomSheet<void>(
                context: hostContext,
                useRootNavigator: true,
                isScrollControlled: true,
                builder: (_) =>
                    AddToPlaylistSheet(hostContext: hostContext, song: song),
              );
            }),
          ),
        ),
        if (!isCurrentSong)
          _SongOptionRow(
            icon: AppIcons.queueAdd,
            title: enqueued ? loc.song_option_enqueue : loc.song_option_play_next,
            onPressed: () => unawaited(
              _closeAndRun(context, () async {
                if (isCasting) {
                  await ref
                      .read(castPeerControllerProvider.notifier)
                      .enqueueSongs(<Song>[song]);
                  _showMessage(loc.song_option_enqueued);
                } else if (isDlnaCasting) {
                  await ref
                      .read(dlnaCastProvider.notifier)
                      .enqueueSongs(<Song>[song]);
                  _showMessage(loc.song_option_enqueued);
                } else {
                  await ref.read(playerProvider.notifier).playNext(song);
                  _showMessage(loc.song_option_play_next_added);
                }
              }),
            ),
          ),
        _SongOptionRow(
          icon: AppIcons.profile,
          title: loc.song_option_artist(artistName),
          onPressed: !canOpenArtist
              ? null
              : () => unawaited(
                  _closeAndRun(context, () async {
                    await Navigator.of(hostContext).push<void>(
                      MusicFlowPageRoute<void>(
                        context: hostContext,
                        builder: (_) =>
                            ArtistDetailPage(artistId: song.artistId!),
                      ),
                    );
                  }),
                ),
          onLongPress: () {
            Clipboard.setData(ClipboardData(text: artistName));
            ToastNotifier.show(loc.song_option_artist_copied(artistName));
          },
        ),
        _SongOptionRow(
          icon: AppIcons.albumOutline,
          title: loc.song_option_album(albumName),
          onPressed: !canOpenAlbum
              ? null
              : () => unawaited(
                  _closeAndRun(context, () async {
                    await Navigator.of(hostContext).push<void>(
                      MusicFlowPageRoute<void>(
                        context: hostContext,
                        builder: (_) => AlbumDetailPage(albumId: song.albumId!),
                      ),
                    );
                  }),
                ),
          onLongPress: () {
            Clipboard.setData(ClipboardData(text: albumName));
            ToastNotifier.show(loc.song_option_album_copied(albumName));
          },
        ),
      ]);
    }

    if (extraActions.isNotEmpty) {
      actions.add(
        Padding(
          padding: EdgeInsets.symmetric(vertical: context.musicFlowSpacing.xs),
          child: const MusicFlowDivider(),
        ),
      );
      for (final action in extraActions) {
        actions.add(
          _SongOptionRow(
            icon: action.icon,
            title: action.title,
            destructive: action.isDestructive,
            onPressed: () => unawaited(
              _closeAndRun(context, () async => action.onPressed()),
            ),
          ),
        );
      }
    }

    return MusicFlowBottomSheet(
      title: song.isPreview ? loc.song_option_title_preview : loc.song_option_title,
      showDragHandle: compactSheet,
      sceneRadius: !compactSheet,
      padding: EdgeInsets.fromLTRB(
        context.musicFlowSpacing.md,
        0,
        context.musicFlowSpacing.md,
        context.musicFlowSpacing.md,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.74,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _SongSummary(
                song: song,
                artistName: artistName,
                albumName: albumName,
                onCopyTitle: () {
                  Clipboard.setData(ClipboardData(text: song.title));
                  ToastNotifier.show(loc.song_option_copied_title(song.title));
                },
              ),
              Padding(
                padding: EdgeInsets.symmetric(vertical: context.musicFlowSpacing.xs),
                child: const MusicFlowDivider(),
              ),
              ...actions,
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _closeAndRun(
    BuildContext sheetContext,
    Future<void> Function() action,
  ) async {
    Navigator.of(sheetContext).pop();
    await Future<void>.delayed(Duration.zero);
    if (!hostContext.mounted) return;
    await action();
  }

  void _showMessage(String message) {
    if (!hostContext.mounted) return;
    showMusicFlowMessage(hostContext, message);
  }
}

class _SongSummary extends StatelessWidget {
  const _SongSummary({
    required this.song,
    required this.artistName,
    required this.albumName,
    required this.onCopyTitle,
  });

  final Song song;
  final String artistName;
  final String albumName;
  final VoidCallback onCopyTitle;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return MusicFlowPressable(
      semanticLabel: loc.song_option_summary_semantic(song.title, artistName, albumName),
      onLongPress: onCopyTitle,
      minimumSize: Size(
        double.infinity,
        context.musicFlowInteraction.expandedSongRowHeight,
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: context.musicFlowSpacing.xs),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            SizedBox.square(
              dimension: context.musicFlowInteraction.minimumTouchTarget,
              child: MusicFlowArtwork(
                coverArtId: song.artworkReference,
                semanticLabel: loc.song_cover_semantic(song.title),
                size: context.musicFlowInteraction.minimumTouchTarget,
                requestSize: 192,
                borderRadius: context.musicFlowRadii.detail,
              ),
            ),
            SizedBox(width: context.musicFlowSpacing.sm),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    song.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context.musicFlowTypography.title,
                  ),
                  SizedBox(height: context.musicFlowSpacing.xxs),
                  Text(
                    '$artistName · $albumName',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context.musicFlowTypography.metadata,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SongOptionRow extends StatelessWidget {
  const _SongOptionRow({
    required this.icon,
    required this.title,
    required this.onPressed,
    this.onLongPress,
    this.destructive = false,
    this.selected = false,
  });

  final IconData icon;
  final String title;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final bool destructive;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final colors = context.musicFlowColors;
    final enabled = onPressed != null || onLongPress != null;
    final accent = destructive ? colors.error : colors.accent;
    final foreground = enabled
        ? destructive
              ? colors.error
              : colors.ink
        : colors.onDisabled;

    return MusicFlowPressable(
      semanticLabel: <String>[
        title,
        if (selected) loc.song_option_selected,
        if (!enabled) loc.song_option_not_available,
      ].join('，'),
      selected: selected,
      onPressed: onPressed,
      onLongPress: onLongPress,
      minimumSize: Size(double.infinity, context.musicFlowInteraction.songRowHeight),
      child: Ink(
        decoration: BoxDecoration(
          color: selected
              ? accent.withValues(alpha: 0.1)
              : enabled
              ? Colors.transparent
              : colors.raised.withValues(alpha: 0.55),
          borderRadius: context.musicFlowRadii.control,
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: context.musicFlowSpacing.xs,
            vertical: context.musicFlowSpacing.xs,
          ),
          child: Row(
            children: <Widget>[
              SizedBox.square(
                dimension: context.musicFlowInteraction.minimumTouchTarget,
                child: Center(
                  child: Icon(
                    icon,
                    size: 22,
                    color: enabled ? accent : colors.onDisabled,
                  ),
                ),
              ),
              SizedBox(width: context.musicFlowSpacing.xs),
              Expanded(
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.musicFlowTypography.title.copyWith(
                    color: foreground,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

