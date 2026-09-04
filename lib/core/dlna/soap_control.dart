import 'dart:async';
import 'dart:io';

/// SOAP 控制模块
/// 向 DLNA 设备发送 AVTransport 和 RenderingControl 命令
class SoapControl {
  static const String _avTransport =
      'urn:schemas-upnp-org:service:AVTransport:1';
  static const String _renderingControl =
      'urn:schemas-upnp-org:service:RenderingControl:1';
  static const Duration _timeout = Duration(seconds: 8);

  /// 检测类方法(GetTransportInfo/GetPositionInfo)的短超时：这两路是本帧自动续播
  /// 判定的关键帧，慢设备若迟迟不返回会导致错过曲末窗口；给 2s 短超时让检测帧
  /// 每次都尽快返回(失败按 UNKNOWN/0 处理)。控制类方法保持默认 8s 超时。
  static const Duration _detectTimeout = Duration(seconds: 2);

  /// 构造 SOAP 信封
  static String _envelope(String service, String action,
      Map<String, String> args) {
    final inner = args.entries
        .map((e) => '<${e.key}>${_escapeXml(e.value)}</${e.key}>')
        .join();
    return '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body><u:$action xmlns:u="$service">$inner</u:$action></s:Body>'
        '</s:Envelope>';
  }

  /// XML 转义
  static String _escapeXml(String s) {
    return s
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }

  /// 发送 SOAP 请求
  /// [timeout] 覆盖默认超时：检测类方法传短超时(_detectTimeout)以快速返回，
  /// 控制类方法(设置类)省略该参数则用默认 8s。
  static Future<String> call(
    String controlUrl,
    String service,
    String action,
    Map<String, String> args, {
    Duration timeout = _timeout,
  }) async {
    final body = _envelope(service, action, args);
    final uri = Uri.parse(controlUrl);

    final client = HttpClient();
    client.connectionTimeout = timeout;

    try {
      final request = await client.postUrl(uri);
      request.headers.contentType =
          ContentType('text', 'xml', charset: 'utf-8');
      request.headers.set('SOAPAction', '"$service#$action"');
      request.write(body);

      // 连接超时之外，继续对响应接收施加同样的短超时，确保每帧都能尽快收敛。
      final response = await request.close().timeout(timeout);
      final text = await response.transform(const SystemEncoding().decoder).join();

      // 检查 UPnP 错误
      if (text.contains('<s:Fault') || text.contains('errorCode')) {
        final codeMatch = RegExp(r'<errorCode>([^<]*)</errorCode>', caseSensitive: false)
            .firstMatch(text);
        final descMatch = RegExp(r'<errorDescription>([^<]*)</errorDescription>', caseSensitive: false)
            .firstMatch(text);
        final code = codeMatch?.group(1) ?? '?';
        final desc = descMatch?.group(1) ?? 'fault';
        throw SoapException(action, 'UPnP error $code: $desc');
      }

      return text;
    } on SocketException catch (e) {
      throw SoapException(action, 'network error: ${e.message}');
    } on TimeoutException {
      throw SoapException(action, 'request timed out');
    } finally {
      client.close(force: true);
    }
  }

  // ==================== AVTransport 方法 ====================

  /// 停止播放
  static Future<void> stop(String controlUrl) async {
    try {
      await call(controlUrl, _avTransport, 'Stop', {'InstanceID': '0'});
    } catch (_) {}
  }

  /// 设置播放 URI
  static Future<void> setAvTransportUri(
    String controlUrl,
    String uri,
    String metadata,
  ) async {
    await call(controlUrl, _avTransport, 'SetAVTransportURI', {
      'InstanceID': '0',
      'CurrentURI': uri,
      'CurrentURIMetaData': metadata,
    });
  }

  /// 设置下一首（无缝切歌）
  static Future<bool> setNextAvTransportUri(
    String controlUrl,
    String uri,
    String metadata,
  ) async {
    try {
      await call(controlUrl, _avTransport, 'SetNextAVTransportURI', {
        'InstanceID': '0',
        'NextURI': uri,
        'NextURIMetaData': metadata,
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 开始播放
  static Future<void> play(String controlUrl) async {
    await call(controlUrl, _avTransport, 'Play', {
      'InstanceID': '0',
      'Speed': '1',
    });
  }

  /// 暂停播放
  static Future<void> pause(String controlUrl) async {
    await call(controlUrl, _avTransport, 'Pause', {
      'InstanceID': '0',
    });
  }

  /// 跳转进度
  static Future<void> seek(String controlUrl, int seconds) async {
    final h = (seconds ~/ 3600).toString().padLeft(2, '0');
    final m = ((seconds % 3600) ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    final target = '$h:$m:$s';

    await call(controlUrl, _avTransport, 'Seek', {
      'InstanceID': '0',
      'Unit': 'REL_TIME',
      'Target': target,
    });
  }

  /// 获取传输状态
  static Future<String> getTransportInfo(String controlUrl) async {
    try {
      final xml = await call(
        controlUrl,
        _avTransport,
        'GetTransportInfo',
        {'InstanceID': '0'},
        timeout: _detectTimeout,
      );
      final match = RegExp(r'<CurrentTransportState>([^<]*)</CurrentTransportState>', caseSensitive: false)
          .firstMatch(xml);
      return match?.group(1)?.trim() ?? 'UNKNOWN';
    } catch (_) {
      return 'UNKNOWN';
    }
  }

  /// 获取播放进度
  static Future<({int position, int duration})> getPositionInfo(
    String controlUrl,
  ) async {
    try {
      final xml = await call(
        controlUrl,
        _avTransport,
        'GetPositionInfo',
        {'InstanceID': '0'},
        timeout: _detectTimeout,
      );

      final relTime = RegExp(r'<RelTime>([^<]*)</RelTime>', caseSensitive: false)
          .firstMatch(xml)
          ?.group(1)
          ?.trim();
      final trackDur = RegExp(r'<TrackDuration>([^<]*)</TrackDuration>', caseSensitive: false)
          .firstMatch(xml)
          ?.group(1)
          ?.trim();

      return (
        position: _parseHms(relTime ?? '00:00:00'),
        duration: _parseHms(trackDur ?? '00:00:00'),
      );
    } catch (_) {
      return (position: 0, duration: 0);
    }
  }

  /// 解析 HH:MM:SS 格式为秒数
  static int _parseHms(String hms) {
    final match = RegExp(r'(\d+):(\d+):(\d+)').firstMatch(hms);
    if (match == null) return 0;
    return int.parse(match.group(1)!) * 3600 +
        int.parse(match.group(2)!) * 60 +
        int.parse(match.group(3)!);
  }

  // ==================== RenderingControl 方法 ====================

  /// 设置音量
  static Future<void> setVolume(String controlUrl, int volume) async {
    await call(controlUrl, _renderingControl, 'SetVolume', {
      'InstanceID': '0',
      'Channel': 'Master',
      'DesiredVolume': volume.toString(),
    });
  }

  /// 获取音量
  static Future<int> getVolume(String controlUrl) async {
    try {
      final xml = await call(
        controlUrl,
        _renderingControl,
        'GetVolume',
        {'InstanceID': '0', 'Channel': 'Master'},
      );
      final match = RegExp(r'<CurrentVolume>([^<]*)</CurrentVolume>', caseSensitive: false)
          .firstMatch(xml);
      return int.tryParse(match?.group(1)?.trim() ?? '') ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// 设置静音
  static Future<void> setMute(String controlUrl, bool muted) async {
    await call(controlUrl, _renderingControl, 'SetMute', {
      'InstanceID': '0',
      'Channel': 'Master',
      'DesiredMute': muted ? '1' : '0',
    });
  }

  /// 获取静音状态
  static Future<bool> getMute(String controlUrl) async {
    try {
      final xml = await call(
        controlUrl,
        _renderingControl,
        'GetMute',
        {'InstanceID': '0', 'Channel': 'Master'},
      );
      final match = RegExp(r'<CurrentMute>([^<]*)</CurrentMute>', caseSensitive: false)
          .firstMatch(xml);
      final value = match?.group(1)?.trim().toLowerCase() ?? '0';
      return value == '1' || value == 'true';
    } catch (_) {
      return false;
    }
  }
}

/// SOAP 调用异常
class SoapException implements Exception {
  final String action;
  final String message;

  const SoapException(this.action, this.message);

  @override
  String toString() => 'SoapException($action): $message';
}
