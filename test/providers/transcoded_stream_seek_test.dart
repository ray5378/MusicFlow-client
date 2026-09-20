import 'package:musicflow_client/providers/player/transcoded_stream_seek.dart';
import 'package:flutter_test/flutter_test.dart';

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

    test('serverPipesAllHttpStreams 版本门控', () {
      // 非 MusicFlow 服务端(Navidrome):一律 false。
      expect(
        serverPipesAllHttpStreams(
            serverType: 'navidrome', serverVersion: '0.60.0'),
        isFalse,
      );
      // MusicFlow 老版本:直传仍在,false。
      expect(
        serverPipesAllHttpStreams(
            serverType: 'MusicFlow', serverVersion: '3.0.46'),
        isFalse,
      );
      expect(
        serverPipesAllHttpStreams(
            serverType: 'musicflow', serverVersion: '3.0.35'),
        isFalse,
      );
      // 管道首版及之后:true(含跳号 3.1.0)。
      expect(
        serverPipesAllHttpStreams(
            serverType: 'MusicFlow', serverVersion: '3.0.47'),
        isTrue,
      );
      expect(
        serverPipesAllHttpStreams(
            serverType: 'musicflow', serverVersion: '3.1.0'),
        isTrue,
      );
      // 未知/非法版本:保守 false。
      expect(serverPipesAllHttpStreams(serverType: 'MusicFlow', serverVersion: null), isFalse);
      expect(serverPipesAllHttpStreams(serverType: 'MusicFlow', serverVersion: 'dev'), isFalse);
      expect(serverPipesAllHttpStreams(serverType: null, serverVersion: '3.0.47'), isFalse);
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
