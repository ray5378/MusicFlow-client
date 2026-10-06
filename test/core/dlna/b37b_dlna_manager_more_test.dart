// b37b — `lib/core/dlna/dlna_manager.dart` 补测（原 19 miss）。
//
// 逐行核对后的可达目标（其余见文件末「未覆盖说明」）：
//   952      位置「明显回退」判定分支（设备自环/重播）→ 清空停滞计数。
//   980      真实时长未知且设备回报 TrackDuration>0 时回填 _currentRealDuration。
//   1100     _pollStatus 外层 catch（onStatusChanged 回调抛错）。
//   1229/1230 _advanceIndexForSkip 的 shuffle 分支。
//
// 设备侧由本机 127.0.0.1 的真实 HttpServer 扮演（SOAP 控制面），与既有
// dlna_manager_cov_test.dart 同款；本文件只补上述分支，避免与既有用例重复。
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

  /// 设备实际收到并「开始播放」的直链（按 Play 顺序记录）。
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

  static String _hms(int sec) {    final h = (sec ~/ 3600).toString().padLeft(2, '0');
    final m = ((sec % 3600) ~/ 60).toString().padLeft(2, '0');
    final s = (sec % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  String _descriptionXml() => '<?xml version="1.0"?>'
      '<root xmlns="urn:schemas-upnp-org:device-1-0">'
      '<device>'
      '<deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>'
      '<friendlyName>模拟电视</friendlyName>'
      '<UDN>uuid:sim-mr-b37b</UDN>'
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

Future<String> _streamUrl(String songId) async =>
    'http://server/stream/$songId.m3u8';

void main() {
  late _FakeDlnaServer server;
  late DlnaManager manager;

  DlnaDevice controlled() => DlnaDevice(
        id: 'b37b',
        name: '模拟电视',
        location: server.descriptionUrl,
        lastSeen: DateTime.now(),
        avTransportUrl: server.avTransportUrl,
        renderingControlUrl: server.renderingControlUrl,
      );

  setUp(() async {
    server = _FakeDlnaServer();
    await server.start();
    manager = DlnaManager();
    await manager.init(streamUrlBuilder: _streamUrl);
    await Future<void>.delayed(const Duration(milliseconds: 300));
  });

  tearDown(() async {
    await manager.dispose();
    await server.close();
  });

  // ==========================================================================
  // 952 / 980：设备上报位置「明显回退」与真实时长回填
  // ==========================================================================
  test('设备上报时长>0 且真实时长未知 → 回填当前时长且位置回退不清零曲末', () async {
    // 真实时长未知(duration:null) → advanceDuration 只能取设备上报的 TrackDuration，
    // 触发 980 的回填；随后设备位置由 300 回退到 290（回退 10s > 5s 阈值）→ 走 952。
    server.transportState = 'PLAYING';
    server.reportedDuration = 600;
    server.positionOverride = 300;

    final ok = await manager.startCast(controlled(), _tracks(duration: null));
    expect(ok, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 2300)); // 首帧落盘

    // 回退：300 → 290（差 10s > _positionWrapDrift=5）。
    server.positionOverride = 290;
    await Future<void>.delayed(const Duration(milliseconds: 4300)); // 触发若干帧

    // 位置回退还远未到尾，不应触发任何自动续播/切歌。
    expect(manager.castQueueIndex, 0, reason: '位置回退不应被当成曲末而切歌');
    expect(manager.isCasting, isTrue);
  });

  // ==========================================================================
  // 1100：_pollStatus 外层 catch（回调抛错不得中断轮询链）
  // ==========================================================================
  test('onStatusChanged 回调抛错被 _pollStatus 兜住，轮询链不自毁', () async {
    server.transportState = 'PLAYING';
    server.reportedDuration = 300;
    server.positionOverride = 10;

    var throws = 0;
    // 第 1 次回调（startCast 内部一帧）不抛，避免影响投屏建立；
    // 之后每次状态回写都抛，逼出 _pollStatus 的外层 catch（1100）。
    manager.onStatusChanged = (s) {
      if (throws++ >= 1) throw StateError('listener boom');
    };

    final ok = await manager.startCast(controlled(), _tracks(duration: 300));
    expect(ok, isTrue);

    await Future<void>.delayed(const Duration(milliseconds: 5000)); // 至少两帧

    // 回调抛错被吞（1100），管理器仍存活、投屏未被打断。
    expect(throws, greaterThanOrEqualTo(2), reason: '回调应被多次触发并抛错');
    expect(manager.isCasting, isTrue, reason: '回调抛错不应中断轮询/投屏');
    expect(manager.castQueueIndex, 0);
  });

  // ==========================================================================
  // 1229/1230：_advanceIndexForSkip 的 shuffle 分支
  // ==========================================================================
  test('pre-cast 预检判无源：shuffle 模式走随机跳过分支并停下', () async {
    final probe = DlnaManager();
    probe.setPlayMode('shuffle');
    await probe.init(
      streamUrlBuilder: _streamUrl,
      probeSong: (songId) async => false, // 全部判无源
    );
    try {
      final ok = await probe.startCast(controlled(), _tracks(duration: 6));
      expect(ok, isTrue, reason: '预检无限跳不应挂死 startCast');
      expect(probe.castQueueIndex, inInclusiveRange(0, 3),
          reason: 'shuffle 无源时随机跳过，游标应落在队列内');
      expect(server.playedUris, isEmpty, reason: '全部无源时不应有任何曲目真正下发');
    } finally {
      await probe.dispose();
    }
  });

  test('pre-cast 预检判无源：shuffle 单曲队列无法跳到别首 → 停在当前首', () async {
    final probe = DlnaManager();
    probe.setPlayMode('shuffle');
    await probe.init(
      streamUrlBuilder: _streamUrl,
      probeSong: (songId) async => false,
    );
    try {
      final ok = await probe.startCast(
        controlled(),
        _tracks(duration: 6, count: 1),
      );
      expect(ok, isTrue);
      expect(probe.castQueueIndex, 0,
          reason: 'shuffle 单曲队列 _advanceIndexForSkip 返回 false，停在当前首');
      expect(server.playedUris, isEmpty);
    } finally {
      await probe.dispose();
    }
  });

  // ==========================================================================
  // 未覆盖说明（原 19 miss 中其余行不可达/防御分支）：
  //   296   _markStaleDevices 的「lastSeen>10min 置离线」体：设备 lastSeen 恒由
  //         DeviceDescriptionParser.fetch 取 now()，测试无法把已入列设备的时间戳
  //         拨回 10 分钟前（无注入点）→ 不可达。
  //   630   _stopDevice 内 SoapControl.stop 的 catch：SoapControl.stop 自身已吞掉
  //         全部异常，永不抛出 → 该 catch 不可达。
  //   690/692/694 seek 的 SOAP REL_TIME 兜底：走到该处前提 _currentDevice!=null，
  //         而 track==null 意味着队列空——两者互斥（D-016 已标注不可达）。
  //   731/742/744 seek 重建各段 catch：需设备侧 Stop/Set/Play 抛异常，但 SoapControl
  //         各方法对 Set 已 try/catch、Stop 亦吞异常，测试无法从设备侧逼出
  //         seek 外层 catch（SoapException 只在网络层失败时抛，且被上游吞）。
  //   907   _pollStatus 读音量/静音的 catch：SoapControl.getVolume/getMute 自身吞异常
  //         恒不抛 → 不可达。
  //   1086/1087 _stallCount≥2 触发的自动跳过：D-023 已证实逐帧连击条件自相矛盾、
  //         计数无法凑满 2 → 不可达（真实缺陷，见报告）。
  //   1220/1221 _handleCastPlaybackError 体：仅被 1087 调用，随 D-023 一同不可达。
  // ==========================================================================
}
