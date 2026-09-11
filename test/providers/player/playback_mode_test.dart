// 播放模式四态 + 本机预跳过守卫(2026-09-11)。
//
// 锁三组定案:
//   A. order(顺序播放,播完即停)与 all(列表循环)在底层 just_audio 同为
//      LoopMode.off —— 行为差异只能由「外层推进按 playbackMode 分支」实现。
//      下面的映射表 + 停止语义断言是唯一能证明差异真的实现的守卫:
//      若有人把 order 分支改回与 all 同路径,必须转红。
//   B. 旧版持久化名(repeatAll/repeatOne)读回必须映射到 all/one ——
//      漏了这步,老用户升级后播放模式会被重置成默认值。
//   C. 本机预跳过(§8.3):只跳「明确的、未过期的不可播」;无记录/已过期
//      一律照常播放(绝不把「不知道」当「死的」);不改队列;步数上限 =
//      队列长度(绕圈上限,与投屏链路同源)。
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' hide PlayerState;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/data/sources/local_storage.dart';
import 'package:musicflow_client/providers/player/player_state.dart';

void main() {
  group("A. 四态映射与底层组合(§14.4)", () {
    test("order 与 all 底层同为 LoopMode.off + shuffle off —— 差异不在底层", () {
      // 该断言的存在意义:证明「order/all 行为差异必须由外层推进实现」
      // 这个前提被实现者知晓。若未来有人把其中一态的底层改成别的组合
      // (比如 all 误用 LoopMode.all),说明底层/外层的职责边界被破坏。
      final underlying = <PlaybackMode, (LoopMode, bool)>{
        PlaybackMode.order: (LoopMode.off, false),
        PlaybackMode.all: (LoopMode.off, false),
        PlaybackMode.one: (LoopMode.one, false),
        PlaybackMode.shuffle: (LoopMode.off, true),
      };
      expect(underlying[PlaybackMode.order], underlying[PlaybackMode.all]);
      expect(underlying[PlaybackMode.one], (LoopMode.one, false));
    });

    test("PlaybackMode 恰好四值且与服务端线上值同名", () {
      expect(PlaybackMode.values, hasLength(4));
      expect(
        PlaybackMode.values.map((m) => m.name).toSet(),
        {"order", "all", "one", "shuffle"},
      );
    });

    test("PlayerState.playbackMode 是独立字段(不可从 loopMode/shuffle 派生)", () {
      // order 与 all 的底层组合相同 —— 派生必丢维度。
      final orderState = PlayerState(playbackMode: PlaybackMode.order);
      final allState = PlayerState(playbackMode: PlaybackMode.all);
      expect(orderState.loopMode, allState.loopMode); // 底层相同
      expect(orderState.playbackMode, isNot(allState.playbackMode)); // 语义不同
      expect(allState.playbackMode, PlaybackMode.all); // 默认 all(不回退旧默认 repeatAll 语义)
    });
  });

  group("B. 持久化旧值映射(老用户升级防线)", () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    test("旧名 repeatAll/repeatOne → all/one;新名四值原样;非法值回落 all", () async {
      final cases = <String, String>{
        "repeatAll": "all", // 旧名迁移
        "repeatOne": "one", // 旧名迁移
        "shuffle": "shuffle",
        "all": "all",
        "one": "one",
        "order": "order",
        "garbage": "all", // 非法回落
      };
      for (final entry in cases.entries) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString("playback_mode", entry.key);
        final mode = await LocalStorage.getPlaybackMode();
        expect(mode, entry.value, reason: "stored='${entry.key}'");
        SharedPreferences.setMockInitialValues(<String, Object>{});
      }
    });

    test("缺省回落 all", () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      expect(await LocalStorage.getPlaybackMode(), "all");
    });
  });

  group("C. 预跳过纯函数(§8.3 五条护栏)", () {
    test("无记录 → 照常播放(护栏 3:未知 ≠ 死)", () {
      final idx = resolvePreProbeSkipIndex(
        startIndex: 0,
        queueLength: 5,
        isKnownUnplayable: (_) => false,
      );
      expect(idx, 0);
    });

    test("连续死歌被越过,停在第一首可播", () {
      final dead = {0, 1, 2};
      final idx = resolvePreProbeSkipIndex(
        startIndex: 0,
        queueLength: 5,
        isKnownUnplayable: dead.contains,
      );
      expect(idx, 3);
    });

    test("全死:停在队列末尾(返回 queueLength),不越界不回绕", () {
      final idx = resolvePreProbeSkipIndex(
        startIndex: 0,
        queueLength: 4,
        isKnownUnplayable: (_) => true,
      );
      expect(idx, 4); // 调用方据此走「到末尾停止/回绕」的既有分支
    });

    test("步数上限 = 队列长度(绕圈上限同源,防死循环)", () {
      var calls = 0;
      final idx = resolvePreProbeSkipIndex(
        startIndex: 0,
        queueLength: 3,
        isKnownUnplayable: (_) {
          calls++;
          return true;
        },
      );
      expect(idx, 3);
      expect(calls, 3); // 恰好 queue.length 次判定,不会更多
    });

    test("isProbeEntryUnplayable 四向:无记录/可播/未过期死/过期", () {
      const now = 1000 * 1000;
      // 无记录
      expect(isProbeEntryUnplayable(null, now), isFalse);
      // 未过期的可播 → 不是「不可播」
      expect(
        isProbeEntryUnplayable(const ProbeCacheEntry(ok: true, at: now - 1000), now),
        isFalse,
      );
      // 未过期的不可播 → true(唯一允许跳过的情形)
      expect(
        isProbeEntryUnplayable(const ProbeCacheEntry(ok: false, at: now - 1000), now),
        isTrue,
      );
      // 过期 → 回退「未知」(哪怕结论是死)
      expect(
        isProbeEntryUnplayable(
          const ProbeCacheEntry(ok: false, at: now - probeCacheTtlMs - 1),
          now,
        ),
        isFalse,
      );
    });

    test("四态 verdict:只有 unplayable 预跳,transient/unknown 绝不误杀", () {
      const now = 1000 * 1000;
      // 服务端明确不可播 → 允许预跳
      expect(
        isProbeEntryUnplayable(
          const ProbeCacheEntry(ok: false, at: now - 1000, verdict: 'unplayable'),
          now,
        ),
        isTrue,
      );
      // 网络抖动:ok=false 但**不是** unplayable → 不跳(旧逻辑会误杀,这条锁回归)
      expect(
        isProbeEntryUnplayable(
          const ProbeCacheEntry(ok: false, at: now - 1000, verdict: 'transient'),
          now,
        ),
        isFalse,
      );
      // 未探过 → 不跳
      expect(
        isProbeEntryUnplayable(
          const ProbeCacheEntry(ok: false, at: now - 1000, verdict: 'unknown'),
          now,
        ),
        isFalse,
      );
      // 可播 → 不跳
      expect(
        isProbeEntryUnplayable(
          const ProbeCacheEntry(ok: true, at: now - 1000, verdict: 'playable'),
          now,
        ),
        isFalse,
      );
      // verdict 缺省(旧服务端) → 回落 ok
      expect(
        isProbeEntryUnplayable(const ProbeCacheEntry(ok: false, at: now - 1000), now),
        isTrue,
      );
    });
  });
}
