import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/dlna/cast_http.dart';
import 'package:musicflow_client/core/dlna/dlna_manager.dart';
import 'package:musicflow_client/core/dlna/dlna_models.dart';

/// ============================================================================
/// DlnaManager 状态机 / 设备管理 / 队列编辑 / seek 重建 覆盖率补测（batch17）
/// ----------------------------------------------------------------------------
/// 与 `dlna_auto_next_sim_test.dart` 的分工：
///   - 那个文件专注「自动续播三路判据」(nearEnd / wallDone / deviceEnded / 卡死硬触发)；
///   - 本文件专注「其余全部逻辑分支」：状态位读取、播放模式、设备发现与别名/
///     禁用/删除、切歌序列化、SetNext 预置与降级、pause/resume、seek 重投流、
///     volume/mute、投屏队列增删改序、保活摘除、预检无限跳、轮询帧游标对齐。
///
/// 设备侧一律由 `_FakeDlnaServer`（本机 127.0.0.1 上的真实 HttpServer）扮演，
/// 同时承担三件事：
///   1. `/description.xml` → `DeviceDescriptionParser.fetch` 的发现链路；
///   2. `/AVTransport/control` + `/RenderingControl/control` → SOAP 控制面；
///   3. 可编程错误注入（fault 动作集合）→ 复现设备/网络异常分支。
/// 通过 `positionOverride` / `transportOverride` / `alternateTransportState`
/// 可在**不依赖墙钟**的前提下精确摆出轮询每一帧看到的 (position, state)，
/// 让续播判定可以被确定性验证。
/// ============================================================================

/// 本机模拟 DLNA 设备（SOAP + description.xml 一体）
class _FakeDlnaServer {
  HttpServer? _server;
  int _port = 0;

  // ==================== 设备行为开关 ====================

  /// GetTransportInfo 回报的传输态（[alternateTransportState] 打开时被逐帧翻转）。
  String transportState = 'PLAYING';

  /// true 时 GetTransportInfo 在 PLAYING / ERROR 之间逐帧翻转，
  /// 用于复现「设备反复崩/恢复」——stall 分支要求**逐帧** prevState==PLAYING，
  /// 恒定 ERROR 只会命中一次连击，翻转让两次连击都能成立。
  bool alternateTransportState = false;
  int _alternateFlip = 0;

  /// GetPositionInfo 回报的整曲时长（秒）；0 表示 rawHTTP 设备不报时长。
  int reportedDuration = 0;

  /// 是否回报真实进度；false 时恒报 position=0。
  bool reportPosition = true;

  /// GetVolume / GetMute 的当前值。
  int volume = 30;
  bool muted = false;

  /// 非 null 时 GetPositionInfo 直接回报该值（跳过墙钟推导，供确定性摆帧）。
  int? positionOverride;

  /// 需要返回 SOAP 错误（body 含 <errorCode>，SoapControl 据此抛 SoapException）的动作名。
  final Set<String> faults = <String>{};

  // ==================== 观测记录 ====================

  final List<String> playedUris = <String>[];
  final List<String> setAvUris = <String>[];
  final List<String> setNextUris = <String>[];
  final List<String> stoppedUris = <String>[];
  final List<String> seekTargets = <String>[];
  final List<int> setVolumeCalls = <int>[];
  final List<bool> setMuteCalls = <bool>[];
  final Set<String> sawActions = <String>{};

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
      final soapAction = (req.headers.value('soapaction') ?? '').replaceAll('"', '');
      final action = soapAction.split('#').last;
      if (action.isEmpty) return;

      sawActions.add(action);
      final faulted = faults.contains(action);

      switch (action) {
        case 'GetTransportInfo':
          if (faulted) {
            await _respondFault(req, action);
            return;
          }
          final state = alternateTransportState
              ? ((_alternateFlip++) % 2 == 0 ? 'ERROR' : 'PLAYING')
              : transportState;
          await _respondSoap(req, action,
              '<CurrentTransportState>$state</CurrentTransportState>'
              '<CurrentTransportStatus>OK</CurrentTransportStatus>'
              '<CurrentSpeed>1</CurrentSpeed>');
          return;

        case 'GetPositionInfo':
          if (faulted) {
            await _respondFault(req, action);
            return;
          }
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
          break;

        case 'SetNextAVTransportURI':
          if (faulted) {
            await _respondFault(req, action);
            return;
          }
          setNextUris.add(_tagOf(body, 'NextURI') ?? '');
          break;

        case 'Play':
          _playStartAt = DateTime.now();
          if (_currentUri.isNotEmpty) playedUris.add(_currentUri);
          break;

        case 'Stop':
          if (faulted) {
            await _respondFault(req, action);
            return;
          }
          stoppedUris.add(_currentUri);
          break;

        case 'Pause':
          break;

        case 'Seek':
          seekTargets.add(_tagOf(body, 'Target') ?? '');
          break;

        case 'GetVolume':
          await _respondSoap(req, action, '<CurrentVolume>$volume</CurrentVolume>');
          return;

        case 'GetMute':
          await _respondSoap(
              req, action, '<CurrentMute>${muted ? 1 : 0}</CurrentMute>');
          return;

        case 'SetVolume':
          setVolumeCalls.add(
              int.tryParse(_tagOf(body, 'DesiredVolume') ?? '0') ?? 0);
          break;

        case 'SetMute':
          setMuteCalls.add((_tagOf(body, 'DesiredMute') ?? '0') == '1');
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
      '<friendlyName>模拟电视</friendlyName>'
      '<manufacturer>b17-sim</manufacturer>'
      '<modelName>b17-model</modelName>'
      '<UDN>uuid:sim-mr-b17</UDN>'
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

// ==================== SSDP 注入工具 ====================

/// 与生产 `SsdpDiscovery._skipInterface` 同一套过滤规则，保证发送端与监听端同网段。
bool _isSkippableInterface(NetworkInterface iface) {
  final name = iface.name.toLowerCase();
  const keywords = <String>[
    'vethernet',
    'hyper',
    'tailscale',
    'wireguard',
    'wg0',
    'radmin',
    'mihomo',
    'vpn',
    'tunnel',
    'tap',
    'tun',
    'virtualbox',
    'vmware',
    'loopback',
    'zerotier',
    'hamachi',
    'easytier',
  ];
  if (keywords.any(name.contains)) return true;
  if (name == 'et' || name.startsWith('et_') || name.startsWith('et-')) return true;
  return iface.addresses.any(_isBlockedIpv4);
}

bool _isBlockedIpv4(InternetAddress a) {
  if (a.type != InternetAddressType.IPv4) return false;
  final ip = a.address;
  return ip.startsWith('127.') ||
      ip.startsWith('169.254.') ||
      ip.startsWith('198.18.') ||
      ip.startsWith('198.19.') ||
      ip.startsWith('100.64.');
}

Future<List<NetworkInterface>> _physicalInterfaces() async {
  try {
    final all = await NetworkInterface.list(includeLinkLocal: false);
    return all.where((i) => !_isSkippableInterface(i)).toList();
  } catch (_) {
    return const [];
  }
}

/// NOTIFY 发送端 socket（跨用例复用，避免反复 bind 端口）。
final List<RawDatagramSocket> _notifySockets = <RawDatagramSocket>[];
RawDatagramSocket? _loopbackNotifySocket;

Future<void> _ensureNotifySockets() async {
  if (_notifySockets.isNotEmpty || _loopbackNotifySocket != null) return;
  for (final iface in await _physicalInterfaces()) {
    final ips =
        iface.addresses.where((a) => a.type == InternetAddressType.IPv4).toList();
    if (ips.isEmpty) continue;
    try {
      // 环回口不做 join（生产代码过滤掉 loopback 接口，join 也收不到）；
      // 其余物理接口按生产同规则 join 多播组，保证与监听端同网段。
      final sock = await RawDatagramSocket.bind(
        ips.first.address == '127.0.0.1'
            ? InternetAddress.loopbackIPv4
            : InternetAddress(ips.first.address),
        0,
      );
      try {
        sock.joinMulticast(InternetAddress('239.255.255.250'), iface);
      } catch (_) {}
      _notifySockets.add(sock);
    } catch (_) {}
  }
  if (_notifySockets.isEmpty) {
    try {
      _loopbackNotifySocket =
          await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    } catch (_) {}
  }
}

void _closeNotifySockets() {
  for (final s in _notifySockets) {
    try {
      s.close();
    } catch (_) {}
  }
  _notifySockets.clear();
  try {
    _loopbackNotifySocket?.close();
  } catch (_) {}
  _loopbackNotifySocket = null;
}

/// 向 DLNA 被动监听端口(1900)发一条 NOTIFY：物理网卡多播 + 回环单播双路投递，
/// 任一路径被 `SsdpDiscovery` 监听器接住即可驱动 `DlnaManager._handleSsdpEvent`。
void _fireNotify(String location, {required bool alive}) {
  final msg = [
    'NOTIFY * HTTP/1.1',
    'HOST: 239.255.255.250:1900',
    'NT: urn:schemas-upnp-org:device:MediaRenderer:1',
    'NTS: ssdp:${alive ? 'alive' : 'byebye'}',
    'LOCATION: $location',
    'USN: uuid:sim-mr-b17::urn:schemas-upnp-org:device:MediaRenderer:1',
    '',
    '',
  ].join('\r\n');
  final data = msg.codeUnits;
  for (final s in _notifySockets) {
    s.send(data, InternetAddress('239.255.255.250'), 1900);
  }
  _loopbackNotifySocket?.send(data, InternetAddress.loopbackIPv4, 1900);
}

/// 轮询等待条件成立（超时返回最终状态，便于在断言里给出原因）。
Future<bool> _waitUntil(
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 3),
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

  /// 指向本机模拟设备的 DlnaDevice（带 SOAP 控制地址）。
  DlnaDevice _controlled() => DlnaDevice(
        id: 'b17',
        name: '模拟电视',
        location: server.descriptionUrl,
        lastSeen: DateTime.now(),
        avTransportUrl: server.avTransportUrl,
        renderingControlUrl: server.renderingControlUrl,
      );

  /// 只有 AVTransport、没有 RenderingControl 的模拟设备（走音量/静音早退分支）。
  DlnaDevice _noRendering() => DlnaDevice(
        id: 'b17-norc',
        name: '无音量控制电视',
        location: server.descriptionUrl,
        lastSeen: DateTime.now(),
        avTransportUrl: server.avTransportUrl,
      );

  setUp(() async {
    server = _FakeDlnaServer();
    await server.start();
    manager = DlnaManager();
    await manager.init(streamUrlBuilder: _streamUrl);
    // 等 SsdpDiscovery 逐接口 bind + joinMulticast 完成（异步，bind 失败时静默跳过）。
    await Future<void>.delayed(const Duration(milliseconds: 400));
  });

  tearDown(() async {
    await manager.dispose();
    await server.close();
    _closeNotifySockets();
  });

  // ==========================================================================
  // 1. 状态位读取与播放模式
  // ==========================================================================
  group('状态位读取与播放模式', () {
    test('未投屏时各 getter 返回安全初值', () {
      expect(manager.isCasting, isFalse, reason: '未投屏时不应处于投屏态');
      expect(manager.castQueue, isEmpty, reason: '投屏队列初始为空');
      expect(manager.castQueueIndex, -1, reason: '未投屏时游标为 -1');
      expect(manager.playMode, 'all', reason: '默认列表循环');
      expect(manager.isMuted, isFalse, reason: '默认不静音');
      expect(manager.castPath, DlnaCastPath.direct, reason: '恒为逐首直传档位');
      expect(manager.isSelfLooping, isFalse, reason: '客户端逐首续播，不自行整队循环');
      // 未经 _probeDevice 时能力位取 DeviceCapability 默认值：只有「可直连拉流」
      // 默认为 true（绝大多数渲染器都具备），另两项保守默认 false。
      expect(manager.capability.supportsDirectHttp, isTrue);
      expect(manager.capability.supportsSetNext, isFalse);
      expect(manager.capability.reportsDuration, isFalse);
    });

    test('setPlayMode 只接受 order/one/all/shuffle，非法值被丢弃', () {
      for (final mode in <String>['order', 'one', 'all', 'shuffle']) {
        manager.setPlayMode(mode);
        expect(manager.playMode, mode, reason: '合法模式 $mode 应生效');
      }
      // 先把模式钉成 order，再喂非法值：若非法值被有效忽略，模式应原地不动。
      manager.setPlayMode('order');
      manager.setPlayMode('loop');
      expect(
        manager.playMode,
        'order',
        reason: '[D-017 锁定修复] 非法模式仍被忽略、_playMode 保持原值，'
            '但已不再静默 —— setPlayMode 现在会打一条 warn 日志，'
            'UI 传参错误可在诊断日志里定位',
      );
      manager.setPlayMode('');
      expect(manager.playMode, 'order', reason: '空串同样被忽略');
    });
  });

  // ==========================================================================
  // 2. 设备发现与设备管理
  // ==========================================================================
  group('设备发现与设备管理', () {
    /// 发 alive 并等 description.xml 解析出设备，返回该设备。
    Future<DlnaDevice> _announceAndWait() async {
      await _ensureNotifySockets();
      for (var i = 0; i < 8; i++) {
        _fireNotify(server.descriptionUrl, alive: true);
        await Future<void>.delayed(const Duration(milliseconds: 150));
        final found = manager.devices
            .where((d) => d.location == server.descriptionUrl)
            .toList();
        if (found.isNotEmpty) return found.first;
      }
      fail('SSDP alive 未能在超时内解析出设备：devices=${manager.devices.length}');
    }

    test('SSDP alive → 设备入列，携带解析后的 SOAP 控制地址且可用', () async {
      final device = await _announceAndWait();

      // 只按 location 取本机模拟设备：测试网段里可能还有真实 renderer 被动发现，
      // 设备表总长会漂移。
      expect(
        manager.devices.where((d) => d.location == server.descriptionUrl).toList(),
        hasLength(1),
        reason: 'alive 应产出 1 台本机模拟设备',
      );
      expect(device.id, 'sim-mr-b17', reason: 'UDN 去掉 uuid: 前缀后为 id');
      expect(device.name, '模拟电视', reason: 'friendlyName 应被解析');
      expect(device.manufacturer, 'b17-sim');
      expect(device.model, 'b17-model');
      expect(device.available, isTrue);
      expect(device.disabled, isFalse);
      expect(device.avTransportUrl, server.avTransportUrl);
      expect(device.renderingControlUrl, server.renderingControlUrl);
      expect(
        manager.onlineDevices
            .where((d) => d.location == server.descriptionUrl)
            .toList(),
        hasLength(1),
        reason: '可用且未禁用的本机设备应落在 onlineDevices',
      );
    });

    test('同 id 设备再次 alive 不会重复入列（走 existing 覆盖分支）', () async {
      final first = await _announceAndWait();
      _fireNotify(server.descriptionUrl, alive: true);
      await Future<void>.delayed(const Duration(milliseconds: 250));

      final mine =
          manager.devices.where((d) => d.location == server.descriptionUrl).toList();
      expect(mine, hasLength(1), reason: '同 id 覆盖写回而非追加');
      expect(mine.first.id, first.id);
    });

    test('SSDP byebye → 已发现设备自动标记为不可用', () async {
      await _announceAndWait();

      _fireNotify(server.descriptionUrl, alive: false);
      final ok = await _waitUntil(() => manager.devices.any((d) => !d.available));
      expect(ok, isTrue, reason: 'byebye 应把该 location 的设备置为不可用');

      final device =
          manager.devices.firstWhere((d) => d.location == server.descriptionUrl);
      expect(device.available, isFalse);
      expect(
        manager.onlineDevices
            .where((d) => d.location == server.descriptionUrl)
            .toList(),
        isEmpty,
        reason: '不可用设备不应再计入 onlineDevices',
      );
    });

    test('别名 / 禁用 / 删除三件套：改别名即生效，禁用后不再在线，删除即出列', () async {
      final device = await _announceAndWait();

      manager.setDeviceAlias(device.id, '客厅音箱');
      expect(manager.devices.firstWhere((d) => d.id == device.id).alias,
          '客厅音箱');

      manager.setDeviceDisabled(device.id, true);
      final disabled = manager.devices.firstWhere((d) => d.id == device.id);
      expect(disabled.disabled, isTrue);
      expect(
        manager.onlineDevices.where((d) => d.id == device.id).toList(),
        isEmpty,
        reason: '被禁用的设备不应出现在 onlineDevices',
      );

      manager.removeDevice(device.id);
      expect(manager.devices.where((d) => d.id == device.id).toList(), isEmpty);
      expect(manager.onlineDevices, isEmpty);
    });

    test('byebye 指向未登记设备时是空操作（遍历不到即静默返回）', () async {
      await _ensureNotifySockets();
      _fireNotify('http://127.0.0.1:9/none.xml', alive: false);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(manager.devices, isEmpty, reason: '未登记的 location 不应产生设备');
    });

    test('onDevicesChanged 在别名 / 禁用 / 删除三个改动点都被推送', () async {
      final pushed = <List<DlnaDevice>>[];
      manager.onDevicesChanged = (list) => pushed.add(list);
      final device = await _announceAndWait();

      manager.setDeviceAlias(device.id, '客厅音箱');
      manager.setDeviceDisabled(device.id, true);
      manager.removeDevice(device.id);

      // 用「推送内容里能否观察到该设备的相应变化」来判定，而不是比对推送次数：
      // SSDP 被动事件同样会推 onDevicesChanged，次数会并发漂移。
      expect(
        pushed.any((l) => l.any((d) => d.id == device.id && d.alias == '客厅音箱')),
        isTrue,
        reason: '改别名应推一次 onDevicesChanged',
      );
      expect(
        pushed.any((l) => l.any((d) => d.id == device.id && d.disabled)),
        isTrue,
        reason: '禁用设备应推一次 onDevicesChanged',
      );
      expect(
        pushed.any((l) => l.every((d) => d.id != device.id)),
        isTrue,
        reason: '删除设备后推送的设备表里不应再有它',
      );
      expect(
        manager.devices.where((d) => d.id == device.id).toList(),
        isEmpty,
        reason: '删除后该设备应已出列',
      );
    });

    test('别名/禁用/删除对不存在的 id 是静默空操作', () async {
      // 同样不假设设备表为空（网段里可能有真实 renderer 被动发现），只比对改动前后。
      final before = manager.devices.length;
      manager.setDeviceAlias('nope', 'x');
      manager.setDeviceDisabled('nope', true);
      manager.removeDevice('nope');
      expect(manager.devices.length, before, reason: '未命中 id 时不应抛错也不应改列表');
    });

    test('scanDevices 只钉住「不抛错 / 不破坏已初始化状态」[D-024 锁定修复]', () async {
      // [D-024 锁定修复] SsdpDiscovery.search 的拨号阶段已纳入总超时约束，
      // scanDevices 也改为并发拉取各台 description.xml 且每台限时
      // （perDeviceFetchTimeout，默认 6s）—— 慢设备/失联设备不再可能拖死整次扫描。
      // 测试机网段仍不能密闭复现「慢设备应答」，这里继续只钉住：调用不抛异常，
      // 且不会动摇管理器状态；限时行为见 b40e2_dlna_manager_fixes_test.dart。
      await expectLater(manager.scanDevices(), completes);
      expect(manager.devices, isA<List<DlnaDevice>>(), reason: '扫描后设备表访问器仍可用');
      for (final d in manager.devices) {
        expect(d.location, isA<String>());
        expect(d.id, isA<String>());
      }
    });
  });

  // ==========================================================================
  // 3. 投屏建立校验与能力探测
  // ==========================================================================
  group('投屏建立校验与能力探测', () {
    DlnaDevice _handleless() => DlnaDevice(
          id: 'no-av',
          name: '无控制地址',
          location: 'http://127.0.0.1:1/desc.xml',
          lastSeen: DateTime.now(),
        );

    test('六类非法入参一律返回 false，且不产生任何设备侧行为', () async {
      expect(
        await manager.startCast(_handleless(), _tracks(duration: 6)),
        isFalse,
        reason: '没有 avTransportUrl 的设备不可投',
      );
      expect(
        await manager.startCast(
          _controlled().copyWith(available: false),
          _tracks(duration: 6),
        ),
        isFalse,
        reason: '不可用设备不可投',
      );
      expect(
        await manager.startCast(
          _controlled().copyWith(disabled: true),
          _tracks(duration: 6),
        ),
        isFalse,
        reason: '被禁用的设备不可投',
      );
      expect(
        await manager.startCast(_controlled(), const <DlnaCastTrack>[]),
        isFalse,
        reason: '空队列不可投',
      );
      expect(
        await manager.startCast(
          _controlled(),
          _tracks(duration: 6),
          startIndex: 99,
        ),
        isFalse,
        reason: '越界起始下标不可投',
      );
      expect(
        await manager.startCast(
          _controlled(),
          _tracks(duration: 6),
          startIndex: -1,
        ),
        isFalse,
        reason: '负起始下标不可投',
      );
      expect(server.sawActions, isEmpty, reason: '被拒的分支都不应落到设备侧');
    });

    test('startCast 成功：能力探测为纯直传档位，队列就位且首曲直链已下发', () async {
      final ok = await manager.startCast(_controlled(), _tracks(duration: 6));
      expect(ok, isTrue);
      expect(manager.isCasting, isTrue);
      expect(manager.castQueue, hasLength(4));
      expect(manager.castQueueIndex, 0);
      // _probeDevice：有 AVTransport 即 supportsDirectHttp，SetNext/时长一律保守 false。
      expect(manager.capability.supportsDirectHttp, isTrue);
      expect(manager.capability.supportsSetNext, isFalse);
      expect(manager.capability.reportsDuration, isFalse);
      expect(manager.castPath, DlnaCastPath.direct);
      expect(server.playedUris, hasLength(1));
      expect(server.playedUris.first, contains('song0'));
      expect(server.setNextUris, hasLength(1), reason: '成功投屏应预置下一首(song1)');
      expect(server.setNextUris.first, contains('song1'));
    });

    test('startCast 指定起始下标从该曲开始投', () async {
      final ok = await manager.startCast(
        _controlled(),
        _tracks(duration: 6),
        startIndex: 2,
      );
      expect(ok, isTrue);
      expect(manager.castQueueIndex, 2);
      expect(server.playedUris.first, contains('song2'), reason: '应从第 2 首开始播');
    });

    test('投屏建立瞬间失败会回滚：停轮询、停设备、清投屏态并返回 false', () async {
      final failing = DlnaManager();
      await failing.init(
        streamUrlBuilder: (songId) => throw StateError('boom-$songId'),
      );
      try {
        final ok = await failing.startCast(_controlled(), _tracks(duration: 6));
        expect(ok, isFalse, reason: '首曲取流失败应整体回滚');
        expect(failing.isCasting, isFalse, reason: '回滚后不应仍处于投屏态');
        expect(failing.castQueue, isEmpty);
        expect(failing.castQueueIndex, -1);
      } finally {
        await failing.dispose();
      }
    });
  });

  // ==========================================================================
  // 4. 切歌序列化(playAt / next / previous / shuffle)
  // ==========================================================================
  group('切歌序列化', () {
    test('playAt 跳到指定曲目并真下发直链；越界与同曲为空操作', () async {
      await manager.startCast(_controlled(), _tracks(duration: 6));

      await manager.playAt(2);
      expect(manager.castQueueIndex, 2);
      expect(server.playedUris.last, contains('song2'), reason: 'playAt 应对设备重投流');

      await manager.playAt(2);
      expect(server.playedUris.length, 2, reason: '同曲空操作：不应重复下发');

      await manager.playAt(9);
      await manager.playAt(-1);
      expect(manager.castQueueIndex, 2, reason: '越界下标应被忽略');
      expect(server.playedUris.length, 2);
    });

    test('未投屏时 playAt/previous 静默早退', () async {
      await manager.playAt(1);
      await manager.previous();
      expect(manager.castQueueIndex, -1);
      expect(server.sawActions, isEmpty);
    });

    test('next/previous 按 order 模式线性移动，末首 next 不越界', () async {
      manager.setPlayMode('order'); // 默认 all 会绕回队首，这里显式钉成 order
      await manager.startCast(_controlled(), _tracks(duration: 6));

      await manager.next();
      expect(manager.castQueueIndex, 1);
      await manager.previous();
      expect(manager.castQueueIndex, 0);

      await manager.next();
      await manager.next();
      await manager.next();
      expect(manager.castQueueIndex, 3);
      await manager.next();
      expect(manager.castQueueIndex, 3, reason: 'order 模式末首之后保持停止');
    });

    test('previous 在第 0 首是空操作（order/all/one 一律不越界）', () async {
      manager.setPlayMode('all');
      await manager.startCast(_controlled(), _tracks(duration: 6));
      await manager.previous();
      expect(manager.castQueueIndex, 0, reason: '第 0 首按上一首不应把游标推成 -1');
    });

    test('one 模式 next 与 order 同路（线性前进、末首不越界）；单曲队列一律早退',
        () async {
      manager.setPlayMode('one');
      await manager.startCast(_controlled(), _tracks(duration: 6));
      // one 走 switch 的 default 分支：线性 ++，不重放当前曲，末首不越界。
      await manager.next();
      expect(manager.castQueueIndex, 1, reason: 'one 模式 next 会前进（死曲不重放）');
      expect(server.playedUris.last, contains('song1'));

      // 单曲队列：next 越界早退、previous 在第 0 首早退、shuffle 无其他可选下标。
      final playedSoFar = server.playedUris.length;
      await manager.startCast(_controlled(), _tracks(duration: 6, count: 1));
      expect(
        server.playedUris.length,
        playedSoFar + 1,
        reason: '重新投屏应再下发一次当前直链',
      );
      await manager.next();
      expect(manager.castQueueIndex, 0, reason: '单曲队列 next 早退');
      await manager.previous();
      expect(manager.castQueueIndex, 0, reason: '第 0 首 previous 早退');
      manager.setPlayMode('shuffle');
      await manager.next();
      expect(manager.castQueueIndex, 0, reason: '_randomOtherIndex 在单曲队列直返当前下标');
    });

    test('shuffle 模式 next 随机落到别的下标，且恒不越界', () async {
      manager.setPlayMode('shuffle');
      await manager.startCast(_controlled(), _tracks(duration: 6), startIndex: 0);

      for (var i = 0; i < 6; i++) {
        await manager.next();
        expect(
          manager.castQueueIndex,
          inInclusiveRange(0, 3),
          reason: 'shuffle 游标不应越界',
        );
        if (manager.castQueueIndex != 0) break;
      }
      expect(manager.castQueueIndex, isNot(0), reason: 'shuffle next 应切到另一首');
    });

    test('快速连点切歌不抛错、最终停在最后点的曲目', () async {
      await manager.startCast(_controlled(), _tracks(duration: 6));
      final before = server.setAvUris.length;

      await Future.wait(<Future<void>>[
        manager.playAt(1),
        manager.playAt(2),
        manager.playAt(3),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(manager.castQueueIndex, 3);
      expect(
        server.setAvUris.length,
        greaterThanOrEqualTo(before + 2),
        reason: '[D-021 钉住现状] playAt 在串行化链之外就改 _queueIndex，'
            '连点会把同一曲目重复 Set 多次；修复后应改为把下标排队再统一切歌。',
      );
    });
  });

  // ==========================================================================
  // 5. SetNext 预置与降级
  // ==========================================================================
  group('SetNext 预置与降级', () {
    test('SetNext 返回 SOAP 错误 → 永久降级为手动切歌', () async {
      server.faults.add('SetNextAVTransportURI');
      final ok = await manager.startCast(_controlled(), _tracks(duration: 6));
      expect(ok, isTrue, reason: '预置失败不应阻断当前曲开播');
      expect(
        await manager.probeEnqueueSupport(_controlled()),
        isFalse,
        reason: '预置失败后 _nextSupported 应置否（probe 返回 Future，必须 await 才能比）',
      );
      expect(server.playedUris, hasLength(1), reason: '当前曲照常下发');
      expect(server.setNextUris, isEmpty, reason: '预置失败后不应再有 SetNext 下发');

      // 下一次切歌：链路上不会再出现 SetNext（已降级）。
      await manager.next();
      expect(server.setNextUris, isEmpty);
    });

    test('下一首取流抛 DlnaSongUnplayableException 时只放弃预置，当前曲照播', () async {
      final probe = DlnaManager();
      await probe.init(
        streamUrlBuilder: (songId) => songId == 'song1'
            ? throw const DlnaSongUnplayableException('song1')
            : _streamUrl(songId),
      );
      try {
        final ok = await probe.startCast(_controlled(), _tracks(duration: 6));
        expect(ok, isTrue, reason: '下一首无源不应影响当前曲开播');
        expect(probe.castQueueIndex, 0);
        expect(server.playedUris, hasLength(1), reason: '当前曲仍应真下发');
        expect(server.setNextUris, isEmpty, reason: '下一首无源时不下发预置');
      } finally {
        await probe.dispose();
      }
    });

    test('probeEnqueueSupport 对 SetNext 成功的设备回写 _nextSupported 为 true',
        () async {
      await manager.startCast(_controlled(), _tracks(duration: 6));
      expect(await manager.probeEnqueueSupport(_controlled()), isTrue);
    });

    test('probeEnqueueSupport 对没有 AVTransport 的设备直接返回 false', () async {
      expect(
        await manager.probeEnqueueSupport(DlnaDevice(
          id: 'x',
          name: 'x',
          location: 'http://127.0.0.1:1/d.xml',
          lastSeen: DateTime.now(),
          avTransportUrl: null,
        )),
        isFalse,
      );
    });
  });

  // ==========================================================================
  // 6. 暂停 / 恢复
  // ==========================================================================
  group('暂停与恢复', () {
    test('未投屏时 pause/resume 静默早退，不产生任何 SOAP', () async {
      await manager.pause();
      await manager.resume();
      expect(server.sawActions, isEmpty);
    });

    test('pause/resume 真下发 SOAP 并回写合成状态', () async {
      final seen = <String>[];
      manager.onStatusChanged = (s) => seen.add(s.state);
      await manager.startCast(_controlled(), _tracks(duration: 6));

      await manager.pause();
      expect(server.sawActions.contains('Pause'), isTrue);
      expect(seen.last, 'PAUSED');

      await manager.resume();
      expect(server.sawActions.contains('Play'), isTrue);
      expect(seen.last, 'PLAYING');
    });

    test('设备的 Pause 返回 SOAP 错误时被吞掉，不冒泡给调用方', () async {
      server.faults.add('Pause');
      await manager.startCast(_controlled(), _tracks(duration: 6));
      // pause() 内部 try/catch：SoapControl.pause 抛 SoapException → 记日志后返回。
      await manager.pause();
      expect(server.faults.contains('Pause'), isTrue);
    });

    test('resume / setVolume / toggleMute 的 SOAP 报错同样被吞掉', () async {
      server.faults.addAll(<String>['Play', 'SetVolume', 'SetMute']);
      await manager.startCast(_controlled(), _tracks(duration: 6));

      // 三个方法各自 try/catch 记日志后返回：不冒泡、不回写合成状态
      // （toggleMute 在 setMute 失败时不应把静音翻转过去）。
      await manager.resume();
      expect(manager.isCasting, isTrue, reason: 'resume 失败不应影响投屏态');
      await manager.setVolume(88);
      await manager.toggleMute();
      expect(manager.isMuted, isFalse, reason: 'setMute 失败时不应把静音回写成 true');
      // 假设备在响应 SOAP 错误之前就先记账，故只断言错误注入确实在下发链上，
      // 不反过来断言「没下发」。
      expect(server.faults.containsAll(<String>['Play', 'SetVolume', 'SetMute']), isTrue);
    });
  });

  // ==========================================================================
  // 7. seek：重投流重建（单块最大）
  // ==========================================================================
  group('seek 重投流', () {
    test('未投屏时 seek 早退：只打日志不下发任何 SOAP', () async {
      await manager.seek(42);
      expect(server.sawActions, isEmpty, reason: '没有当前设备时 seek 应静默早退');
    });

    test('stopCast 之后 seek 依旧早退（设备已被清空）', () async {
      await manager.startCast(_controlled(), _tracks(duration: 6));
      await manager.stopCast();
      expect(manager.isCasting, isFalse);

      await manager.seek(10);
      expect(
        server.sawActions.contains('Seek'),
        isFalse,
        reason: '[D-016 已删除（2026-10-07）] SOAP Seek 兜底已按用户决策移除：'
            '「有设备必有队列信息」不变量成立，seek 只走重投流重建路径。',
      );
    });

    test('stopCast 真下发 Stop 并清空投屏态，可重复调用且能再次投屏', () async {
      final disconnected = <int>[];
      manager.onCastDisconnected = () => disconnected.add(1);
      await manager.startCast(_controlled(), _tracks(duration: 6));
      await manager.stopCast();

      expect(server.stoppedUris, isNotEmpty, reason: 'stopCast 应先停设备');
      expect(manager.isCasting, isFalse);
      expect(manager.castQueue, isEmpty);
      expect(manager.castQueueIndex, -1);
      expect(disconnected, hasLength(1));

      final stoppedSoFar = server.stoppedUris.length;
      await manager.stopCast();
      expect(
        server.stoppedUris,
        hasLength(stoppedSoFar),
        reason: '重复 stopCast 不应重复下发 Stop',
      );

      // 退出投屏态后仍可重新建立，轮询与预置一并恢复。
      final nextSoFar = server.setNextUris.length;
      expect(
        await manager.startCast(_controlled(), _tracks(duration: 6)),
        isTrue,
        reason: 'stopCast 之后应能再次 startCast',
      );
      expect(manager.castQueueIndex, 0);
      expect(
        server.setNextUris.length,
        nextSoFar + 1,
        reason: '重建后应重新预置下一首',
      );
    });

    test('正常 seek 走重投流：新直链带 timeOffset，设备重收 Stop/Set/Play', () async {
      await manager.startCast(_controlled(), _tracks(duration: 6));
      final beforeSet = server.setAvUris.length;

      await manager.seek(42);

      expect(server.setAvUris.length, greaterThan(beforeSet), reason: 'seek 应重建流');
      expect(server.setAvUris.last, contains('timeOffset=42'), reason: '必须带 timeOffset');
      expect(server.setAvUris.last, contains('song0'), reason: 'seek 仍指向当前曲目');
      expect(server.seekTargets, isEmpty, reason: '不应走 SOAP REL_TIME Seek');
      expect(server.stoppedUris, isNotEmpty, reason: '重建前应先 Stop 当前流');
      expect(manager.castQueueIndex, 0, reason: 'seek 不应改动队列游标');
    });

    test('[D-015 锁定修复] seek 重建 setUri 失败：立即外显 ERROR + 下一轮轮询自动重投',
        () async {
      server.faults.add('SetAVTransportURI');
      final st = <DlnaDeviceStatus>[];
      manager.onStatusChanged = (s) => st.add(s);
      await manager.startCast(_controlled(), _tracks(duration: 600));

      final stopSoFar = server.stoppedUris.length;
      final callsSoFar = st.length;

      // [D-015 已修复] 重建失败不再静默：置待重投标记 + onStatusChanged 推 ERROR，
      // 下一轮轮询自动重投一次；重投仍失败（本例故障持续注入）则只重投一次即放弃，
      // 不再死循环。外部至少能立刻从状态流看到「失败了」。
      await manager.seek(42);

      expect(
        server.faults.contains('SetAVTransportURI'),
        isTrue,
        reason: '注入的故障应确实落在下发链路上',
      );
      expect(
        server.stoppedUris.length,
        greaterThan(stopSoFar),
        reason: '重建前确实先 Stop 了设备',
      );
      expect(
        st.length,
        greaterThan(callsSoFar),
        reason: 'D-015 锁定修复：seek 重建失败必须经 onStatusChanged 外显（ERROR）',
      );
      expect(
        st.last.state,
        'ERROR',
        reason: 'D-015 锁定修复：失败态对外可见，外部能区分「拖动成功/失败」',
      );
      expect(
        manager.isCasting,
        isTrue,
        reason: '重投方案下不回滚投屏态，等自动重投',
      );
      expect(
        manager.castQueueIndex,
        0,
        reason: '游标不回滚',
      );
    });

    test('seek 秒数为 0 时同样拼 timeOffset=0（不做裁剪）', () async {
      await manager.startCast(_controlled(), _tracks(duration: 6));
      await manager.seek(0);
      expect(server.setAvUris.last, contains('timeOffset=0'));
    });
  });

  // ==========================================================================
  // 8. 音量与静音
  // ==========================================================================
  group('音量与静音', () {
    test('未投屏时 setVolume/toggleMute 早退', () async {
      await manager.setVolume(50);
      await manager.toggleMute();
      expect(server.sawActions, isEmpty);
    });

    test('setVolume 先 clamp 到 0~100 再下发（越界值不裸发）', () async {
      await manager.startCast(_controlled(), _tracks(duration: 6));

      await manager.setVolume(140);
      expect(server.setVolumeCalls.last, 100, reason: '上限应被 clamp 到 100');
      await manager.setVolume(-20);
      expect(server.setVolumeCalls.last, 0, reason: '下限应被 clamp 到 0');
      await manager.setVolume(37);
      expect(server.setVolumeCalls.last, 37);

      final seen = <int>[];
      manager.onStatusChanged = (s) => seen.add(s.volume);
      await manager.setVolume(64);
      expect(seen.last, 64, reason: '合成状态里记的是入参原值(未裁剪)');
    });

    test('toggleMute 翻转静音并回写状态', () async {
      await manager.startCast(_controlled(), _tracks(duration: 6));
      expect(manager.isMuted, isFalse);

      await manager.toggleMute();
      expect(server.setMuteCalls, [true]);
      expect(manager.isMuted, isTrue);

      await manager.toggleMute();
      expect(server.setMuteCalls, [true, false]);
      expect(manager.isMuted, isFalse);
    });

    test('设备没有 RenderingControl 地址时 setVolume/toggleMute 早退', () async {
      // 注意：这里直接构造无 RenderingControl 的设备（更直白）；
      // D-022 修复后 `copyWith(renderingControlUrl: null)` 也能真正清空了。
      await manager.startCast(_noRendering(), _tracks(duration: 6));
      await manager.setVolume(55);
      await manager.toggleMute();
      expect(server.setVolumeCalls, isEmpty, reason: '无 RenderingControl 地址不应下发音量');
      expect(server.setMuteCalls, isEmpty);
    });

    test('[D-022 已修] copyWith 显式传 null 清空可空字段，省略保持原值', () {
      final withAlias = _controlled().copyWith(alias: '客厅音箱');
      final cleared = withAlias.copyWith(renderingControlUrl: null, alias: null);
      expect(
        cleared.renderingControlUrl,
        isNull,
        reason: '[D-022] copyWith 已用哨兵区分「省略/显式 null」，显式 null 真正清空，'
            '「抹掉 RenderingControl 地址」的调用生效（无音量控制分支可达）。',
      );
      expect(cleared.alias, isNull, reason: '显式 null 清空 alias');
      final kept = withAlias.copyWith(disabled: true);
      expect(kept.renderingControlUrl, server.renderingControlUrl,
          reason: '省略参数保持原值');
      expect(kept.alias, '客厅音箱', reason: '省略参数保持原值');
      expect(kept.avTransportUrl, server.avTransportUrl, reason: '传值的字段正常生效');
    });
  });

  // ==========================================================================
  // 9. 投屏队列编辑：追加 / 删除 / 排序
  // ==========================================================================
  group('投屏队列编辑', () {
    test('enqueueSongs 只追加不中断当前播放，并推 onTrackChanged', () async {
      await manager.startCast(_controlled(), _tracks(duration: 6));
      final beforePlayed = server.playedUris.length;

      await manager.enqueueSongs(<DlnaCastTrack>[_track('song9', '追加曲', 6)]);

      expect(manager.castQueue, hasLength(5));
      expect(manager.castQueue.last.songId, 'song9');
      expect(manager.castQueueIndex, 0, reason: '追加不应改动当前游标');
      expect(server.playedUris.length, beforePlayed, reason: '追加不应重投当前曲');
    });

    test('空追加（空列表 / 未投屏）为空操作', () async {
      await manager.enqueueSongs(const <DlnaCastTrack>[]);
      expect(manager.castQueue, isEmpty);

      await manager.startCast(_controlled(), _tracks(duration: 6));
      await manager.enqueueSongs(const <DlnaCastTrack>[]);
      expect(manager.castQueue, hasLength(4));
    });

    test('removeQueueItem 三种游标修正：删当前曲之前 / 删除当前曲本身 / 删到队尾收缩',
        () async {
      await manager.startCast(
        _controlled(),
        _tracks(duration: 6),
        startIndex: 2,
      );
      expect(manager.castQueueIndex, 2);

      // 删当前曲之前(0) → 游标整体前移，仍指向同一首。
      await manager.removeQueueItem(0);
      expect(manager.castQueue, hasLength(3));
      expect(manager.castQueueIndex, 1);
      expect(manager.castQueue[1].songId, 'song2');

      // 删当前曲本身 → 游标保持指向下一首位置。
      await manager.removeQueueItem(1);
      expect(manager.castQueueIndex, 1);
      expect(manager.castQueue, hasLength(2));

      // 删最后一个 → 游标收缩到队尾。
      await manager.removeQueueItem(1);
      expect(manager.castQueue, hasLength(1));
      expect(manager.castQueueIndex, 0, reason: '队列收缩后游标不应越界');
    });

    test('removeQueueItem 越界下标为空操作', () async {
      await manager.startCast(_controlled(), _tracks(duration: 6));
      await manager.removeQueueItem(99);
      await manager.removeQueueItem(-1);
      expect(manager.castQueue, hasLength(4));
      expect(manager.castQueueIndex, 0);
    });

    test('removeQueueItem 删空整队会直接停止投屏', () async {
      await manager.startCast(_controlled(), _tracks(duration: 6));
      await manager.removeQueueItem(0);
      await manager.removeQueueItem(0);
      await manager.removeQueueItem(0);
      await manager.removeQueueItem(0);

      expect(manager.castQueue, isEmpty);
      expect(manager.isCasting, isFalse, reason: '队列被清空应退出投屏态');
      expect(manager.castQueueIndex, -1);
    });

    test('reorderQueue 拖动曲目后游标跟随被拖动的那一首', () async {
      await manager.startCast(_controlled(), _tracks(duration: 6));
      // from=0 / to=3：to 是「原列表净插入位」，移除后实际插入位为 to-1=2。
      await manager.reorderQueue(0, 3);

      expect(
        manager.castQueue.map((t) => t.songId).toList(),
        ['song1', 'song2', 'song0', 'song3'],
        reason: 'to 为原列表净插入位，移除后落点右移一格',
      );
      expect(manager.castQueueIndex, 2, reason: '游标跟随被拖动的 song0');
    });

    test('reorderQueue 非法参数与同位拖动均为空操作', () async {
      await manager.startCast(_controlled(), _tracks(duration: 6));
      await manager.reorderQueue(0, 99);
      await manager.reorderQueue(-1, 1);
      await manager.reorderQueue(1, -5);
      await manager.reorderQueue(1, 1);
      expect(
        manager.castQueue.map((t) => t.songId).toList(),
        ['song0', 'song1', 'song2', 'song3'],
      );
      expect(manager.castQueueIndex, 0);
    });

    test('clearCastQueue 等价于 stopCast：清状态并推断连回调', () async {
      final disconnected = <int>[];
      manager.onCastDisconnected = () => disconnected.add(1);
      await manager.startCast(_controlled(), _tracks(duration: 6));

      await manager.clearCastQueue();

      expect(manager.isCasting, isFalse);
      expect(manager.castQueue, isEmpty);
      expect(manager.castQueueIndex, -1);
      expect(disconnected, hasLength(1));
    });
  });

  // ==========================================================================
  // 10. 客户端保活摘除
  // ==========================================================================
  group('客户端保活摘除', () {
    test('detachClientKeepalive 摘掉回调后不再收到状态/曲目/断连通知', () async {
      final statuses = <String>[];
      final tracks = <int>[];
      final disconnected = <int>[];
      manager.onStatusChanged = (s) => statuses.add(s.state);
      manager.onTrackChanged = (i) => tracks.add(i);
      manager.onCastDisconnected = () => disconnected.add(1);

      await manager.startCast(_controlled(), _tracks(duration: 6));
      // startCast 建立链路时本就会推一帧状态/曲目，detach 之前先快照基准量。
      final statusesAtDetach = statuses.length;
      final tracksAtDetach = tracks.length;
      final disconnectedAtDetach = disconnected.length;

      manager.detachClientKeepalive();

      // 摘除后再次触发内部回调路径：不再推给外部。
      await manager.playAt(2);
      await manager.pause();

      expect(
        statuses,
        hasLength(statusesAtDetach),
        reason: 'detach 后 onStatusChanged 应已被置 null',
      );
      expect(
        tracks,
        hasLength(tracksAtDetach),
        reason: 'detach 后 onTrackChanged 应已被置 null',
      );
      expect(
        disconnected,
        hasLength(disconnectedAtDetach),
        reason: 'detach 后 onCastDisconnected 应已被置 null',
      );
      // detach 只停客户端侧动作，不打断设备播放。
      expect(manager.isCasting, isTrue);
      expect(server.playedUris.last, contains('song2'));

      // 摘除后再 dispose 不应抛错。
      await manager.dispose();
    });
  });

  // ==========================================================================
  // 11. 轮询帧：游标对齐 / 曲中段异常停止兜底 / 预检无限跳
  // ==========================================================================
  group('轮询帧判定', () {
    test('设备自切到预置下一首时只对齐游标，不重复下发播放', () async {
      // 组合摆帧：真实时长取长曲 600s（wallDone / positionStuck / deviceEnded 全部
      // 按真实时长判，观测窗内不可能命中），设备侧上报时长 8s、位置 5s（≥5s）
      // 加工帧位置回落 1s（<5s）→ 这一帧唯一命中 nearEnd + startedOver 的对齐分支。
      server.reportedDuration = 8;
      server.positionOverride = 5; // 上一帧距曲末 ≤3s（8 - 5 = 3）
      await manager.startCast(_controlled(), _tracks(duration: 600));
      await Future<void>.delayed(const Duration(milliseconds: 2400)); // 首帧状态落盘

      server.positionOverride = 1; // 本帧位置回绕到 <5s → startedOver
      await Future<void>.delayed(const Duration(milliseconds: 4400)); // 触发 _alignToNext

      expect(
        manager.castQueueIndex,
        1,
        reason: 'nearEnd+startedOver 时应按 _provisionedIndex 对齐到下一首',
      );
      expect(
        server.playedUris.length,
        1,
        reason: '_alignToNext 不应再下发新的 Set/Play（设备已自主切换）',
      );
    });

    test('[D-023 钉住现状] 曲中段异常停止兜底不可达：连击计数凑不满 2', () async {
      // 长曲 + 小进度：nearEnd / wallDone / deviceEnded / positionStuck 全不成立，
      // 理论只剩 stall 分支可命中 —— 用它把这条兜底路径钉死。
      server.reportedDuration = 300;
      server.positionOverride = 8;
      await manager.startCast(_controlled(), _tracks(duration: 300));
      await Future<void>.delayed(const Duration(milliseconds: 2200)); // 首帧：状态落盘

      // [D-023 锁定修复] 设备曲中段恒报 ERROR（不再恢复）。原缺陷：ERROR 帧把
      // _currentStatus.state 改写成 ERROR，下一帧 prevState 便不再是 PLAYING，
      // 连击最多到 1 就断 —— 兜底不可达。修复后采用「连击段延续」语义：首帧
      // 非播态仍要求 prevState==PLAYING，随后只要无 PLAYING/PAUSED 帧插入就连击
      // 持续累计，恒报 ERROR 也能凑满 2 触发自动跳下一首。
      server.transportState = 'ERROR';
      await Future<void>.delayed(const Duration(milliseconds: 5200)); // ~2 帧后应触发跳过
      server.transportState = 'PLAYING'; // 立刻恢复，避免继续连击跳过更多曲目
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(
        manager.castQueueIndex,
        1,
        reason: '[D-023 锁定修复] 曲中段连续异常停止（恒报 ERROR）凑满 2 帧'
            '应触发自动跳过，游标推进到下一首',
      );
      expect(server.playedUris, hasLength(2),
          reason: '自动跳过应真实下发下一首的 Set+Play');
    });

    test('pre-cast 预检判无源：order 模式一路跳过，到队尾即停', () async {
      final probe = DlnaManager();
      probe.setPlayMode('order'); // 钉成 order：绕圈到队尾即停，不回绕
      await probe.init(
        streamUrlBuilder: _streamUrl,
        probeSong: (songId) async => false, // 全部判无源
      );
      try {
        final ok = await probe.startCast(_controlled(), _tracks(duration: 6));
        expect(ok, isTrue, reason: '预检无限跳不应挂死 startCast');
        expect(
          probe.castQueueIndex,
          3,
          reason: '[D-020 钉住现状] order 模式绕满一圈无源时停在队尾(3)，由看门狗下一圈重试',
        );
        expect(server.playedUris, isEmpty, reason: '全部无源时不应有任何曲目真正下发');
      } finally {
        await probe.dispose();
      }
    });

    test('pre-cast 预检判无源：all 模式绕一圈回起点，首曲可播时正常开播', () async {
      final probe = DlnaManager();
      probe.setPlayMode('all');
      await probe.init(
        streamUrlBuilder: _streamUrl,
        probeSong: (songId) async => songId == 'song0', // 只有第 0 首有源
      );
      try {
        // 从下标 1 起投：song1~song3 全被跳过，绕一圈回到 song0 才开播。
        final ok =
            await probe.startCast(_controlled(), _tracks(duration: 6), startIndex: 1);
        expect(ok, isTrue);
        expect(probe.castQueueIndex, 0, reason: 'all 模式绕圈后应回到第 0 首');
        expect(server.playedUris, hasLength(1), reason: '只应下发 song0');
        expect(server.playedUris.first, contains('song0'));
        expect(server.setNextUris, hasLength(1), reason: '开播后应预置下一首(song1)');
      } finally {
        await probe.dispose();
      }
    });
  });
}
