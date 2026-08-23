/// 搜索子系统模型:对齐主项目 web 的 entity-search / playlist-search。
/// 四类目(歌曲/专辑/艺术家/歌单)共用同一套「聚合/本地/插件」搜索范式。
library;

import 'song.dart';

/// 搜索类目
enum SearchEntityKind { song, album, artist, playlist }

/// 搜索模式:聚合(本地+所有插件)/ 本地(仅音乐库)/ 插件(单插件)
enum SearchMode { aggregate, local, plugin }

/// 已启用且声明对应能力的插件(搜索来源下拉动态列出)
class SearchProvider {
  final String id;
  final String name;
  final List<String> platforms;
  final Map<String, String> platformLabels;

  SearchProvider({
    required this.id,
    required this.name,
    this.platforms = const [],
    this.platformLabels = const {},
  });

  factory SearchProvider.fromJson(Map<String, dynamic> json) {
    return SearchProvider(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      platforms: (json['platforms'] as List? ?? [])
          .map((e) => e as String)
          .toList(),
      platformLabels: (json['platformLabels'] as Map? ?? {}).map(
        (k, v) => MapEntry(k.toString(), v.toString()),
      ),
    );
  }
}

/// 远程歌曲(搜索结果)。isLocal 时 id 为本地库歌曲 id,可直接播放。
class SearchSong {
  final String id;
  final String source;
  final String name;
  final String artist;
  final String album;
  final int duration;
  final String cover;
  final String suffix;
  final String platformLabel;
  final String providerId;
  final String providerName;
  final bool isLocal;

  SearchSong({
    required this.id,
    this.source = '',
    this.name = '',
    this.artist = '',
    this.album = '',
    this.duration = 0,
    this.cover = '',
    this.suffix = '',
    this.platformLabel = '',
    this.providerId = '',
    this.providerName = '',
    this.isLocal = false,
  });

  /// 远程搜索结果解析。
  /// [providerId] 可选覆盖:后端 search/items 返回的歌曲条目**不带 providerId**,
  /// 但 /rest/stream-remote 与导入接口都必须带 provider。由仓库层在解析时
  /// 用请求参数里的 providerId 补齐,否则 buildRemoteSong 拼出的流 URL
  /// provider 为空 → 后端返回 Missing provider/source/id → 试听/入库全挂。
  factory SearchSong.fromRemoteJson(
    Map<String, dynamic> json, {
    String? providerId,
  }) {
    return SearchSong(
      id: json['id'] as String? ?? '',
      source: json['source'] as String? ?? '',
      name: json['name'] as String? ?? '',
      artist: json['artist'] as String? ?? '',
      album: json['album'] as String? ?? '',
      duration: (json['duration'] as num?)?.toInt() ?? 0,
      cover: json['cover'] as String? ?? '',
      suffix: json['suffix'] as String? ?? '',
      platformLabel: json['platformLabel'] as String? ?? json['source'] as String? ?? '',
      // 优先用仓库层传入的 providerId(单插件搜索时后端条目不带该字段)；
      // 为空则回退条目自带的 providerId(聚合搜索时后端会给每条补 providerId)。
      providerId: (providerId == null || providerId.isEmpty)
          ? (json['providerId'] as String? ?? '')
          : providerId,
      providerName: json['providerName'] as String? ?? '',
    );
  }

  /// 由本地库 Song 构造(本地搜索结果)
  factory SearchSong.fromLocal(Song song) {
    return SearchSong(
      id: song.id,
      name: song.title,
      artist: song.artist ?? '',
      album: song.album ?? '',
      duration: song.duration ?? 0,
      cover: song.coverArt ?? '',
      suffix: song.suffix ?? '',
      isLocal: true,
    );
  }
}

/// 远程专辑。isLocal 时 id 为本地库专辑 id。
class SearchAlbum {
  final String id;
  final String source;
  final String name;
  final String artist;
  final String cover;
  final String trackCount;
  final String year;
  final String link;
  final String platformLabel;
  final String providerId;
  final String providerName;
  final bool isLocal;

  SearchAlbum({
    required this.id,
    this.source = '',
    this.name = '',
    this.artist = '',
    this.cover = '',
    this.trackCount = '',
    this.year = '',
    this.link = '',
    this.platformLabel = '',
    this.providerId = '',
    this.providerName = '',
    this.isLocal = false,
  });

  factory SearchAlbum.fromRemoteJson(
    Map<String, dynamic> json, {
    String? providerId,
  }) {
    return SearchAlbum(
      id: json['id'] as String? ?? '',
      source: json['source'] as String? ?? '',
      name: json['name'] as String? ?? '',
      artist: json['artist'] as String? ?? '',
      cover: json['cover'] as String? ?? '',
      trackCount: json['trackCount']?.toString() ?? '',
      year: json['year']?.toString() ?? '',
      link: json['link'] as String? ?? '',
      platformLabel: json['platformLabel'] as String? ?? json['source'] as String? ?? '',
      // 优先用仓库层传入的 providerId(单插件搜索时后端条目不带该字段)；
      // 为空则回退条目自带的 providerId(聚合搜索时后端会给每条补 providerId)。
      providerId: (providerId == null || providerId.isEmpty)
          ? (json['providerId'] as String? ?? '')
          : providerId,
      providerName: json['providerName'] as String? ?? '',
    );
  }
}

/// 远程艺术家(仅展示,无入库)。isLocal 时 id 为本地库艺术家 id。
class SearchArtist {
  final String id;
  final String source;
  final String name;
  final String avatar;
  final String link;
  final String albumCount;
  final String songCount;
  final String platformLabel;
  final String providerId;
  final String providerName;
  final bool isLocal;

  SearchArtist({
    required this.id,
    this.source = '',
    this.name = '',
    this.avatar = '',
    this.link = '',
    this.albumCount = '',
    this.songCount = '',
    this.platformLabel = '',
    this.providerId = '',
    this.providerName = '',
    this.isLocal = false,
  });

  factory SearchArtist.fromRemoteJson(
    Map<String, dynamic> json, {
    String? providerId,
  }) {
    return SearchArtist(
      id: json['id'] as String? ?? '',
      source: json['source'] as String? ?? '',
      name: json['name'] as String? ?? '',
      avatar: json['avatar'] as String? ?? json['cover'] as String? ?? '',
      link: json['link'] as String? ?? '',
      albumCount: json['albumCount']?.toString() ?? '',
      songCount: json['songCount']?.toString() ?? '',
      platformLabel: json['platformLabel'] as String? ?? json['source'] as String? ?? '',
      // 优先用仓库层传入的 providerId(单插件搜索时后端条目不带该字段)；
      // 为空则回退条目自带的 providerId(聚合搜索时后端会给每条补 providerId)。
      providerId: (providerId == null || providerId.isEmpty)
          ? (json['providerId'] as String? ?? '')
          : providerId,
      providerName: json['providerName'] as String? ?? '',
    );
  }
}

/// 远程歌单。isLocal 时 id 为本地库歌单 id。
class SearchPlaylist {
  final String id;
  final String source;
  final String name;
  final String creator;
  final String cover;
  final String trackCount;
  final String link;
  final String platformLabel;
  final String providerId;
  final String providerName;
  final bool imported;
  final bool isLocal;

  SearchPlaylist({
    required this.id,
    this.source = '',
    this.name = '',
    this.creator = '',
    this.cover = '',
    this.trackCount = '',
    this.link = '',
    this.platformLabel = '',
    this.providerId = '',
    this.providerName = '',
    this.imported = false,
    this.isLocal = false,
  });

  factory SearchPlaylist.fromRemoteJson(
    Map<String, dynamic> json, {
    String? providerId,
  }) {
    return SearchPlaylist(
      id: json['id'] as String? ?? '',
      source: json['source'] as String? ?? '',
      name: json['name'] as String? ?? '',
      creator: json['creator'] as String? ?? '',
      cover: json['cover'] as String? ?? '',
      trackCount: json['trackCount']?.toString() ?? '',
      link: json['link'] as String? ?? '',
      platformLabel: json['platformLabel'] as String? ?? json['source'] as String? ?? '',
      // 优先用仓库层传入的 providerId(单插件搜索时后端条目不带该字段)；
      // 为空则回退条目自带的 providerId(聚合搜索时后端会给每条补 providerId)。
      providerId: (providerId == null || providerId.isEmpty)
          ? (json['providerId'] as String? ?? '')
          : providerId,
      providerName: json['providerName'] as String? ?? '',
      imported: json['imported'] as bool? ?? false,
    );
  }
}

/// 一次搜索的整体结果(按类目只填对应字段)
class SearchOutcome {
  final List<SearchSong> songs;
  final List<SearchAlbum> albums;
  final List<SearchArtist> artists;
  final List<SearchPlaylist> playlists;
  final bool isLocal;

  SearchOutcome({
    this.songs = const [],
    this.albums = const [],
    this.artists = const [],
    this.playlists = const [],
    this.isLocal = false,
  });

  bool get isEmpty =>
      songs.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty;
}

/// 一次搜索请求(作为 provider family 的 key)
class SearchRequest {
  final SearchEntityKind kind;
  final SearchMode mode;
  final String query;
  final String providerId; // 插件模式下有效

  SearchRequest({
    required this.kind,
    required this.mode,
    required this.query,
    this.providerId = '',
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SearchRequest &&
          runtimeType == other.runtimeType &&
          kind == other.kind &&
          mode == other.mode &&
          query == other.query &&
          providerId == other.providerId;

  @override
  int get hashCode =>
      kind.hashCode ^ mode.hashCode ^ query.hashCode ^ providerId.hashCode;
}
