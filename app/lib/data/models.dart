/// 数据模型：字段解析全部容错（服务端数值可能为浮点/缺失）。
library;


class Song {
  const Song({
    required this.id,
    required this.title,
    this.artist,
    this.artistId,
    this.album,
    this.albumId,
    this.durationSeconds,
    this.bitRateKbps,
    this.sizeBytes,
    this.suffix,
    this.coverArt,
    this.starred = false,
    this.track,
    this.year,
  });

  factory Song.fromJson(Map<String, dynamic> j) => Song(
    id: '${j['id']}',
    title: (j['title'] ?? j['name'] ?? '').toString(),
    artist: (j['artist'] as String?)?.trim(),
    artistId: (j['artistId'])?.toString(),
    album: (j['album'] as String?)?.trim(),
    albumId: (j['albumId'])?.toString(),
    durationSeconds: _num(j['duration']),
    bitRateKbps: _num(j['bitRate']),
    sizeBytes: _num(j['size']),
    suffix: (j['suffix'] ?? j['contentType'])?.toString().toLowerCase(),
    coverArt: (j['coverArt'])?.toString(),
    starred: j['starred'] != null,
    track: _num(j['track']),
    year: _num(j['year']),
  );

  final String id;
  final String title;
  final String? artist;
  final String? artistId;
  final String? album;
  final String? albumId;
  final num? durationSeconds;
  final num? bitRateKbps;
  final num? sizeBytes;
  final String? suffix;
  final String? coverArt;
  final bool starred;
  final num? track;
  final num? year;

  Song copyWith({bool? starred}) => Song(
    id: id, title: title, artist: artist, artistId: artistId, album: album,
    albumId: albumId, durationSeconds: durationSeconds, bitRateKbps: bitRateKbps,
    sizeBytes: sizeBytes, suffix: suffix, coverArt: coverArt,
    starred: starred ?? this.starred, track: track, year: year,
  );
}

class Album {
  const Album({
    required this.id,
    required this.name,
    this.artist,
    this.artistId,
    this.coverArt,
    this.songCount,
    this.durationSeconds,
    this.year,
  });

  factory Album.fromJson(Map<String, dynamic> j) => Album(
    id: '${j['id']}',
    name: (j['name'] ?? j['title'] ?? j['album'] ?? '').toString(),
    artist: (j['artist'] as String?)?.trim(),
    artistId: (j['artistId'])?.toString(),
    coverArt: (j['coverArt'])?.toString(),
    songCount: _num(j['songCount']),
    durationSeconds: _num(j['duration']),
    year: _num(j['year']),
  );

  final String id;
  final String name;
  final String? artist;
  final String? artistId;
  final String? coverArt;
  final num? songCount;
  final num? durationSeconds;
  final num? year;
}

class Artist {
  const Artist({required this.id, required this.name, this.coverArt, this.albumCount});

  factory Artist.fromJson(Map<String, dynamic> j) => Artist(
    id: '${j['id']}',
    name: (j['name'] ?? '').toString(),
    coverArt: (j['coverArt'] ?? j['avatar'])?.toString(),
    albumCount: _num(j['albumCount']),
  );

  final String id;
  final String name;
  final String? coverArt;
  final num? albumCount;
}

class Playlist {
  const Playlist({
    required this.id,
    required this.name,
    this.coverArt,
    this.songCount,
    this.owner,
  });

  factory Playlist.fromJson(Map<String, dynamic> j) => Playlist(
    id: '${j['id']}',
    name: (j['name'] ?? '').toString(),
    coverArt: (j['coverArt'])?.toString(),
    songCount: _num(j['songCount'] ?? j['songcount'] ?? j['trackCount']),
    owner: (j['owner'] as String?)?.trim(),
  );

  final String id;
  final String name;
  final String? coverArt;
  final num? songCount;
  final String? owner;
}

/// 聚合搜索结果条目（在线歌曲，可直接经 /rest/stream-remote 播放）。
class RemoteSong {
  const RemoteSong({
    required this.providerId,
    required this.source,
    required this.id,
    required this.name,
    this.artist,
    this.album,
    this.durationSeconds,
    this.coverUrl,
    this.suffix,
    this.platformLabel,
  });

  factory RemoteSong.fromJson(Map<String, dynamic> j) => RemoteSong(
    providerId: '${j['providerId'] ?? ''}',
    source: '${j['source'] ?? ''}',
    id: '${j['id'] ?? ''}',
    name: (j['name'] ?? '').toString(),
    artist: (j['artist'] as String?)?.trim(),
    album: (j['album'] as String?)?.trim(),
    durationSeconds: _num(j['duration']),
    coverUrl: (j['cover'] as String?)?.trim(),
    suffix: (j['suffix'] as String?)?.toLowerCase(),
    platformLabel: (j['platformLabel'] as String?)?.trim(),
  );

  final String providerId;
  final String source;
  final String id;
  final String name;
  final String? artist;
  final String? album;
  final num? durationSeconds;
  final String? coverUrl;
  final String? suffix;
  final String? platformLabel;

  Map<String, dynamic> toImportJson() => {
    'id': id,
    'source': source,
    'name': name,
    'artist': artist ?? '',
    'album': album ?? '',
    'duration': durationSeconds ?? 0,
    'cover': coverUrl ?? '',
    if (suffix != null) 'suffix': suffix,
  };
}

class Paged<T> {
  const Paged({required this.items, required this.total});
  final List<T> items;
  final int total;
}

num? _num(Object? v) {
  if (v == null) return null;
  if (v is num) return v;
  return num.tryParse('$v');
}
