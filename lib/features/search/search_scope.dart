import 'package:flutter/material.dart';

import '../../data/models/search.dart';
import '../../l10n/generated/app_localizations.dart';

/// 首页搜索入口与搜索页共用的搜索范围。
///
/// 枚举顺序即 UI 展示顺序:所有 / 歌单 / 音乐 / 艺术家 / 专辑。
/// 「音乐」与「歌曲」同义(服务端实体是 song),UI 文案统一用「音乐」。
enum SearchScope {
  all,
  playlist,
  song,
  artist,
  album,
}

/// 「所有」档的本地/全网结果堆叠顺序(需求:歌单 → 歌曲 → 专辑 → 艺术家)。
const List<SearchScope> kSearchScopeStackOrder = <SearchScope>[
  SearchScope.playlist,
  SearchScope.song,
  SearchScope.album,
  SearchScope.artist,
];

extension SearchScopeExtension on SearchScope {
  /// 切换器/浮层上的短标签。
  String label(AppLocalizations loc) => switch (this) {
        SearchScope.all => loc.search_scope_all,
        SearchScope.playlist => loc.widgets_playlists,
        SearchScope.song => loc.widgets_music,
        SearchScope.artist => loc.widgets_artists,
        SearchScope.album => loc.widgets_albums,
      };

  /// 浮层里每项的一行说明。
  String description(AppLocalizations loc) => switch (this) {
        SearchScope.all => loc.search_scope_all_desc,
        SearchScope.playlist => loc.search_scope_playlist_desc,
        SearchScope.song => loc.search_scope_song_desc,
        SearchScope.artist => loc.search_scope_artist_desc,
        SearchScope.album => loc.widgets_albums,
      };

  /// 结果区块标题(结果区用「歌曲」,切换器用「音乐」)。
  String sectionTitle(AppLocalizations loc) => switch (this) {
        SearchScope.song => loc.widgets_songs,
        _ => label(loc),
      };

  /// 对应的服务端搜索实体;「所有」无单一实体,需分段堆叠。
  SearchEntityKind? get kind => switch (this) {
        SearchScope.all => null,
        SearchScope.playlist => SearchEntityKind.playlist,
        SearchScope.song => SearchEntityKind.song,
        SearchScope.artist => SearchEntityKind.artist,
        SearchScope.album => SearchEntityKind.album,
      };

  /// 该范围内需要展示的实体顺序(单类型档只有自己)。
  List<SearchScope> get stackedScopes => switch (this) {
        SearchScope.all => kSearchScopeStackOrder,
        _ => <SearchScope>[this],
      };
}

/// 搜索范围索引(避免 UI 层依赖枚举序)。
@immutable
class SearchScopeSelection {
  const SearchScopeSelection({this.scope = SearchScope.all});

  final SearchScope scope;

  SearchScopeSelection copyWith({SearchScope? scope}) =>
      SearchScopeSelection(scope: scope ?? this.scope);
}
