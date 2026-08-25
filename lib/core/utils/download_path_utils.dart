import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

const _defaultPathSegmentMaxLength = 64;
const _defaultSuffixMaxLength = 16;
const _downloadFileNameMaxLength = 96;

/// Builds a download file path that is guaranteed to stay under [rootDir].
/// When [title]/[artist] are provided, the drop-in file is named
/// 「歌名 - 歌手」（可读，保留中文），否则回退为 [songId] 的稳定安全名。
String buildDownloadFilePath({
  required String rootDir,
  required String libraryId,
  required String songId,
  required String suffix,
  String? title,
  String? artist,
}) {
  final trimmedRoot = rootDir.trim();
  if (trimmedRoot.isEmpty) {
    throw ArgumentError.value(
      rootDir,
      'rootDir',
      'Download root cannot be empty',
    );
  }

  final safeLibraryId = sanitizeDownloadPathSegment(
    libraryId,
    fallback: 'library',
  );
  final fileName = buildDownloadFileName(
    title: title,
    artist: artist,
    songId: songId,
  );
  final safeSuffix = sanitizeDownloadFileSuffix(suffix);
  final normalizedRoot = p.normalize(trimmedRoot);
  final candidate = p.normalize(
    p.join(normalizedRoot, safeLibraryId, '$fileName.$safeSuffix'),
  );

  if (!p.isWithin(normalizedRoot, candidate)) {
    throw ArgumentError.value(
      candidate,
      'candidate',
      'Resolved download path escaped the download root',
    );
  }

  return candidate;
}

/// 构建可读的下载文件名「歌名 - 歌手」。
/// 仅删除文件名非法字符（`\ / : * ? " < > |` 与控制符），保留中文等可读字符；
/// 无可用标题时回退到 [songId] 的稳定安全名。
String buildDownloadFileName({
  String? title,
  String? artist,
  String? songId,
}) {
  final titlePart = sanitizeDownloadFileNameText(title);
  final artistPart = sanitizeDownloadFileNameText(artist);

  final String name;
  if (titlePart.isEmpty && artistPart.isEmpty) {
    name = sanitizeDownloadPathSegment(songId ?? 'song', fallback: 'song');
  } else {
    name = artistPart.isNotEmpty
        ? '$titlePart - $artistPart'
        : titlePart;
  }
  return _truncateDownloadFileName(name);
}

/// 清理单个文件名片段：删除文件名非法字符/控制符，合并多余下划线。
String sanitizeDownloadFileNameText(String? value) {
  final trimmed = value?.trim() ?? '';
  final cleaned = trimmed
      .replaceAll(RegExp(r'[\\/:*?"<>|\u0000-\u001f]'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^[.\s_]+|[.\s_]+$'), '');
  return (cleaned == '.' || cleaned == '..') ? '' : cleaned;
}

String _truncateDownloadFileName(String name) {
  final trimmed = name.replaceAll(RegExp(r'[. ]+$'), '');
  final finalName =
      trimmed.length <= _downloadFileNameMaxLength
      ? trimmed
      : trimmed.substring(0, _downloadFileNameMaxLength);
  return finalName.replaceAll(RegExp(r'[. ]+$'), '');
}

bool isPathWithinRoot({
  required String rootDir,
  required String candidatePath,
  bool allowRoot = false,
}) {
  final normalizedRoot = p.normalize(rootDir.trim());
  final normalizedCandidate = p.normalize(candidatePath.trim());

  if (allowRoot && p.equals(normalizedRoot, normalizedCandidate)) {
    return true;
  }

  return p.isWithin(normalizedRoot, normalizedCandidate);
}

/// Rewrites a user or server controlled path segment into a stable safe name.
String sanitizeDownloadPathSegment(
  String value, {
  required String fallback,
  int maxLength = _defaultPathSegmentMaxLength,
}) {
  final trimmed = value.trim();
  final normalized = trimmed
      .replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');

  var base = normalized;
  if (base.isEmpty || base == '.' || base == '..') {
    base = fallback;
  }

  final clipped = base.length > maxLength ? base.substring(0, maxLength) : base;
  final needsHash =
      clipped != trimmed ||
      normalized != trimmed ||
      base != normalized ||
      trimmed.isEmpty ||
      trimmed == '.' ||
      trimmed == '..' ||
      base.length > maxLength;

  if (!needsHash) {
    return clipped;
  }

  final digest = sha256
      .convert(utf8.encode(trimmed))
      .toString()
      .substring(0, 12);
  return _appendStableSuffix(clipped, '_$digest', maxLength);
}

/// Rewrites a file suffix into a safe extension.
String sanitizeDownloadFileSuffix(
  String suffix, {
  String fallback = 'mp3',
  int maxLength = _defaultSuffixMaxLength,
}) {
  final cleaned = suffix.trim().replaceAll(RegExp(r'[^A-Za-z0-9]+'), '');
  final normalized = cleaned.toLowerCase();
  if (normalized.isEmpty) {
    return fallback;
  }
  if (normalized.length <= maxLength) {
    return normalized;
  }
  return normalized.substring(0, maxLength);
}

String _appendStableSuffix(String base, String suffix, int maxLength) {
  if (base.length + suffix.length <= maxLength) {
    return '$base$suffix';
  }

  final prefixLength = maxLength - suffix.length;
  if (prefixLength <= 0) {
    return suffix.substring(suffix.length - maxLength);
  }

  return '${base.substring(0, prefixLength)}$suffix';
}
