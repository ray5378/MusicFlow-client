import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_app/core/format.dart';
import 'package:musicflow_app/core/theme.dart';

void main() {
  test('字体规格对齐箭头音乐（26/19/15/13/12/11）', () {
    final t = AppTypography(Brightness.light);
    expect(t.display.fontSize, 26);
    expect(t.headline.fontSize, 19);
    expect(t.title.fontSize, 15);
    expect(t.body.fontSize, 13);
    expect(t.label.fontSize, 12);
    expect(t.meta.fontSize, 11);
  });

  test('主题可构建', () {
    expect(AppTypography(Brightness.light).theme(), isA<ThemeData>());
    expect(AppTypography(Brightness.dark).theme().brightness, Brightness.dark);
  });

  test('时长格式化', () {
    expect(Fmt.duration(235), '3:55');
    expect(Fmt.duration(3723), '1:02:03');
    expect(Fmt.duration(null), '0:00');
  });

  test('音质行拼接（对齐箭头音乐样式）', () {
    final line = Fmt.qualityLine(
      suffix: 'flac',
      bitRateKbps: 138,
      size: 29_818_880,
      durationSeconds: 235,
    );
    expect(line, 'Lossless • 138kbps • FLAC • 28.44M • 3:55');

    expect(Fmt.qualityLine(suffix: 'mp3'), 'MP3');
  });
}
