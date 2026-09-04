import '../../data/models/music_library.dart';
import '../../data/models/server_address.dart';
import '../utils/server_url_security.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

/// DLNA 直投强制 http 拉流的共用工具。
///
/// 背景：很多 DLNA 渲染器（OpenWrt 上的 GMediaRender/GStreamer 精简构建等）
/// 没有 TLS 栈，拿到 `https` 拉流地址会一次 GET 都不发、直接拒拉，
/// 卡在 TRANSITIONING 且无声。因此交给设备的拉流 URL **一律强制 http**：
/// 控制面（客户端自己的 API 请求、换 token）维持当前线路不变，
/// 只重写「交给设备的 URL」的协议与主机（origin）。
///
/// 规则（ray 确认，2026-08-30）：
/// 1. http 地址可用性沿用地址池健康检查结果（不额外探测）；
/// 2. 手动锁定 https 线路时，拉流地址仍然强制 http（锁定只影响客户端控制面）；
/// 3. 换 token 的请求仍走客户端当前连接，仅拼接给设备的 URL 换 http 基地址；
/// 4. 打开直投面板即检测，无可用 http 地址则提示并禁止投流；
/// 5. 交给设备的所有资源 URL（流、封面等）一起换 http。

/// 直投面板在无可用 http 地址时展示的提示文案（ray 指定措辞）。
String kDlnaCastHttpRequiredHint(AppLocalizations loc) => loc.core_dlna_cast_required_hint;

/// 直投专用 http 基地址不存在时抛出，供上层区分「缺 http 配置」与一般失败。
class DlnaCastHttpUnavailableException implements Exception {
  const DlnaCastHttpUnavailableException();

  @override
  String toString() => 'DlnaCastHttpUnavailable: no http cast base (add an http connection in the music library)';
}

/// 判断服务器地址是否为明文 http。
bool isHttpServerUrl(String url) => url.toLowerCase().startsWith('http://');

/// 从媒体库地址中挑出直投专用的 http 基地址；没有可用 http 地址时返回 null。
///
/// 选择规则：
/// 1. 当前活跃地址本身是 http → 直接用（客户端此刻正通过它成功请求/播歌，
///    它的可达性是最新鲜的事实，优先级最高）；
/// 2. 否则取健康检查 ok 的 http 地址（[MusicLibrary.addresses] 已按优先级排序），
///    **忽略手动锁定**——锁定只影响客户端控制面，不限制投流拉流面；
/// 3. 都没有 → null，调用方必须禁止投流并提示 [kDlnaCastHttpRequiredHint]。
String? pickDlnaCastHttpBase({
  required List<ServerAddress> addresses,
  ServerAddress? activeAddress,
}) {
  final active = activeAddress;
  if (active != null && isHttpServerUrl(active.url)) {
    return normalizeServerBaseUrl(active.url);
  }
  for (final address in addresses) {
    if (address.status == ServerAddressStatus.ok && isHttpServerUrl(address.url)) {
      return normalizeServerBaseUrl(address.url);
    }
  }
  return null;
}

/// 把 [url] 重写为以 [base] 为 origin 的同路径 URL。
///
/// 服务端换 token 只返回相对路径 `/rest/dlna/stream/:token`，客户端拼主机；
/// 这里在拼接前把「主机来源」从客户端当前线路换成投流专用 http 基地址。
/// 路径与查询参数原样保留（鉴权参数与主机无关，重写后仍有效）。
/// 解析失败时原样返回 [url]，由后续流程按既有失败路径处理。
String rewriteUrlToBase(String url, String base) {
  if (url.isEmpty || base.isEmpty) return url;
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return url;
  final pathWithQuery = uri.path + (uri.hasQuery ? '?${uri.query}' : '');
  return joinServerUrl(base, pathWithQuery);
}

/// 组装投流专用 http 基地址；当前媒体库没有可用 http 地址时返回 null。
///
/// [library] 为当前活跃媒体库（其 [MusicLibrary.addresses] 即地址池快照），
/// [activeAddress] 为地址池当前活跃地址。两个输入任一变化（编辑媒体库地址、
/// 探测切换线路）时调用方应重新计算，保证面板打开与每次换 token 都用最新状态。
String? resolveDlnaCastHttpBase({
  required MusicLibrary? library,
  required ServerAddress? activeAddress,
}) {
  return pickDlnaCastHttpBase(
    addresses: library?.addresses ?? const <ServerAddress>[],
    activeAddress: activeAddress,
  );
}
