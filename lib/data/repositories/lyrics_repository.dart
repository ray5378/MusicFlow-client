import '../../core/utils/logger.dart';
import '../models/lyrics.dart';
import '../sources/lyrics/lyrics_source.dart';

/// 歌词仓库 — 按优先级 Fallback（不做本地缓存，实时拉取）
class LyricsRepository {
  final List<LyricsSource> _sources;

  LyricsRepository({
    required List<LyricsSource> sources,
  }) : _sources = sources;

  Future<Lyrics?> getLyrics({
    required String songId,
    required String title,
    required String artist,
    String? album,
    Duration? duration,
  }) async {
    final allowExternalLookup = _canUseExternalSources(
      title: title,
      artist: artist,
    );

    // 按优先级逐一查询提供商
    for (final source in _sources) {
      if (!allowExternalLookup && source.id != 'subsonic') {
        continue;
      }
      try {
        final lyrics = await source.fetchLyrics(
          title: title,
          artist: artist,
          album: album,
          duration: duration,
          songId: songId,
        );
        if (lyrics != null && !lyrics.isEmpty) {
          return lyrics;
        }
      } catch (e) {
        Logger.warn('Lyrics source ${source.id} failed: $e');
      }
    }

    return null;
  }

  bool _canUseExternalSources({required String title, required String artist}) {
    if (_isUnknownArtist(artist)) return false;
    if (_looksLikePathTitle(title)) return false;
    return true;
  }

  bool _isUnknownArtist(String artist) {
    final normalized = artist.trim().toLowerCase();
    if (normalized.isEmpty) return true;
    return normalized == 'unknown artist' ||
        normalized == '[unknown artist]' ||
        normalized == '[unknown]';
  }

  bool _looksLikePathTitle(String title) {
    final normalized = title.trim().toLowerCase();
    if (normalized.isEmpty) return true;
    final slashCount =
        '/'.allMatches(normalized).length + '\\'.allMatches(normalized).length;
    if (slashCount >= 2) return true;
    if (normalized.contains('cdimage')) return true;
    return false;
  }
}
