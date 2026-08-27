import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import '../utils/logger.dart';

/// SSDP 设备发现模块
/// 使用 UDP 多播发送 M-SEARCH 并监听 NOTIFY 响应。
///
/// **** Windows 多网卡扫描修复（v2） ****
/// 实测：单纯「逐接口发多播」在 Windows 多网卡(多网段)下仍扫不到只在其中一个
/// 网段的 DLNA 设备，原因是 Windows 的多播**出接口**并不总是跟随 socket 绑定的
/// 地址——未显式锁定接口时，系统按默认多播接口发包，极可能落在与设备不同的网段。
/// 本版修复：
///   1. 每接口 socket **join 到该接口**（`joinMulticast(group, iface)` 锁定具体
///      网卡的组播成员，避免默认网卡），再发 M-SEARCH。
///   2. M-SEARCH **重发 3 次**（0 / 700 / 1400ms），容忍多播丢包与慢设备(接近 MX)。
///   3. 对绑定了具体 IP 的接口，额外发一份**子网定向广播**(x.y.z.255)；多播出接
///      口选错时，定向广播仍能按绑定接口被路由到本网段，兜底命中设备。
///   4. 兜底任意地址(0.0.0.0) socket 改发全局广播 255.255.255.255。
///   5. **过滤虚拟/VPN/隧道/链路本地接口**(Hyper-V vEthernet、tailscale、wireguard、
///      tunnel/tap/vpn、169.254/198.18/100.64 等)。Windows 上这些接口会带私网地址，
///      既污染系统「默认多播出接口」的选择，又让单播主机扫描去扫不存在的网段；
///      参考 auto-cast 的做法主动剔除，避免多网卡下白扫与误选。
///
/// 被动监听(NOTIFY)同样改为**逐接口 join**，覆盖所有网段的设备自播(ssdp:alive)。
class SsdpDiscovery {
  static const String _ssdpAddr = '239.255.255.250';
  static const int _ssdpPort = 1900;
  static const String _mrSt = 'urn:schemas-upnp-org:device:MediaRenderer:1';
  static const Duration _staleness = Duration(minutes: 10);

  /// 「任意地址」兜底哨兵：当探测不到任何可拨号接口 IP 时，回退绑定 `0.0.0.0`
  /// 单发一次 M-SEARCH，保证纯本机/异网环境下也至少有一次探测机会。
  static const String _anyAddressSentinel = '0.0.0.0';

  /// 每接口 M-SEARCH 重发间隔/次数（配合默认 4s 扫描超时）。
  static const int _probeRounds = 3;
  static const Duration _probeInterval = Duration(milliseconds: 700);

  /// 单播主机扫描上限网段(子网掩码取 /24，扫 .1~.254)。
  static const int _maxHostProbeEnd = 254;

  final Map<String, _SsdpAnnounced> _announced = {};
  final List<RawDatagramSocket> _listenerSockets = [];
  final List<Timer> _listenerTimers = [];
  bool _listening = false;

  /// 发送 M-SEARCH 并收集响应
  /// 返回发现的设备 location URL 列表
  ///
  /// [bindAddresses] 供测试显式注入要拨号的 IPv4 地址列表(可含环回以驱动逐接口
  /// 循环)；为空且未注入时自动探测全部非环回接口地址。
  Future<List<String>> search({
    Duration timeout = const Duration(seconds: 4),
    List<String>? bindAddresses,
  }) async {
    final locations = <String>{};
    final sockets = <RawDatagramSocket>[];
    final timers = <Timer>[];
    // 已做过单播主机扫描的私有 /24 子网（避免重复投递多张网卡落在同一子网）。
    final scannedSubnets = <String>{};

    final probe = bindAddresses ?? await _probeExplicitIpv4Addresses();
    // 无任何明确地址时回退到「任意地址」兜底拨号一次，保证始终至少一次探测机会。
    final addrs = probe.isEmpty ? [_anyAddressSentinel] : probe;
    Logger.debugWithTag('SSDP', '扫描开始: 拨号地址=$addrs 超时=${timeout.inMilliseconds}ms');

    final msearch = [
      'M-SEARCH * HTTP/1.1',
      'HOST: $_ssdpAddr:$_ssdpPort',
      'MAN: "ssdp:discover"',
      'MX: 3',
      'ST: $_mrSt',
      '',
      '',
    ].join('\r\n');
    final data = Uint8List.fromList(msearch.codeUnits);

    Future<void> drain(RawDatagramSocket socket) {
      locations.addAll(_collect(socket));
      return Future.value();
    }

    /// 对单个接口拨号：绑定该接口 IP → 在该接口 join 多播 → 重发 M-SEARCH(多播+
    /// 定向广播兜底)。
    Future<void> dial(String addr) async {
      RawDatagramSocket socket;
      final isAny = addr == _anyAddressSentinel;
      try {
        socket = await RawDatagramSocket.bind(
          isAny ? InternetAddress.anyIPv4 : InternetAddress(addr),
          0,
          reuseAddress: true,
        );
      } catch (_) {
        // 某接口绑定失败直接跳过：Windows 禁用网卡/权限不足时保证其余接口正常。
        return;
      }

      // 允许广播（定向/全局兜底需要）。
      try {
        socket.broadcastEnabled = true;
      } catch (_) {}

      // 关键：多播成员锁定到「该地址所属接口」。Windows 上若不传接口，join 落在
      // 默认多播接口；这里传 iface 使其组播身份跟随被绑定的网卡。
      try {
        final iface = isAny ? null : await _interfaceForAddress(addr);
        if (iface != null) {
          socket.joinMulticast(InternetAddress(_ssdpAddr), iface);
        } else {
          socket.joinMulticast(InternetAddress(_ssdpAddr));
        }
      } catch (_) {}

      sockets.add(socket);
      final drainTimer =
          Timer.periodic(const Duration(milliseconds: 80), (_) {
        drain(socket);
      });
      timers.add(drainTimer);

      /// 一轮探测：主发多播 + 兜底广播。
      void sendProbe() {
        socket.send(data, InternetAddress(_ssdpAddr), _ssdpPort);
        // 定向广播：从绑定具体接口的 socket 发往本网段广播地址，多播出接口选错时
        // 仍能按绑定接口路由到设备所在网段（大多数 DLNA/SSDP 设备会应答广播）。
        if (!isAny) {
          final bc = _directedBroadcast(addr);
          if (bc != null) {
            try {
              socket.send(data, InternetAddress(bc), _ssdpPort);
            } catch (_) {}
          }
        } else {
          // 任意地址兜底：改发全局广播，尽量覆盖默认接口所在网段。
          try {
            socket.send(data, InternetAddress('255.255.255.255'), _ssdpPort);
          } catch (_) {}
        }
      }

      sendProbe();
      for (int i = 1; i < _probeRounds; i++) {
        timers.add(Timer(_probeInterval * i, sendProbe));
      }

      // 单播主机扫描兜底：对/24 私有子网逐 host 发单播 M-SEARCH。多播/广播在个别
      // Windows 网卡上可能受系统多播行为影响收不到回包，但单播请求+单播回源不依赖
      // OS 多播，命中 DLNA 设备最稳。仅在子网唯一时执行一次（避免 g_Gk 多网卡重复）。
      if (!isAny) {
        final subnet = _subnetBase24(addr);
        if (subnet != null && scannedSubnets.add(subnet)) {
          for (int host = 1; host <= 254 && host <= _maxHostProbeEnd; host++) {
            final target = '$subnet.$host';
            try {
              socket.send(data, InternetAddress(target), _ssdpPort);
            } catch (_) {}
          }
        }
      }
    }

    try {
      // 逐接口拨号（语义与旧实现一致；顺序无关紧要）。
      await Future.forEach(addrs, dial);
      // 等待 timeout 后统一回收（与旧实现语义一致：超时即返回当前发现）。
      await Future<void>.delayed(timeout);
    } finally {
      for (final t in timers) {
        t.cancel();
      }
      for (final s in sockets) {
        s.close();
      }
    }

    Logger.debugWithTag('SSDP', '扫描结束: 拨号地址=$addrs 收到 ${locations.length} 个 LOCATION 响应');
    return locations.toList();
  }

  /// 从 socket 当前排队的数据报中解析出全部 LOCATION。
  List<String> _collect(RawDatagramSocket? socket) {
    if (socket == null) return const [];
    final found = <String>[];
    Datagram? packet;
    while ((packet = socket.receive()) != null) {
      final text = String.fromCharCodes(packet!.data);
      final locMatch = RegExp(r'^LOCATION:\s*(.+)$', multiLine: true)
          .firstMatch(text);
      if (locMatch != null) {
        found.add(locMatch.group(1)!.trim());
      }
    }
    return found;
  }

  /// 返回全部非环回接口的 IPv4 地址（去重），逐接口拨号用。
  Future<List<String>> _probeExplicitIpv4Addresses() async {
    final addrs = <String>{};
    try {
      final interfaces = await _probeInterfaces();
      for (final iface in interfaces) {
        for (final a in iface.addresses) {
          if (a.type == InternetAddressType.IPv4) addrs.add(a.address);
        }
      }
    } catch (_) {}
    return addrs.toList();
  }

  /// 返回全部非环回接口（含 IPv4 线索），供逐接口 join / 被动监听多网卡覆盖。
  /// 会剔除虚拟/VPN/隧道/链路本地接口：它们带私网地址却无法承载真实 DLNA 设备，
  /// 且在 Windows 上会干扰多播出接口选择与单播扫描网段。
  Future<List<NetworkInterface>> _probeInterfaces() async {
    final result = <NetworkInterface>[];
    try {
      final interfaces =
          await NetworkInterface.list(includeLinkLocal: false);
      for (final iface in interfaces) {
        if (_skipInterface(iface)) continue;
        final hasIpv4 =
            iface.addresses.any((a) => a.type == InternetAddressType.IPv4);
        if (hasIpv4) result.add(iface);
      }
    } catch (_) {}
    return result;
  }

  /// 判断某接口是否应被剔除（虚拟扩卡 / VPN / 隧道 / 链路本地等）。
  bool _skipInterface(NetworkInterface iface) {
    final name = iface.name.toLowerCase();
    const keywords = <String>[
      'vethernet', // Hyper-V 虚拟以太网适配器
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
      'easytier', // EasyTier：Linux 侧 `dev_name=easytier` 的 TUN
    ];
    if (keywords.any(name.contains)) return true;
    // EasyTier(Windows) 自动生成网卡名 `et_{序号}_{随机4位}`（如 et_6_vg7l / et_net_a）。
    // 注意：不能按裸 `et` 前缀过滤，否则会把真实网卡 "Ethernet" 一并挡掉。
    // 只匹配 `et_` 或 `et-` 前缀（及完全等于 `et`），避开 "Ethernet" 这类以 et 开头的
    // 物理网卡，见 EasyTier/src/arch/windows.rs 的接口命名。
    final et = name;
    if (et == 'et' || et.startsWith('et_') || et.startsWith('et-')) return true;
    return iface.addresses.any(_isBlockedIpv4);
  }

  /// 链路本地 / 保留网段：不承载真实局域网 DLNA 设备，且会让单播扫描扫空网段。
  bool _isBlockedIpv4(InternetAddress a) {
    if (a.type != InternetAddressType.IPv4) return false;
    final ip = a.address;
    return ip.startsWith('127.') ||
        ip.startsWith('169.254.') ||
        ip.startsWith('198.18.') ||
        ip.startsWith('198.19.') ||
        ip.startsWith('100.64.');
  }

  /// 根据 IPv4 地址反查其所属接口（用于将该 address 的 socket 多播成员锁定到接口）。
  Future<NetworkInterface?> _interfaceForAddress(String addr) async {
    try {
      for (final iface in await _probeInterfaces()) {
        for (final a in iface.addresses) {
          if (a.type == InternetAddressType.IPv4 && a.address == addr) {
            return iface;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  /// 按 /24 推导某 IPv4 的子网定向广播地址（兜底：多播出接口选错时命中本网段）。
  /// 非点分十进制或环回/任意地址返回 null。
  String? _directedBroadcast(String addr) {
    final parts = addr.split('.');
    if (parts.length != 4) return null;
    for (final p in parts) {
      final n = int.tryParse(p);
      if (n == null || n < 0 || n > 255) return null;
    }
    if (parts[0] == '127' || addr == _anyAddressSentinel) return null;
    return '${parts[0]}.${parts[1]}.${parts[2]}.255';
  }

  /// 私有 /24 子网的「前 3 段」；仅对私网地址(10/172.16-31/192.168)返回，其它如
  /// 环回/169.254/公网返回 null(不做全网段主机扫描)。
  String? _subnetBase24(String addr) {
    final parts = addr.split('.');
    if (parts.length != 4) return null;
    int a;
    int b;
    try {
      a = int.parse(parts[0]);
      b = int.parse(parts[1]);
    } catch (_) {
      return null;
    }
    if (a < 0 || a > 255 || b < 0 || b > 255) return null;
    final private = a == 10 || (a == 172 && b >= 16 && b <= 31) || a == 192 && b == 168;
    if (!private) return null;
    return '${parts[0]}.${parts[1]}.${parts[2]}';
  }

  /// 启动被动监听（NOTIFY 消息）。逐接口 join，覆盖所有网段设备自播。
  void startListening({
    void Function(String location, bool alive)? onDeviceUpdate,
  }) {
    if (_listening) return;
    _listening = true;
    _setupListenerSockets(onDeviceUpdate);
  }

  Future<void> _setupListenerSockets(
    void Function(String location, bool alive)? onDeviceUpdate,
  ) async {
    final interfaces = await _probeInterfaces();
    // 无明确接口时仍绑定任意地址 join 默认多播接口，保证至少有监听通道。
    final targets = interfaces.isEmpty ? <NetworkInterface?>[null] : interfaces;

    for (final iface in targets) {
      RawDatagramSocket socket;
      try {
        socket = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          _ssdpPort,
          reuseAddress: true,
        );
      } catch (_) {
        // 端口被占/权限不足：跳过该接口，其余接口照常监听。
        continue;
      }

      try {
        if (iface != null) {
          socket.joinMulticast(InternetAddress(_ssdpAddr), iface);
        } else {
          socket.joinMulticast(InternetAddress(_ssdpAddr));
        }
      } catch (_) {}

      _listenerSockets.add(socket);
      final timer = Timer.periodic(const Duration(milliseconds: 120), (_) {
        _drainSsdp(socket, onDeviceUpdate);
      });
      _listenerTimers.add(timer);
    }
  }

  void _drainSsdp(
    RawDatagramSocket socket,
    void Function(String location, bool alive)? onDeviceUpdate,
  ) {
    Datagram? packet;
    while ((packet = socket.receive()) != null) {
      final text = String.fromCharCodes(packet!.data);
      if (!text.startsWith('NOTIFY')) continue;

      final locMatch = RegExp(r'^LOCATION:\s*(.+)$', multiLine: true)
          .firstMatch(text);
      final ntsMatch = RegExp(r'^NTS:\s*(.+)$', multiLine: true)
          .firstMatch(text);
      final usnMatch = RegExp(r'^USN:\s*(.+)$', multiLine: true)
          .firstMatch(text);

      if (locMatch == null) continue;

      final location = locMatch.group(1)!.trim();
      final nts = ntsMatch?.group(1)?.trim() ?? '';
      final usn = usnMatch?.group(1)?.trim() ?? '';

      if (nts == 'ssdp:byebye') {
        _announced.remove(usn);
        onDeviceUpdate?.call(location, false);
      } else if (nts == 'ssdp:alive' || nts == 'ssdp:update') {
        _announced[usn] = _SsdpAnnounced(
          location: location,
          lastSeen: DateTime.now(),
        );
        onDeviceUpdate?.call(location, true);
      }
    }
  }

  /// 停止被动监听
  void stopListening() {
    for (final t in _listenerTimers) {
      t.cancel();
    }
    _listenerTimers.clear();
    for (final s in _listenerSockets) {
      s.close();
    }
    _listenerSockets.clear();
    _listening = false;
  }

  /// 获取所有已发现的 location（包括被动监听到的）
  List<String> get discoveredLocations {
    final now = DateTime.now();
    final locations = <String>{};

    // 清理过期条目
    _announced.removeWhere((_, info) {
      if (now.difference(info.lastSeen) > _staleness) {
        return true;
      }
      locations.add(info.location);
      return false;
    });

    return locations.toList();
  }

  /// 清理资源
  void dispose() {
    stopListening();
    _announced.clear();
  }
}

class _SsdpAnnounced {
  final String location;
  final DateTime lastSeen;

  const _SsdpAnnounced({
    required this.location,
    required this.lastSeen,
  });
}