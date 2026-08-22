import 'package:flutter/material.dart';

import 'echo_colors.dart';

/// Echo's single-family, content-first type hierarchy.
@immutable
class EchoTypography extends ThemeExtension<EchoTypography> {
  const EchoTypography({
    required this.display,
    required this.headline,
    required this.title,
    required this.body,
    required this.label,
    required this.metadata,
  });

  final TextStyle display;
  final TextStyle headline;
  final TextStyle title;
  final TextStyle body;
  final TextStyle label;
  final TextStyle metadata;

  factory EchoTypography.standard(EchoColors colors) {
    // 字号规格对齐「箭头音乐」参考稿(/root/opencode/photo/ui.jpg):
    // 内容紧凑、层级分明 —— 大标题 26 / 区块标题 19 / 条目标题 15 /
    // 正文 13 / 标签 12 / 元数据 11。禁止在 UI 中硬编码字号,统一走本令牌。
    return EchoTypography(
      display: TextStyle(
        color: colors.ink,
        fontSize: 26,
        fontWeight: FontWeight.w700,
        height: 1.16,
        letterSpacing: -0.52,
      ),
      headline: TextStyle(
        color: colors.ink,
        fontSize: 19,
        fontWeight: FontWeight.w700,
        height: 1.22,
        letterSpacing: -0.19,
      ),
      title: TextStyle(
        color: colors.ink,
        fontSize: 15,
        fontWeight: FontWeight.w600,
        height: 1.3,
      ),
      body: TextStyle(
        color: colors.ink,
        fontSize: 13,
        fontWeight: FontWeight.w400,
        height: 1.5,
      ),
      label: TextStyle(
        color: colors.ink,
        fontSize: 12,
        fontWeight: FontWeight.w600,
        height: 1.25,
        letterSpacing: 0.12,
      ),
      metadata: TextStyle(
        color: colors.muted,
        fontSize: 11,
        fontWeight: FontWeight.w500,
        height: 1.25,
        fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
      ),
    );
  }

  @override
  EchoTypography copyWith({
    TextStyle? display,
    TextStyle? headline,
    TextStyle? title,
    TextStyle? body,
    TextStyle? label,
    TextStyle? metadata,
  }) {
    return EchoTypography(
      display: display ?? this.display,
      headline: headline ?? this.headline,
      title: title ?? this.title,
      body: body ?? this.body,
      label: label ?? this.label,
      metadata: metadata ?? this.metadata,
    );
  }

  @override
  EchoTypography lerp(covariant EchoTypography? other, double t) {
    if (other == null) {
      return this;
    }
    return EchoTypography(
      display: TextStyle.lerp(display, other.display, t)!,
      headline: TextStyle.lerp(headline, other.headline, t)!,
      title: TextStyle.lerp(title, other.title, t)!,
      body: TextStyle.lerp(body, other.body, t)!,
      label: TextStyle.lerp(label, other.label, t)!,
      metadata: TextStyle.lerp(metadata, other.metadata, t)!,
    );
  }
}
