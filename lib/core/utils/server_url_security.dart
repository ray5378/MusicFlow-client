bool isSupportedServerUrl(String rawUrl) {
  final uri = Uri.tryParse(rawUrl.trim());
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    return false;
  }

  final scheme = uri.scheme.toLowerCase();
  return scheme == 'http' || scheme == 'https';
}

bool isInsecureHttpUrl(String rawUrl) {
  final uri = Uri.tryParse(rawUrl.trim());
  if (uri == null || uri.host.isEmpty) {
    return false;
  }

  return uri.scheme.toLowerCase() == 'http';
}

/// 归一化服务器基地址：去空白 + 去尾部斜杠 + 丢弃 query/fragment。
///
/// 为什么必须做：baseUrl 会被手工拼接成 `baseUrl + '/rest/getCoverArt'`
/// （封面/音频流/下载 URL 不走 Dio，无法依赖 Dio 的路径规范化）。
/// 一旦 baseUrl 带尾斜杠（从浏览器地址栏复制必然带 `/`），拼接结果是
/// `http://host:port//rest/getCoverArt`。MusicFlow 服务端对 `//rest/...`
/// **返回 200 + SPA index.html 而不是 404**，于是图片解码器与播放器静默拿到
/// 一段 HTML —— 表现为「所有封面不显示 + 所有歌曲无法播放」，且无任何报错。
///
/// 保留子路径部署能力（反代挂在 `/music` 下时 `/music` 不能被吃掉）。
String normalizeServerBaseUrl(String rawUrl) {
  final trimmed = rawUrl.trim();
  if (trimmed.isEmpty) return '';

  final uri = Uri.tryParse(trimmed);
  if (uri == null || !uri.hasAuthority) {
    // 非法/相对地址：退化为字符串去尾斜杠，不抛异常（避免影响登录流程）。
    var fallback = trimmed;
    while (fallback.length > 1 && fallback.endsWith('/')) {
      fallback = fallback.substring(0, fallback.length - 1);
    }
    return fallback;
  }

  var path = uri.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }

  return Uri(
    scheme: uri.scheme,
    userInfo: uri.userInfo.isEmpty ? null : uri.userInfo,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: path,
  ).toString();
}

/// 安全拼接服务器 URL，保证 base 与 path 之间恰好一个斜杠。
///
/// 所有不经过 Dio 的 URL（封面 / 音频流 / 下载）都必须用它，
/// 禁止 `baseUrl + path` 直接相加（见 [normalizeServerBaseUrl] 的说明）。
String joinServerUrl(String baseUrl, String path) {
  final base = normalizeServerBaseUrl(baseUrl);
  if (base.isEmpty) return '';
  if (path.isEmpty) return base;

  final suffix = path.startsWith('/') ? path : '/$path';
  return '$base$suffix';
}
