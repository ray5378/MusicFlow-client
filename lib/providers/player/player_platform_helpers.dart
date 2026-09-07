part of 'player_provider.dart';

const _playerLogTag = 'PLAYER';
const _playDbgTag = 'PLAYDBG';

bool get _isDesktopPlatform =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.macOS);

bool get _isApplePlatform =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS);

/// 将解析后的试听元数据写回原队列项，同时保留其它正式/试听歌曲。
@visibleForTesting
({List<Song> queue, int index}) resolvePreviewPlaybackQueue({
  required List<Song> queue,
  required int preferredIndex,
  required Song unresolvedSong,
  required Song resolvedSong,
}) {
  final nextQueue = List<Song>.of(queue);
  var nextIndex = preferredIndex;

  if (nextQueue.isEmpty) {
    return (queue: <Song>[resolvedSong], index: 0);
  }

  final preferredIndexMatches =
      nextIndex >= 0 &&
      nextIndex < nextQueue.length &&
      nextQueue[nextIndex].id == unresolvedSong.id;
  if (!preferredIndexMatches) {
    final matchedIndex = nextQueue.indexWhere(
      (item) => item.id == unresolvedSong.id,
    );
    if (matchedIndex >= 0) {
      nextIndex = matchedIndex;
    } else {
      nextIndex = nextIndex.clamp(0, nextQueue.length);
      nextQueue.insert(nextIndex, resolvedSong);
      return (queue: nextQueue, index: nextIndex);
    }
  }

  nextQueue[nextIndex] = resolvedSong;
  return (queue: nextQueue, index: nextIndex);
}
