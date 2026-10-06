// batch40 E2 —— DlnaManager 域缺陷修复验证（D-015 / D-019 / D-023 / D-024）。
//
// 与 dlna_manager_cov_test.dart 同款姿势：设备侧由本机 127.0.0.1 的真实
// HttpServer 扮演（SOAP 控制面 + description.xml），可编程故障注入；
// 不装 TestWidgetsFlutterBinding（真 socket 测试会被劫持 HttpClient）。
//
// 本文件断言的是**修复后**的行为：
//   * D-015  seek 重建失败 → onStatusChanged 外显 ERROR + 下一轮轮询自动重投一次；
//            重投仍失败则停止自动重试（不再死循环）。
//   * D-019  追加到队尾且「下一首」正指向新曲 → 不预置 SetNext；
//            对照组：下一首指向既有曲目 → 照旧预置。
//   * D-023  曲中段设备恒报 ERROR → 连击凑满 2 自动跳下一首（原兜底不可达已修）。
//   * D-024  SsdpDiscovery.search 总超时收紧 + scanDevices 单台 fetch 限时参数可用。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/dlna/dlna_manager.dart';
import 'package:musicflow_client/core/dlna/dlna_models.dart';
import 'package:musicflow_client/core/dlna/ssdp_discovery.dart';

/// 本机模拟 DLNA 设备（SOAP + description.xml 一体），按 b40e2 需求裁剪：
/// 额外支持「接下来 N 次 SetAVTransportURI 返回故障」（驱动 D-015 重投路径）。
class _FakeDlnaServer {
  HttpServer? _server;
  int _port = 0;

  String transportState = 'PLAYING';
  int reportedDuration = 0;
  bool reportPosition = true;
  int? positionOverride;

  /// >0 时接下来的 N 次 SetAVTransportURI 回 SOAP 故障。
  int failNextSetAv = 0;

  final List<String> playedUris = <String>[];
  final List<String> setAvUris = <String>[];
  final List<String> setNextUris = <String>[];
  final List<String> stoppedUris = <String>[];

  String _currentUri = '';
  DateTime? _playStartAt;

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
          await _respondSoap(req, action,
              '<CurrentTransportState>$transportState</CurrentTransportState>'
              '<CurrentTransportStatus>OK</CurrentTransportStatus>'
              '<CurrentSpeed>1</CurrentSpeed>');
          return;
        case 'GetPositionInfo':
          final dur = reportedDuration;
          final pos = positionOverride ?? _derivedPosition();
          await _respondSoap(req, action,
              '<TrackDuration>${_hms(dur)}</TrackDuration>'
              '<RelTime>${_hms(pos)}</RelTime>'
              '<TrackURI>$_currentUri</TrackURI>');
          return;
        case 'SetAVTransportURI':
          _currentUri = _tagOf(body, 'CurrentURI') ?? _currentUri;
          setAvUris.add(_currentUri);
          if (failNextSetAv > 0) {
            failNextSetAv--;
            await _respondFault(req, action);
            return;
          }
          break;
        case 'SetNextAVTransportURI':
          setNextUris.add(_tagOf(body, 'NextURI') ?? '');
          break;
        case 'Play':
          _playStartAt = DateTime.now();
          if (_currentUri.isNotEmpty) playedUris.add(_currentUri);
          break;
        case 'Stop':
          stoppedUris.add(_currentUri);
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

  int _derivedPosition() {
    if (!reportPosition || reportedDuration <= 0 || _playStartAt == null) {
      return 0;
    }
    final elapsed =
        DateTime.now().difference(_playStartAt!).inMilliseconds / 1000.0;
    return elapsed.floor().clamp(0, reportedDuration);
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

  String _descriptionXml() => '<?xml version="1.0"?>'
      '<root xmlns="urn:schemas-upnp-org:device-1-0">'
      '<device>'
      '<deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>'
      '<friendlyName>b40e2模拟电视</friendlyName>'
      '<manufacturer>b40e2-sim</manufacturer>'
      '<modelName>b40e2-model</modelName>'
      '<UDN>uuid:sim-mr-b40e2</UDN>'
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

  Future<void> _respond(HttpRequest req, int code, String body, String type) async {
    final parts = type.split('/');
    req.response.statusCode = code;
    req.response.headers.contentType =
        ContentType(parts.first, parts.last, charset: 'utf-8');
    req.response.write(body);
    await req.response.close();
  }

  Future<void> _respondSoap(HttpRequest req, String action, String inner) async {
    const ns = 'urn:schemas-upnp-org:service:AVTransport:1';
    final out = '<?xml version="1.0"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
        '<s:Body><u:${action}Response xmlns:u="$ns">$inner</u:${action}Response>'
        '</s:Body></s:Envelope>';
    await _respond(req, 200, out, 'text/xml');
  }

  Future<void> _respondFault(HttpRequest req, String action) async {
    final out = '<?xml version="1.0"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
        '<s:Body><u:${action}Fault xmlns:u="urn:x">'
        '<errorCode>401</errorCode>'
        '<errorDescription>sim fault</errorDescription>'
        '</u:${action}Fault></s:Body></s:Envelope>';
    await _respond(req, 200, out, 'text/xml');
  }
}

/// 轮询等待条件成立（超时返回最终状态，便于断言给原因）。
Future<bool> _waitUntil(
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 6),
}) async {
  final sw = Stopwatch()..start();
  while (sw.elapsed < timeout) {
    if (cond()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return cond();
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

  DlnaDevice _controlled() => DlnaDevice(
        id: 'b40e2',
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
    // 等 SsdpDiscovery 逐接口 bind + joinMulticast 完成（异步，bind 失败时静默跳过）。
    await Future<void>.delayed(const Duration(milliseconds: 300));
  });

  tearDown(() async {
    await manager.dispose();
    await server.close();
  });

  group('D-015 seek 重建失败自动重投', () {
    test('重建失败立即外显 ERROR，下一轮轮询自动重投成功后恢复 PLAYING', () async {
      await manager.startCast(_controlled(), _tracks(duration: 600));
      final statuses = <DlnaDeviceStatus>[];
      manager.onStatusChanged = (s) => statuses.add(s);
      final setAvBeforeSeek = server.setAvUris.length;

      // 让接下来的第 1 次 Set（即 seek 重建那次）失败；重投那次放行。
      server.failNextSetAv = 1;
      await manager.seek(42);

      // 失败信号必须外显：onStatusChanged 推 ERROR（原缺陷是全程静默）。
      expect(
        statuses.map((s) => s.state),
        contains('ERROR'),
        reason: 'D-015：seek 重建失败必须经 onStatusChanged 外显，不得静默',
      );
      expect(
        server.setAvUris.length,
        greaterThan(setAvBeforeSeek),
        reason: '重建确实尝试了 SetAVTransportURI(timeOffset=42)',
      );
      expect(server.setAvUris.last, contains('timeOffset=42'));
      final attemptsAfterSeek = server.setAvUris.length;

      // 下一轮轮询（2s 周期）自动重投一次：Set 放行 → 恢复 PLAYING。
      final recovered = await _waitUntil(
        () => statuses.isNotEmpty && statuses.last.state == 'PLAYING',
        timeout: const Duration(seconds: 5),
      );
      expect(recovered, isTrue, reason: '自动重投成功后应恢复 PLAYING 外显');
      expect(
        server.setAvUris.length,
        greaterThan(attemptsAfterSeek),
        reason: '重投应再次下发 SetAVTransportURI',
      );
      expect(server.setAvUris.last, contains('timeOffset=42'));
      expect(manager.castQueueIndex, 0, reason: '同曲重投不改变游标');
      expect(manager.isCasting, isTrue, reason: '重投成功不回滚投屏态');
    });

    test('重投仍失败：只重投一次即放弃，不再无限循环', () async {
      await manager.startCast(_controlled(), _tracks(duration: 600));
      final statuses = <DlnaDeviceStatus>[];
      manager.onStatusChanged = (s) => statuses.add(s);

      // 两次 Set（seek 重建 + 自动重投）全部失败。
      server.failNextSetAv = 2;
      await manager.seek(42);

      // 等过两个轮询周期以上，确认只发生 2 次 Set 尝试（重建 + 重投一次）。
      await Future<void>.delayed(const Duration(milliseconds: 5600));
      final attempts1 = server.setAvUris.length;
      await Future<void>.delayed(const Duration(milliseconds: 2600));
      final attempts2 = server.setAvUris.length;

      expect(attempts2, attempts1, reason: '放弃自动重试后不应再有 Set 尝试');
      expect(
        statuses.map((s) => s.state),
        contains('ERROR'),
        reason: '两次失败都应外显 ERROR',
      );
      expect(manager.isCasting, isTrue);
    });
  });

  group('D-019 enqueueSongs 队尾预置抑制', () {
    test('追加后「下一首」正指向队尾新曲：不预置 SetNext', () async {
      // 当前曲为队列最后一首（index 3），all 模式下 startCast 预置的是回绕的 index 0。
      await manager.startCast(
        _controlled(),
        _tracks(duration: 600),
        startIndex: 3,
      );
      final setNextBefore = server.setNextUris.length;
      expect(setNextBefore, greaterThan(0), reason: 'startCast 时应已预置下一首');

      await manager.enqueueSongs(<DlnaCastTrack>[_track('song9', '追加曲', 600)]);

      expect(manager.castQueue, hasLength(5));
      expect(manager.castQueue.last.songId, 'song9');
      expect(manager.castQueueIndex, 3, reason: '追加不改变游标');
      expect(
        server.setNextUris,
        hasLength(setNextBefore),
        reason: 'D-019：下一首指向本次追加的队尾新曲时不应下发 SetNext，'
            '等真正切歌时再由客户端主动推',
      );
    });

    test('对照组：下一首指向既有曲目时照旧预置', () async {
      await manager.startCast(_controlled(), _tracks(duration: 600));
      final setNextBefore = server.setNextUris.length;

      await manager.enqueueSongs(<DlnaCastTrack>[_track('song9', '追加曲', 600)]);

      expect(manager.castQueue, hasLength(5));
      // 当前 index 0，all 模式下一首 = index 1（既有曲目 song1）→ 照旧预置。
      expect(
        server.setNextUris.length,
        greaterThan(setNextBefore),
        reason: '下一首指向既有曲目时预置行为不变',
      );
    });
  });

  group('D-023 曲中段异常停止自动跳过', () {
    test('设备恒报 ERROR：连击凑满 2 触发自动跳下一首（原兜底不可达已修）', () async {
      // 长曲 + 小进度：nearEnd / wallDone / deviceEnded / positionStuck 全不成立，
      // 只有 stall 分支可命中。原缺陷：ERROR 帧把 _currentStatus.state 改写成 ERROR，
      // 下一帧 prevState 不再是 PLAYING，连击最多到 1 —— 兜底不可达。
      server.reportedDuration = 300;
      server.positionOverride = 8;
      await manager.startCast(_controlled(), _tracks(duration: 300));
      await Future<void>.delayed(const Duration(milliseconds: 2400)); // 首帧落盘 PLAYING

      server.transportState = 'ERROR'; // 曲中段设备恒报 ERROR（不再翻转恢复）
      final advanced = await _waitUntil(
        () => manager.castQueueIndex == 1,
        timeout: const Duration(seconds: 8),
      );
      // 立刻恢复 PLAYING，避免后续帧继续连击跳到更后面的曲目。
      server.transportState = 'PLAYING';
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(advanced, isTrue,
          reason: 'D-023：曲中段连续异常停止应触发自动跳下一首，游标推进到 1');
      expect(manager.castQueueIndex, 1);
      expect(
        server.playedUris.length,
        2,
        reason: '跳下一首应真实下发 Set+Play（song0 起播一次 + song1 一次）',
      );
    });
  });

  group('D-024 扫描超时保护', () {
    test('SsdpDiscovery.search 总超时收紧后仍按时返回且不抛错', () async {
      final discovery = SsdpDiscovery();
      final sw = Stopwatch()..start();
      final locations = await discovery.search(
        timeout: const Duration(milliseconds: 400),
        bindAddresses: <String>['127.0.0.1'],
      );
      sw.stop();
      expect(locations, isA<List<String>>());
      expect(
        sw.elapsed,
        lessThan(const Duration(seconds: 3)),
        reason: 'D-024：拨号+等待阶段应受总超时约束，不再可能被卡死拖长',
      );
    });

    test('scanDevices 支持单台 fetch 限时参数且正常完成', () async {
      final devices = await manager.scanDevices(
        perDeviceFetchTimeout: const Duration(milliseconds: 300),
      );
      expect(devices, isA<List<DlnaDevice>>());
      expect(manager.isCasting, isFalse, reason: '扫描不影响投屏态');
    });
  });
}
