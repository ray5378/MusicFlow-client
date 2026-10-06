// b38b3 —— `lib/core/dlna/dlna_manager.dart` 剩余可获得覆盖的补测。
//
// 逐行核对 230 lcov 后，b37b 已判定多数剩余行为「不可达/防御分支」，但其中
// 两条其实**可达**、只是被此前分析漏掉：
//   731      seek 重建流的 `SoapControl.play` catch：`SoapControl.play` 并未
//            像 stop/getVolume 那样吞异常（见 soap_control.dart:135-140），设备
//            回 UPnP Fault 时会抛 SoapException → 命中该 catch。
//   742-744  seek 外层 catch：包住了 `_directStreamUrl(track.songId)`，而
//            `_directStreamUrl` 就是注入的 `streamUrlBuilder`（dlna_manager.dart:219），
//            测试注入一个「起播成功后开始抛错」的 builder 即可命中。
//
// 设备侧由本机 127.0.0.1 的真实 HttpServer 扮演（与 dlna_manager_cov_test.dart 同款）。
// 产品代码零改动；只读 lib。

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/dlna/dlna_manager.dart';
import 'package:musicflow_client/core/dlna/dlna_models.dart';

class _FakeDlnaServer {
  HttpServer? _server;
  int _port = 0;

  String transportState = 'PLAYING';
  int reportedDuration = 0;
  int? positionOverride;

  /// true 时所有 SOAP 动作都回 UPnP Fault（errorCode）：
  /// 逼出 SoapControl 里未吞异常的方法（play/setAvTransportUri）抛 SoapException。
  bool soapFault = false;

  /// 收到的全部 SOAPAction（去掉 service# 前缀），fault 模式下同样记录。
  final List<String> soapActions = <String>[];

  final List<String> playedUris = <String>[];
  String _currentUri = '';

  String get base => 'http://127.0.0.1:$_port';
  String get descriptionUrl => '$base/description.xml';
  String get avTransportUrl => '$base/AVTransport/control';
  String get renderingControlUrl => '$base/RenderingControl/control';

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
      final body = await utf8.decoder.bind(req).join();
      if (req.uri.path.endsWith('description.xml')) {
        await _respond(req, 200, _descriptionXml(), 'text/xml');
        return;
      }
      final soapAction =
          (req.headers.value('soapaction') ?? '').replaceAll('"', '');
      final action = soapAction.split('#').last;
      if (action.isEmpty) return;
      soapActions.add(action);
      if (soapFault) {
        await _respond(req, 200, _faultXml(action), 'text/xml');
        return;
      }
      switch (action) {
        case 'GetTransportInfo':
          await _respondSoap(
              req,
              action,
              '<CurrentTransportState>$transportState</CurrentTransportState>'
              '<CurrentTransportStatus>OK</CurrentTransportStatus>');
          return;
        case 'GetPositionInfo':
          final dur = reportedDuration;
          final pos = positionOverride ?? 0;
          await _respondSoap(
              req,
              action,
              '<TrackDuration>${_hms(dur)}</TrackDuration>'
              '<RelTime>${_hms(pos)}</RelTime>');
          return;
        case 'GetVolume':
          await _respondSoap(req, action, '<CurrentVolume>30</CurrentVolume>');
          return;
        case 'GetMute':
          await _respondSoap(req, action, '<CurrentMute>0</CurrentMute>');
          return;
        case 'SetAVTransportURI':
          _currentUri = _tagOf(body, 'CurrentURI') ?? _currentUri;
          break;
        case 'Play':
          if (_currentUri.isNotEmpty) playedUris.add(_currentUri);
          break;
        default:
          break;
      }
      await _respondSoap(req, action, '');
    } catch (e) {
      debugPrint('[_FakeDlnaServer] handle error: $e');
      try {
        req.response.statusCode = 500;
        await req.response.close();
      } catch (_) {}
    }
  }

  static String? _tagOf(String body, String tag) {
    final m = RegExp('<$tag[^>]*>([^<]*)</$tag>').firstMatch(body);
    return m?.group(1);
  }

  static String _hms(int sec) {
    final h = (sec ~/ 3600).toString().padLeft(2, '0');
    final m = ((sec % 3600) ~/ 60).toString().padLeft(2, '0');
    final s = (sec % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  static String _faultXml(String action) => '<?xml version="1.0"?>'
      '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
      '<s:Body><u:${action}Fault xmlns:u="urn:x">'
      '<errorCode>716</errorCode>'
      '<errorDescription>sim fault</errorDescription>'
      '</u:${action}Fault></s:Body></s:Envelope>';

  String _descriptionXml() => '<?xml version="1.0"?>'
      '<root xmlns="urn:schemas-upnp-org:device-1-0">'
      '<device>'
      '<deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>'
      '<friendlyName>模拟电视</friendlyName>'
      '<UDN>uuid:sim-mr-b38b3</UDN>'
      '<serviceList>'
      '<service>'
      '<serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>'
      '<controlURL>/AVTransport/control</controlURL>'
      '</service>'
      '<service>'
      '<serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>'
      '<controlURL>/RenderingControl/control</controlURL>'
      '</service>'
      '</serviceList>'
      '</device>'
      '</root>';

  Future<void> _respond(
      HttpRequest req, int code, String body, String type) async {
    final parts = type.split('/');
    req.response.statusCode = code;
    req.response.headers.contentType =
        ContentType(parts.first, parts.last, charset: 'utf-8');
    req.response.write(body);
    await req.response.close();
  }

  Future<void> _respondSoap(
      HttpRequest req, String action, String inner) async {
    const ns = 'urn:schemas-upnp-org:service:AVTransport:1';
    final out = '<?xml version="1.0"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
        '<s:Body><u:${action}Response xmlns:u="$ns">$inner</u:${action}Response>'
        '</s:Body></s:Envelope>';
    await _respond(req, 200, out, 'text/xml');
  }
}

List<DlnaCastTrack> _tracks({int? duration, int count = 4}) =>
    [for (var i = 0; i < count; i++) _track('song$i', '曲$i', duration)];

DlnaCastTrack _track(String id, String title, int? duration) => DlnaCastTrack(
      songId: id,
      title: title,
      artist: '模拟歌手',
      duration: duration,
    );

void main() {
  late _FakeDlnaServer server;
  late DlnaManager manager;

  /// 起播成功后是否让 streamUrlBuilder 抛错（用于逼出 seek 外层 catch）。
  var throwOnStreamUrl = false;

  Future<String> streamUrl(String songId) async {
    if (throwOnStreamUrl) throw StateError('stream-url boom');
    return 'http://server/stream/$songId.m3u8';
  }

  DlnaDevice controlled() => DlnaDevice(
        id: 'b38b3',
        name: '模拟电视',
        location: server.descriptionUrl,
        lastSeen: DateTime.now(),
        avTransportUrl: server.avTransportUrl,
        renderingControlUrl: server.renderingControlUrl,
      );

  setUp(() async {
    throwOnStreamUrl = false;
    server = _FakeDlnaServer();
    await server.start();
    manager = DlnaManager();
    await manager.init(streamUrlBuilder: streamUrl);
    await Future<void>.delayed(const Duration(milliseconds: 300));
  });

  tearDown(() async {
    await manager.dispose();
    await server.close();
  });

  // ==========================================================================
  // 731：seek 重建流的 SoapControl.play 失败 → catch 吞掉并继续重锚
  // ==========================================================================
  test('seek 重建时设备对 Play 回 UPnP Fault：派生的 play 失败被吞，仍完成重锚',
      () async {
    server.transportState = 'PLAYING';
    server.reportedDuration = 600;
    server.positionOverride = 30;

    final ok = await manager.startCast(controlled(), _tracks(duration: 600));
    expect(ok, isTrue, reason: '正常起播');
    await Future<void>.delayed(const Duration(milliseconds: 300));

    final playsBefore =
        server.soapActions.where((a) => a == 'Play').length;

    // 让设备对所有 SOAP 动作回 Fault：Stop 内部吞、setUri 抛被 725 catch、
    // Play 抛被 730/731 catch。三段落各自兜住后 seek 不向上抛。
    server.soapFault = true;
    await expectLater(
      manager.seek(42),
      completes,
      reason: 'seek 内部各段失败都不应向上抛',
    );
    expect(manager.isCasting, isTrue, reason: 'seek 失败不应断开投屏');
    expect(manager.castQueueIndex, 0, reason: 'seek 不应改变队列游标');
    // 关键证据：seek 重建确实把 Play 下发给了（正在回 Fault 的）设备，
    // 即 SoapControl.play 抛出了 SoapException 并被 731 的 catch 吞掉。
    expect(
      server.soapActions.where((a) => a == 'Play').length,
      greaterThan(playsBefore),
      reason: 'seek 重建应下发 Play；设备回 Fault → 命中 731 的 catch',
    );
    expect(server.soapActions.contains('SetAVTransportURI'), isTrue,
        reason: 'seek 重建也应下发 SetAVTransportURI');
  });

  // ==========================================================================
  // 742-744：seek 内 `_directStreamUrl` 抛错 → 外层 catch 兜住，不改状态
  // ==========================================================================
  test('seek 时 streamUrlBuilder 抛错：外层 catch 兜住，位置不被改写', () async {
    server.transportState = 'PLAYING';
    server.reportedDuration = 600;
    server.positionOverride = 10;

    final ok = await manager.startCast(controlled(), _tracks(duration: 600));
    expect(ok, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 300));

    final actionsBefore = List<String>.of(server.soapActions);

    // 起播已成功；此后换流 URL 构造抛错 → seek 在 line 703 抛 → 742-744 兜住，
    // 尚未下发任何 Stop/Set/Play（它们在 try 之后）。
    throwOnStreamUrl = true;
    await expectLater(
      manager.seek(55),
      completes,
      reason: '外层 catch（742-744）应吞掉 stream-url 异常',
    );
    expect(manager.isCasting, isTrue);
    expect(manager.castQueueIndex, 0);
    // 证据：构造直链失败发生在任何 SOAP 下发之前 → seek 期间无新增 Play/Set。
    final during = server.soapActions.sublist(actionsBefore.length);
    expect(during.contains('SetAVTransportURI'), isFalse,
        reason: '直链构造失败应早于 SetAVTransportURI（走 742 catch）');
    expect(during.contains('Play'), isFalse);
  });
}
