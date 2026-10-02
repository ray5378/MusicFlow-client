import 'package:flutter/foundation.dart';

/// 首页分区用户自定义布局（客户端自治）。
///
/// 覆盖服务端分区清单的顺序与可见性：
/// - [order]：用户排过序的分区 key（按用户顺序）；服务端新增分区不在其中，
///   追加到合并结果尾部。
/// - [hidden]：用户隐藏的分区 key；最终可见 = 服务端 visible && !hidden。
///
/// 持久化于 SharedPreferences（key `home_section_layout_v1`，JSON 字符串，
/// 仅 5 个分区的小列表，符合 prefs「只放小设置」的约束）。
@immutable
class HomeSectionLayout {
  final List<String> order;
  final List<String> hidden;

  /// mini 播放器（全局固定模块，非 discover 分区）是否显示，默认 true。
  /// 复用分区布局同一份持久化通道（`home_section_layout_v1`），不新开
  /// prefs key；旧数据缺该字段时回落 true（向后兼容）。
  final bool miniPlayerVisible;

  const HomeSectionLayout({
    this.order = const <String>[],
    this.hidden = const <String>[],
    this.miniPlayerVisible = true,
  });

  /// 无用户自定义（首次使用/清除后）：完全遵循服务端清单。
  static const HomeSectionLayout empty = HomeSectionLayout();

  bool get isEmpty =>
      order.isEmpty && hidden.isEmpty && miniPlayerVisible;

  HomeSectionLayout copyWith({
    List<String>? order,
    List<String>? hidden,
    bool? miniPlayerVisible,
  }) {
    return HomeSectionLayout(
      order: order ?? this.order,
      hidden: hidden ?? this.hidden,
      miniPlayerVisible: miniPlayerVisible ?? this.miniPlayerVisible,
    );
  }

  factory HomeSectionLayout.fromJson(Map<String, dynamic> json) {
    List<String> readList(Object? raw) {
      if (raw is! List) return const <String>[];
      return <String>[
        for (final item in raw)
          if (item is String && item.isNotEmpty) item,
      ];
    }

    return HomeSectionLayout(
      order: readList(json['order']),
      hidden: readList(json['hidden']),
      miniPlayerVisible: json['miniPlayerVisible'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'order': order,
      'hidden': hidden,
      'miniPlayerVisible': miniPlayerVisible,
    };
  }
}
