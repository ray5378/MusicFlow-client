// b37b — `lib/core/dlna/soap_control.dart` 补测（原 13 miss）。
//
// 未覆盖行：83/85(call 的 SocketException/Timeout 抛出)、98(stop 失败吞掉)、
// 155-162(seek 主体)、183(getTransportInfo 失败)、253(getVolume 失败)、
// 281(getMute 失败)。
//
// 策略：本机起真实 HttpServer 扮演 DLNA 设备的 SOAP 端点，
//   * 成功响应 → 覆盖 seek 主体与各 getter 的解析；
//   * UPnP Fault body → 覆盖 call 的 fault 分支；
//   * 连不上的地址 → SocketException；
//   * 收下请求不回的 server → TimeoutException。
// 产品代码零改动；只读 lib。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/dlna/soap_control.dart';

/// 一个最小 SOAP 端点：可编程返回 fault / 正常响应 / 挂起不回。
class _SoapServer {
  HttpServer? _server;
  int _port = 0;

  /// 观测到的 SOAPAction（去引号后的 `service#action`）。
  final List<String> actions = <String>[];
  final List<String> bodies = <String>[];

  /// true 时返回带 errorCode 的 UPnP Fault。
  bool fault = false;

  /// true 时收下请求但不回响应（用于触发客户端超时）。
  bool hang = false;

  /// GetTransportInfo / GetPositionInfo / GetVolume / GetMute 的回报体。
  String transportState = 'PLAYING';
  int volume = 42;
  bool muted = true;

  String get base => 'http://127.0.0.1:$_port';
  String get controlUrl => '$base/AVTransport/control';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _port = _server!.port;
    _server!.listen(_handle);
  }

  Future<void> close() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      final body = await utf8Decode(req);
      bodies.add(body);
      final action = (req.headers.value('soapaction') ?? '').replaceAll('"', '');
      actions.add(action);
      if (hang) {
        // 故意不响应：让客户端的 .timeout() 触发。
        return;
      }
      if (fault) {
        await _respond(req, _faultXml(action.split('#').last));
        return;
      }
      final name = action.split('#').last;
      String inner;
      switch (name) {
        case 'GetTransportInfo':
          inner = '<CurrentTransportState>$transportState</CurrentTransportState>';
        case 'GetVolume':
          inner = '<CurrentVolume>$volume</CurrentVolume>';
        case 'GetMute':
          inner = '<CurrentMute>${muted ? 1 : 0}</CurrentMute>';
        default:
          inner = '';
      }
      await _respond(req, _envelope(name, inner));
    } catch (_) {
      try {
        req.response.statusCode = 500;
        await req.response.close();
      } catch (_) {}
    }
  }

  Future<String> utf8Decode(HttpRequest req) async {
    try {
      return await utf8.decoder.bind(req).join();
    } catch (_) {
      return '';
    }
  }

  static String _envelope(String action, String inner) =>
      '<?xml version="1.0"?>'
      '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
      '<s:Body><u:${action}Response xmlns:u="urn:x">$inner</u:${action}Response>'
      '</s:Body></s:Envelope>';

  static String _faultXml(String action) =>
      '<?xml version="1.0"?>'
      '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
      '<s:Body><u:${action}Fault xmlns:u="urn:x">'
      '<errorCode>402</errorCode>'
      '<errorDescription>sim fault</errorDescription>'
      '</u:${action}Fault></s:Body></s:Envelope>';

  Future<void> _respond(HttpRequest req, String body) async {
    req.response.statusCode = 200;
    req.response.headers.contentType =
        ContentType('text', 'xml', charset: 'utf-8');
    req.response.write(body);
    await req.response.close();
  }
}

/// 取一个「确定连不上」的本地端口：先绑定再立刻释放。
Future<int> _deadPort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
}

void main() {
  late _SoapServer server;

  setUp(() async {
    server = _SoapServer();
    await server.start();
  });

  tearDown(() async {
    await server.close();
  });

  group('call 的传输层异常', () {
    test('连接被拒 → SocketException 归一为 SoapException(network error)', () async {
      final port = await _deadPort();
      await expectLater(
        SoapControl.call(
          'http://127.0.0.1:$port/AVTransport/control',
          'urn:x',
          'Play',
          const <String, String>{},
        ),
        throwsA(
          isA<SoapException>().having(
            (e) => e.message,
            'message',
            contains('network error'),
          ),
        ),
      );
    });

    test('服务端收下不回应 → 超时归一为 SoapException(request timed out)', () async {
      server.hang = true;
      await expectLater(
        SoapControl.call(
          server.controlUrl,
          'urn:x',
          'Play',
          const <String, String>{},
          timeout: const Duration(milliseconds: 250),
        ),
        throwsA(
          isA<SoapException>().having(
            (e) => e.message,
            'message',
            contains('timed out'),
          ),
        ),
      );
    });

    test('UPnP Fault body → SoapException 带 errorCode', () async {
      server.fault = true;
      await expectLater(
        SoapControl.call(
          server.controlUrl,
          'urn:x',
          'Play',
          const <String, String>{},
        ),
        throwsA(
          isA<SoapException>().having(
            (e) => e.message,
            'message',
            allOf(contains('402'), contains('sim fault')),
          ),
        ),
      );
    });

    test('SoapException.toString 带 action 前缀', () {
      const e = SoapException('Play', 'boom');
      expect(e.toString(), 'SoapException(Play): boom');
    });
  });

  group('AVTransport 控制方法', () {
    test('stop 失败被吞掉，不向上抛', () async {
      final port = await _deadPort();
      // stop 内部 catch 所有异常（soap_control.dart:97-99）。
      await expectLater(
        SoapControl.stop('http://127.0.0.1:$port/ctl'),
        completes,
      );
    });

    test('seek 组装 HH:MM:SS 目标并下发', () async {
      await SoapControl.seek(server.controlUrl, 3661); // 1h1m1s
      expect(server.actions.last, contains('#Seek'));
      expect(server.bodies.last, contains('<Target>01:01:01</Target>'));
      expect(server.bodies.last, contains('REL_TIME'));
    });

    test('seek 秒数不足一分钟时补零（6 秒 → 00:00:06）', () async {
      await SoapControl.seek(server.controlUrl, 6);
      expect(server.bodies.last, contains('<Target>00:00:06</Target>'));
    });

    test('getTransportInfo 成功解析状态；失败回落 UNKNOWN', () async {
      server.transportState = 'PAUSED_PLAYBACK';
      expect(await SoapControl.getTransportInfo(server.controlUrl),
          'PAUSED_PLAYBACK');

      final port = await _deadPort();
      expect(
        await SoapControl.getTransportInfo('http://127.0.0.1:$port/ctl'),
        'UNKNOWN',
      );
    });

    test('setNextAvTransportUri 成功返回 true，失败返回 false', () async {
      expect(
        await SoapControl.setNextAvTransportUri(
            server.controlUrl, 'http://x/next', '<x/>'),
        isTrue,
      );
      final port = await _deadPort();
      expect(
        await SoapControl.setNextAvTransportUri(
            'http://127.0.0.1:$port/ctl', 'http://x/next', '<x/>'),
        isFalse,
      );
    });
  });

  group('RenderingControl 方法', () {
    test('getVolume 成功解析整数；失败回落 0', () async {
      server.volume = 77;
      expect(await SoapControl.getVolume(server.controlUrl), 77);

      final port = await _deadPort();
      expect(await SoapControl.getVolume('http://127.0.0.1:$port/ctl'), 0);
    });

    test('getMute 成功解析布尔；失败回落 false', () async {
      server.muted = true;
      expect(await SoapControl.getMute(server.controlUrl), isTrue);
      server.muted = false;
      expect(await SoapControl.getMute(server.controlUrl), isFalse);

      final port = await _deadPort();
      expect(await SoapControl.getMute('http://127.0.0.1:$port/ctl'), isFalse);
    });

    test('setVolume / setMute 真下发对应动作', () async {
      await SoapControl.setVolume(server.controlUrl, 55);
      expect(server.actions.last, contains('#SetVolume'));
      expect(server.bodies.last, contains('<DesiredVolume>55</DesiredVolume>'));

      await SoapControl.setMute(server.controlUrl, true);
      expect(server.actions.last, contains('#SetMute'));
      expect(server.bodies.last, contains('<DesiredMute>1</DesiredMute>'));
    });
  });
}
