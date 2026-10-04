// =============================================================================
// batch24 补测：seek（拖动进度条）落点里的「纯换算」部分
//
// 覆盖范围：lib/providers/player/transcoded_stream_seek.dart 里公开可导的纯
//           函数 / 纯类型（不需要宿主、不碰任何私有字段，零成本可达）：
//             · TranscodedStreamSeekTarget（fromLogical / toLogical）
//             · addPlaybackPositionOffset
//             · shouldUseServerTimeOffsetSeek
//
// 为什么只测这一块：同目录的 player_seek.dart 只有一个 mixin
// （mixin PlayerSeekInternals on PlayerNotifier），体内直接读写 PlayerNotifier 的
// 「库私有」成员；Dart 私有名按库隔离 + PlayerNotifier 基类构造体不可覆写，
// 导致测试库造不出可接管状态的宿主（本批把四条路线全部走完证伪，详见
// outputs/b24-final-report.md 与 outputs/b24-seek-doc.md）。
// 所以本批先把「seek 落点里唯一能零成本单测」的部分钉死，mixin 本体留给下一批
// 按 b24-seek-doc.md 第八节给 mixin 加 accessor 之后再动。
//
// 性质：纯增量新增，不修改任何已有测试。
// =============================================================================
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/providers/player/transcoded_stream_seek.dart';

void main() {
  group(
    '一、TranscodedStreamSeekTarget：逻辑位置 ↔ 服务器拉取偏移 ↔ 引擎源位置',
    () {
      test(
        'fromLogical：serverOffset 取「整秒」的整数部分，'
        'sourcePosition 就是「不够一秒」的余数（拖到 90s → 服务器从 90s 起拉，'
        '引擎再播 0s）',
        () {
          final target =
              TranscodedStreamSeekTarget.fromLogical(Duration(seconds: 90));

          expect(target.logicalPosition, const Duration(seconds: 90));
          expect(target.serverOffset, const Duration(seconds: 90));
          expect(target.sourcePosition, Duration.zero);
        },
      );

      test(
        'fromLogical：带毫秒的目标 —— serverOffset 只认整秒，'
        'sourcePosition 把那点毫秒接住（否则会丢）',
        () {
          final target = TranscodedStreamSeekTarget.fromLogical(
            const Duration(milliseconds: 90500), // 90.5s
          );

          // 90.5s → 整秒 90s 走 timeOffset 重拉
          expect(target.serverOffset, const Duration(seconds: 90));
          // 多出来的 500ms 不从服务器拿，得让本地引擎接着播
          expect(target.sourcePosition, const Duration(milliseconds: 500));
        },
      );

      test(
        'fromLogical：负目标 —— 归一到 0，serverOffset / sourcePosition 一块归零，'
        '不吐负数',
        () {
          final target = TranscodedStreamSeekTarget.fromLogical(
            const Duration(seconds: -20),
          );

          expect(target.logicalPosition, Duration.zero);
          expect(target.serverOffset, Duration.zero);
          expect(target.sourcePosition, Duration.zero);
        },
      );

      test(
        'toLogical：引擎回报的「源位置 + 服务器偏移 = 逻辑位置」回读换算',
        () {
          final target =
              TranscodedStreamSeekTarget.fromLogical(Duration(seconds: 90));

          // 源位置是「重拉起播后引擎报的秒」，要加回 serverOffset 才是逻辑位置。
          expect(target.toLogical(const Duration(seconds: 10)), const Duration(seconds: 100));
          expect(target.toLogical(const Duration(seconds: 50)), const Duration(seconds: 140));
          expect(
            target.toLogical(const Duration(seconds: -20)),
            const Duration(seconds: 70),
            reason: '合计为负才归零，不是把入参当负数吞掉',
          );
        },
      );

      test(
        'toLogical：maximum 兜底 —— 超出曲目末尾的那点回读值被截到末尾',
        () {
          final target =
              TranscodedStreamSeekTarget.fromLogical(Duration(seconds: 90));

          // 10s + 90s = 100s，但整首只有 95s
          expect(
            target.toLogical(
              const Duration(seconds: 10),
              maximum: const Duration(seconds: 95),
            ),
            const Duration(seconds: 95),
          );
          // 没超就原样返回
          expect(
            target.toLogical(
              const Duration(seconds: 10),
              maximum: const Duration(seconds: 120),
            ),
            const Duration(seconds: 100),
          );
        },
      );
    },
  );

  group('二、addPlaybackPositionOffset：把「源位置 + 偏移」合成逻辑位置', () {
    test('正常相加，负值合计归零（不是吐负数）', () {
      expect(
        addPlaybackPositionOffset(
          const Duration(seconds: -20),
          const Duration(seconds: 90),
        ),
        const Duration(seconds: 70),
      );
      expect(
        addPlaybackPositionOffset(
          const Duration(seconds: -150),
          const Duration(seconds: 90),
        ),
        Duration.zero,
      );
    });

    test('maximum 只在「逻辑位置被加过头」时截住', () {
      expect(
        addPlaybackPositionOffset(
          const Duration(seconds: 90),
          const Duration(seconds: 90),
          maximum: const Duration(seconds: 100),
        ),
        const Duration(seconds: 100),
      );
      // 没超 maximum 就不动
      expect(
        addPlaybackPositionOffset(
          const Duration(seconds: 90),
          const Duration(seconds: 90),
          maximum: const Duration(seconds: 500),
        ),
        const Duration(seconds: 180),
      );
      // maximum 为 0 / 负数时视为「不限」，由调用方自己兜
      expect(
        addPlaybackPositionOffset(
          const Duration(seconds: 90),
          const Duration(seconds: 90),
          maximum: Duration.zero,
        ),
        const Duration(seconds: 180),
      );
    });
  });

  group(
    '三、shouldUseServerTimeOffsetSeek：这条流能不能「按服务器偏移重拉」',
    () {
      test(
        'serverPipelinedHttp=true —— 无条件走 timeOffset 重拉'
        '（服务端全通道实时管道，格式一致也没用）',
        () {
          expect(
            shouldUseServerTimeOffsetSeek(
              requestedFormat: 'mp3',
              requestedMaxBitRate: 320,
              sourceFormat: 'mp3',
              sourceBitRate: 320,
              serverPipelinedHttp: true,
            ),
            isTrue,
          );
          expect(
            shouldUseServerTimeOffsetSeek(
              requestedFormat: 'raw',
              requestedMaxBitRate: null,
              sourceFormat: 'flac',
              sourceBitRate: 1411,
              serverPipelinedHttp: true,
            ),
            isTrue,
          );
        },
      );

      test(
        '格式一致 + 码率不限 —— 可以复用原流，不用 timeOffset 重拉',
        () {
          expect(
            shouldUseServerTimeOffsetSeek(
              requestedFormat: 'mp3',
              requestedMaxBitRate: null,
              sourceFormat: 'MP3',
              sourceBitRate: 320,
            ),
            isFalse,
          );
        },
      );

      test(
        '格式一致 + 但要求的码率比源还低 —— 会真转码，必须 timeOffset 重拉',
        () {
          expect(
            shouldUseServerTimeOffsetSeek(
              requestedFormat: 'mp3',
              requestedMaxBitRate: 64,
              sourceFormat: 'mp3',
              sourceBitRate: 320,
            ),
            isTrue,
          );
        },
      );

      test(
        '格式不一致 —— 服务器一定会转码，这条流不可字节 seek，必须重拉',
        () {
          expect(
            shouldUseServerTimeOffsetSeek(
              requestedFormat: 'flac',
              requestedMaxBitRate: null,
              sourceFormat: 'mp3',
              sourceBitRate: 320,
            ),
            isTrue,
          );
        },
      );

      test(
        'raw 走「纯码率」分支：请求码率低于源码率 → 会转码 → 重拉',
        () {
          expect(
            shouldUseServerTimeOffsetSeek(
              requestedFormat: 'raw',
              requestedMaxBitRate: 128,
              sourceFormat: 'flac',
              sourceBitRate: 1411,
            ),
            isTrue,
          );
        },
      );

      test(
        'raw + 请求码率不限（null）：不会转码，可以直接字节 seek',
        () {
          expect(
            shouldUseServerTimeOffsetSeek(
              requestedFormat: 'raw',
              requestedMaxBitRate: null,
              sourceFormat: 'flac',
              sourceBitRate: 1411,
            ),
            isFalse,
          );
        },
      );

      test(
        'raw + 请求码率高于源码率：服务器不会「升码」，也可以直接字节 seek',
        () {
          expect(
            shouldUseServerTimeOffsetSeek(
              requestedFormat: 'raw',
              requestedMaxBitRate: 1920,
              sourceFormat: 'flac',
              sourceBitRate: 1411,
            ),
            isFalse,
          );
        },
      );

      test(
        '降级旋钮：serverPipelinedHttp 默认 false，'
        '服务端能力没探测到时按旧格式/码率结论走',
        () {
          expect(
            shouldUseServerTimeOffsetSeek(
              requestedFormat: 'mp3',
              requestedMaxBitRate: null,
              sourceFormat: 'mp3',
              sourceBitRate: 320,
            ),
            isFalse,
          );
        },
      );
    },
  );
}
