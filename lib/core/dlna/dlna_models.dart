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

/// 投屏路径档位。
/// 客户端逐首 `SetAVTransportURI(服务端直连流 URL) → Play`，设备用自己的网卡
/// **直连服务器自拉流**，客户端仅遥控；曲毕由客户端轮询检测自动 Set 下一首续播。
enum DlnaCastPath { direct }

/// 设备投屏能力（由描述文件 + 实探结果组合判定）。
class DeviceCapability {
  /// 能直连服务器 URL 拉流（绝大多数渲染器都具备）。
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

  /// copyWith 哨兵：区分「省略参数（保持原值）」与「显式传 null（清空字段）」。
  static const Object _unset = Object();

  DlnaDevice copyWith({
    String? id,
    String? name,
    Object? alias = _unset,
    String? location,
    Object? manufacturer = _unset,
    Object? model = _unset,
    Object? avTransportUrl = _unset,
    Object? renderingControlUrl = _unset,
    DateTime? lastSeen,
    bool? available,
    bool? disabled,
  }) {
    return DlnaDevice(
      id: id ?? this.id,
      name: name ?? this.name,
      // [D-022 已修] 可空字段用哨兵区分两种语义：省略=保持、显式 null=清空。
      // 不传参数的既有调用（如 copyWith(available: false)）行为完全不变，源兼容。
      alias: _resolveNullable(alias, this.alias),
      location: location ?? this.location,
      manufacturer: _resolveNullable(manufacturer, this.manufacturer),
      model: _resolveNullable(model, this.model),
      avTransportUrl: _resolveNullable(avTransportUrl, this.avTransportUrl),
      renderingControlUrl:
          _resolveNullable(renderingControlUrl, this.renderingControlUrl),
      lastSeen: lastSeen ?? this.lastSeen,
      available: available ?? this.available,
      disabled: disabled ?? this.disabled,
    );
  }

  /// [D-022] 哨兵解析：省略（= _unset）→ 保持 current；其余（含显式 null）→ 采用传入值。
  static T? _resolveNullable<T>(Object? value, T? current) =>
      identical(value, _unset) ? current : value as T?;
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
