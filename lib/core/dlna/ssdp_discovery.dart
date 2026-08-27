import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// SSDP 设备发现模块
/// 使用 UDP 多播发送 M-SEARCH 并监听 NOTIFY 响应
class SsdpDiscovery {
  static const String _ssdpAddr = '239.255.255.250';
  static const int _ssdpPort = 1900;
  static const String _mrSt = 'urn:schemas-upnp-org:device:MediaRenderer:1';
  static const Duration _staleness = Duration(minutes: 10);
  /// 「任意地址」兜底哨兵：当探测不到任何可拨号接口 IP 时，回退绑定 `0.0.0.0`
  /// 单发一次 M-SEARCH，保证纯本机/异网环境下也至少有一次探测机会。
  static const String _anyAddressSentinel = '0.0.0.0';

  final Map<String, _SsdpAnnounced> _announced = {};
  RawDatagramSocket? _listenerSocket;
  Timer? _pollTimer;
  bool _listening = false;

  /// 发送 M-SEARCH 并收集响应
  /// 返回发现的设备 location URL 列表
  ///
  /// **** Windows 多网卡扫描修复 ****
  /// 此前只绑定 `任何地址` 并向多播组 join/发一次 M-SEARCH，Windows 上存在多个
  /// 接口(有线/无线/VPN/虚拟网卡)时依赖系统默认路由，极易选错网卡导致同一局域网
  /// 的 DLNA 设备扫不到。现改为**逐接口**拨号：为每个非环回接口的 IPv4 地址各
  /// 建一个独立 socket，从其绑定 IP 发出 M-SEARCH 并监听该接口，设备按包源地址
  /// 单播回应能可靠落回本 socket。任一接口 join 失败不致命——SSDP 响应本就是
  /// 单播回源，socket 收单播无需多播组成员资格。
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

    final probe = bindAddresses ?? await _probeExplicitIpv4Addresses();
    // 无任何明确地址时回退到「任意地址」兜底拨号一次，保证始终至少一次探测机会。
    final addrs = probe.isEmpty ? [_anyAddressSentinel] : probe;

    // M-SEARCH 报文（ST 仅请求 MediaRenderer，避免回复泛洪）。
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

    try {
      for (final addr in addrs) {
        RawDatagramSocket socket;
        try {
          socket = await RawDatagramSocket.bind(
            addr == _anyAddressSentinel ? InternetAddress.anyIPv4 : InternetAddress(addr),
            0,
            reuseAddress: true,
          );
        } catch (_) {
          // 某接口绑定失败直接跳过：Windows 禁用网卡/权限不足时保证其余接口正常。
          continue;
        }

        // 尽力加入多播组（失败不影响单播响应回源）。
        try {
          socket.joinMulticast(InternetAddress(_ssdpAddr));
        } catch (_) {}

        sockets.add(socket);
        socket.send(data, InternetAddress(_ssdpAddr), _ssdpPort);
        timers.add(Timer.periodic(const Duration(milliseconds: 100), (_) {
          _pollDatagrams(socket, locations.add);
        }));
      }

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

    return locations.toList();
  }

  /// 返回全部非环回接口的 IPv4 地址（去重），逐接口拨号用。
  Future<List<String>> _probeExplicitIpv4Addresses() async {
    final addrs = <String>{};
    try {
      final interfaces =
          await NetworkInterface.list(includeLinkLocal: false);
      for (final iface in interfaces) {
        if (iface.name.startsWith('lo')) continue;
        for (final a in iface.addresses) {
          if (a.type == InternetAddressType.IPv4) addrs.add(a.address);
        }
      }
    } catch (_) {}
    return addrs.toList();
  }

  /// 轮询接收 UDP 数据报
  void _pollDatagrams(RawDatagramSocket? socket, void Function(String) onLocation) {
    if (socket == null) return;
    Datagram? packet;
    while ((packet = socket.receive()) != null) {
      final text = String.fromCharCodes(packet!.data);
      final locMatch = RegExp(r'^LOCATION:\s*(.+)$', multiLine: true)
          .firstMatch(text);
      if (locMatch != null) {
        final location = locMatch.group(1)!.trim();
        onLocation(location);
      }
    }
  }

  /// 启动被动监听（NOTIFY 消息）
  void startListening({
    void Function(String location, bool alive)? onDeviceUpdate,
  }) {
    if (_listening) return;
    _listening = true;

    RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      _ssdpPort,
      reuseAddress: true,
    ).then((socket) {
      _listenerSocket = socket;

      try {
        socket.joinMulticast(InternetAddress(_ssdpAddr));
      } catch (_) {}

      _pollTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
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
      });
    });
  }

  /// 停止被动监听
  void stopListening() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _listenerSocket?.close();
    _listenerSocket = null;
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
