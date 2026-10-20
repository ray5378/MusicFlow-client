import 'package:musicflow_client/providers/player/transcoded_stream_seek.dart';
import 'package:flutter_test/flutter_test.dart';

// 作用域说明(2026-10-20):本文件的用例都以 `serverPipelinedHttp: false` 走到**格式/码率
// 比对分支**,描述的是**外部服务端**(Navidrome 等)「源格式相同且码率达标即可字节直传」
// 的启发式 —— 这条分支本服务端用不到(本服务端首行 `if (serverPipelinedHttp) return true`
// 就命中,见 lib/providers/player/transcoded_stream_seek.dart)。故服务端侧 2026-10-20 的
// 「显式档位一律转码」改动**不影响**本文件用例,两侧刻意分道,免得为本服务端的 D1 去
// 劣化外服务器的字节 seek。
void main() {
  group('shouldUseServerTimeOffsetSeek', () {
    test('detects explicit format transcoding', () {
      expect(
        shouldUseServerTimeOffsetSeek(
          requestedFormat: 'mp3',
          requestedMaxBitRate: 320,
          sourceFormat: 'flac',
          sourceBitRate: 1011,
        ),
        isTrue,
      );
    });

    test('keeps a matching source format below the limit seekable', () {
      expect(
        shouldUseServerTimeOffsetSeek(
          requestedFormat: 'mp3',
          requestedMaxBitRate: 320,
          sourceFormat: 'mp3',
          sourceBitRate: 192,
        ),
        isFalse,
      );
    });

    test('detects bitrate-limited transcoding', () {
      expect(
        shouldUseServerTimeOffsetSeek(
          requestedFormat: null,
          requestedMaxBitRate: 192,
          sourceFormat: 'flac',
          sourceBitRate: 1011,
        ),
        isTrue,
      );
    });

    test('normalizes source bitrate expressed in bps', () {
      expect(
        shouldUseServerTimeOffsetSeek(
          requestedFormat: null,
          requestedMaxBitRate: 192,
          sourceFormat: 'mp3',
          sourceBitRate: 320000,
        ),
        isTrue,
      );
    });

    test('keeps raw streams on ordinary byte seek', () {
      expect(
        shouldUseServerTimeOffsetSeek(
          requestedFormat: 'raw',
          requestedMaxBitRate: null,
          sourceFormat: 'flac',
          sourceBitRate: 1011,
        ),
        isFalse,
      );
    });

    test(
      'does not classify a source already below the limit as transcoded',
      () {
        expect(
          shouldUseServerTimeOffsetSeek(
            requestedFormat: null,
            requestedMaxBitRate: 192,
            sourceFormat: 'mp3',
            sourceBitRate: 128,
          ),
          isFalse,
        );
      },
    );
  });

  group('共享契约表（与服务器 decideTranscode 对齐）', () {
    // 与 MusicFlow 服务器 tests/services/transcode.test.ts 的共享契约表完全一致：
    // 同一输入下 should（客户端 shouldUseServerTimeOffsetSeek == 服务器 decideTranscode.should）
    // 必须两边相同。客户端 CI（transcode-chain.yml）与服务器 CI 同时跑这套用例，
    // 任一侧改动判定逻辑都会各自失败，防止链路漂移。
    const vectors = <({
      String? fmt,
      int? br,
      String? srcFmt,
      int? srcBr,
      bool expected,
    })>[
      (fmt: null, br: null, srcFmt: 'flac', srcBr: 1011, expected: false),
      (fmt: 'raw', br: null, srcFmt: 'flac', srcBr: 1011, expected: false),
      (fmt: 'mp3', br: 320, srcFmt: 'flac', srcBr: 1011, expected: true),
      (fmt: 'mp3', br: 320, srcFmt: 'mp3', srcBr: 192, expected: false),
      (fmt: 'mp3', br: null, srcFmt: 'mp3', srcBr: 320, expected: false),
      (fmt: 'aac', br: null, srcFmt: 'flac', srcBr: 1011, expected: true),
      (fmt: null, br: 192, srcFmt: 'flac', srcBr: 1011, expected: true),
      (fmt: null, br: 192, srcFmt: 'mp3', srcBr: 128, expected: false),
      (fmt: null, br: 1000, srcFmt: 'flac', srcBr: 900, expected: false),
      (fmt: 'mp3', br: 128, srcFmt: 'mp3', srcBr: 320, expected: true),
      (fmt: 'flac', br: null, srcFmt: 'flac', srcBr: 1011, expected: false),
      (fmt: null, br: 192, srcFmt: 'mp3', srcBr: 320000, expected: true),
      (fmt: 'aac', br: null, srcFmt: 'aac', srcBr: 256, expected: false),
    ];

    for (final v in vectors) {
      test(
        'fmt=${v.fmt} br=${v.br} src=${v.srcFmt} srcbr=${v.srcBr} → should=${v.expected}',
        () {
          expect(
            shouldUseServerTimeOffsetSeek(
              requestedFormat: v.fmt,
              requestedMaxBitRate: v.br,
              sourceFormat: v.srcFmt,
              sourceBitRate: v.srcBr,
            ),
            v.expected,
          );
        },
      );
    }
  });

  group('P2-3 服务端管道化能力判定', () {
    test('serverPipelinedHttp=true 时无条件走 timeOffset(格式一致也不例外)', () {
      // P2-1 后服务端即使格式码率全匹配,返回的也是实时流,字节 seek 必死。
      expect(
        shouldUseServerTimeOffsetSeek(
          requestedFormat: 'mp3',
          requestedMaxBitRate: 320,
          sourceFormat: 'mp3',
          sourceBitRate: 192,
          serverPipelinedHttp: true,
        ),
        isTrue,
      );
    });

    test('默认保持旧判定(共享契约表不受影响)', () {
      expect(
        shouldUseServerTimeOffsetSeek(
          requestedFormat: 'mp3',
          requestedMaxBitRate: 320,
          sourceFormat: 'mp3',
          sourceBitRate: 192,
        ),
        isFalse,
      );
    });

    test('serverPipesAllHttpStreams 只认服务端类型,不再看版本快照', () {
      // 非 MusicFlow 服务端(Navidrome)、类型未知:false。
      expect(
        serverPipesAllHttpStreams(
            serverType: 'navidrome', serverVersion: '0.60.0'),
        isFalse,
      );
      expect(
        serverPipesAllHttpStreams(serverType: null, serverVersion: '4.0.14'),
        isFalse,
      );
      // MusicFlow:一律 true —— 含 type 自报名带后缀、版本未知、**版本快照落后**。
      // 2026-09-23 事故:版本门控依赖登录时写一次的静态快照,服务端升级到管道化
      // 版本后老库永久判死 → 拖动重拉关闭 → Android「拖到哪都从头播」。
      for (final type in <String>['MusicFlow', 'musicflow', 'MusicFlow-web']) {
        for (final version in <String?>[
          '3.0.35',
          '3.0.46',
          '3.0.47',
          '3.1.0',
          '4.0.14',
          null,
          'dev',
        ]) {
          expect(
            serverPipesAllHttpStreams(serverType: type, serverVersion: version),
            isTrue,
            reason: 'type=$type version=$version',
          );
        }
      }
    });
  });

  group('D1(2026-10-20 任务A):未带 format 但服务端默认出 FLAC → 需 timeOffset', () {
    // 任务A:服务端默认输出编码已全局统一 FLAC —— 未带 format/码率时服务端也会
    // 转码出 FLAC(不可字节 seek)。客户端必须走 timeOffset 重拉、不得源内字节 seek、
    // 不得从头播放。实现上本服务端(MusicFlow*)一律 serverPipelinedHttp=true,
    // shouldUseServerTimeOffsetSeek 无条件 true → resolveSeekReloadPlan 必产出重拉计划。
    // 重拉计划本身的地址改写断言见 seek_reload_routing_test.dart 的「D1」组。
    test('未带 format + 未限码率 + 本服务端 → 判定为需 timeOffset(与源族无关)', () {
      for (final src in <String>['mp3', 'flac', 'ogg', 'm4a']) {
        expect(
          shouldUseServerTimeOffsetSeek(
            requestedFormat: null,
            requestedMaxBitRate: null,
            sourceFormat: src,
            sourceBitRate: 320,
            serverPipelinedHttp: true,
          ),
          isTrue,
          reason: 'src=$src',
        );
      }
    });
  });

  group('TranscodedStreamSeekTarget', () {
    test(
      'splits logical time into whole-second offset and source remainder',
      () {
        final target = TranscodedStreamSeekTarget.fromLogical(
          const Duration(milliseconds: 45070),
        );

        expect(target.serverOffset, const Duration(seconds: 45));
        expect(target.sourcePosition, const Duration(milliseconds: 70));
        expect(
          target.toLogical(const Duration(milliseconds: 292)),
          const Duration(milliseconds: 45292),
        );
      },
    );

    test('clamps logical positions to the song duration', () {
      final target = TranscodedStreamSeekTarget.fromLogical(
        const Duration(seconds: 150),
      );

      expect(
        target.toLogical(
          const Duration(seconds: 5),
          maximum: const Duration(seconds: 152),
        ),
        const Duration(seconds: 152),
      );
    });
  });
}
