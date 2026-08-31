import 'package:flutter/material.dart';

import '../../data/models/search.dart';

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
  String get label => switch (this) {
        SearchScope.all => '所有',
        SearchScope.playlist => '歌单',
        SearchScope.song => '音乐',
        SearchScope.artist => '艺术家',
        SearchScope.album => '专辑',
      };

  /// 浮层里每项的一行说明。
  String get description => switch (this) {
        SearchScope.all => '全部内容',
        SearchScope.playlist => '仅歌单',
        SearchScope.song => '即歌曲',
        SearchScope.artist => '歌手',
        SearchScope.album => '专辑',
      };

  /// 结果区块标题(结果区用「歌曲」,切换器用「音乐」)。
  String get sectionTitle => switch (this) {
        SearchScope.song => '歌曲',
        _ => label,
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
