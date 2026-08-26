/// DLNA 模块数据模型

/// 投屏曲目（链路 B）—— 轻量模型，不依赖业务 Song 层
class DlnaCastTrack {
  final String songId;
  final String title;
  final String? artist;
  final String? album;

  const DlnaCastTrack({
    required this.songId,
    required this.title,
    this.artist,
    this.album,
  });
}

/// DLNA 设备信息
class DlnaDevice {
  final String id; // UDN (uuid)
  final String name; // friendlyName
  final String? alias; // 用户自定义名称
  final String location; // description.xml URL
  final String? manufacturer;
  final String? model;
  final String? avTransportUrl; // AVTransport 控制 URL
  final String? renderingControlUrl; // RenderingControl 控制 URL
  final DateTime lastSeen;
  final bool available;
  final bool disabled;

  const DlnaDevice({
    required this.id,
    required this.name,
    this.alias,
    required this.location,
    this.manufacturer,
    this.model,
    this.avTransportUrl,
    this.renderingControlUrl,
    required this.lastSeen,
    this.available = true,
    this.disabled = false,
  });

  String get displayName => alias?.isNotEmpty == true ? alias! : name;

  DlnaDevice copyWith({
    String? id,
    String? name,
    String? alias,
    String? location,
    String? manufacturer,
    String? model,
    String? avTransportUrl,
    String? renderingControlUrl,
    DateTime? lastSeen,
    bool? available,
    bool? disabled,
  }) {
    return DlnaDevice(
      id: id ?? this.id,
      name: name ?? this.name,
      alias: alias ?? this.alias,
      location: location ?? this.location,
      manufacturer: manufacturer ?? this.manufacturer,
      model: model ?? this.model,
      avTransportUrl: avTransportUrl ?? this.avTransportUrl,
      renderingControlUrl: renderingControlUrl ?? this.renderingControlUrl,
      lastSeen: lastSeen ?? this.lastSeen,
      available: available ?? this.available,
      disabled: disabled ?? this.disabled,
    );
  }
}

/// DLNA 投屏会话
class DlnaCastSession {
  final String token; // 流会话 token
  final String deviceId;
  final String songId;
  final DateTime createdAt;
  final DateTime expiresAt;

  const DlnaCastSession({
    required this.token,
    required this.deviceId,
    required this.songId,
    required this.createdAt,
    required this.expiresAt,
  });

  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

/// DLNA 播放状态
class DlnaDeviceStatus {
  final String state; // PLAYING / PAUSED / STOPPED / TRANSITIONING
  final int position; // 秒
  final int duration; // 秒
  final int volume; // 0-100
  final bool muted;

  const DlnaDeviceStatus({
    this.state = 'STOPPED',
    this.position = 0,
    this.duration = 0,
    this.volume = 0,
    this.muted = false,
  });

  DlnaDeviceStatus copyWith({
    String? state,
    int? position,
    int? duration,
    int? volume,
    bool? muted,
  }) {
    return DlnaDeviceStatus(
      state: state ?? this.state,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      volume: volume ?? this.volume,
      muted: muted ?? this.muted,
    );
  }
}

/// SSDP 设备发现结果（原始数据，待解析 description.xml）
class SsdpDeviceRaw {
  final String location;
  final DateTime lastSeen;

  const SsdpDeviceRaw({
    required this.location,
    required this.lastSeen,
  });
}
