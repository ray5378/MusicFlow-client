// batch36-B —— `lib/features/library/utils/library_sorting.dart` 剩余未覆盖行补测。
//
// 已有 library_sorting_coverage_gap_test.dart 覆盖 sortSongs/sortPlaylists 的
// 排序语义与 createSharedPinyinResolver；本文件专攻两处**从未被调用的分支**：
//   * SongSortOptionX.label / PlaylistSortOptionX.label —— 排序下拉文案全部枚举；
//   * compareSongsForSortCached / comparePlaylistsForSortCached 的
//     durationDesc / updatedAsc / updatedDesc / defaultOrder 兜底分支。
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/features/library/utils/library_sorting.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

Song _song(String id, String title, {String? artist, int? duration, DateTime? created}) =>
    Song(id: id, title: title, artist: artist, duration: duration, created: created);

Playlist _playlist(
  String id,
  String name, {
  String? owner,
  int? duration,
  DateTime? created,
  DateTime? changed,
}) =>
    Playlist(
      id: id,
      name: name,
      owner: owner,
      duration: duration ?? 0,
      songCount: 0,
      created: created,
      changed: changed,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppLocalizations loc;

  setUpAll(() async {
    loc = await AppLocalizations.delegate.load(const Locale('zh'));
  });

  group('SongSortOptionX.label 全枚举文案', () {
    test('每个枚举都有非空文案', () {
      for (final option in SongSortOption.values) {
        expect(option.label(loc), isNotEmpty, reason: '$option 文案为空');
      }
    });

    test('各枚举映射到对应本地化 getter', () {
      expect(SongSortOption.defaultOrder.label(loc), loc.song_sort_default_order);
      expect(SongSortOption.alphabeticalAsc.label(loc), loc.song_sort_alphabetical_asc);
      expect(SongSortOption.alphabeticalDesc.label(loc), loc.song_sort_alphabetical_desc);
      expect(SongSortOption.durationAsc.label(loc), loc.song_sort_duration_asc);
      expect(SongSortOption.durationDesc.label(loc), loc.song_sort_duration_desc);
      expect(SongSortOption.updatedAsc.label(loc), loc.song_sort_updated_asc);
      expect(SongSortOption.updatedDesc.label(loc), loc.song_sort_updated_desc);
    });

    test('升降序文案互不相同（UI 不能显示成同一项）', () {
      expect(
        SongSortOption.alphabeticalAsc.label(loc),
        isNot(SongSortOption.alphabeticalDesc.label(loc)),
      );
      expect(
        SongSortOption.durationAsc.label(loc),
        isNot(SongSortOption.durationDesc.label(loc)),
      );
      expect(
        SongSortOption.updatedAsc.label(loc),
        isNot(SongSortOption.updatedDesc.label(loc)),
      );
    });
  });

  group('PlaylistSortOptionX.label 全枚举文案', () {
    test('每个枚举都有非空文案', () {
      for (final option in PlaylistSortOption.values) {
        expect(option.label(loc), isNotEmpty, reason: '$option 文案为空');
      }
    });

    test('各枚举映射到对应本地化 getter', () {
      expect(PlaylistSortOption.defaultOrder.label(loc), loc.song_sort_default_order);
      expect(PlaylistSortOption.alphabeticalAsc.label(loc), loc.song_sort_alphabetical_asc);
      expect(PlaylistSortOption.alphabeticalDesc.label(loc), loc.song_sort_alphabetical_desc);
      expect(PlaylistSortOption.durationAsc.label(loc), loc.song_sort_duration_asc);
      expect(PlaylistSortOption.durationDesc.label(loc), loc.song_sort_duration_desc);
      // 歌单的「最近更新」与歌曲的「按更新时间」是各自独立的 getter。
      expect(PlaylistSortOption.updatedAsc.label(loc), loc.playlist_sort_updated_asc);
      expect(PlaylistSortOption.updatedDesc.label(loc), loc.playlist_sort_updated_desc);
    });
  });

  group('selectableSongSortOptionsWithoutDefault', () {
    test('等于全部枚举去掉 defaultOrder，且顺序保持', () {
      expect(
        selectableSongSortOptionsWithoutDefault,
        equals(
          SongSortOption.values
              .where((o) => o != SongSortOption.defaultOrder)
              .toList(),
        ),
      );
    });
  });

  group('compareSongsForSortCached 剩余分支', () {
    final resolver = createSharedPinyinResolver();

    test('defaultOrder 恒返回 0', () {
      final a = _song('1', 'zzz');
      final b = _song('2', 'aaa');
      expect(
        compareSongsForSortCached(a, b, SongSortOption.defaultOrder, resolver),
        0,
      );
    });

    test('durationDesc 时长相同 → 回退标题升序', () {
      final a = _song('1', 'b', duration: 100);
      final b = _song('2', 'a', duration: 100);
      // 时长相等 → fallback() 走标题升序 ⇒ a 排在 b 之后（positive）。
      expect(
        compareSongsForSortCached(a, b, SongSortOption.durationDesc, resolver),
        greaterThan(0),
      );
    });

    test('updatedAsc 缺省(-1) → 时间早者在前', () {
      final base = DateTime.fromMillisecondsSinceEpoch(1000);
      final a = _song('1', 'a');
      final b = _song('2', 'b', created: base);
      expect(
        compareSongsForSortCached(a, b, SongSortOption.updatedAsc, resolver),
        lessThan(0),
      );
    });

    test('updatedDesc 时间相同 → 回退标题升序', () {
      final base = DateTime.fromMillisecondsSinceEpoch(1000);
      final a = _song('1', 'b', created: base);
      final b = _song('2', 'a', created: base);
      expect(
        compareSongsForSortCached(a, b, SongSortOption.updatedDesc, resolver),
        greaterThan(0),
      );
    });

    test('alphabeticalDesc 标题不同 → 降序', () {
      final a = _song('1', 'alpha');
      final b = _song('2', 'bravo');
      expect(
        compareSongsForSortCached(a, b, SongSortOption.alphabeticalDesc, resolver),
        greaterThan(0),
      );
    });
  });

  group('comparePlaylistsForSortCached 剩余分支', () {
    final resolver = createSharedPinyinResolver();

    test('defaultOrder 恒返回 0', () {
      final a = _playlist('1', 'zzz');
      final b = _playlist('2', 'aaa');
      expect(
        comparePlaylistsForSortCached(a, b, PlaylistSortOption.defaultOrder, resolver),
        0,
      );
    });

    test('alphabeticalDesc 名称不同 → 降序', () {
      final a = _playlist('1', 'alpha');
      final b = _playlist('2', 'bravo');
      expect(
        comparePlaylistsForSortCached(a, b, PlaylistSortOption.alphabeticalDesc, resolver),
        greaterThan(0),
      );
    });

    test('durationDesc 时长相同 → 回退名称升序', () {
      final a = _playlist('1', 'b', duration: 10);
      final b = _playlist('2', 'a', duration: 10);
      expect(
        comparePlaylistsForSortCached(a, b, PlaylistSortOption.durationDesc, resolver),
        greaterThan(0),
      );
    });

    test('updatedAsc changed 早者在前', () {
      final base = DateTime.fromMillisecondsSinceEpoch(1000);
      final a = _playlist('1', 'a', changed: base);
      final b = _playlist('2', 'b', changed: base.add(const Duration(days: 1)));
      expect(
        comparePlaylistsForSortCached(a, b, PlaylistSortOption.updatedAsc, resolver),
        lessThan(0),
      );
    });

    test('updatedDesc changed 晚者在前', () {
      final base = DateTime.fromMillisecondsSinceEpoch(1000);
      final a = _playlist('1', 'a', changed: base);
      final b = _playlist('2', 'b', changed: base.add(const Duration(days: 1)));
      expect(
        comparePlaylistsForSortCached(a, b, PlaylistSortOption.updatedDesc, resolver),
        greaterThan(0),
      );
    });

    test('updatedAsc 二者均无时间 → 回退名称升序', () {
      final a = _playlist('1', 'b');
      final b = _playlist('2', 'a');
      expect(
        comparePlaylistsForSortCached(a, b, PlaylistSortOption.updatedAsc, resolver),
        greaterThan(0),
      );
    });
  });

  group('sortSongs/sortPlaylists 覆盖未走到的排序选项', () {
    test('durationDesc 完整排序输出', () {
      final songs = <Song>[
        _song('1', 'a', duration: 100),
        _song('2', 'b', duration: 300),
        _song('3', 'c', duration: 200),
      ];
      expect(
        sortSongs(songs, SongSortOption.durationDesc).map((s) => s.id),
        ['2', '3', '1'],
      );
    });

    test('playlist updatedDesc 完整排序输出', () {
      final base = DateTime.fromMillisecondsSinceEpoch(1000);
      final playlists = <Playlist>[
        _playlist('1', 'a', created: base),
        _playlist('2', 'b', changed: base.add(const Duration(days: 2))),
      ];
      expect(
        sortPlaylists(playlists, PlaylistSortOption.updatedDesc).map((p) => p.id),
        ['2', '1'],
      );
    });
  });
}
