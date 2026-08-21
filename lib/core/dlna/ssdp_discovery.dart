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

  final Map<String, _SsdpAnnounced> _announced = {};
  RawDatagramSocket? _listenerSocket;
  Timer? _pollTimer;
  bool _listening = false;

  /// 发送 M-SEARCH 并收集响应
  /// 返回发现的设备 location URL 列表
  Future<List<String>> search({Duration timeout = const Duration(seconds: 4)}) async {
    final locations = <String>{};
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
        final interfaces = await NetworkInterface.list(includeLinkLocal: false);
        NetworkInterface? multicastInterface;
        for (final iface in interfaces) {
          if (!iface.name.startsWith('lo')) {
            multicastInterface = iface;
            break;
          }
        }
        multicastInterface ??= interfaces.isNotEmpty ? interfaces.first : null;
        if (multicastInterface != null) {
          socket.joinMulticast(
            InternetAddress(_ssdpAddr),
            multicastInterface,
          );
        }
      } catch (_) {
        // 多播加入失败不影响单播搜索
      }

      // 轮询接收响应
      final receiveTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
        _pollDatagrams(socket, (location) {
          locations.add(location);
        });
      });

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
      final completer = Completer<void>();
      timer = Timer(timeout, () {
        receiveTimer.cancel();
        if (!completer.isCompleted) completer.complete();
      });

      await completer.future;
    } finally {
      timer?.cancel();
      socket?.close();
    }

    return locations.toList();
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
