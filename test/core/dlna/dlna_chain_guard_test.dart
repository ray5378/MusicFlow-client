import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/dlna/cast_http.dart';
import 'package:musicflow_client/core/dlna/dlna_manager.dart';
import 'package:musicflow_client/core/dlna/dlna_models.dart';

/// ============================================================================
/// 播放链路守卫（用户拍板 2026-09-09，防回归）：
///   1. 投前预检判「无可用音源」→ 按播放模式跳下一首，不把死链扔给设备干等；
///   2. 服务端换 token 409（DlnaSongUnplayableException）→ 同样跳下一首；
///   3. 预检请求自身失败（网络抖）≠ 源失效 → 不误杀，照投交设备实测兜底；
///   4. 单曲队列判无源 → 不投、不抛异常（startCast 正常返回，状态由看门狗接管）。
/// 换源治愈 / 无停播阈值（本机 + 直投）由对应实现保证；此处守住直投侧的关键分支。
/// ============================================================================

/// 最小化本地模拟 DLNA 设备：只实现 AVTransport 关键动作并记录实际收到的直链。
class _MiniFakeDevice {
  HttpServer? _server;
  late int _port;
  String state = 'STOPPED';
  String _currentUri = '';
  final List<String> playedUris = <String>[];

  String get controlUrl => 'http://127.0.0.1:$_port/AVTransport/control';
  String get renderingUrl => 'http://127.0.0.1:$_port/RenderingControl/control';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _port = _server!.port;
    _server!.listen(_handle);
  }

  Future<void> close() => _server?.close(force: true) ?? Future<void>.value();

  Future<void> _handle(HttpRequest req) async {
    String body = '';
    try {
      body = await utf8.decoder.bind(req).join();
    } catch (_) {}
    final action =
        (req.headers.value('soapaction') ?? '').replaceAll('"', '').split('#').last;
    String inner;
    switch (action) {
      case 'GetTransportInfo':
        inner = '<CurrentTransportState>$state</CurrentTransportState>'
            '<CurrentTransportStatus>OK</CurrentTransportStatus>'
            '<CurrentSpeed>1</CurrentSpeed>';
        break;
      case 'GetPositionInfo':
        inner = '<TrackDuration>00:00:00</TrackDuration>'
            '<RelTime>00:00:00</RelTime>'
            '<TrackURI>$_currentUri</TrackURI>';
        break;
      case 'SetAVTransportURI':
        _currentUri =
            RegExp(r'<CurrentURI>([^<]*)</CurrentURI>').firstMatch(body)?.group(1) ?? '';
        inner = '';
        break;
      case 'SetNextAVTransportURI':
        inner = '';
        break;
      case 'Play':
        state = 'PLAYING';
        playedUris.add(_currentUri);
        inner = '';
        break;
      case 'Stop':
        state = 'STOPPED';
        inner = '';
        break;
      default:
        inner = '';
    }
    req.response.headers.set('Content-Type', 'text/xml; charset="utf-8"');
    await req.response.addStream(Stream.fromIterable([
      utf8.encode('<?xml version="1.0" encoding="utf-8"?>'
          '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
          '<s:Body><u:${action}Response xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">'
          '$inner</u:${action}Response></s:Body></s:Envelope>'),
    ]));
    await req.response.close();
  }
}

DlnaDevice _device(_MiniFakeDevice fake) => DlnaDevice(
      id: 'guard-device',
      name: '守卫音箱',
      location: 'http://127.0.0.1/desc.xml',
      lastSeen: DateTime(2026, 1, 1),
      avTransportUrl: fake.controlUrl,
      renderingControlUrl: fake.renderingUrl,
    );

List<DlnaCastTrack> _tracks([int n = 3]) => <DlnaCastTrack>[
      for (var i = 0; i < n; i++)
        DlnaCastTrack(songId: 'song$i', title: '曲$i', artist: '守卫歌手'),
    ];

void main() {
  late _MiniFakeDevice fake;
  late DlnaManager manager;

  setUp(() async {
    fake = _MiniFakeDevice();
    await fake.start();
    manager = DlnaManager();
  });

  tearDown(() async {
    await manager.dispose();
    await fake.close();
  });

  test('预检判无源 → 跳下一首继续投，不把死链扔给设备', () async {
    await manager.init(
      streamUrlBuilder: (songId) async => 'http://server/stream/$songId.m3u8',
      probeSong: (songId) async => songId != 'song1', // song1 判无源
    );
    manager.setPlayMode('all');

    final ok = await manager.startCast(_device(fake), _tracks(), startIndex: 1);

    expect(ok, isTrue);
    expect(manager.castQueueIndex, 2, reason: 'song1 无源应跳到 song2');
    expect(fake.playedUris, ['http://server/stream/song2.m3u8'],
        reason: '设备只应收到 song2 的直链，死链 song1 不下发');
  });

  test('换 token 409（DlnaSongUnplayableException）→ 同样跳下一首', () async {
    await manager.init(
      streamUrlBuilder: (songId) async {
        if (songId == 'song0') throw DlnaSongUnplayableException(songId);
        return 'http://server/stream/$songId.m3u8';
      },
      probeSong: (songId) async => true, // 预检全放行，仅 token 阶段 409
    );
    manager.setPlayMode('all');

    final ok = await manager.startCast(_device(fake), _tracks(), startIndex: 0);

    expect(ok, isTrue);
    expect(manager.castQueueIndex, 1);
    expect(fake.playedUris, ['http://server/stream/song1.m3u8']);
  });

  test('预检请求自身失败（网络抖）不误杀：照常投递', () async {
    await manager.init(
      streamUrlBuilder: (songId) async => 'http://server/stream/$songId.m3u8',
      probeSong: (songId) async => throw Exception('probe request failed'),
    );
    manager.setPlayMode('all');

    final ok = await manager.startCast(_device(fake), _tracks(), startIndex: 0);

    expect(ok, isTrue);
    expect(fake.playedUris, ['http://server/stream/song0.m3u8'],
        reason: '探测失败≠源失效，应照投交设备实测兜底');
  });

  test('order 模式末首无源 → 自然停止：不投、不抛、不回环', () async {
    await manager.init(
      streamUrlBuilder: (songId) async => 'http://server/stream/$songId.m3u8',
      probeSong: (songId) async => false, // 全部判无源
    );
    manager.setPlayMode('order');

    final ok = await manager.startCast(
      _device(fake),
      _tracks(2),
      startIndex: 1, // 末首
    );

    expect(ok, isTrue, reason: '判无源只跳过，不视为投屏失败');
    expect(fake.playedUris, isEmpty, reason: 'order 队尾无源应自然停止');
    expect(manager.castQueueIndex, 1);
  });

  test('整队判无源 → 一整圈后停在当前状态（不挂死、不无限绕圈）', () async {
    var probeCalls = 0;
    await manager.init(
      streamUrlBuilder: (songId) async => 'http://server/stream/$songId.m3u8',
      probeSong: (songId) async {
        probeCalls++;
        return false;
      },
    );
    manager.setPlayMode('all');

    final ok = await manager.startCast(_device(fake), _tracks(3), startIndex: 0);

    expect(ok, isTrue);
    expect(fake.playedUris, isEmpty);
    expect(probeCalls, lessThanOrEqualTo(3), reason: '单次激活最多绕一整圈，不得无限绕');
  });
}
