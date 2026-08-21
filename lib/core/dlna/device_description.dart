import 'dart:async';
import 'dart:io';
import 'dlna_models.dart';

/// 设备描述 XML 解析器
/// 从 description.xml 提取设备信息和服务 URL
class DeviceDescriptionParser {
  /// 从 location URL 获取设备信息
  static Future<DlnaDevice?> fetch(String location) async {
    try {
      final uri = Uri.parse(location);
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 5);

      final request = await client.getUrl(uri);
      final response = await request.close();
      final xml = await response.transform(
        const SystemEncoding().decoder,
      ).join();
      client.close(force: true);

      return _parseXml(xml, location);
    } catch (_) {
      return null;
    }
  }

  /// 解析 description.xml 内容
  static DlnaDevice? _parseXml(String xml, String location) {
    // 提取 friendlyName
    final friendlyName = _extractTag(xml, 'friendlyName') ?? '未知设备';

    // 提取 UDN
    final udn = _extractTag(xml, 'UDN') ?? '';
    final id = udn.replaceFirst(RegExp(r'^uuid:', caseSensitive: false), '');
    if (id.isEmpty) return null;

    // 提取 manufacturer 和 model
    final manufacturer = _extractTag(xml, 'manufacturer');
    final model = _extractTag(xml, 'modelName');

    // 解析服务列表，找到 AVTransport 和 RenderingControl
    String? avTransportUrl;
    String? renderingControlUrl;

    final serviceRegex = RegExp(
      r'<service\b[^>]*>([\s\S]*?)<\/service>',
      caseSensitive: false,
    );

    for (final match in serviceRegex.allMatches(xml)) {
      final block = match.group(1)!;
      final serviceType = _extractTag(block, 'serviceType') ?? '';
      final controlUrl = _extractTag(block, 'controlURL') ?? '';

      if (controlUrl.isEmpty) continue;

      if (RegExp(r'AVTransport', caseSensitive: false).hasMatch(serviceType)) {
        avTransportUrl = _toAbsolute(controlUrl, location);
      } else if (RegExp(r'RenderingControl', caseSensitive: false)
          .hasMatch(serviceType)) {
        renderingControlUrl = _toAbsolute(controlUrl, location);
      }
    }

    // 没有 AVTransport 的设备无法投屏
    if (avTransportUrl == null) return null;

    return DlnaDevice(
      id: id,
      name: friendlyName,
      location: location,
      manufacturer: manufacturer,
      model: model,
      avTransportUrl: avTransportUrl,
      renderingControlUrl: renderingControlUrl,
      lastSeen: DateTime.now(),
      available: true,
    );
  }

  /// 提取 XML 标签内容
  static String? _extractTag(String xml, String tag) {
    final regex = RegExp(
      '<$tag[^>]*>([^<]*)</$tag>',
      caseSensitive: false,
    );
    final match = regex.firstMatch(xml);
    return match?.group(1)?.trim();
  }

  /// 将相对 URL 转为绝对 URL
  static String _toAbsolute(String url, String base) {
    try {
      return Uri.parse(url).resolve(base).toString();
    } catch (_) {
      return url;
    }
  }
}
