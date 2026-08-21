import 'dart:async';
import 'dart:io';

/// SSDP 设备发现模块
/// 使用 UDP 多播发送 M-SEARCH 并监听 NOTIFY 响应
class SsdpDiscovery {
  static const String _ssdpAddr = '239.255.255.250';
  static const int _ssdpPort = 1900;
  static const String _mrSt = 'urn:schemas-upnp-org:device:MediaRenderer:1';
  static const Duration _staleness = Duration(minutes: 10);

  final Map<String, _SsdpAnnounced> _announced = {};
  Socket? _listenerSocket;
  bool _listening = false;

  /// 发送 M-SEARCH 并收集响应
  /// 返回发现的设备 location URL 列表
  Future<List<String>> search({Duration timeout = const Duration(seconds: 4)}) async {
    final locations = <String>{};
    Completer<void>? completer;
    Timer? timer;
    RawDatagramSocket? socket;

    try {
      socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
        reuseAddress: true,
      );

      // 加入多播组以接收响应
      try {
        socket.joinMulticast(
          InternetAddress(_ssdpAddr),
          NetworkInterface.list(includeLinkLocal: false).then((interfaces) {
            // 选择第一个非回环接口
            for (final iface in interfaces) {
              if (!iface.name.startsWith('lo')) {
                return iface;
              }
            }
            return interfaces.first;
          }) as FutureOr<NetworkInterface>,
        );
      } catch (_) {
        // 多播加入失败不影响单播搜索
      }

      // 监听响应
      socket.listen(
        (RawDatagramPacket packet) {
          final text = String.fromCharCodes(packet.data);
          final locMatch = RegExp(r'^LOCATION:\s*(.+)$', multiLine: true)
              .firstMatch(text);
          if (locMatch != null) {
            final location = locMatch.group(1)!.trim();
            locations.add(location);
          }
        },
        onError: (_) {},
      );

      // 发送 M-SEARCH
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
      socket.send(
        data,
        InternetAddress(_ssdpAddr),
        _ssdpPort,
      );

      // 等待响应
      completer = Completer<void>();
      timer = Timer(timeout, () {
        if (!completer!.isCompleted) completer.complete();
      });

      await completer.future;
    } finally {
      timer?.cancel();
      socket?.close();
    }

    return locations.toList();
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

      socket.listen(
        (RawDatagramPacket packet) {
          final text = String.fromCharCodes(packet.data);
          if (!text.startsWith('NOTIFY')) return;

          final locMatch = RegExp(r'^LOCATION:\s*(.+)$', multiLine: true)
              .firstMatch(text);
          final ntsMatch = RegExp(r'^NTS:\s*(.+)$', multiLine: true)
              .firstMatch(text);
          final usnMatch = RegExp(r'^USN:\s*(.+)$', multiLine: true)
              .firstMatch(text);

          if (locMatch == null) return;

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
        },
        onError: (_) {},
      );
    });
  }

  /// 停止被动监听
  void stopListening() {
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
