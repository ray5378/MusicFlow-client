/// DLNA 模块数据模型
library;

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

/// 投屏路径档位（A 档·直传直连）。
/// 客户端逐首 `SetAVTransportURI(服务端直连流 URL) → Play`，设备用自己的网卡
/// **直连服务器自拉流**，客户端仅遥控；曲毕由客户端轮询检测自动 Set 下一首续播。
/// 不做本地中继/推流（v3.2 起已删除 `local_relay.dart`）。
enum DlnaCastPath { direct }

/// 设备投屏能力（由描述文件 + 实探结果组合判定）。
/// 仅 A 档·直传直连：设备持有一根 AVTransport 控制点即可逐首 Set 自拉流。
class DeviceCapability {
  /// 能直连服务器 URL 拉流（绝大多数渲染器都具备，A 档前提）。
  final bool supportsDirectHttp;

  /// 支持 SetNextAVTransportURI 无缝预置下一首。
  final bool supportsSetNext;

  /// GetPositionInfo 能回报真实时长（RawHTTP 流常回报 0，此时依赖墙钟兜底）。
  final bool reportsDuration;

  const DeviceCapability({
    this.supportsDirectHttp = true,
    this.supportsSetNext = false,
    this.reportsDuration = false,
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
