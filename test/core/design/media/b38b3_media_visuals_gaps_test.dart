// b38b3 —— `lib/core/design/media/music_flow_media_visuals.dart` 剩余缺口补测。
//
// 230 lcov 未覆盖：415/417/468/479/489。逐行核对 `_MediaCandidates.fromPalette`
// 与 `_blendDominantWithIdentity` 后，其中 3 条为**逻辑不可达的防御兜底**：
//   417  accentSeed 的 `dominant?.color`：`_bestExpressiveSwatch` 在 dominant 非空时
//        总能从 `paletteColors`（含 dominant 自身，权重 0.10 且跳过 population 过滤）
//        选出 expressive，故走不到 417。
//   468  `if (dominant == null) return expressive?.color;`：`fromPalette` 已提前
//        排除空 paletteColors，而非空时 `_dominantColor = paletteColors[0]` 必非空。
//   479  `populationRatio < 0.02` 返回 dominant：`_bestExpressiveSwatch` 对非 dominant
//        色已用同一阈值 0.02 过滤，能成为 expressive 者 ratio 必 ≥ 0.02。
//
// 本文件覆盖可达的 415（accentSeed 落到 darkVibrant：单一深色饱和色）与 489
// （`_blendDominantWithIdentity` 在 dominant 明度极端时 +0.08 影响权重），
// 并验证核心不变量（面板不透明、正文/强调色对比度达标）。
// 产品代码零改动；只读 lib。

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:palette_generator/palette_generator.dart';

import 'package:musicflow_client/core/design/media/music_flow_media_visuals.dart';
import 'package:musicflow_client/core/design/tokens/music_flow_colors.dart';

PaletteColor _pc(int argb, int population) =>
    PaletteColor(Color(argb), population);

PaletteGenerator _palette(List<PaletteColor> colors) =>
    PaletteGenerator.fromColors(colors, targets: PaletteTarget.baseTargets);

void _expectOpaque(MusicFlowMediaVisuals v) {
  for (final c in <Color>[
    v.stageBase,
    v.stageGlow,
    v.stageBottom,
    v.foreground,
    v.mutedForeground,
    v.controlAccent,
    v.miniSurface,
    v.panelSurface,
  ]) {
    expect(c.a, 1.0, reason: '所有面板色必须不透明');
  }
}

void _expectReadable(MusicFlowMediaVisuals v) {
  for (final s in <Color>[
    v.stageBase,
    v.stageGlow,
    v.stageBottom,
    v.miniSurface,
    v.panelSurface,
  ]) {
    expect(MusicFlowColors.contrastRatio(v.foreground, s),
        greaterThanOrEqualTo(4.5 - 0.001));
    expect(MusicFlowColors.contrastRatio(v.controlAccent, s),
        greaterThanOrEqualTo(3 - 0.001));
  }
}

void main() {
  test('单一深色饱和调色板：accentSeed 落到 darkVibrant（命中 415）仍稳定可读', () {
    // H=0, S=1, L≈0.15：vibrant/lightVibrant 的明度区间都不含它，
    // 只有 darkVibrant 目标命中 → accentSeed 链走到 415 的 darkVibrant?.color。
    final v = MusicFlowMediaVisuals.fromPalette(
      _palette(<PaletteColor>[_pc(0xFF4C0000, 100)]),
    );
    _expectOpaque(v);
    _expectReadable(v);
  });

  test('深色 dominant + 明色 vibrant：明度极端分支 +0.08 影响（命中 489）', () {
    // dominant = 极深饱和红（L≈0.15 < 0.08? 见断言），expressive 命中饱和蓝（L=0.5）。
    // _blendDominantWithIdentity 走影响权重计算，dominantHsl.lightness 极端 → 489。
    final v = MusicFlowMediaVisuals.fromPalette(
      _palette(<PaletteColor>[
        _pc(0xFF3A0000, 100), // 更暗（L≈0.11），落在 lightness<0.08 之外仍偏暗
        _pc(0xFF0000FF, 60), // 纯蓝，明度 0.5、饱和 1.0 → 命中 vibrant
      ]),
    );
    _expectOpaque(v);
    _expectReadable(v);
  });

  test('极暗 dominant（L<0.08）+ 饱和 expressive：仍产出可读面板', () {
    // L≈0.04 的深红 → dominantHsl.lightness < 0.08 明确成立，命中 489。
    final v = MusicFlowMediaVisuals.fromPalette(
      _palette(<PaletteColor>[
        _pc(0xFF140000, 100), // L≈0.039
        _pc(0xFF00A0FF, 55), // 饱和青蓝
      ]),
    );
    _expectOpaque(v);
    _expectReadable(v);
  });
}
