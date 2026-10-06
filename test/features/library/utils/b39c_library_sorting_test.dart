// b39c —— Route C 补测：`lib/features/library/utils/library_sorting.dart` 剩余缺口。
//
// 覆盖点：
//   * 101 / 326：歌曲降序字母排序在「比较结果相等」时进入 _compareDescendingBy 的
//     fallback(() => 0)。
//   * 218 / 326：歌单降序字母排序同理。
//   * 246 / 250：歌单无 changed/created 时 updatedAsc 用 -1 兜底，并带上字母序 fallback。
//
// 纯函数，直接调用比较器即可。
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/features/library/utils/library_sorting.dart';

void main() {
  final PinyinResolver pinyin = createSharedPinyinResolver();

  Song song(String id, String title, String? artist) =>
      Song(id: id, title: title, artist: artist);

  Playlist playlist(
    String id,
    String name, {
    String? owner,
    DateTime? created,
    DateTime? changed,
  }) =>
      Playlist(
        id: id,
        name: name,
        owner: owner,
        songCount: 0,
        duration: 0,
        created: created,
        changed: changed,
      );

  test('歌曲名/歌手都相同 → 降序字母排序走 fallback()=>0（101/326）', () {
    final left = song('a', '同名歌', '同一歌手');
    final right = song('b', '同名歌', '同一歌手');

    expect(
      compareSongsForSortCached(
        left,
        right,
        SongSortOption.alphabeticalDesc,
        pinyin,
      ),
      0,
    );
  });

  test('歌单名/主人都相同 → 降序字母排序走 fallback()=>0（218/326）', () {
    final left = playlist('a', '同名歌单', owner: '同一主人');
    final right = playlist('b', '同名歌单', owner: '同一主人');

    expect(
      comparePlaylistsForSortCached(
        left,
        right,
        PlaylistSortOption.alphabeticalDesc,
        pinyin,
      ),
      0,
    );
  });

  test('歌单无 changed/created → updatedAsc 用 -1 兜底（246/250）', () {
    // 两侧都没有时间戳 ⇒ 左侧 -1、右侧 -1 ⇒ 相等 ⇒ 走到字母序 fallback。
    final left = playlist('a', 'AAA');
    final right = playlist('b', 'BBB');

    final result = comparePlaylistsForSortCached(
      left,
      right,
      PlaylistSortOption.updatedAsc,
      pinyin,
    );

    // fallback 回落到字母序：AAA < BBB ⇒ 负值。
    expect(result, lessThan(0));
  });

  test('歌单一侧有时间戳、一侧无 → updatedAsc 仍用 -1 参与比较（246）', () {
    final left = playlist('a', 'AAA', changed: DateTime(2024, 5, 1));
    final right = playlist('b', 'BBB'); // 无 changed/created ⇒ -1

    expect(
      comparePlaylistsForSortCached(
        left,
        right,
        PlaylistSortOption.updatedAsc,
        pinyin,
      ),
      greaterThan(0),
    );
  });
}
