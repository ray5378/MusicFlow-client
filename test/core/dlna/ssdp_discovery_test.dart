import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/dlna/ssdp_discovery.dart';

/// ============================================================================
/// 本地模拟 SSDP DLNA 响应者（真实 UDP 服务）
/// ----------------------------------------------------------------------------
/// 监听 1900（UPnP SSDP 端口）并加入 239.255.255.250 多播组，收到 `M-SEARCH`
/// 后按包**源地址/源端口**单播回一个带 `LOCATION` 的标准 SSDP 响应——复刻真实
/// DLNA 设备（电视/音箱）的应答行为，用于打通「客户端扫描 → 设备发现」链路，
/// 重点是 Windows 多网卡场景下逐接口拨号后仍能收到回源单播。
/// ============================================================================
class _FakeSsdpResponder {
  static const String _mcAddr = '239.255.255.250';
  static const int _port = 1900;

  final String location;
  RawDatagramSocket? _server;
  int _msearchCount = 0;

  _FakeSsdpResponder(this.location);

  /// 实际收到的 M-SEARCH 请求数（用于断言确实有拨号达到本响应者）。
  int get msearchCount => _msearchCount;

  Future<void> start() async {
    _server = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      _port,
      reuseAddress: true,
    );

    // 加入多播组，接收发给 239.255.255.250:1900 的 M-SEARCH。
    try {
      final ifaces = await NetworkInterface.list(includeLinkLocal: false);
      NetworkInterface? iface;
      for (final i in ifaces) {
        if (!i.name.startsWith('lo')) {
          iface = i;
          break;
        }
      }
      if (iface != null) {
        _server!.joinMulticast(InternetAddress(_mcAddr), iface);
      } else {
        _server!.joinMulticast(InternetAddress(_mcAddr));
      }
    } catch (_) {}

    // 捕获局部引用：避免 UDP 回调在 close() 置空字段后仍读到 `_server!` 触发空指针。
    final server = _server!;
    server.listen((event) {
      final d = server.receive();
      if (d == null) return;
      final req = String.fromCharCodes(d.data);
      if (!req.startsWith('M-SEARCH')) return;
      _msearchCount++;

      // 标准 M-SEARCH 响应：LOCATION 描述设备 description.xml 地址。
      final resp = [
        'HTTP/1.1 200 OK',
        'CACHE-CONTROL: max-age=1800',
        'LOCATION: $location',
        'EXT:',
        'SERVER: libmedia/1.0 UPnP/1.0 sim',
        'ST: urn:schemas-upnp-org:device:MediaRenderer:1',
        'USN: uuid:sim-mr-0001::urn:schemas-upnp-org:device:MediaRenderer:1',
        '',
        '',
      ].join('\r\n');
      // 单播回源（Windows 逐接口拨号后，客户端绑定该接口 IP 的 socket 即可收到）。
      server.send(resp.codeUnits, d.address, d.port);
    });
  }

  Future<void> close() async {
    if (_server == null) return;
    _server?.close();
    _server = null;
    // 让尚在派发队列中的 UDP 回调收尾，避免测试结束后出现残留异步。
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  const location = 'http://127.0.0.1:58888/description.xml';
  late _FakeSsdpResponder responder;

  setUp(() async {
    responder = _FakeSsdpResponder(location);
    await responder.start();
  });

  tearDown(() async {
    await responder.close();
  });

  test('自动探测全部接口后逐接口拨号，能发现本地模拟 DLNA 设备(单播回源)', () async {
    final discovery = SsdpDiscovery();
    final locations = await discovery.search(timeout: const Duration(seconds: 2));
    discovery.dispose();

    expect(locations, contains(location),
        reason: '逐接口拨号后应从模拟设备回源单播响应中解析出 LOCATION');
    expect(responder.msearchCount, greaterThanOrEqualTo(1),
        reason: '应有至少一次 M-SEARCH 实际到达响应者');
  });

  test('显式注入接口地址(模拟 Windows 多网卡逐个拨号)同样能发现设备', () async {
    // 取当前非环回接口 IP，注入让 search 显式对其拨号。
    final ifaces = await NetworkInterface.list(includeLinkLocal: false);
    final addr = ifaces
        .where((i) => !i.name.startsWith('lo'))
        .expand((i) => i.addresses)
        .where((a) => a.type == InternetAddressType.IPv4)
        .map((a) => a.address)
        .toList();

    // 注入同一地址两次：验证多接口循环对相同地址只经 Set 去重、不影响发现。
    final injected = [if (addr.isNotEmpty) addr.first, if (addr.isNotEmpty) addr.first];

    final discovery = SsdpDiscovery();
    final locations = await discovery.search(
      timeout: const Duration(seconds: 2),
      bindAddresses: injected,
    );
    discovery.dispose();

    expect(locations, contains(location),
        reason: '显式逐接口拨号后应解析到设备 LOCATION');
  });

  test('无可用接口信息(传递空列表)时回退任意地址兜底，仍能发现设备', () async {
    final discovery = SsdpDiscovery();
    final locations = await discovery.search(
      timeout: const Duration(seconds: 2),
      bindAddresses: const [],
    );
    discovery.dispose();

    // 空列表 → 走 0.0.0.0 单发兜底；模拟设备收到多播即回单播，仍应发现。
    expect(locations, contains(location),
        reason: '即使无明确接口，兜底任意地址拨号仍应扫描到设备');
  });

  test('同一扫描窗口内 M-SEARCH 重发多轮(容忍丢包/慢设备)', () async {
    final discovery = SsdpDiscovery();
    await discovery.search(timeout: const Duration(seconds: 2));
    discovery.dispose();

    // 0/700/1400ms 共 3 轮多播探测；2s 窗口内应全部到达响应者。
    expect(responder.msearchCount, greaterThanOrEqualTo(3),
        reason: '扫描窗口内应对同一接口重发多轮 M-SEARCH，而非仅发一次');
  });

  test('被动监听逐接口 join：收到 ssdp:alive NOTIFY 即回调上报设备', () async {
    final discovery = SsdpDiscovery();
    final received = <String>[];
    discovery.startListening(
      onDeviceUpdate: (loc, alive) => received.add(loc),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));

    // 扮演 DLNA 设备从本机非环回接口向 SSDP 多播组发 NOTIFY ssdp:alive。
    final ifaces = await NetworkInterface.list(includeLinkLocal: false);
    NetworkInterface? iface;
    for (final i in ifaces) {
      if (!i.name.startsWith('lo')) {
        iface = i;
        break;
      }
    }
    final notifySocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final notifyMsg = [
      'NOTIFY * HTTP/1.1',
      'HOST: 239.255.255.250:1900',
      'NT: urn:schemas-upnp-org:device:MediaRenderer:1',
      'NTS: ssdp:alive',
      'LOCATION: $location',
      'USN: uuid:sim-nfy-0001::urn:schemas-upnp-org:device:MediaRenderer:1',
      '',
      '',
    ].join('\r\n');
    if (iface != null) {
      notifySocket.joinMulticast(InternetAddress('239.255.255.250'), iface);
    } else {
      notifySocket.joinMulticast(InternetAddress('239.255.255.250'));
    }
    notifySocket.send(notifyMsg.codeUnits, InternetAddress('239.255.255.250'), 1900);

    await Future<void>.delayed(const Duration(milliseconds: 500));
    notifySocket.close();
    discovery.stopListening();

    expect(received, contains(location),
        reason: '被动监听逐接口 join 后应收到 ssdp:alive NOTIFY 并回调设备 LOCATION');
  });
}