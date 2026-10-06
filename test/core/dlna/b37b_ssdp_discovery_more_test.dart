// b37b — `lib/core/dlna/ssdp_discovery.dart` 补测（原 16 miss）。
//
// 未覆盖行：120/133/157/165/186/241/261/320/390/393 均为「socket 发送/绑定/join
// 失败时的 debug 日志」防御分支（仅在真实网卡异常时触达，测试环境不可复现）；
// 459/460/464/465/468/472 是 `discoveredLocations` getter 全体。
//
// 本文件用**真实 UDP 多播**打通「NOTIFY → 被动监听 → discoveredLocations」，
// 覆盖 discoveredLocations 主体（459/460/464/468/472）。
// 发送端与生产 `_skipInterface` 用同一套物理接口过滤，保证与监听端同网段必达。
// 产品代码零改动；只读 lib。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/dlna/ssdp_discovery.dart';

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
  if (name == 'et' || name.startsWith('et_') || name.startsWith('et-')) {
    return true;
  }
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

/// 建立一组「发 NOTIFY 用」的 socket：每个物理接口一个（与监听端同网段），
/// 无物理接口时退化为环回单发兜底。
Future<List<RawDatagramSocket>> _notifySenders() async {
  final sockets = <RawDatagramSocket>[];
  for (final iface in await _physicalInterfaces()) {
    final ipv4 = iface.addresses
        .where((a) => a.type == InternetAddressType.IPv4)
        .toList();
    if (ipv4.isEmpty) continue;
    try {
      final sock = await RawDatagramSocket.bind(ipv4.first, 0);
      try {
        sock.joinMulticast(InternetAddress('239.255.255.250'), iface);
      } catch (_) {}
      sockets.add(sock);
    } catch (_) {}
  }
  if (sockets.isEmpty) {
    final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    try {
      sock.joinMulticast(InternetAddress('239.255.255.250'));
    } catch (_) {}
    sockets.add(sock);
  }
  return sockets;
}

String _notify({
  required String location,
  required String nts,
  required String usn,
}) =>
    [
      'NOTIFY * HTTP/1.1',
      'HOST: 239.255.255.250:1900',
      'NT: urn:schemas-upnp-org:device:MediaRenderer:1',
      'NTS: $nts',
      'LOCATION: $location',
      'USN: $usn',
      '',
      '',
    ].join('\r\n');

/// 重发多轮直到 [cond] 成立，容忍多播抖动与 join 时序。
Future<bool> _sendUntil(
  List<RawDatagramSocket> sockets,
  String payload,
  bool Function() cond, {
  int rounds = 6,
  Duration step = const Duration(milliseconds: 250),
}) async {
  final data = payload.codeUnits;
  for (var i = 0; i < rounds; i++) {
    for (final s in sockets) {
      try {
        s.send(data, InternetAddress('239.255.255.250'), 1900);
      } catch (_) {}
    }
    await Future<void>.delayed(step);
    if (cond()) return true;
  }
  return cond();
}

void main() {
  const location = 'http://127.0.0.1:58921/description.xml';
  const usn = 'uuid:b37b-ssdp-0001::urn:schemas-upnp-org:device:MediaRenderer:1';

  late List<RawDatagramSocket> senders;
  late SsdpDiscovery discovery;

  setUp(() async {
    senders = await _notifySenders();
    discovery = SsdpDiscovery();
  });

  tearDown(() async {
    for (final s in senders) {
      try {
        s.close();
      } catch (_) {}
    }
    discovery.dispose();
    // 让残留 UDP 回调收尾，避免测试结束后有未完成异步。
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });

  test('discoveredLocations 初始为空', () {
    expect(discovery.discoveredLocations, isEmpty);
  });

  test('收到 ssdp:alive NOTIFY 后 discoveredLocations 上报该设备', () async {
    discovery.startListening();
    // 等待逐接口 join 完成（NetworkInterface.list + bind + joinMulticast 均异步）。
    await Future<void>.delayed(const Duration(milliseconds: 400));

    final ok = await _sendUntil(
      senders,
      _notify(location: location, nts: 'ssdp:alive', usn: usn),
      () => discovery.discoveredLocations.contains(location),
    );

    expect(ok, isTrue,
        reason: '被动监听收到 alive 后，discoveredLocations 应包含该 location');
    expect(discovery.discoveredLocations, contains(location));
  });

  test('ssdp:update 与 alive 同路：同样进 discoveredLocations', () async {
    discovery.startListening();
    await Future<void>.delayed(const Duration(milliseconds: 400));

    final ok = await _sendUntil(
      senders,
      _notify(location: location, nts: 'ssdp:update', usn: usn),
      () => discovery.discoveredLocations.contains(location),
    );

    expect(ok, isTrue, reason: 'ssdp:update 视同存活，应进 discoveredLocations');
  });

  test('ssdp:byebye 回调 alive=false（设备离线上报）', () async {
    final updates = <(String, bool)>[];
    discovery.startListening(
      onDeviceUpdate: (loc, alive) => updates.add((loc, alive)),
    );
    await Future<void>.delayed(const Duration(milliseconds: 400));

    final ok = await _sendUntil(
      senders,
      _notify(location: location, nts: 'ssdp:byebye', usn: usn),
      () => updates.any((u) => u.$1 == location && !u.$2),
    );

    expect(ok, isTrue, reason: 'byebye 应回调 location 且 alive=false');
  });

  test('非 NOTIFY 数据报与缺 LOCATION 的 NOTIFY 都不产生回调', () async {
    final updates = <(String, bool)>[];
    discovery.startListening(
      onDeviceUpdate: (loc, alive) => updates.add((loc, alive)),
    );
    await Future<void>.delayed(const Duration(milliseconds: 400));

    // 唯一标记：多播地址 239.255.255.250 在 flutter test 并行执行多个 DLNA
    // 测试文件时被共享，本监听器必然会收到「其它并发测试」发来的设备报文，
    // 故不能直接要求 updates 为空（否则偶发硬红）。改为只断言「本用例构造的
    // 两类无效报文没有泄漏成 onDeviceUpdate」。
    const token = 'b37b-invalid-probe';
    final marker = 'http://127.0.0.1:9/$token/description.xml';

    // ① 不是 NOTIFY 开头（应被 continue 丢弃）。刻意带上 LOCATION：若实现误
    //    处理非 NOTIFY 报文，就会以 marker 形式暴露出来。
    await _sendUntil(
      senders,
      'M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\n'
          'LOCATION: $marker\r\n\r\n',
      () => false,
      rounds: 2,
      step: const Duration(milliseconds: 150),
    );
    // ② NOTIFY 但缺 LOCATION（locMatch==null → continue）。带上唯一 USN：
    //    即便实现改用 USN 拼 URL 也会被抓住；实现若上报空 URL 同样被抓住。
    await _sendUntil(
      senders,
      'NOTIFY * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\n'
          'NTS: ssdp:alive\r\nUSN: uuid:$token::$usn\r\n\r\n',
      () => false,
      rounds: 2,
      step: const Duration(milliseconds: 150),
    );

    final leaked = updates
        .where((u) => u.$1.contains(token) || u.$1.isEmpty)
        .toList();
    expect(leaked, isEmpty,
        reason: '两类无效报文都不应产生 onDeviceUpdate（并发串扰的外来设备不计）');
  });
}
