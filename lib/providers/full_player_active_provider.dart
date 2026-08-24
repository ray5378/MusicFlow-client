import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 大屏播放页是否正在顶层前台显示。
///
/// Windows 桌面端据此隐藏自绘标题栏，让播放页真正全屏沉浸，
/// 消除顶部因标题栏(surface 白底)残留产生的白条/白边。
final fullPlayerActiveProvider = StateProvider<bool>((ref) => false);