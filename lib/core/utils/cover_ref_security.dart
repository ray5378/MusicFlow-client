const _trustedCoverUrlPrefix = 'trusted-url:';

final RegExp _safeServerCoverIdPattern = RegExp(
  r'^(?!https?://)(?!file://)(?!/)(?!.*\.\.)(?!.*[\\/\s?#])[A-Za-z0-9._:-]{1,256}$',
);

final RegExp _trustedCoverUrlRefPattern = RegExp(
  r'^trusted-url:(https?://[^\s]+)$',
);

String? sanitizeServerCoverArtId(String? value) {
  final trimmed = value?.trim() ?? '';
  if (trimmed.isEmpty) return null;
  if (!_safeServerCoverIdPattern.hasMatch(trimmed)) {
    return null;
  }
  return trimmed;
}

bool isSafeServerCoverArtId(String? value) {
  return sanitizeServerCoverArtId(value) != null;
}

String toTrustedCoverUrlRef(String url) {
  final trimmed = url.trim();
  if (!_trustedCoverUrlRefPattern.hasMatch('$_trustedCoverUrlPrefix$trimmed')) {
    throw ArgumentError.value(url, 'url', 'Invalid trusted cover URL');
  }
  return '$_trustedCoverUrlPrefix$trimmed';
}

String? tryToTrustedCoverUrlRef(String? url) {
  final trimmed = url?.trim() ?? '';
  if (trimmed.isEmpty) return null;
  if (!_trustedCoverUrlRefPattern.hasMatch('$_trustedCoverUrlPrefix$trimmed')) {
    return null;
  }
  return '$_trustedCoverUrlPrefix$trimmed';
}

String? extractTrustedCoverUrl(String? value) {
  final trimmed = value?.trim() ?? '';
  if (trimmed.isEmpty) return null;
  final match = _trustedCoverUrlRefPattern.firstMatch(trimmed);
  return match?.group(1);
}

bool isTrustedCoverUrlRef(String? value) {
  return extractTrustedCoverUrl(value) != null;
}

/// 解析封面上报值，生成可直接交给 [CoverArtImage.coverArtId] 的引用。
/// 兼容两种形式：
/// - 完整 `http(s)://` 链接：包装成 `trusted-url:` 引用走服务端代理；
/// - 服务端 coverArtId（如 `al-xxx` / `pl-xxx`）：原样返回走 `/rest/getCoverArt`。
/// 两者都解析失败返回 null（不上传无效值，卡片显示封面占位）。
String? toCoverArtRef(String? cover) {
  final trimmed = cover?.trim() ?? '';
  if (trimmed.isEmpty) return null;
  if (trimmed.startsWith(_trustedCoverUrlPrefix)) {
    return extractTrustedCoverUrl(trimmed) != null ? trimmed : null;
  }
  final trusted = tryToTrustedCoverUrlRef(trimmed);
  if (trusted != null) return trusted;
  if (sanitizeServerCoverArtId(trimmed) != null) return trimmed;
  return null;
}
