// 桌面歌词纯逻辑单元测试(无框架,任意标准 C++17 编译器可编)。
//
// 覆盖 windows/runner/desktop_lyric_logic.h 的三个纯函数:
//   - LyricStrokeColorFor : 描边色随填充色亮度自适应(亮字收深/暗字提亮)
//   - MarqueeOffsetPx     : 跑马灯 时序(句首/句尾停 1.8s + 匀速滚 + 循环)
//   - MovedBeyondThreshold: 按下位移阈值(单击 vs 拖动窗口判定)
//
// CI: desktop-lyric-guard.yml / native-logic-tests (ubuntu, g++ -Werror)
// 本地: cl /EHsc /std:c++17 tool/desktop_lyric_logic_test.cc && test.exe
#include "../windows/runner/desktop_lyric_logic.h"

#include <cstdio>

namespace {

int g_checks = 0;
int g_failures = 0;

void ExpectNear(double actual, double expected, const char* what) {
  ++g_checks;
  const double diff = actual > expected ? actual - expected : expected - actual;
  if (diff > 1e-6) {
    ++g_failures;
    std::printf("FAIL %s: actual=%.6f expected=%.6f\n", what, actual,
                expected);
  }
}

void ExpectTrue(bool cond, const char* what) {
  ++g_checks;
  if (!cond) {
    ++g_failures;
    std::printf("FAIL %s\n", what);
  }
}

void ExpectRgb(const dllogic::LyricRgb& c, int r, int g, int b,
               const char* what) {
  ++g_checks;
  if (c.r != r || c.g != g || c.b != b) {
    ++g_failures;
    std::printf("FAIL %s: got=(%d,%d,%d) expected=(%d,%d,%d)\n", what, c.r,
                c.g, c.b, r, g, b);
  }
}

void TestStrokeColor() {
  // 暖黄 accent(240,197,90):lum≈197.7 ≥150 → 同色相收深 45%。
  ExpectRgb(dllogic::LyricStrokeColorFor(240, 197, 90), 108, 89, 41,
            "stroke: warm amber darkened");
  // 深色(30,40,50):lum≈38 <150 → 向白提亮 75%。
  ExpectRgb(dllogic::LyricStrokeColorFor(30, 40, 50), 199, 201, 204,
            "stroke: dark color lightened");
  // 亮度边界 150:恰在阈值上走收深分支(>=)。
  ExpectRgb(dllogic::LyricStrokeColorFor(150, 150, 150), 68, 68, 68,
            "stroke: lum==150 boundary darkens");
  // 黑色下限:提亮到 75% 灰,绝不出 0(保证可见描边)。
  ExpectRgb(dllogic::LyricStrokeColorFor(0, 0, 0), 191, 191, 191,
            "stroke: black lightened to visible gray");
  // 白色上限:收深到 45% 灰,浅色壁纸上仍有对比。
  ExpectRgb(dllogic::LyricStrokeColorFor(255, 255, 255), 115, 115, 115,
            "stroke: white darkened");
}

void TestMarquee() {
  const double overflow = 100.0;
  const double speed = 40.0;  // px/s → 100px 滚 2500ms
  // 不超宽(<=2)恒为 0,任何时刻都不滚。
  ExpectNear(dllogic::MarqueeOffsetPx(2.0, speed, 1800, 999999), 0.0,
             "marquee: overflow==2 stays put");
  ExpectNear(dllogic::MarqueeOffsetPx(1.9, speed, 1800, 123456), 0.0,
             "marquee: overflow<2 stays put");
  // 速度退化(<=0)直接不滚,绝无除零。
  ExpectNear(dllogic::MarqueeOffsetPx(overflow, 0.0, 1800, 5000), 0.0,
             "marquee: zero speed guard");
  // 句首停留:前 1.8s 偏移 0。
  ExpectNear(dllogic::MarqueeOffsetPx(overflow, speed, 1800, 0), 0.0,
             "marquee: head hold start");
  ExpectNear(dllogic::MarqueeOffsetPx(overflow, speed, 1800, 1799), 0.0,
             "marquee: head hold end");
  // 匀速滚动段:线性推进。
  ExpectNear(dllogic::MarqueeOffsetPx(overflow, speed, 1800, 1800), 0.0,
             "marquee: scroll phase starts at 0");
  ExpectNear(dllogic::MarqueeOffsetPx(overflow, speed, 1800, 3050), 50.0,
             "marquee: scroll phase midpoint");
  ExpectNear(dllogic::MarqueeOffsetPx(overflow, speed, 1800, 4299), 99.96,
             "marquee: scroll phase near end");
  // 句尾停留:滚完后停在句尾。
  ExpectNear(dllogic::MarqueeOffsetPx(overflow, speed, 1800, 4300), 100.0,
             "marquee: tail hold start");
  ExpectNear(dllogic::MarqueeOffsetPx(overflow, speed, 1800, 6099), 100.0,
             "marquee: tail hold end");
  // 循环回绕:一个周期后从头再来。
  ExpectNear(dllogic::MarqueeOffsetPx(overflow, speed, 1800, 6100), 0.0,
             "marquee: wraps to head");
  ExpectNear(dllogic::MarqueeOffsetPx(overflow, speed, 1800, 6100 + 3050), 50.0,
             "marquee: second cycle midpoint");
}

void TestTapThreshold() {
  // 阈值内:原地单击(开/关主窗口)。
  ExpectTrue(!dllogic::MovedBeyondThreshold(0, 0, 6), "tap: no move");
  ExpectTrue(!dllogic::MovedBeyondThreshold(3, 4, 6), "tap: dist==threshold");
  ExpectTrue(!dllogic::MovedBeyondThreshold(4, 4, 6), "tap: within threshold");
  // 阈值外:判定为拖动窗口。
  ExpectTrue(dllogic::MovedBeyondThreshold(6, 0, 5), "drag: axis move");
  ExpectTrue(dllogic::MovedBeyondThreshold(-4, -5, 6), "drag: negative dir");
}

}  // namespace

int main() {
  TestStrokeColor();
  TestMarquee();
  TestTapThreshold();
  std::printf("desktop_lyric_logic: %d checks, %d failures\n", g_checks,
              g_failures);
  return g_failures == 0 ? 0 : 1;
}
