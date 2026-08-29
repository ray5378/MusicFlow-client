import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/album.dart';
import '../data/models/artist.dart';
import '../data/models/song.dart';
import 'api_provider.dart';
import 'library_provider.dart';
import 'music_provider.dart';
import 'playlist_provider.dart';

/// 库总览计数：艺术家 / 专辑 / 歌曲 / 歌单。
///
/// 每个维度只取 `page(1, 1)` 的 `total`（或歌单列表长度），不拉全量；
/// 任一维度失败时该维度为 null，由 [format] 自动隐藏，不影响其余维度展示。
class LibraryCounts {
  const LibraryCounts({
    this.artistCount,
    this.albumCount,
    this.songCount,
    this.playlistCount,
  });

  final int? artistCount;
  final int? albumCount;
  final int? songCount;
  final int? playlistCount;

  bool get isEmpty =>
      artistCount == null &&
      albumCount == null &&
      songCount == null &&
      playlistCount == null;

  /// `8 位艺术家 · 30 张专辑 · 2105 首歌曲 · 12 个歌单`
  String format() {
    return <String>[
      if (artistCount != null) '$artistCount 位艺术家',
      if (albumCount != null) '$albumCount 张专辑',
      if (songCount != null) '$songCount 首歌曲',
      if (playlistCount != null) '$playlistCount 个歌单',
    ].join(' · ');
  }

  /// 单维度标签：库页面只显示本页对应类型的计数（null 表示该维度缺失）。
  String? get artistsLabel =>
      artistCount == null ? null : '共 $artistCount 名艺人';
  String? get albumsLabel =>
      albumCount == null ? null : '共 $albumCount 张专辑';
  String? get songsLabel => songCount == null ? null : '共 $songCount 首歌曲';
  String? get playlistsLabel =>
      playlistCount == null ? null : '共 $playlistCount 个歌单';
}

/// 库总览计数。非 autoDispose：五个库页面共用一份结果，切库时自动重算。
final libraryCountsProvider = FutureProvider<LibraryCounts>((ref) async {
  // 活跃库变化时自动重新统计。
  ref.watch(activeLibraryProvider);

  final repository = ref.watch(musicRepositoryProvider);
  if (repository == null) return const LibraryCounts();

  // 地址探测/线路切换完成后再取，避免冷启动瞬间空手而归。
  await ref.read(ensureActiveAddressProvider.future);

  final counts = await Future.wait<int?>(<Future<int?>>[
    _pageTotal<Artist>(() => repository.getArtistsPage(1, 1)),
    _pageTotal<Album>(() => repository.getAlbumsPage(1, 1)),
    _pageTotal<Song>(() => repository.getSongsPage(1, 1)),
    _playlistTotal(ref),
  ]);

  return LibraryCounts(
    artistCount: counts[0],
    albumCount: counts[1],
    songCount: counts[2],
    playlistCount: counts[3],
  );
});

Future<int?> _pageTotal<T>(
  Future<({List<T> items, int total})> Function() fetch,
) async {
  try {
    final page = await fetch();
    return page.total;
  } catch (_) {
    return null;
  }
}

Future<int?> _playlistTotal(Ref ref) async {
  try {
    final playlists = await ref.read(playlistsProvider.future);
    return playlists.length;
  } catch (_) {
    return null;
  }
}
