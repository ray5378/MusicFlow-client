import '../../../data/models/playlist.dart';
import '../../../data/models/song.dart';
import '../../../utils/pinyin_helper.dart';

enum SongSortOption {
  defaultOrder,
  alphabeticalAsc,
  alphabeticalDesc,
  durationAsc,
  durationDesc,
  updatedAsc,
  updatedDesc,
}

const selectableSongSortOptions = <SongSortOption>[
  SongSortOption.defaultOrder,
  SongSortOption.alphabeticalAsc,
  SongSortOption.alphabeticalDesc,
  SongSortOption.durationAsc,
  SongSortOption.durationDesc,
  SongSortOption.updatedAsc,
  SongSortOption.updatedDesc,
];

const selectableSongSortOptionsWithoutDefault = <SongSortOption>[
  SongSortOption.alphabeticalAsc,
  SongSortOption.alphabeticalDesc,
  SongSortOption.durationAsc,
  SongSortOption.durationDesc,
  SongSortOption.updatedAsc,
  SongSortOption.updatedDesc,
];

extension SongSortOptionX on SongSortOption {
  String get label {
    switch (this) {
      case SongSortOption.defaultOrder:
        return '默认顺序';
      case SongSortOption.alphabeticalAsc:
        return '字母 A-Z';
      case SongSortOption.alphabeticalDesc:
        return '字母 Z-A';
      case SongSortOption.durationAsc:
        return '时长从短到长';
      case SongSortOption.durationDesc:
        return '时长从长到短';
      case SongSortOption.updatedAsc:
        return '时间从旧到新';
      case SongSortOption.updatedDesc:
        return '时间从新到旧';
    }
  }

  bool get usesAlphabeticalIndexBar => this == SongSortOption.alphabeticalAsc;
}

/// 拼音解析器：整次排序内共享同一缓存，避免比较器反复触发 lpinyin 转换。
typedef PinyinResolver = String Function(String text);

/// 构造一个共享缓存的拼音解析器（供整次排序复用）。
///
/// 排序比较器会被调用 O(n log n) 次，若每次比较都现场重算拼音（字典查表），
/// 大列表会卡顿；这里把拼音结果按原文缓存，将重复转换降为「不同文本数」次。
PinyinResolver createSharedPinyinResolver() {
  final cache = <String, String>{};
  return (text) => cache.putIfAbsent(text, () => PinyinUtils.getPinyin(text));
}

List<Song> sortSongs(List<Song> songs, SongSortOption option) {
  if (songs.length < 2 || option == SongSortOption.defaultOrder) {
    return List<Song>.of(songs);
  }

  final sorted = List<Song>.of(songs);
  final pinyinOf = createSharedPinyinResolver();
  sorted.sort(
    (left, right) => compareSongsForSortCached(left, right, option, pinyinOf),
  );
  return sorted;
}

/// 带共享拼音缓存的歌曲比较器（与 [compareSongsForSort] 同序）。
///
/// [pinyinOf] 由调用方在整次排序内复用同一个缓存（见 [createSharedPinyinResolver]），
/// 避免 O(n log n) 次比较里反复触发 lpinyin 字典转换。
int compareSongsForSortCached(
  Song left,
  Song right,
  SongSortOption option,
  PinyinResolver pinyinOf,
) {
  switch (option) {
    case SongSortOption.defaultOrder:
      return 0;
    case SongSortOption.alphabeticalAsc:
      return _compareSongAlphabetically(left, right, pinyinOf);
    case SongSortOption.alphabeticalDesc:
      return _compareDescendingBy(
        _compareSongAlphabetically(left, right, pinyinOf),
        fallback: () => 0,
      );
    case SongSortOption.durationAsc:
      return _compareAscending(
        left.duration ?? -1,
        right.duration ?? -1,
        fallback: () => _compareSongAlphabetically(left, right, pinyinOf),
      );
    case SongSortOption.durationDesc:
      return _compareDescending(
        left.duration ?? -1,
        right.duration ?? -1,
        fallback: () => _compareSongAlphabetically(left, right, pinyinOf),
      );
    case SongSortOption.updatedAsc:
      return _compareAscending(
        left.created?.millisecondsSinceEpoch ?? -1,
        right.created?.millisecondsSinceEpoch ?? -1,
        fallback: () => _compareSongAlphabetically(left, right, pinyinOf),
      );
    case SongSortOption.updatedDesc:
      return _compareDescending(
        left.created?.millisecondsSinceEpoch ?? -1,
        right.created?.millisecondsSinceEpoch ?? -1,
        fallback: () => _compareSongAlphabetically(left, right, pinyinOf),
      );
  }
}

/// Compares two songs using the same ordering as [sortSongs].
///
/// Keeping the comparator public lets callers sort richer row models while
/// retaining metadata such as a song's original position in a playlist.
int compareSongsForSort(Song left, Song right, SongSortOption option) {
  // 单次比较使用独立缓存；整次排序请用 [compareSongsForSortCached] +
  // [createSharedPinyinResolver] 共享缓存。
  return compareSongsForSortCached(
    left,
    right,
    option,
    createSharedPinyinResolver(),
  );
}

enum PlaylistSortOption {
  defaultOrder,
  alphabeticalAsc,
  alphabeticalDesc,
  durationAsc,
  durationDesc,
  updatedAsc,
  updatedDesc,
}

const selectablePlaylistSortOptions = <PlaylistSortOption>[
  PlaylistSortOption.defaultOrder,
  PlaylistSortOption.alphabeticalAsc,
  PlaylistSortOption.alphabeticalDesc,
  PlaylistSortOption.durationAsc,
  PlaylistSortOption.durationDesc,
  PlaylistSortOption.updatedAsc,
  PlaylistSortOption.updatedDesc,
];

extension PlaylistSortOptionX on PlaylistSortOption {
  String get label {
    switch (this) {
      case PlaylistSortOption.defaultOrder:
        return '默认顺序';
      case PlaylistSortOption.alphabeticalAsc:
        return '字母 A-Z';
      case PlaylistSortOption.alphabeticalDesc:
        return '字母 Z-A';
      case PlaylistSortOption.durationAsc:
        return '时长从短到长';
      case PlaylistSortOption.durationDesc:
        return '时长从长到短';
      case PlaylistSortOption.updatedAsc:
        return '更新时间从旧到新';
      case PlaylistSortOption.updatedDesc:
        return '更新时间从新到旧';
    }
  }
}

List<Playlist> sortPlaylists(
  List<Playlist> playlists,
  PlaylistSortOption option,
) {
  if (playlists.length < 2 || option == PlaylistSortOption.defaultOrder) {
    return List<Playlist>.of(playlists);
  }

  final sorted = List<Playlist>.of(playlists);
  final pinyinOf = createSharedPinyinResolver();
  sorted.sort(
    (left, right) =>
        comparePlaylistsForSortCached(left, right, option, pinyinOf),
  );
  return sorted;
}

/// 带共享拼音缓存的歌单比较器（与 [sortPlaylists] 同序）。
int comparePlaylistsForSortCached(
  Playlist left,
  Playlist right,
  PlaylistSortOption option,
  PinyinResolver pinyinOf,
) {
  switch (option) {
    case PlaylistSortOption.defaultOrder:
      return 0;
    case PlaylistSortOption.alphabeticalAsc:
      return _comparePlaylistAlphabetically(left, right, pinyinOf);
    case PlaylistSortOption.alphabeticalDesc:
      return _compareDescendingBy(
        _comparePlaylistAlphabetically(left, right, pinyinOf),
        fallback: () => 0,
      );
    case PlaylistSortOption.durationAsc:
      return _compareAscending(
        left.duration,
        right.duration,
        fallback: () => _comparePlaylistAlphabetically(left, right, pinyinOf),
      );
    case PlaylistSortOption.durationDesc:
      return _compareDescending(
        left.duration,
        right.duration,
        fallback: () => _comparePlaylistAlphabetically(left, right, pinyinOf),
      );
    case PlaylistSortOption.updatedAsc:
      return _compareAscending(
        left.changed?.millisecondsSinceEpoch ??
            left.created?.millisecondsSinceEpoch ??
            -1,
        right.changed?.millisecondsSinceEpoch ??
            right.created?.millisecondsSinceEpoch ??
            -1,
        fallback: () => _comparePlaylistAlphabetically(left, right, pinyinOf),
      );
    case PlaylistSortOption.updatedDesc:
      return _compareDescending(
        left.changed?.millisecondsSinceEpoch ??
            left.created?.millisecondsSinceEpoch ??
            -1,
        right.changed?.millisecondsSinceEpoch ??
            right.created?.millisecondsSinceEpoch ??
            -1,
        fallback: () => _comparePlaylistAlphabetically(left, right, pinyinOf),
      );
  }
}

int _compareSongAlphabetically(
  Song left,
  Song right,
  PinyinResolver pinyinOf,
) {
  return _compareAlphabetically(
    primaryLeft: left.title,
    primaryRight: right.title,
    secondaryLeft: left.artist,
    secondaryRight: right.artist,
    pinyinOf: pinyinOf,
  );
}

int _comparePlaylistAlphabetically(
  Playlist left,
  Playlist right,
  PinyinResolver pinyinOf,
) {
  return _compareAlphabetically(
    primaryLeft: left.name,
    primaryRight: right.name,
    secondaryLeft: left.owner,
    secondaryRight: right.owner,
    pinyinOf: pinyinOf,
  );
}

int _compareAlphabetically({
  required String primaryLeft,
  required String primaryRight,
  String? secondaryLeft,
  String? secondaryRight,
  required PinyinResolver pinyinOf,
}) {
  final leftPinyin = pinyinOf(primaryLeft).toLowerCase();
  final rightPinyin = pinyinOf(primaryRight).toLowerCase();
  final primaryResult = leftPinyin.compareTo(rightPinyin);
  if (primaryResult != 0) return primaryResult;

  final leftRaw = primaryLeft.toLowerCase();
  final rightRaw = primaryRight.toLowerCase();
  final rawResult = leftRaw.compareTo(rightRaw);
  if (rawResult != 0) return rawResult;

  final leftSecondary = (secondaryLeft ?? '').toLowerCase();
  final rightSecondary = (secondaryRight ?? '').toLowerCase();
  return leftSecondary.compareTo(rightSecondary);
}

int _compareDescending(
  int left,
  int right, {
  required int Function() fallback,
}) {
  final result = right.compareTo(left);
  if (result != 0) return result;
  return fallback();
}

int _compareAscending(int left, int right, {required int Function() fallback}) {
  final result = left.compareTo(right);
  if (result != 0) return result;
  return fallback();
}

int _compareDescendingBy(
  int comparisonResult, {
  required int Function() fallback,
}) {
  if (comparisonResult != 0) return -comparisonResult;
  return fallback();
}
