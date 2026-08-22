import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

/// DLNA 设备（SSDP 发现）。
class DlnaDevice {
  DlnaDevice({
    required this.id,
    required this.name,
    required this.avTransportUrl,
    this.renderingControlUrl,
  });

  final String id; // UDN
  final String name;
  final String avTransportUrl;
  final String? renderingControlUrl;
}

/// 设备播放状态快照。
class DlnaStatus {
  const DlnaStatus({
    this.active = false,
    this.state = 'STOPPED',
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.volume,
    this.muted = false,
  });

  final bool active;
  final String state; // PLAYING / PAUSED_PLAYBACK / STOPPED
  final Duration position;
  final Duration duration;
  final int? volume;
  final bool muted;

  DlnaStatus copyWith({
    bool? active,
    String? state,
    Duration? position,
    Duration? duration,
    int? volume,
    bool? muted,
  }) =>
      DlnaStatus(
        active: active ?? this.active,
        state: state ?? this.state,
        position: position ?? this.position,
        duration: duration ?? this.duration,
        volume: volume ?? this.volume,
        muted: muted ?? this.muted,
      );
}

Duration _parseHms(String? s) {
  if (s == null || s.isEmpty) return Duration.zero;
  final p = s.split(':');
  if (p.length != 3) return Duration.zero;
  final h = int.tryParse(p[0]) ?? 0;
  final m = int.tryParse(p[1]) ?? 0;
  final sec = double.tryParse(p[2]) ?? 0;
  return Duration(seconds: h * 3600 + m * 60 + sec.round());
}

String _hms(Duration d) {
  final total = d.inSeconds.clamp(0, 86399);
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}

/// SOAP 动作信封。
String soapEnvelope(String service, String action, Map<String, String> args) {
  final body = args.entries
      .map((e) => '<${e.key}>${_esc(e.value)}</${e.key}>')
      .join();
  return '''<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body><u:$action xmlns:u="$service">$body</u:$action></s:Body>
</s:Envelope>''';
}

String _esc(String v) => v
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

const _avt = 'urn:schemas-upnp-org:service:AVTransport:1';
const _rcs = 'urn:schemas-upnp-org:service:RenderingControl:1';

/// DLNA 投屏服务：SSDP 发现 → 描述解析 → SOAP 控制 → 状态轮询。
class DlnaService {
  final http.Client _http = http.Client();

  final ValueNotifier<List<DlnaDevice>> devices = ValueNotifier([]);
  final ValueNotifier<DlnaStatus> status =
      ValueNotifier(const DlnaStatus());

  RawDatagramSocket? _ssdpSocket;
  StreamSubscription<RawSocketEvent>? _ssdpSub;
  Timer? _discoverTimer;

  static const _ssdpAddr = '239.255.255.250';
  static const _ssdpPort = 1900;
  static const _searchTarget = 'urn:schemas-upnp-org:device:MediaRenderer:1';
  static const _ssdpClientPort = 0;

  // ==================== 发现 ====================

  Future<void> scan({Duration window = const Duration(seconds: 4)}) async {
    final found = <String, DlnaDevice>{};
    try {
      _ssdpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, _ssdpClientPort);
      _ssdpSocket!.send(utf8.encode(_mSearch()), InternetAddress(_ssdpAddr), _ssdpPort);
      _ssdpSub = _ssdpSocket!.listen((_) {
        final dg = _ssdpSocket?.receive();
        if (dg == null) return;
        final text = utf8.decode(dg.data, allowMalformed: true);
        final loc = RegExp(
          r'LOCATION:\s*(\S+)',
          caseSensitive: false,
        ).firstMatch(text)?.group(1);
        if (loc != null && !found.containsKey(loc)) found[loc] = _pending(loc);
      });
      // M-SEARCH 发两轮提高命中率。
      _discoverTimer = Timer(window ~/ 2, () {
        _ssdpSocket?.send(utf8.encode(_mSearch()), InternetAddress(_ssdpAddr), _ssdpPort);
      });
      await Future<void>.delayed(window);
      final list = <DlnaDevice>[];
      for (final loc in found.keys) {
        final d = await _describe(loc);
        if (d != null) list.add(d);
      }
      devices.value = list;
    } catch (_) {
      // 组播不可用（如无多播权限）：保留空列表，UI 可重试。
    } finally {
      _closeSsdp();
    }
  }

  void _closeSsdp() {
    _discoverTimer?.cancel();
    _ssdpSub?.cancel();
    _ssdpSocket?.close();
    _ssdpSocket = null;
  }

  DlnaDevice _pending(String location) => DlnaDevice(id: location, name: location, avTransportUrl: location);

  String _mSearch() => 'M-SEARCH * HTTP/1.1\r\n'
      'HOST: $_ssdpAddr:$_ssdpPort\r\n'
      'MAN: "ssdp:discover"\r\n'
      'MX: 3\r\n'
      'ST: $searchTargetSt\r\n'
      '\r\n';

  static const searchTargetSt = _searchTarget;

  /// 拉取设备描述 XML 并提取控制 URL。
  Future<DlnaDevice?> _describe(String location) async {
    try {
      final res = await _http
          .get(Uri.parse(location))
          .timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) return null;
      final doc = XmlDocument.parse(utf8.decode(res.bodyBytes));
      final base = doc.findAllElements('URLBase').map((e) => e.innerText).firstOrNull ??
          location;
      final udn = doc.findAllElements('UDN').map((e) => e.innerText).firstOrNull ?? location;
      var friendly = doc
          .findAllElements('friendlyName')
          .map((e) => e.innerText.trim())
          .firstOrNull;
      friendly = (friendly == null || friendly.isEmpty) ? 'DLNA 设备' : friendly;

      String? controlOf(String serviceType) {
        for (final svc in doc.findAllElements('service')) {
          final st = svc.findElements('serviceType').map((e) => e.innerText).firstOrNull;
          if (st != serviceType) continue;
          final rel = svc.findElements('controlURL').map((e) => e.innerText).firstOrNull;
          if (rel == null || rel.isEmpty) continue;
          return Uri.parse(base).resolve(rel).toString();
        }
        return null;
      }

      final avt = controlOf(_avt);
      if (avt == null) return null;
      final rcs = controlOf(_rcs);
      return DlnaDevice(
        id: udn,
        name: friendly,
        avTransportUrl: avt,
        renderingControlUrl: rcs,
      );
    } catch (_) {
      return null;
    }
  }

  // ==================== 控制 ====================

  Future<bool> postAction(
    String controlUrl,
    String serviceType,
    String action,
    Map<String, String> args,
  ) async {
    try {
      final res = await _http
          .post(
            Uri.parse(controlUrl),
            headers: {
              'content-type': 'text/xml; charset="utf-8"',
              'SOAPACTION': '"$serviceType#$action"',
            },
            body: soapEnvelope(serviceType, action, args),
          )
          .timeout(const Duration(seconds: 8));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, String>?> fetchStateResponse(
    String controlUrl,
    String serviceType,
    String action,
    Map<String, String> args,
  ) async {
    try {
      final res = await _http
          .post(
            Uri.parse(controlUrl),
            headers: {
              'content-type': 'text/xml; charset="utf-8"',
              'SOAPACTION': '"$serviceType#$action"',
            },
            body: soapEnvelope(serviceType, action, args),
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final doc = XmlDocument.parse(utf8.decode(res.bodyBytes));
      final resp = doc.findAllElements('${action}Response').firstOrNull;
      if (resp == null) return null;
      final out = <String, String>{};
      for (final child in resp.childElements) {
        out[child.localName] = child.innerText;
      }
      return out;
    } catch (_) {
      return null;
    }
  }

  DlnaDevice? currentDevice;

  /// 投屏：Stop → SetAVTransportURI → Play。成功后状态置为 PLAYING。
  Future<bool> cast(DlnaDevice device, String streamUrl,
      {String? title, String? artist}) async {
    currentDevice = device;
    status.value = status.value.copyWith(active: true, state: 'BUFFERING', position: Duration.zero);
    final meta = _didl(title: title ?? '', artist: artist ?? '', uri: streamUrl);
    await postAction(device.avTransportUrl, _avt, 'Stop', {'InstanceID': '0'});
    final setOk = await postAction(device.avTransportUrl, _avt, 'SetAVTransportURI', {
      'InstanceID': '0',
      'CurrentURI': streamUrl,
      'CurrentURIMetaData': meta,
    });
    if (!setOk) {
      status.value = const DlnaStatus();
      return false;
    }
    final playOk = await postAction(
      device.avTransportUrl,
      _avt,
      'Play',
      {'InstanceID': '0', 'Speed': '1'},
    );
    status.value = status.value.copyWith(active: playOk, state: playOk ? 'PLAYING' : 'STOPPED');
    return playOk;
  }

  Future<void> pause() async {
    final d = currentDevice;
    if (d == null) return;
    final ok = await postAction(d.avTransportUrl, _avt, 'Pause', {'InstanceID': '0'});
    if (ok) status.value = status.value.copyWith(state: 'PAUSED_PLAYBACK');
  }

  Future<void> resume() async {
    final d = currentDevice;
    if (d == null) return;
    final ok = await postAction(d.avTransportUrl, _avt, 'Play', {'InstanceID': '0', 'Speed': '1'});
    if (ok) status.value = status.value.copyWith(state: 'PLAYING');
  }

  Future<void> stop() async {
    final d = currentDevice;
    if (d != null) {
      await postAction(d.avTransportUrl, _avt, 'Stop', {'InstanceID': '0'});
    }
    currentDevice = null;
    status.value = const DlnaStatus();
  }

  Future<void> seek(Duration position) async {
    final d = currentDevice;
    if (d == null) return;
    await postAction(d.avTransportUrl, _avt, 'Seek', {
      'InstanceID': '0',
      'Unit': 'REL_TIME',
      'Target': _hms(position),
    });
    status.value = status.value.copyWith(position: position);
  }

  Future<void> setVolume(int volume) async {
    final d = currentDevice;
    if (d == null || d.renderingControlUrl == null) return;
    final ok = await postAction(d.renderingControlUrl!, _rcs, 'SetVolume', {
      'InstanceID': '0',
      'Channel': 'Master',
      'DesiredVolume': '${volume.clamp(0, 100)}',
    });
    if (ok) status.value = status.value.copyWith(volume: volume.clamp(0, 100));
  }

  /// 轮询一次设备状态（由 PlayerService 定时调用）。
  Future<void> pollStatus() async {
    final d = currentDevice;
    if (d == null) return;
    final t = await fetchStateResponse(d.avTransportUrl, _avt, 'GetTransportInfo', {'InstanceID': '0'});
    final state = t?['CurrentTransportState'] ?? 'STOPPED';
    final active = state == 'PLAYING' || state == 'PAUSED_PLAYBACK' || state == 'TRANSITIONING';
    var next = status.value.copyWith(active: active, state: active ? (state == 'TRANSITIONING' ? 'PLAYING' : state) : 'STOPPED');
    if (!active) {
      status.value = next;
      return;
    }
    final pos = await fetchStateResponse(d.avTransportUrl, _avt, 'GetPositionInfo', {'InstanceID': '0'});
    if (pos != null) {
      next = next.copyWith(
        position: _parseHms(pos['RelTime']),
        duration: _parseHms(pos['TrackDuration']),
      );
    }
    if (d.renderingControlUrl != null && status.value.volume == null) {
      final vol = await fetchStateResponse(
        d.renderingControlUrl!,
        _rcs,
        'GetVolume',
        {'InstanceID': '0', 'Channel': 'Master'},
      );
      final v = int.tryParse(vol?['CurrentVolume'] ?? '');
      if (v != null) next = next.copyWith(volume: v);
    }
    status.value = next;
  }

  String _didl({required String title, required String artist, required String uri}) {
    final item = '''
<item id="musicflow-1" restricted="0">
<title>${_esc(title)}</title>
<creator>${_esc(artist)}</creator>
<upnp:class>object.item.audioItem.musicTrack</upnp:class>
</item>''';
    return _esc('<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
        'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/">$item</DIDL-Lite>');
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
