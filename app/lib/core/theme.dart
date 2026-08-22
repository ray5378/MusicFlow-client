import 'package:flutter/material.dart';

/// 设计令牌：颜色与字体规格（对齐箭头音乐参考稿）。
/// 全项目禁止硬编码字号/颜色，统一引用本文件。
abstract final class AppColors {
  static const seed = Color(0xFF6750A4);
  static const canvasLight = Color(0xFFF3F2F7);
  static const canvasDark = Color(0xFF141318);
}

/// 字体规格表（px）：display26 / headline19 / title15 / body13 / label12 / meta11。
@immutable
class AppTypography {
  const AppTypography(this.brightness);

  final Brightness brightness;

  Color get ink => brightness == Brightness.dark ? Colors.white : const Color(0xFF1B1B1F);
  Color get muted => brightness == Brightness.dark
      ? Colors.white70
      : const Color(0xFF5A5A64);

  TextStyle get display => TextStyle(fontSize: 26, fontWeight: FontWeight.w700, height: 1.16, color: ink);
  TextStyle get headline => TextStyle(fontSize: 19, fontWeight: FontWeight.w700, height: 1.22, color: ink);
  TextStyle get title => TextStyle(fontSize: 15, fontWeight: FontWeight.w600, height: 1.3, color: ink);
  TextStyle get body => TextStyle(fontSize: 13, fontWeight: FontWeight.w400, height: 1.5, color: ink);
  TextStyle get label => TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: ink);
  TextStyle get meta => TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w500,
    height: 1.25,
    color: muted,
  );

  ThemeData theme() {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.seed,
      brightness: brightness,
    );
    return ThemeData(
      colorScheme: scheme,
      scaffoldBackgroundColor: brightness == Brightness.dark
          ? AppColors.canvasDark
          : AppColors.canvasLight,
      useMaterial3: true,
      fontFamilyFallback: const ['Microsoft YaHei', 'PingFang SC', 'Noto Sans SC'],
      textTheme: TextTheme(
        displaySmall: display,
        headlineSmall: headline,
        titleMedium: title,
        bodyMedium: body,
        labelMedium: label,
        labelSmall: meta,
      ),
    );
  }
}
