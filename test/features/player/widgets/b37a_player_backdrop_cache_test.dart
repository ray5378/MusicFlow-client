// batch37-A：`lib/features/player/widgets/player_backdrop.dart` 的**对比度结果缓存**
// 容量封顶分支（源码 226-228，lcov 未命中行 227）。
//
// `_ensureBackdropContrast` 用 (candidate, foreground, control) 三元组做缓存键，
// 容量达到 `_backdropContrastCacheLimit`(96) 时**整体清空**一次，防止换封面时
// 无界增长。日常渲染只碰固定几个封面 → 这条封顶分支在 UI 路径上几乎到不了；
// 这里直接用 `MusicFlowPlayerBackdrop.decoration` 这个**纯 getter**（不 pump、
// 不依赖 BuildContext）连续喂进远超 96 个不同取色，把封顶分支逼出来。
//
// 断言分两层：
//   1) 遍历过程**不得抛异常**（缓存清空后写入逻辑仍自洽）；
//   2) 最后一组 decoration 的三段渐变色仍满足与前景 4.5:1 / 控件 3:1 的对比底线，
//      确保「清空缓存」没有把对比度保证一起清掉。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/features/player/widgets/player_backdrop.dart';
import 'package:palette_generator/palette_generator.dart';

void main() {
  test('对比度缓存达到 96 上限后整体清空，且清空后仍保证对比度', () {
    MusicFlowMediaVisuals? last;
    // 用黄金角撒 400 个互不相同的色相 → 三元组键远超 96。
    for (var i = 0; i < 400; i++) {
      final hue = (i * 137.508) % 360;
      final base = HSVColor.fromAHSV(
        1,
        hue,
        0.45 + (i % 4) * 0.15,
        0.22 + (i % 6) * 0.13,
      ).toColor();
      final accent = HSVColor.fromAHSV(1, (hue + 180) % 360, 0.7, 0.6).toColor();

      last = MusicFlowMediaVisuals.fromPalette(
        PaletteGenerator.fromColors(<PaletteColor>[
          PaletteColor(base, 120),
          PaletteColor(accent, 48),
          PaletteColor(Color.lerp(base, Colors.white, 0.5)!, 20),
        ]),
      );

      // 两种模式都取一次 decoration，三种渐变色全部过一遍缓存写入。
      MusicFlowPlayerBackdrop(
        visuals: last,
        mode: MusicFlowPlayerBackdropMode.mini,
      ).decoration;
      MusicFlowPlayerBackdrop(
        visuals: last,
        mode: MusicFlowPlayerBackdropMode.stage,
      ).decoration;
    }

    final visuals = last!;
    final stage = MusicFlowPlayerBackdrop(
      visuals: visuals,
      mode: MusicFlowPlayerBackdropMode.stage,
    ).decoration;
    final gradient = stage.gradient! as LinearGradient;
    expect(gradient.colors.length, 3);
    for (final color in gradient.colors) {
      expect(
        MusicFlowColors.contrastRatio(visuals.foreground, color),
        greaterThanOrEqualTo(4.5),
        reason: '缓存清空后三段底色仍须对前景保持 AA（227 行清空前后的写入一致）',
      );
      expect(
        MusicFlowColors.contrastRatio(visuals.controlAccent, color),
        greaterThanOrEqualTo(3),
      );
    }
  });
}
