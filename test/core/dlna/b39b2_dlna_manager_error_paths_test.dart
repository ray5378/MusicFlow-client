// b39b2 —— Route B：dlna_manager 错误兜底路径补测。
//
// 覆盖 lcov 未命中行：
//   * dlna_manager.dart:630   stopCast 时 SoapControl.stop 抛错（设备不可达）
//   * dlna_manager.dart:907   状态轮询第 4 帧拉音量/静音失败
//   * dlna_manager.dart:1094  自动续播动作抛错被隔离（resume action error）
//
// 其余未命中行经源码核查不可达，逐行结论见文件末尾注释。
//
// 产品代码零改动；仅新增 test/。

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/dlna/dlna_manager.dart';
import 'package:musicflow_client/core/dlna/dlna_models.dart';

/// 本机模拟 DLNA 设备（SOAP 控制面，从 dlna_manager_cov_test.dart 精简而来）。
class _FakeDlnaServer {
  HttpServer? _server;
  int _port = 0;

  String transportState = 'PLAYING';
  int reportedDuration = 0;
  int? positionOverride;
  int volume = 30;
  bool muted = false;

  /// 返回 SOAP 错误（SoapControl 据此抛 SoapException）的动作名。
  final Set<String> faults = <String>{};

  final List<String> setAvUris = <String>[];
  final List<String> setNextUris = <String>[];
  final List<String> stoppedUris = <String>[];
  final Set<String> sawActions = <String>{};
  final List<String> rawRequests = <String>[];

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
    rawRequests.add('${req.method} ${req.uri.path} soapaction=${req.headers.value('soapaction')}');
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
      sawActions.add(action);
      final faulted = faults.contains(action);

      switch (action) {
        case 'GetTransportInfo':
          await _respondSoap(req, action,
              '<CurrentTransportState>$transportState</CurrentTransportState>'
              '<CurrentTransportStatus>OK</CurrentTransportStatus>'
              '<CurrentSpeed>1</CurrentSpeed>');
          return;
        case 'GetPositionInfo':
          final pos = positionOverride ?? _derivedPosition();
          await _respondSoap(req, action,
              '<TrackDuration>${_hms(reportedDuration)}</TrackDuration>'
              '<RelTime>${_hms(pos)}</RelTime>'
              '<TrackURI>$_currentUri</TrackURI>');
          return;
        case 'SetAVTransportURI':
          _currentUri =
              RegExp(r'<CurrentURI[^>]*>([^<]*)</CurrentURI>')
                      .firstMatch(body)
                      ?.group(1) ??
                  _currentUri;
          setAvUris.add(_currentUri);
          break;
        case 'SetNextAVTransportURI':
          setNextUris.add(
              RegExp(r'<NextURI[^>]*>([^<]*)</NextURI>')
                      .firstMatch(body)
                      ?.group(1) ??
                  '');
          break;
        case 'Play':
          _playStartAt = DateTime.now();
          break;
        case 'Stop':
          stoppedUris.add(_currentUri);
          break;
        default:
          break;
      }

      if (faulted) {
        await _respondFault(req, action);
        return;
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
    if (reportedDuration <= 0 || _playStartAt == null) return 0;
    final elapsed =
        DateTime.now().difference(_playStartAt!).inMilliseconds / 1000.0;
    return elapsed.floor().clamp(0, reportedDuration);
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
      '<friendlyName>模拟电视</friendlyName>'
      '<UDN>uuid:sim-mr-b39b2</UDN>'
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

void main() {
  // 注意：这里**不能**调用 TestWidgetsFlutterBinding.ensureInitialized() ——
  // 测试绑定会全局劫持 HttpClient（所有出站请求一律返回 400 的假响应），
  // SoapControl 走 `HttpClient()` 构造的真实 socket 就再也到不了本文件的
  // _FakeDlnaServer（dlna_manager_cov_test.dart 同理不装 binding）。
  late _FakeDlnaServer server;
  late DlnaManager manager;
  var castDisconnected = 0;
  final statuses = <DlnaDeviceStatus>[];
  // 自动续播用例的故障开关：置真后 streamUrlBuilder 对第二首抛普通异常。
  bool throwOnStreamS2 = false;

  DlnaDevice device() => DlnaDevice(
        id: 'b39b2',
        name: '模拟电视',
        location: server.descriptionUrl,
        lastSeen: DateTime.now(),
        avTransportUrl: server.avTransportUrl,
        renderingControlUrl: server.renderingControlUrl,
      );

  List<DlnaCastTrack> tracks() => <DlnaCastTrack>[
        const DlnaCastTrack(
            songId: 's1', title: '一', duration: 300, mimeHint: 'audio/mpeg'),
        const DlnaCastTrack(
            songId: 's2', title: '二', duration: 300, mimeHint: 'audio/mpeg'),
      ];

  setUp(() async {
    server = _FakeDlnaServer();
    await server.start();
    manager = DlnaManager();
    castDisconnected = 0;
    statuses.clear();
    manager.onCastDisconnected = () => castDisconnected++;
    manager.onStatusChanged = (s) => statuses.add(s);
    await manager.init(
      streamUrlBuilder: (songId) async {
        if (throwOnStreamS2 && songId == 's2') {
          throw StateError('stream url broken (b39b2)');
        }
        return 'http://server/stream/$songId';
      },
    );
    // 等 SsdpDiscovery 逐接口 bind + joinMulticast 完成（异步）。
    await Future<void>.delayed(const Duration(milliseconds: 400));
  });

  tearDown(() async {
    await manager.dispose();
    await server.close();
  });

  group('stopCast 错误兜底', () {
    test('设备端口已关闭 → SoapControl.stop 抛错被吞，投屏态照常清理（line 630）',
        () async {
      final ok = await manager.startCast(device(), tracks());
      expect(ok, isTrue, reason: '前置：正常起投');

      // 模拟设备掉线：直接关停 SOAP 服务，Stop 请求必然连接被拒。
      await server.close();

      // stopCast 不应抛出：SoapControl.stop 的异常被 catch 后仅记日志（630），
      // 随后照常清理投屏态并回调 onCastDisconnected。
      await manager.stopCast();
      expect(manager.isCasting, isFalse, reason: '异常路径同样应清理投屏态');
      expect(castDisconnected, 1, reason: '断连回调应照常触发');
    });
  });

  group('状态轮询音量读取失败', () {
    test('第 4 帧拉音量遇 SOAP fault → 吞错沿用旧音量（line 907）', () async {
      final ok = await manager.startCast(device(), tracks());
      expect(ok, isTrue);

      // GetVolume 返回 SOAP fault → SoapControl.getVolume 抛 SoapException
      // → 命中轮询内层 catch（907）。音量每 4 帧读一次（_volumeEveryNPolls=4，
      // 轮询周期 2s），留足 10s 保证至少跑到第 4 帧。
      server.faults.add('GetVolume');

      await Future<void>.delayed(const Duration(seconds: 12));

      expect(server.sawActions.contains('GetVolume'), isTrue,
          reason:
              '前置：第 4 帧确实发起了音量读取（并因 fault 抛错） (raw=${server.rawRequests.take(12).toList()}, frames=${statuses.length}, lastVol=${statuses.isEmpty ? '-' : statuses.last.volume}, lastState=${statuses.isEmpty ? '-' : statuses.last.state})');
      expect(manager.isCasting, isTrue, reason: '音量读取失败不应中断投屏');
      expect(statuses, isNotEmpty, reason: '轮询帧应持续回写状态');
      expect(statuses.last.volume, 0, reason: '读失败沿用上一帧（初始）音量');
    }, timeout: const Timeout(Duration(seconds: 30)));
  });

  group('自动续播动作异常隔离', () {
    test('曲末推进时换流 URL 抛错 → 被轮询 catch 隔离不崩溃（line 1094）',
        () async {
      server.reportedDuration = 300;
      server.positionOverride = 299; // 剩余 1s：首轮即落入 nearEnd 判定。
      throwOnStreamS2 = false;
      final ok = await manager.startCast(device(), tracks());
      expect(ok, isTrue);

      // 起投成功后让 streamUrlBuilder 对第二首抛普通 StateError：
      // 首轮轮询（2s）把状态写成 PLAYING/299/300；随后轮询（或曲末到点定时器
      // ~800ms 提前触发）发现 nearEnd → _advanceAfterCompletion（all 模式推进到
      // 下标 1）→ _playSwitch → _playCurrentTrack 里 _directStreamUrl('s2')
      // 抛错（仅 DlnaSongUnplayableException 会被吞，普通异常继续传播）→
      // 传播到轮询的续播动作 try → 命中 catch（1094），本帧状态回写与后续轮询
      // 不受影响。
      throwOnStreamS2 = true;

      await Future<void>.delayed(const Duration(seconds: 6));

      expect(manager.isCasting, isTrue, reason: '续播动作抛错不应中断投屏');
      expect(statuses, isNotEmpty);
      expect(statuses.last.state, 'PLAYING',
          reason: '抛错帧之后状态回写仍应执行');
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}

/*
 * 其余未命中行的可达性结论（源码核查，flutter test 环境下均不可达，不虚设用例）：
 *
 * - 296（_markStaleDevices 把 >10min 未见的设备置 available=false）：
 *   设备入列的唯二途径（SSDP alive 解析 / scanDevices 拉取 description）都以
 *   DateTime.now() 写 lastSeen，紧接着的 _markStaleDevices 不可能算出 >10 分钟；
 *   测试无法回拨 lastSeen（_devices 私有）。
 *
 * - 690-694（seek 无当前曲时回退 SOAP Seek）：[D-016] 已钉住现状 —— 走到该分支
 *   要求 _currentDevice.avTransportUrl 非 null 且 _queueIndex 越界；现有一条路径
 *   都不会只清队列不清设备（removeQueueItem 清空队列时先 stopCast，_clearCastState
 *   两者同清）。
 *
 * - 1086-1087（曲中段异常停播连击 ≥2 → _handleCastPlaybackError）：[D-023] 已钉住
 *   现状 —— prev 取自上一帧刚写回的 _currentStatus.state，ERROR 帧自己就改写了
 *   state，_stallCount 最多加 1 就被 PLAYING 帧清零，永远凑不满 2。
 *
 * - 1220-1221（_handleCastPlaybackError 函数体）：唯一调用点就是上面 1087 的
 *   不可达分支。
 */
