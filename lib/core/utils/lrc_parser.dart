import 'package:musicflow_client/data/models/lyrics_line.dart';
import 'package:musicflow_client/data/models/structured_lyrics.dart';

/// LRC 格式解析器（用于 LRCLIB、网易云等外部源）
class LrcParser {
  /// [D-003] 无时间戳行的排序哨兵：排在所有带时间戳行之后。
  static const int _noTimestampSentinelMs = 0x7FFFFFFF;

  // [mm:ss.xx] 或 [mm:ss.xxx]
  // [D-004] 小数位支持 1~3 位毫秒（如 [00:01.5]）。
  static final _timeTagRegExp = RegExp(r'\[(\d{1,3}):(\d{2})\.(\d{1,3})\]');

  // 增强型逐字时间标签 <mm:ss.xx>（APT/Enhanced LRC）：本客户端只做逐行滚动，
  // 不支持逐字卡拉 OK，剥掉标签避免其残留在歌词文本里显示成乱码。
  static final _wordTagRegExp = RegExp(r'<\d{1,3}:\d{2}(?:\.\d{1,3})?>');

  /// 将 LRC 文本解析为统一的 StructuredLyrics
  static StructuredLyrics parse(String lrcContent) {
    final lines = lrcContent.split('\n');
    final lyricsLines = <LyricsLine>[];
    var hasTags = false;

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      // 跳过元数据标签 [ti:], [ar:], [al:] 等
      if (RegExp(r'^\[[a-z]{2}:').hasMatch(trimmed)) continue;

      final matches = _timeTagRegExp.allMatches(trimmed);
      if (matches.isEmpty) {
        // 无时间戳的纯文本行（非标准但常见）
        if (trimmed.isNotEmpty && !trimmed.startsWith('[')) {
          lyricsLines.add(LyricsLine(value: trimmed));
        }
        continue;
      }

      hasTags = true;

      // 提取歌词文本（移除所有时间戳与逐字标签）
      final text = trimmed
          .replaceAll(_timeTagRegExp, '')
          .replaceAll(_wordTagRegExp, '')
          .trim();

      // 一行可能有多个时间戳（共享歌词文本）
      for (final match in matches) {
        final minutes = int.parse(match.group(1)!);
        final seconds = int.parse(match.group(2)!);
        final rawMs = match.group(3)!;
        // [D-004] 1/2/3 位毫秒按十分位/百分位/千分位补齐到 3 位。
        final msValue = int.parse(rawMs);
        final milliseconds = rawMs.length == 1
            ? msValue * 100
            : rawMs.length == 2
                ? msValue * 10
                : msValue;

        final totalMs = minutes * 60 * 1000 + seconds * 1000 + milliseconds;

        lyricsLines.add(LyricsLine(startMs: totalMs, value: text));
      }
    }

    // 按时间排序；[D-003] 无时间戳行（startMs == null）排到末尾，
    // 不再被 `?? 0` 顶到最前面。
    if (hasTags) {
      int sortKey(LyricsLine l) => l.startMs ?? _noTimestampSentinelMs;
      lyricsLines.sort((a, b) => sortKey(a).compareTo(sortKey(b)));
    }

    return StructuredLyrics(synced: hasTags, lines: lyricsLines);
  }
}
