#ifndef MUSICFLOW_DESKTOP_LYRIC_LOGIC_H_
#define MUSICFLOW_DESKTOP_LYRIC_LOGIC_H_

// 桌面歌词浮窗纯逻辑(刻意不依赖 windows.h / GDI+):
// 描边色自适应、跑马灯滚动时序、单击/拖动阈值判定。
// 独立成无平台依赖的头,便于 tool/desktop_lyric_logic_test.cc 用任意
// 标准 C++ 编译器(g++ / MSVC)直接单测,CI 上无需 Windows 环境。

namespace dllogic {

// 歌词 RGB 分量(0-255)。
struct LyricRgb {
  int r;
  int g;
  int b;
};

// 歌词描边色随填充色自适应(Rec.601 亮度):
//   亮字(lum >= 150,如暖黄 accent)→ 同色相向黑收深到 45%,浅色壁纸不糊;
//   暗字(lum < 150)→ 向白提亮 75%,保持边缘清晰。
inline LyricRgb LyricStrokeColorFor(int r, int g, int b) {
  const double lum = 0.299 * r + 0.587 * g + 0.114 * b;
  if (lum >= 150.0) {
    const auto darken = [](int c) { return static_cast<int>(c * 0.45 + 0.5); };
    return {darken(r), darken(g), darken(b)};
  }
  const auto lighten = [](int c) {
    return static_cast<int>(c + (255 - c) * 0.75 + 0.5);
  };
  return {lighten(r), lighten(g), lighten(b)};
}

// 跑马灯当前偏移(px,方案 A):句首停 holdMs → 以 speedPxPerSec 匀速左滚
// overflow → 句尾停 holdMs → 循环。
//   overflow      歌词超出可用宽度的像素数(<=2 视为不超宽,偏移恒 0)
//   elapsedMs     距本轮循环起点的毫秒数
// speed<=0 或滚动周期退化为 0 时直接返回 0,绝无除零路径。
inline double MarqueeOffsetPx(double overflow, double speedPxPerSec,
                              unsigned long long holdMs,
                              unsigned long long elapsedMs) {
  if (overflow <= 2.0) return 0.0;
  if (speedPxPerSec <= 0.0) return 0.0;
  const unsigned long long scrollMs =
      static_cast<unsigned long long>(overflow / speedPxPerSec * 1000.0);
  if (scrollMs == 0) return 0.0;
  const unsigned long long total = holdMs + scrollMs + holdMs;
  const unsigned long long p = elapsedMs % total;
  if (p < holdMs) return 0.0;
  if (p < holdMs + scrollMs) {
    return overflow * static_cast<double>(p - holdMs) /
           static_cast<double>(scrollMs);
  }
  return overflow;
}

// 按下后位移是否超出单击阈值:超出 = 判定为拖动窗口,未超出 = 原地单击
// (开关主窗口)。欧氏距离平方与阈值平方比较,避免开方。
inline bool MovedBeyondThreshold(int dx, int dy, int threshold) {
  return dx * dx + dy * dy > threshold * threshold;
}

}  // namespace dllogic

#endif  // MUSICFLOW_DESKTOP_LYRIC_LOGIC_H_
