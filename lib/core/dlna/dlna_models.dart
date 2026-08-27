/// DLNA 模块数据模型

/// 投屏曲目（链路 B）—— 轻量模型，不依赖业务 Song 层
class DlnaCastTrack {
  final String songId;
  final String title;
  final String? artist;
  final String? album;

  /// 真实时长(秒)，来自 Song.duration，可能为 null/0(未知)。
  /// 用于设备不报时长(RawHTTP)时基于墙钟兜底的自动续播与播控进度。
  final int? duration;

  /// MIME 提示（来自 Song 的后缀/内容类型），用于直传 A 的 DIDL 元数据与能力探测。
  final String? mimeHint;

  const DlnaCastTrack({
    required this.songId,
    required this.title,
    this.artist,
    this.album,
    this.duration,
    this.mimeHint,
  });
}

/// 投屏路径档位（A 直传 / B CDS 清单）。硬砍 C 中继后仅此两档。
enum DlnaCastPath { direct, cdsList }

/// 设备投屏能力（由描述文件 + 实探结果组合判定）。
/// 作为「直传优先 A + CDS 清单 B」路径选择（Capability 探测）的输入。
class DeviceCapability {
  /// 能直连服务器 URL 拉流（绝大多数渲染器都具备，A 档前提）。
  final bool supportsDirectHttp;

  /// 具备 ContentDirectory 服务，可接收 CDS 容器整列表自播（B 档前提）。
  final bool supportsContentDirectory;

  /// 支持 SetNextAVTransportURI 无缝预置下一首。
  final bool supportsSetNext;

  /// GetPositionInfo 能回报真实时长（RawHTTP 流常回报 0，此时依赖墙钟兜底）。
  final bool reportsDuration;

  const DeviceCapability({
    this.supportsDirectHttp = true,
    this.supportsContentDirectory = false,
    this.supportsSetNext = false,
    this.reportsDuration = false,
  });

  /// 设备能否自主循环整队列（无需客户端逐首续播）。
  bool get canSelfLoopQueue => supportsContentDirectory;
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
  final String? contentDirectoryUrl; // ContentDirectory(CDS) 控制 URL，B 档前提
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
    this.contentDirectoryUrl,
    required this.lastSeen,
    this.available = true,
    this.disabled = false,
  });

  String get displayName => alias?.isNotEmpty == true ? alias! : name;

  /// 是否暴露 ContentDirectory 服务（能否走 B 档 CDS 清单）。
  bool get supportsContentDirectory => contentDirectoryUrl != null;

  DlnaDevice copyWith({
    String? id,
    String? name,
    String? alias,
    String? location,
    String? manufacturer,
    String? model,
    String? avTransportUrl,
    String? renderingControlUrl,
    String? contentDirectoryUrl,
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
      contentDirectoryUrl: contentDirectoryUrl ?? this.contentDirectoryUrl,
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
