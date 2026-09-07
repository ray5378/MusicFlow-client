import 'package:musicflow_client/data/models/lyrics_line.dart';

/// 一组歌词（对应 OpenSubsonic 的 structuredLyrics 中的一个条目）
class StructuredLyrics {
  final String? displayArtist;
  final String? displayTitle;
  final String? lang;
  final int offsetMs;
  final bool synced;
  final List<LyricsLine> lines;

  StructuredLyrics({
    this.displayArtist,
    this.displayTitle,
    this.lang,
    this.offsetMs = 0,
    required this.synced,
    required this.lines,
  });

  factory StructuredLyrics.fromJson(Map<String, dynamic> json) {
    final lineList =
        (json['line'] as List?)
            ?.whereType<Map>()
            .map((e) => LyricsLine.fromJson(e.cast<String, dynamic>()))
            .toList() ??
        [];
    return StructuredLyrics(
      displayArtist: json['displayArtist'] is String
          ? json['displayArtist'] as String
          : null,
      displayTitle: json['displayTitle'] is String
          ? json['displayTitle'] as String
          : null,
      lang: json['lang'] is String ? json['lang'] as String : null,
      // offset 容错：OpenSubsonic 实现不一定按规范返回整数（字符串/浮点均见过），
      // as int? 会抛 CastError 导致整组歌词静默丢弃，统一按 num/字符串解析。
      offsetMs: switch (json['offset']) {
        num value => value.toInt(),
        String value => int.tryParse(value) ?? 0,
        _ => 0,
      },
      synced: json['synced'] as bool? ?? false,
      lines: lineList,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (displayArtist != null) 'displayArtist': displayArtist,
      if (displayTitle != null) 'displayTitle': displayTitle,
      if (lang != null) 'lang': lang,
      'offset': offsetMs,
      'synced': synced,
      'line': lines.map((l) => l.toJson()).toList(),
    };
  }
}
